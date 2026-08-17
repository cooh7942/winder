import Foundation
import AppKit
import Observation

/// 창 하나의 탐색 상태 — 경로, 히스토리, 파일 목록, 선택, 파일 작업
@Observable
@MainActor
final class TabViewModel: Identifiable {
    let id: UUID = UUID()

    // MARK: - 탭 메타
    // init에서 location에 맞게 덮어쓰므로 여기 값은 초기화 순서를 만족시키기 위한 것
    var tabTitle: String = ShellLocation.home.displayName
    var tabIcon: String  = ShellLocation.home.systemIcon

    // MARK: - 탐색 상태
    // 기본 시작 위치는 홈 — ExplorerWindowViewModel도 .home으로 생성한다
    var location: ShellLocation = .home
    var history: NavigationHistory
    var items: [FileItem] = []
    /// 검색어 — 비어 있지 않으면 items가 이름으로 걸러진다
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            applySearchFilter()
        }
    }
    /// 걸러지기 전 원본 목록 — 검색어를 지우면 이걸로 되돌린다
    private var loadedItems: [FileItem] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    /// A-2: 전체 디스크 접근 권한 부족 — listDirectory가 EPERM/EACCES 오류를 던질 때 설정
    var needsFullDiskAccess: Bool = false

    /// DetailsView가 이 값만 비교해 전체 id 배열 생성·비교 비용을 없앤다.
    private(set) var contentVersion: Int = 0

    // MARK: - 선택
    var selectedIDs: Set<String> = []
    var selectedItems: [FileItem] { items.filter { selectedIDs.contains($0.id) } }
    var hasSelection: Bool { !selectedIDs.isEmpty }

    // MARK: - 보기/정렬
    /// 기본값은 자세히 — 폴더마다 따로 기억되며, 기록이 없는 폴더는 이 값으로 열린다
    var viewMode: ViewMode = .details {
        didSet {
            guard viewMode != oldValue else { return }
            // 복원 중에는 방금 읽어온 값을 그대로 되쓰게 되므로 건너뛴다
            guard !isRestoringViewMode else { return }
            FolderViewModeStore.shared.setMode(viewMode, for: currentURL)
        }
    }
    /// 폴더 이동에 따른 보기 모드 복원 중인지 — 저장 재진입 방지
    private var isRestoringViewMode = false
    var sortDescriptor: FileSortDescriptor = FileSortDescriptor()
    var showHiddenFiles: Bool = false

    // MARK: - 주소창 편집 모드
    var isEditingAddress: Bool = false
    var addressInput: String = ""

    // MARK: - 파일 작업 UI 상태
    /// 삭제 확인 다이얼로그 표시 여부
    var confirmingDelete: Bool = false
    /// 영구 삭제 확인 다이얼로그 표시 여부 (⇧Delete)
    var confirmingPermanentDelete: Bool = false
    /// 현재 인라인 이름 변경 중인 항목 ID — DetailsView가 rename 모드 진입에 사용
    var renamingItemID: String? = nil
    /// 붙여넣기/복사 진행 중 여부 (100+ 항목 시 진행 시트 표시)
    var isPasteInProgress: Bool = false
    /// 붙여넣기 진행률 (isPasteInProgress == true 일 때 유효)
    var pasteProgress: OperationProgress? = nil

    // MARK: - FSEvents 감시
    private var fileWatcher: FileWatcher?
    private var watcherTask: Task<Void, Never>?
    /// 현재 감시 중인 URL — 동일 URL 재시작으로 인한 churn 방지
    private var watchedURL: URL?

    // MARK: - 히스토리 접근자
    var canGoBack: Bool    { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var currentURL: URL?   { location.url }

    var pathSegments: [PathSegment] {
        guard let url = currentURL else {
            return [PathSegment(displayName: location.displayName, url: nil)]
        }
        return makePathSegments(from: url)
    }

    init(location: ShellLocation = .home) {
        self.location = location
        let startURL = location.url ?? FileManager.default.homeDirectoryForCurrentUser
        self.history = NavigationHistory(initial: startURL)
        self.tabTitle = location.displayName
        self.tabIcon  = location.systemIcon
        // 시작 폴더에 기억된 보기 모드로 연다
        self.viewMode = FolderViewModeStore.shared.mode(for: location.url)
    }

    /// 폴더가 바뀔 때 그 폴더에 기억된 보기 모드로 전환 — 기록이 없으면 자세히
    private func restoreViewMode(for url: URL?) {
        isRestoringViewMode = true
        viewMode = FolderViewModeStore.shared.mode(for: url)
        isRestoringViewMode = false
    }

    // MARK: - 탐색

    func navigate(to newLocation: ShellLocation) {
        location = newLocation
        tabTitle  = newLocation.displayName
        tabIcon   = newLocation.systemIcon
        restoreViewMode(for: newLocation.url)
        searchQuery = ""
        selectedIDs.removeAll()
        renamingItemID = nil
        if let url = newLocation.url { history.navigate(to: url) }
        Task { await loadItems() }
    }

    func navigate(to url: URL) { navigate(to: .path(url)) }

    func goBack() {
        guard let url = history.goBack() else { return }
        location = .path(url)
        tabTitle  = FileManager.default.displayName(atPath: url.path)
        tabIcon   = FluentIcons.folder
        restoreViewMode(for: url)
        searchQuery = ""
        selectedIDs.removeAll()
        renamingItemID = nil
        Task { await loadItems() }
    }

    func goForward() {
        guard let url = history.goForward() else { return }
        location = .path(url)
        tabTitle  = FileManager.default.displayName(atPath: url.path)
        tabIcon   = FluentIcons.folder
        restoreViewMode(for: url)
        searchQuery = ""
        selectedIDs.removeAll()
        renamingItemID = nil
        Task { await loadItems() }
    }

    func goUp() {
        guard let url = currentURL, url.pathComponents.count > 1 else { return }
        navigate(to: url.deletingLastPathComponent())
    }

    func reload() { Task { await loadItems() } }

    // MARK: - 정렬

    func sort(by key: SortKey) {
        if sortDescriptor.key == key {
            sortDescriptor.ascending.toggle()
        } else {
            sortDescriptor = FileSortDescriptor(key: key, ascending: true)
        }
        loadedItems = FileSystemService.shared.sort(loadedItems, by: sortDescriptor)
        items = filtered(loadedItems)
        contentVersion += 1
    }

    // MARK: - 검색

    private func filtered(_ source: [FileItem]) -> [FileItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return source }
        return source.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private func applySearchFilter() {
        items = filtered(loadedItems)
        selectedIDs = selectedIDs.intersection(Set(items.map(\.id)))
        contentVersion += 1
    }

    func clearSearch() {
        guard !searchQuery.isEmpty else { return }
        searchQuery = ""
    }

    // MARK: - 파일 열기

    func openItem(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - 파일 작업 (3-3)

    /// 선택 항목 이름 변경
    func renameItem(_ item: FileItem, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        // item.name과 비교 (displayName은 지역화 이름이므로 실제 파일 이름과 다를 수 있음)
        guard !trimmed.isEmpty, trimmed != item.name else {
            renamingItemID = nil
            return
        }
        // 유효성 검사: 파일 이름에 금지된 문자
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            errorMessage = "파일 이름에 '/' 또는 ':'를 사용할 수 없습니다."
            renamingItemID = nil
            return
        }
        // 255바이트 제한 (대부분 파일 시스템 공통 제한)
        guard trimmed.utf8.count <= 255 else {
            errorMessage = "파일 이름이 너무 깁니다. (최대 255바이트)"
            renamingItemID = nil
            return
        }
        // 같은 디렉토리 내 이름 충돌 검사 (대소문자 무시, 자기 자신 제외)
        let lower = trimmed.lowercased()
        if items.first(where: { $0.id != item.id && $0.name.lowercased() == lower }) != nil {
            errorMessage = "'\(trimmed)' 이름의 파일이 이미 있습니다."
            renamingItemID = nil
            return
        }
        renamingItemID = nil
        let oldURL = item.url
        do {
            let newURL = try await FileOperationService.shared.rename(item: item, to: trimmed)
            UndoService.shared.push(.init(description: "이름 바꾸기") {
                try FileManager.default.moveItem(at: newURL, to: oldURL)
            })
            await loadItems(preservingSelection: [newURL.path])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 선택 항목을 휴지통으로 이동
    func trashSelected() async {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        confirmingDelete = false
        do {
            let trashedURLs = try await FileOperationService.shared.trash(items: targets)
            let originalURLs = targets.map(\.url)
            // moveItem으로 휴지통에서 원위치 복원 가능
            if !trashedURLs.isEmpty {
                UndoService.shared.push(.init(description: "삭제") {
                    try await Task.detached(priority: .userInitiated) {
                        for (trashURL, origURL) in zip(trashedURLs, originalURLs) {
                            try FileManager.default.moveItem(at: trashURL, to: origURL)
                        }
                    }.value
                })
            }
            selectedIDs.removeAll()  // 성공 후 선택 해제
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 선택 항목 영구 삭제 (⇧Delete) — 휴지통 거치지 않고 즉시 제거, 되돌리기 불가
    func permanentlyDeleteSelected() async {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        confirmingPermanentDelete = false
        do {
            let urls = targets.map(\.url)
            try await Task.detached(priority: .userInitiated) {
                for url in urls {
                    try FileManager.default.removeItem(at: url)
                }
            }.value
            selectedIDs.removeAll()
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 새 폴더 만들기 (완료 후 자동으로 이름 변경 모드 진입)
    func createFolder() async {
        guard let url = currentURL else { return }
        do {
            let folderURL = try await FileOperationService.shared.createFolder(in: url)
            UndoService.shared.push(.init(description: "새 폴더") {
                try FileManager.default.removeItem(at: folderURL)
            })
            await loadItems()
            selectedIDs = [folderURL.path]
            renamingItemID = folderURL.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 새 텍스트 파일 만들기 (완료 후 자동으로 이름 변경 모드 진입)
    func createTextFile() async {
        guard let url = currentURL else { return }
        do {
            let fileURL = try await FileOperationService.shared.createTextFile(in: url)
            UndoService.shared.push(.init(description: "새 파일") {
                try FileManager.default.removeItem(at: fileURL)
            })
            await loadItems()
            selectedIDs = [fileURL.path]
            renamingItemID = fileURL.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 클립보드 (3-4)

    func copySelected() {
        ClipboardService.shared.copy(items: selectedItems)
    }

    func cutSelected() {
        ClipboardService.shared.cut(items: selectedItems)
    }

    func paste() async {
        guard let url = currentURL else { return }
        let clipboard = ClipboardService.shared
        let urls = clipboard.pasteURLs()
        guard !urls.isEmpty else { return }
        do {
            if clipboard.isCutOperation {
                // 이동 (잘라내기+붙여넣기)
                let srcURLs = clipboard.cutItems.map(\.url)
                let moved = try await FileOperationService.shared.moveItems(srcURLs, to: url)
                clipboard.clearCutState()
                if !moved.isEmpty {
                    UndoService.shared.push(.init(description: "이동") {
                        // 실제 이동된 URL(pair.to)을 원위치(pair.from)로 되돌림
                        try await Task.detached(priority: .userInitiated) {
                            for pair in moved.reversed() {
                                try FileManager.default.moveItem(at: pair.to, to: pair.from)
                            }
                        }.value
                    })
                }
            } else {
                // 복사 — 100개 이상 항목은 진행 시트 표시
                let showProgress = urls.count >= 100
                if showProgress {
                    isPasteInProgress = true
                    pasteProgress = OperationProgress(current: 0, total: urls.count, fileName: "")
                }
                defer {
                    isPasteInProgress = false
                    pasteProgress = nil
                }
                // copyItems가 반환한 실제 생성 URL만 undo 대상으로 삼음
                // removeItem 대신 trashItem: 기존 파일을 실수로 지우는 사고 방지
                let created = try await FileOperationService.shared.copyItems(urls, to: url) { [weak self] p in
                    self?.pasteProgress = p
                }
                UndoService.shared.push(.init(description: "복사") {
                    // trashItem 실패는 개별적으로 무시하므로 detached Task 자체는 throw하지 않는다
                    await Task.detached(priority: .userInitiated) {
                        for createdURL in created {
                            try? FileManager.default.trashItem(at: createdURL, resultingItemURL: nil)
                        }
                    }.value
                })
            }
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 취소 (3-5)

    func undoLastAction() {
        Task {
            await UndoService.shared.performUndo()
            await loadItems()
        }
    }

    // MARK: - 속성 (3-7)

    func openProperties() {
        guard let item = selectedItems.first else { return }
        PropertiesWindowController.show(for: item)
    }

    // MARK: - 전체 선택

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
    }

    // MARK: - FSEvents 감시

    func startWatching() {
        guard let url = currentURL, url != watchedURL else { return }
        stopWatching()
        watchedURL = url
        let watcher = FileWatcher()
        fileWatcher = watcher
        watcherTask = Task {
            for await _ in watcher.watch(url: url) {
                let preserved = selectedIDs
                await loadItems(preservingSelection: preserved)
            }
        }
    }

    // 창 종료·위치 변경 시 반드시 호출 — FSEventStream 누수 방지
    func stopWatching() {
        fileWatcher?.stop()
        fileWatcher = nil
        watcherTask?.cancel()
        watcherTask = nil
        watchedURL = nil
    }

    // MARK: - Private

    func loadItems(preservingSelection: Set<String>? = nil) async {
        guard let url = currentURL else {
            loadedItems = []
            items = []
            stopWatching()
            return
        }
        isLoading = true
        errorMessage = nil
        needsFullDiskAccess = false
        do {
            let fetched = try await FileSystemService.shared.listDirectory(
                at: url, showHidden: showHiddenFiles
            )
            let sorted = FileSystemService.shared.sort(fetched, by: sortDescriptor)
            // A-3: id + dateModified + size 비교 — 내용이 같으면 reloadData() 생략
            let changed = sorted.count != items.count ||
                zip(sorted, items).contains { new, old in
                    new.id != old.id || new.dateModified != old.dateModified || new.size != old.size
                }
            loadedItems = sorted
            items = filtered(sorted)
            if changed { contentVersion += 1 }
            if let preserved = preservingSelection {
                let existingPaths = Set(sorted.map(\.id))
                selectedIDs = preserved.intersection(existingPaths)
            }
            await IconProvider.shared.loadIcons(for: Array(sorted.prefix(80)))
        } catch {
            if isPermissionError(error) {
                needsFullDiskAccess = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
        startWatching()
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // EACCES(13) / EPERM(1) — NSPOSIXErrorDomain
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == 13 || nsError.code == 1) { return true }
        // NSFileReadNoPermissionError(257) — NSCocoaErrorDomain
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 257 { return true }
        return false
    }

    // ⚠️ deletingLastPathComponent() 루프 금지 — URL("/").deletingLastPathComponent()가
    // "/.."를 반환하며 무한히 자라기 때문에 종료 조건이 성립하지 않는다.
    // pathComponents는 유한 배열이므로 이 방식은 항상 안전하게 종료된다.
    private func makePathSegments(from url: URL) -> [PathSegment] {
        let fm = FileManager.default
        let components = url.standardizedFileURL.pathComponents
        guard !components.isEmpty else { return [] }
        var result: [PathSegment] = []
        var accumulated = URL(fileURLWithPath: "/")
        let rootName = fm.displayName(atPath: "/")
        result.append(PathSegment(displayName: rootName.isEmpty ? "Macintosh HD" : rootName,
                                  url: accumulated))
        for component in components.dropFirst() {
            accumulated.appendPathComponent(component)
            result.append(PathSegment(displayName: fm.displayName(atPath: accumulated.path),
                                      url: accumulated))
        }
        return result
    }
}

// MARK: - 브레드크럼 세그먼트
struct PathSegment: Identifiable {
    let id = UUID()
    let displayName: String
    let url: URL?
}
