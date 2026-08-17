import SwiftUI
import AppKit

// NSOutlineView로 탐색 창 트리를 구현 — SwiftUI List로는
// 지연 로딩, 커스텀 disclosure 삼각형, 행 높이/인디케이터 픽셀 정밀 제어가 불가

// MARK: - 즐겨찾기 전용 pasteboard 타입

extension NSPasteboard.PasteboardType {
    /// 사이드바 즐겨찾기 재정렬에 사용하는 전용 타입 — 외부 앱과 충돌 방지
    static let winderFavoriteID = NSPasteboard.PasteboardType("com.tjuxta.winder.favoriteItemID")
}

// MARK: - 트리 노드 모델

/// 백그라운드 열거 결과를 메인 액터로 옮기는 값 타입 — NavNode는 메인 액터 격리라 직접 넘길 수 없다
struct ChildEntry: Sendable {
    let url: URL
    let displayName: String
}

final class NavNode: NSObject {
    let nodeID: String
    let label: String
    let icon: String
    let url: URL?
    let isSection: Bool
    let isSeparator: Bool
    /// B-2: 즐겨찾기로 등록한 폴더가 삭제·이동되어 해석 불가한 상태
    let isUnavailable: Bool
    var children: [NavNode]?
    var isLoadingChildren = false
    /// C-7: 진행 중인 자식 로딩 Task 참조 — 중복 시작 방지 및 await 직접 가능
    var loadingTask: Task<[ChildEntry], Never>? = nil

    var isLeaf: Bool {
        if isSeparator { return true }
        if let children { return children.isEmpty }
        return false
    }
    /// 사용 불가 항목은 탐색 불가 — 우클릭 제거는 menuNeedsUpdate에서 별도 처리
    var isNavigable: Bool { !isSection && !isSeparator && !isUnavailable && url != nil }

    init(id: String, label: String, icon: String = "", url: URL? = nil,
         isSection: Bool = false, isSeparator: Bool = false,
         children: [NavNode]? = nil, isUnavailable: Bool = false) {
        self.nodeID       = id
        self.label        = label
        self.icon         = icon
        self.url          = url
        self.isSection    = isSection
        self.isSeparator  = isSeparator
        self.isUnavailable = isUnavailable
        self.children     = children
    }
}

// MARK: - NSViewRepresentable

struct OutlineViewRepresentable: NSViewRepresentable {
    @Binding var selectedURL: URL?
    /// 현재 탭 URL — 변경 시 트리 자동 확장·선택 (기능 2)
    var currentURL: URL?
    /// 즐겨찾기 목록 — NavigationPaneView가 FavoritesStore를 관찰해 전달 (기능 1)
    var favorites: [FavoriteItem]
    /// P0: 북마크 캐시 버전 — 비동기 rebuildCache() 완료를 뷰가 감지하는 트리거
    var favoritesCacheVersion: Int
    /// B-5: 중복 드롭 시 강조할 즐겨찾기 항목 ID — nil이면 강조 없음
    var highlightedFavoriteID: UUID?
    /// Bonjour로 찾은 네트워크 서버 이름 — NavigationPaneView가 전달
    var networkServers: [String] = []
    let onNavigate: (URL) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let ov = context.coordinator.outlineView
        ov.dataSource  = context.coordinator
        ov.delegate    = context.coordinator
        ov.rowHeight   = FluentMetrics.treeRowHeight
        ov.indentationPerLevel = FluentMetrics.treeIndentWidth
        ov.style       = .plain
        // 투명 배경으로 두면 행이 움직일 때(펼치기·스크롤) 이전에 그린 픽셀이 지워지지 않아
        // 셀이 겹쳐 보인다 — 사이드바 색으로 직접 칠한다
        ov.backgroundColor = FluentColors.sidebarBackground
        ov.usesAlternatingRowBackgroundColors = false
        ov.headerView  = nil
        // .none이면 NavRowView.drawSelection이 호출되지 않아 선택 알약이 그려지지 않는다
        ov.selectionHighlightStyle = .regular
        // Finder 사이드바처럼 섹션 머리글도 같이 스크롤한다 —
        // 켜 두면 반투명 고정 머리글이 아래 행 위에 겹쳐 그려진다
        ov.floatsGroupRows = false
        // C-4: 시스템 삽입선 끄고 WinderDropLineView로 직접 그림
        ov.draggingDestinationFeedbackStyle = .none

        let col = NSTableColumn(identifier: .init("nav"))
        col.isEditable = false
        ov.addTableColumn(col)
        ov.outlineTableColumn = col

        // A-3: 드래그 소스/수신 등록
        // forLocal: [.move, .copy, .link] — .link가 있어야 즐겨찾기 추가 드롭이 수락됨
        // forLocal: false [.copy, .link] — Finder 드래그-아웃 허용
        ov.registerForDraggedTypes([.winderFavoriteID, .fileURL])
        ov.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        ov.setDraggingSourceOperationMask([.copy, .link], forLocal: false)

        // 폴더 더블클릭 시 펼치기/접기 — 단일 클릭 탐색은 그대로 유지
        ov.target = context.coordinator
        ov.doubleAction = #selector(NavOutlineCoordinator.toggleExpansionOfClickedRow)

        // 즐겨찾기 우클릭 컨텍스트 메뉴
        let ctxMenu = NSMenu()
        ctxMenu.autoenablesItems = false
        ctxMenu.delegate = context.coordinator
        ov.menu = ctxMenu

        // C-4: 드래그 삽입선 뷰 추가 (outline view 좌표계에 고정)
        ov.addSubview(context.coordinator.dropLineView)
        ov.onDragFeedbackShouldClear = { [weak coordinator = context.coordinator] in
            coordinator?.hideDropLine()
            coordinator?.setDropTarget(nil)
        }

        ov.reloadData()
        // 즐겨찾기·홈·위치 기본 확장
        ov.expandItem(context.coordinator.favoritesNode, expandChildren: false)
        if let locations = context.coordinator.roots.first(where: { $0.nodeID == "locations" }) {
            ov.expandItem(locations, expandChildren: false)
        }
        // 홈은 지연 로딩 노드 — children이 nil인 채로 펼치면 빈 상태로 열리므로
        // 자식을 먼저 채운 뒤 펼친다
        if let homeNode = context.coordinator.roots.first(where: { $0.nodeID == "home" }) {
            Task { @MainActor [weak coordinator = context.coordinator] in
                await coordinator?.loadChildren(of: homeNode)
                ov.expandItem(homeNode, expandChildren: false)
            }
        }

        let scroll = NSScrollView()
        scroll.documentView  = ov
        scroll.drawsBackground = true
        scroll.backgroundColor = FluentColors.sidebarBackground
        // 트래픽 라이트 자리는 NavigationPaneView가 여백으로 비워 둔다 —
        // 자동 여백까지 더해지면 두 번 들어가므로 끈다
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller   = true
        scroll.autohidesScrollers    = true
        scroll.hasHorizontalScroller = false
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onNavigate = onNavigate

        // P0: items가 같아도 cacheVersion이 바뀌면(비동기 rebuildCache 완료) 갱신
        if favorites != context.coordinator.favoritesSnapshot
            || favoritesCacheVersion != context.coordinator.lastCacheVersion {
            context.coordinator.lastCacheVersion = favoritesCacheVersion
            context.coordinator.updateFavorites(favorites)
        }

        // 최초에는 스냅샷이 nil이라 서버가 없어도 한 번은 채운다
        // (children이 []인 채로 두면 leaf로 판정되어 펼칠 수 없다)
        if networkServers != context.coordinator.networkSnapshot {
            context.coordinator.updateNetwork(networkServers)
        }

        // currentURL 변경 시 트리 reveal
        // ②: lastRevealedURL(성공 시점) 대신 revealTargetURL(요청 시점)과 비교 — 재진입 방지
        if currentURL != context.coordinator.revealTargetURL {
            context.coordinator.scheduleReveal(url: currentURL)
        }

        // B-5: 중복 드롭 강조 변경 시 펄스 실행
        if highlightedFavoriteID != context.coordinator.lastHighlightedID {
            context.coordinator.lastHighlightedID = highlightedFavoriteID
            if let id = highlightedFavoriteID {
                context.coordinator.pulseHighlight(id: id)
            }
        }
    }

    func makeCoordinator() -> NavOutlineCoordinator { NavOutlineCoordinator() }
}

// MARK: - Coordinator

final class NavOutlineCoordinator: NSObject,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    let outlineView = WinderOutlineView()
    /// C-4: Win11 스타일 드래그 삽입선
    let dropLineView = WinderDropLineView()
    var onNavigate: (URL) -> Void = { _ in }

    // MARK: 즐겨찾기 (기능 1)

    /// 즐겨찾기 섹션 노드 — roots[0]에 고정
    let favoritesNode = NavNode(id: "favorites", label: "즐겨찾기",
                                isSection: true, children: [])
    var favoritesSnapshot: [FavoriteItem] = []
    /// P0: 마지막으로 처리한 cacheVersion — -1이면 첫 updateNSView에서 반드시 갱신
    var lastCacheVersion: Int = -1

    // MARK: 트리 구조

    private(set) var roots: [NavNode] = []

    // MARK: 기능 2: reveal 상태

    var lastRevealedURL: URL?
    /// ②: updateNSView 변경 감지용 — scheduleReveal 호출 즉시 설정 (성공 여부 무관)
    private(set) var revealTargetURL: URL?
    /// ③: Bool 대신 카운터 — 취소된 Task의 defer가 새 Task 도중에 0으로 만드는 것 방지
    private var isRevealingCount = 0
    private var revealTask: Task<Void, Never>?

    // B-5: 중복 드롭 펄스 추적
    var lastHighlightedID: UUID? = nil

    override init() {
        super.init()
        roots = [favoritesNode] + NavOutlineCoordinator.buildRoots()
    }

    // MARK: 네트워크 갱신

    /// 마지막으로 반영한 서버 목록 — nil이면 아직 한 번도 채우지 않은 상태
    private(set) var networkSnapshot: [String]?
    /// 새로 고침 직후처럼 결과가 오면 펼쳐 두고 싶을 때
    private var wantsNetworkExpanded = false

    /// 네트워크 섹션 = 마운트된 네트워크 볼륨 + 아직 연결하지 않은 Bonjour 서버
    func updateNetwork(_ servers: [String]) {
        networkSnapshot = servers
        guard let networkNode = roots.first(where: { $0.nodeID == "network" }) else { return }

        let mounted = NetworkBrowserService.mountedNetworkVolumes()
        let mountedNames = Set(mounted.map { FileManager.default.displayName(atPath: $0.path).lowercased() })

        var children: [NavNode] = mounted.map { url in
            NavNode(id: "net_\(url.path)",
                    label: FileManager.default.displayName(atPath: url.path),
                    icon: FluentIcons.network, url: url)
        }
        // 이미 마운트된 서버는 중복으로 보여주지 않는다
        for name in servers where !mountedNames.contains(name.lowercased()) {
            guard let url = NetworkBrowserService.Server(name: name).url else { continue }
            // children: [] — 마운트 전에는 펼칠 것이 없으므로 삼각형을 숨긴다
            children.append(NavNode(id: "net_server_\(name)", label: name,
                                    icon: FluentIcons.network, url: url, children: []))
        }
        if children.isEmpty {
            // children: [] — 안내 문구는 펼칠 것이 없으므로 삼각형을 숨긴다
            children = [NavNode(id: "net_empty", label: "찾은 서버가 없습니다",
                                icon: "", children: [])]
        }

        let wasExpanded = outlineView.isItemExpanded(networkNode) || wantsNetworkExpanded
        networkNode.children = children
        outlineView.reloadItem(networkNode, reloadChildren: true)
        if wasExpanded {
            outlineView.expandItem(networkNode)
            wantsNetworkExpanded = false
        }
    }

    /// 마운트를 시도 중인 서버 노드 — 중복 클릭 방지
    private var connectingServers: Set<String> = []

    /// 네트워크 서버 열기 — 저장된 자격 증명이나 게스트로 마운트되면 그 폴더를 연다.
    /// 자격 증명이 필요해 실패하면 시스템 "서버에 연결" 대화상자로 넘긴다.
    private func connectNetworkServer(_ node: NavNode, url: URL) {
        guard !connectingServers.contains(node.nodeID) else { return }
        connectingServers.insert(node.nodeID)

        Task { @MainActor [weak self] in
            defer { self?.connectingServers.remove(node.nodeID) }
            guard let self else { return }

            if let mounted = await NetworkMountService.mount(url), let first = mounted.first {
                // 마운트된 볼륨이 목록에 나타나도록 갱신하고 그 폴더를 연다
                self.updateNetwork(self.networkSnapshot ?? [])
                self.lastRevealedURL = first
                self.onNavigate(first)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 즐겨찾기 갱신

    func updateFavorites(_ newFavorites: [FavoriteItem]) {
        let wasExpanded = outlineView.isItemExpanded(favoritesNode)
        let hadItems = !favoritesSnapshot.isEmpty
        favoritesSnapshot = newFavorites

        let previous = favoritesNode.children ?? []
        let rebuilt: [NavNode]
        if newFavorites.isEmpty {
            // C-3: 즐겨찾기 0개 — 안내 플레이스홀더
            rebuilt = [NavNode(id: "fav_placeholder",
                               label: "폴더를 여기로 끌어다 놓으세요",
                               icon: "", children: [])]
        } else {
            // 내용이 같은 항목은 기존 NavNode를 그대로 재사용한다.
            // 새 객체로 교체하면 reloadItem이 펼침·선택 상태를 잃어버려,
            // 비동기 rebuildCache()가 끝나는 순간 트리에서 reveal 결과가 사라진다.
            let previousByID = Dictionary(previous.map { ($0.nodeID, $0) },
                                          uniquingKeysWith: { first, _ in first })
            rebuilt = newFavorites.map { item -> NavNode in
                let fresh = Self.makeFavoriteNode(for: item)
                if let old = previousByID[fresh.nodeID],
                   old.label == fresh.label, old.icon == fresh.icon,
                   old.url == fresh.url, old.isUnavailable == fresh.isUnavailable {
                    return old
                }
                return fresh
            }
        }

        // 목록이 완전히 그대로면 reloadItem 자체를 건너뛴다
        let unchanged = rebuilt.count == previous.count
            && zip(rebuilt, previous).allSatisfy { $0 === $1 }
        favoritesNode.children = rebuilt
        if !unchanged {
            outlineView.reloadItem(favoritesNode, reloadChildren: true)
        }

        // 처음으로 항목이 생겼거나 이전에 펼쳐져 있었으면 펼치기
        if wasExpanded || (!hadItems && !newFavorites.isEmpty) {
            outlineView.expandItem(favoritesNode)
        }
    }

    /// B-1 캐시 사용 + B-2 사용 불가 노드 생성 + C-5 알려진 폴더 아이콘
    private static func makeFavoriteNode(for item: FavoriteItem) -> NavNode {
        let nodeID = "fav_\(item.id.uuidString)"
        if let url = FavoritesStore.shared.resolvedByID[item.id] {
            return NavNode(id: nodeID, label: item.name,
                           icon: iconForFavoriteURL(url), url: url)
        }
        // P2-2: 캐시 준비 전(첫 프레임) — lastKnownPath로 임시 URL 생성해 깜빡임 방지
        // 다음 cacheVersion 갱신 시 올바른 해석 URL로 교체됨
        if !item.lastKnownPath.isEmpty {
            let tempURL = URL(fileURLWithPath: item.lastKnownPath)
            return NavNode(id: nodeID, label: item.name,
                           icon: iconForFavoriteURL(tempURL), url: tempURL)
        }
        // B-2: lastKnownPath도 없는 완전 해석 불가 항목 — 회색 경고 아이콘, 탐색 불가
        return NavNode(id: nodeID, label: item.name,
                       icon: FluentIcons.folder, url: nil, isUnavailable: true)
    }

    /// C-5: 알려진 폴더(바탕화면·다운로드·문서 등)면 전용 아이콘, 그 외엔 folder
    private static func iconForFavoriteURL(_ url: URL) -> String {
        let std = url.standardizedFileURL
        for folder in KnownFolder.allCases {
            if folder.url.standardizedFileURL == std {
                return folder.systemIcon
            }
        }
        return FluentIcons.folder
    }

    // MARK: NSOutlineViewDataSource — 기본

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        guard let node = item as? NavNode else { return 0 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return roots[index] }
        guard let node = item as? NavNode, let children = node.children else { return NSNull() }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? NavNode else { return false }
        return !node.isLeaf
    }

    // MARK: NSOutlineViewDataSource — 드래그 소스

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // A-3(a): 탐색 가능한 모든 노드를 드래그 소스로 허용
        guard let node = item as? NavNode, node.isNavigable, let url = node.url,
              url.isFileURL else { return nil }
        let pbItem = NSPasteboardItem()
        // 즐겨찾기 노드는 재정렬 식별용 전용 타입을 함께 기록
        // — validateDrop이 이 타입 유무로 재정렬/추가를 구분함
        if node.nodeID.hasPrefix("fav_") {
            pbItem.setString(String(node.nodeID.dropFirst(4)), forType: .winderFavoriteID)
        }
        pbItem.setString(url.absoluteString, forType: .fileURL)
        return pbItem
    }

    // MARK: NSOutlineViewDataSource — 드롭 수신

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // 드롭이 허용되는 폴더 위에 있을 때만 그 행을 강조한다.
        // 반환 지점이 여러 곳이라 defer로 한 번만 반영 — 값이 그대로면 setDropTarget이 무시하므로
        // 마우스가 움직이는 동안 불필요한 다시 그리기가 생기지 않는다.
        var highlight: NavNode?
        defer { setDropTarget(highlight) }

        let pb = info.draggingPasteboard
        let target = item as? NavNode
        let isInFav = target === favoritesNode || target?.nodeID.hasPrefix("fav_") == true

        // 즐겨찾기 내 재정렬 — winderFavoriteID가 있으면 fav 소스이므로 재정렬 전용
        // fav 노드를 fav 밖으로 드롭하면 무시 (즐겨찾기 항목은 파일 이동 대상이 아님)
        if pb.availableType(from: [.winderFavoriteID]) != nil {
            if !isInFav { hideDropLine() }
            return isInFav ? .move : []
        }

        // 파일 URL 드롭
        if pb.availableType(from: [.fileURL]) != nil {
            let urls = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []

            if isInFav {
                // N-3: fav_ 노드 ON 드롭이고 탐색 가능한 폴더면 → 파일 이동/복사 (즐겨찾기 추가 아님)
                if index == NSOutlineViewDropOnItemIndex,
                   let targetNode = target,
                   targetNode !== favoritesNode,
                   targetNode.isNavigable,
                   let targetURL = targetNode.url {
                    let isInvalid = urls.contains { src in
                        let srcStd = src.standardizedFileURL
                        let dstStd = targetURL.standardizedFileURL
                        return dstStd.path.hasPrefix(srcStd.path + "/") || srcStd == dstStd
                    }
                    guard !isInvalid else { return [] }
                    hideDropLine()
                    highlight = targetNode
                    let isCopy = info.draggingSourceOperationMask.contains(.copy)
                    return isCopy ? .copy : .move
                }

                // B-5: 폴더가 아니면 거부 (파일 드롭 시 금지 커서)
                guard urls.contains(where: { $0.hasDirectoryPath }) else {
                    hideDropLine()
                    return []
                }
                let children = favoritesNode.children ?? []
                let isPlaceholder = children.count == 1 && children[0].nodeID == "fav_placeholder"
                let effectiveIndex: Int
                if index == NSOutlineViewDropOnItemIndex || isPlaceholder {
                    let endIdx = isPlaceholder ? 0 : (children.count)
                    outlineView.setDropItem(favoritesNode, dropChildIndex: endIdx)
                    effectiveIndex = endIdx
                } else {
                    effectiveIndex = index
                }
                // C-4: 삽입선 위치 계산
                if isPlaceholder || children.isEmpty {
                    showDropLine(afterRow: outlineView.row(forItem: favoritesNode))
                } else if effectiveIndex <= 0 {
                    showDropLine(afterRow: outlineView.row(forItem: favoritesNode))
                } else {
                    let prevIdx = min(effectiveIndex - 1, children.count - 1)
                    showDropLine(afterRow: outlineView.row(forItem: children[prevIdx]))
                }
                return .link
            }

            // B-4: 일반 탐색 가능 폴더 노드에 파일 드롭 → 이동/복사
            if let targetNode = target,
               targetNode.isNavigable,
               let targetURL = targetNode.url,
               index == NSOutlineViewDropOnItemIndex {
                // 자기 자신·자기 하위 이동 방지 (A-3: 자기 자신 위 드롭 거부 포함)
                let isInvalid = urls.contains { src in
                    let srcStd = src.standardizedFileURL
                    let dstStd = targetURL.standardizedFileURL
                    return dstStd.path.hasPrefix(srcStd.path + "/") || srcStd == dstStd
                }
                guard !isInvalid else { return [] }
                highlight = targetNode
                let isCopy = info.draggingSourceOperationMask.contains(.copy)
                return isCopy ? .copy : .move
            }
        }

        return []
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        hideDropLine()      // C-4: 드롭 완료 시 삽입선 제거
        setDropTarget(nil)  // 드롭 대상 강조도 함께 해제
        let pb = info.draggingPasteboard

        // 즐겨찾기 내 재정렬
        if let uuidStr = pb.string(forType: .winderFavoriteID),
           let id = UUID(uuidString: uuidStr) {
            Task { @MainActor in
                guard let fromIdx = FavoritesStore.shared.items.firstIndex(where: { $0.id == id }) else { return }
                let toIdx = index == NSOutlineViewDropOnItemIndex
                    ? FavoritesStore.shared.items.count : index
                FavoritesStore.shared.move(from: IndexSet(integer: fromIdx), to: toIdx)
            }
            return true
        }

        let allURLs = (pb.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []

        // B-4: 일반 폴더 노드로 파일 드롭 → 이동/복사
        if let targetNode = item as? NavNode,
           targetNode.isNavigable,
           let targetURL = targetNode.url,
           !allURLs.isEmpty {
            let isCopy = info.draggingSourceOperationMask.contains(.copy)
            Task { @MainActor in
                if isCopy {
                    _ = try? await FileOperationService.shared.copyItems(allURLs, to: targetURL)
                } else {
                    _ = try? await FileOperationService.shared.moveItems(allURLs, to: targetURL)
                }
            }
            return true
        }

        // 파일 목록 폴더 드롭 → 즐겨찾기 추가 (B-3: 삽입 위치, B-5: 중복 펄스)
        let dirs = allURLs.filter { $0.hasDirectoryPath }
        guard !dirs.isEmpty else { return false }
        let insertIndex = index == NSOutlineViewDropOnItemIndex
            ? FavoritesStore.shared.items.count : index
        Task { @MainActor in
            // N-4: 실제 삽입된 항목 수로 offset 계산 — 중복 건너뛰어도 offset이 틀리지 않도록
            var insertedCount = 0
            for url in dirs {
                if FavoritesStore.shared.contains(url: url) {
                    // B-5: 이미 있는 항목 — 펄스 애니메이션 (N-8: pulse 메서드, await 없음)
                    let std = url.standardizedFileURL
                    if let existingID = FavoritesStore.shared.items.first(where: {
                        FavoritesStore.shared.resolvedByID[$0.id] == std
                    })?.id {
                        FavoritesStore.shared.pulse(id: existingID)
                    }
                } else {
                    try? FavoritesStore.shared.add(url: url, at: insertIndex + insertedCount)
                    insertedCount += 1
                }
            }
        }
        return true
    }

    // MARK: NSOutlineViewDelegate — 셀 뷰

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? NavNode else { return nil }

        if node.isSeparator {
            // 구분선도 식별자를 붙여 재사용한다 — 매번 새로 만들면 스크롤할 때마다 뷰가 쌓인다
            let separatorID = NSUserInterfaceItemIdentifier("NavSeparator")
            if let reused = outlineView.makeView(withIdentifier: separatorID, owner: self) {
                return reused
            }
            let v = NSView()
            v.identifier = separatorID
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: v.leadingAnchor,
                                              constant: FluentMetrics.paddingS),
                line.trailingAnchor.constraint(equalTo: v.trailingAnchor,
                                               constant: -FluentMetrics.paddingS),
                line.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }

        let cellID = NSUserInterfaceItemIdentifier("NavCell")
        let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NavCellView
                   ?? NavCellView(identifier: cellID)
        cell.configure(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        // 식별자를 붙여 AppKit 재사용 풀을 태운다 — 없으면 스크롤할 때마다 행 뷰가 새로 할당된다
        let rowID = NSUserInterfaceItemIdentifier("NavRow")
        let rowView: NavRowView
        if let reused = outlineView.makeView(withIdentifier: rowID, owner: self) as? NavRowView {
            rowView = reused
        } else {
            rowView = NavRowView()
            rowView.identifier = rowID
        }
        // 드래그 중 스크롤로 행이 새로 만들어질 수 있으므로 생성 시점에도 상태를 반영한다
        rowView.isDropTarget = (item as? NavNode) === dropTargetNode
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? NavNode else { return FluentMetrics.treeRowHeight }
        if node.isSeparator { return 12 }
        // Finder는 섹션 머리글을 일반 행보다 낮게 잡는다
        return node.isSection ? FluentMetrics.treeSectionRowHeight : FluentMetrics.treeRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? NavNode)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? NavNode else { return false }
        return node.isNavigable
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard isRevealingCount == 0 else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              let url = node.url else { return }
        // smb:// 같은 원격 주소 — 먼저 조용히 마운트해 다른 폴더처럼 열어 본다
        guard url.isFileURL else {
            connectNetworkServer(node, url: url)
            return
        }
        lastRevealedURL = url
        // P2-1: updateNSView가 방금 클릭한 노드를 불필요하게 다시 reveal하는 것 방지
        revealTargetURL = url
        onNavigate(url)
    }

    // MARK: 더블클릭 — 펼치기/접기

    /// 더블클릭한 행의 노드를 펼치거나 접는다.
    /// 자식이 아직 nil인 노드는 expandItem이 outlineViewItemWillExpand를 통해 지연 로딩을 건다.
    @objc func toggleExpansionOfClickedRow() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              !node.isSeparator, !node.isLeaf else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    // MARK: NSOutlineViewDelegate — 폴더 지연 로딩

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? NavNode,
              !node.isSection,         // 섹션(즐겨찾기, 위치)은 지연 로딩 불필요
              node.children == nil && !node.isLoadingChildren else { return }
        Task { @MainActor [weak self] in
            await self?.loadChildren(of: node)
        }
    }

    // MARK: NSMenuDelegate — 컨텍스트 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode else {
            // 빈 영역 — 트리 전체 새로 고침만 제공
            addNavMenuItem(menu, title: "새로 고침", action: #selector(refreshClickedNode))
            return
        }

        if node.nodeID.hasPrefix("fav_") {
            if node.isUnavailable {
                // B-2: 사라진 항목 — 제거만 가능
                addNavMenuItem(menu, title: "즐겨찾기에서 제거", action: #selector(favRemove))
            } else {
                addNavMenuItem(menu, title: "열기", action: #selector(favOpen))
                menu.addItem(.separator())
                // C: "표시 이름 바꾸기" — 실제 폴더 이름은 변경하지 않음을 명확히
                addNavMenuItem(menu, title: "표시 이름 바꾸기", action: #selector(favRename))
                addNavMenuItem(menu, title: "즐겨찾기에서 제거", action: #selector(favRemove))
                menu.addItem(.separator())
                addNavMenuItem(menu, title: "Finder에 표시", action: #selector(favRevealInFinder))
            }
        } else if node.nodeID == "trash" {
            // A-2: 휴지통 — 전체 디스크 접근 권한 없이도 Finder로 열 수 있는 대안 제공
            addNavMenuItem(menu, title: "열기", action: #selector(navOpen))
            menu.addItem(.separator())
            addNavMenuItem(menu, title: "Finder에서 휴지통 열기", action: #selector(trashOpenInFinder))
        } else if node.isNavigable, node.url != nil {
            addNavMenuItem(menu, title: "열기", action: #selector(navOpen))
            menu.addItem(.separator())
            addNavMenuItem(menu, title: "즐겨찾기에 추가", action: #selector(navAddToFavorites))
            addNavMenuItem(menu, title: "Finder에서 보기", action: #selector(navRevealInFinder))
        }

        // 어떤 항목이든 새로 고침은 제공한다
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        addNavMenuItem(menu, title: "새로 고침", action: #selector(refreshClickedNode))
    }

    /// 우클릭한 노드의 하위 목록을 다시 읽는다.
    /// 섹션(위치·네트워크)이나 빈 영역이면 트리 루트를 다시 만든다.
    @objc private func refreshClickedNode() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? NavNode else {
            rebuildRoots()
            return
        }

        if node.nodeID == "network" || node.nodeID.hasPrefix("net_") {
            // 다시 훑는 동안에도 목록(마운트된 볼륨)은 즉시 갱신하고, 결과가 오면 펼쳐 둔다
            wantsNetworkExpanded = true
            NetworkBrowserService.shared.refresh()
            updateNetwork([])
            return
        }
        if node.isSection {
            rebuildRoots()
            return
        }
        guard node.isNavigable else { return }

        // 자식을 비우고 다시 읽는다 — 펼쳐져 있었다면 다시 펼친다
        let wasExpanded = outlineView.isItemExpanded(node)
        node.loadingTask?.cancel()
        node.loadingTask = nil
        node.children = nil
        outlineView.reloadItem(node, reloadChildren: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadChildren(of: node)
            if wasExpanded { self.outlineView.expandItem(node) }
        }
        // 지금 보고 있는 폴더면 파일 목록도 함께 갱신
        if let url = node.url, url.standardizedFileURL == lastRevealedURL?.standardizedFileURL {
            onNavigate(url)
        }
    }

    /// 볼륨·네트워크처럼 바깥 상태가 바뀌는 항목을 반영해 루트를 다시 만든다
    private func rebuildRoots() {
        let expandedIDs = Set(roots.filter { outlineView.isItemExpanded($0) }.map(\.nodeID))
        roots = [favoritesNode] + NavOutlineCoordinator.buildRoots()
        outlineView.reloadData()
        for root in roots where expandedIDs.contains(root.nodeID) {
            outlineView.expandItem(root, expandChildren: false)
        }
        outlineView.expandItem(favoritesNode, expandChildren: false)
    }

    private func addNavMenuItem(_ menu: NSMenu, title: String, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
    }

    @objc private func favRename() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              node.nodeID.hasPrefix("fav_"),
              let id = UUID(uuidString: String(node.nodeID.dropFirst(4))),
              // C-6: 트리 셀 인라인 편집
              let cell = outlineView.view(atColumn: 0, row: row,
                                         makeIfNecessary: false) as? NavCellView
        else { return }

        cell.startEditing(currentName: node.label) { newName in
            Task { @MainActor in FavoritesStore.shared.rename(id: id, to: newName) }
        }
    }

    @objc private func favRemove() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              node.nodeID.hasPrefix("fav_"),
              let id = UUID(uuidString: String(node.nodeID.dropFirst(4))) else { return }
        Task { @MainActor in FavoritesStore.shared.remove(id: id) }
    }

    @objc private func favRevealInFinder() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func favOpen() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              let url = node.url else { return }
        onNavigate(url)
    }

    @objc private func navOpen() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              let url = node.url else { return }
        onNavigate(url)
    }

    @objc private func navAddToFavorites() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              let url = node.url else { return }
        Task { @MainActor in try? FavoritesStore.shared.add(url: url) }
    }

    @objc private func navRevealInFinder() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // A-2: 권한 없이도 Finder로 휴지통 열기
    @objc private func trashOpenInFinder() {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? NavNode,
              let url = node.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 기능 2: 공통 자식 로딩

    @MainActor
    func loadChildren(of node: NavNode) async {
        // C-7: 이미 진행 중인 Task가 있으면 await — 폴링 루프 제거
        if let existing = node.loadingTask {
            let loaded = await existing.value
            if node.children == nil {
                node.children = Self.makeNodes(from: loaded)
                reloadPreservingSelection(node)
            }
            return
        }
        guard node.children == nil else { return }
        guard let url = node.url else { node.children = []; return }

        node.isLoadingChildren = true
        // 두 제외 규칙은 홈뿐 아니라 모든 노드에 적용한다 (판단 근거는 아래 주석 참고)
        let userLibraryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library").standardizedFileURL.path
        // 디스크 접근(열거·displayName)만 백그라운드에서 하고 NavNode 생성은 메인 액터에서 —
        // NavNode는 메인 액터 격리 타입이라 detached 태스크 안에서 만들 수 없다
        let task = Task.detached(priority: .userInitiated) { () -> [ChildEntry] in
            let subDirs = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .nameKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return subDirs
                .filter { child in
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    guard values?.isDirectory == true else { return false }
                    // .app 등 패키지는 사용자에게 문서 하나로 보이므로 펼칠 수 있는 폴더로 취급하지 않는다.
                    // ~/Applications가 있는 환경에서 앱 번들 내부가 트리에 노출되는 것을 막는다.
                    if values?.isPackage == true { return false }
                    // ~/Library는 숨김 플래그가 환경에 따라 달라 .skipsHiddenFiles로 걸러지지 않을 수 있다.
                    // 사용자가 트리로 훑을 대상이 아니므로 이 경로 하나만 제외한다.
                    // (/Library·/System/Library는 볼륨 탐색 시 정상적으로 필요하므로 남긴다)
                    if child.standardizedFileURL.path == userLibraryPath { return false }
                    return true
                }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                .map { ChildEntry(url: $0, displayName: FileManager.default.displayName(atPath: $0.path)) }
        }
        node.loadingTask = task
        let loaded = await task.value
        node.loadingTask = nil
        node.isLoadingChildren = false
        // await 사이에 다른 경로(reveal 등)가 이미 자식을 채웠다면 덮어쓰지 않는다.
        // 덮어쓰면 새 NavNode 객체로 교체되면서 reloadItem이 선택·펼침 상태를 날린다.
        guard node.children == nil else { return }
        node.children = Self.makeNodes(from: loaded)
        reloadPreservingSelection(node)
    }

    /// reloadItem은 선택을 해제하므로, 선택 노드가 여전히 트리에 있으면 되돌린다.
    /// 시작 시 홈을 미리 펼치는 동안 reveal이 만든 선택이 사라지는 것을 막는다.
    private func reloadPreservingSelection(_ node: NavNode) {
        let selectedRow = outlineView.selectedRow
        let selectedNode = selectedRow >= 0
            ? outlineView.item(atRow: selectedRow) as? NavNode : nil
        outlineView.reloadItem(node, reloadChildren: true)
        guard let selectedNode else { return }
        let row = outlineView.row(forItem: selectedNode)
        guard row >= 0, outlineView.selectedRow != row else { return }
        // 프로그램적 선택 복원이 onNavigate를 다시 발생시키지 않도록 reveal 카운터로 감싼다
        isRevealingCount += 1
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRevealingCount -= 1
    }

    private static func makeNodes(from entries: [ChildEntry]) -> [NavNode] {
        entries.map { NavNode(id: $0.url.path, label: $0.displayName,
                              icon: FluentIcons.folder, url: $0.url) }
    }

    // MARK: 기능 2: reveal 스케줄링

    func scheduleReveal(url: URL?) {
        // ②: 즉시 설정 — updateNSView가 동일 URL로 reveal을 반복 예약하는 것 방지
        revealTargetURL = url
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            await self?.reveal(url: url)
        }
    }

    /// targetPath를 포함하는 가장 깊은 조상 노드 반환
    /// 즐겨찾기 → 최상위 탐색 노드(홈) → 섹션 하위(위치의 볼륨·iCloud) 순으로 후보를 모은다
    /// 동일 경로를 여러 후보가 가리키면 즐겨찾기가 우선 선택된다
    private func bestAncestor(for targetPath: String) -> NavNode? {
        var candidates: [NavNode] = []

        // 즐겨찾기 아이템 (가장 먼저 검색 — 동일 URL이면 즐겨찾기 항목이 선택됨)
        if let children = favoritesNode.children {
            candidates.append(contentsOf: children.filter { $0.url?.isFileURL == true })
        }

        // 일반 루트 노드 + 섹션 하위
        for root in roots where root !== favoritesNode {
            if !root.isSection && !root.isSeparator, root.url?.isFileURL == true {
                candidates.append(root)
            }
            if root.isSection, let children = root.children {
                candidates.append(contentsOf: children.filter { !$0.isSeparator && $0.url?.isFileURL == true })
            }
        }

        var best: NavNode?
        var bestLen = -1
        for node in candidates {
            let p = node.url!.standardizedFileURL.path
            // 루트 볼륨("/")은 이미 구분자로 끝나므로 "/"를 덧붙이면 "//"가 되어 아무것도 매칭되지 않는다
            let prefix = p.hasSuffix("/") ? p : p + "/"
            if targetPath == p || targetPath.hasPrefix(prefix), p.count > bestLen {
                bestLen = p.count
                best = node
            }
        }
        return best
    }

    @MainActor
    private func selectNode(_ node: NavNode) {
        // 섹션 하위 노드는 섹션이 펼쳐져야 보임
        if let parent = outlineView.parent(forItem: node) as? NavNode,
           !outlineView.isItemExpanded(parent) {
            outlineView.expandItem(parent)
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    @MainActor
    func reveal(url: URL?) async {
        // ③: 카운터로 관리 — 취소된 Task의 defer가 진행 중인 Task를 0으로 만드는 것 방지
        isRevealingCount += 1
        defer { isRevealingCount -= 1 }

        guard let url else {
            outlineView.deselectAll(nil)
            lastRevealedURL = nil
            return
        }

        let targetPath = url.standardizedFileURL.path
        guard let startNode = bestAncestor(for: targetPath) else {
            outlineView.deselectAll(nil)
            // P1: 실패 시 리셋 — updateNSView가 다음 렌더에서 재시도할 수 있도록
            revealTargetURL = nil
            return
        }

        let startPath = startNode.url!.standardizedFileURL.path

        if targetPath == startPath {
            if !Task.isCancelled {
                selectNode(startNode)
                lastRevealedURL = url
            }
            return
        }

        // 루트 볼륨("/")은 경로 끝에 구분자가 이미 포함되어 있다
        let dropCount = startPath.hasSuffix("/") ? startPath.count : startPath.count + 1
        let afterStart = String(targetPath.dropFirst(dropCount))
        let components = afterStart.components(separatedBy: "/").filter { !$0.isEmpty }

        var currentNode = startNode
        if let parent = outlineView.parent(forItem: startNode) as? NavNode,
           !outlineView.isItemExpanded(parent) {
            outlineView.expandItem(parent)
        }

        for component in components {
            if Task.isCancelled { return }
            if currentNode.children == nil { await loadChildren(of: currentNode) }
            if Task.isCancelled { return }
            if !outlineView.isItemExpanded(currentNode) { outlineView.expandItem(currentNode) }
            guard let child = currentNode.children?.first(where: {
                $0.url.map { $0.standardizedFileURL.lastPathComponent } == component
            }) else { break }
            currentNode = child
        }

        if Task.isCancelled { return }
        selectNode(currentNode)
        lastRevealedURL = url  // 취소되지 않은 경우에만 설정
    }

    // MARK: 드롭 대상 폴더 강조

    /// 드래그가 올라가 있는 폴더 노드 — 행 강조 상태를 여기 하나로 관리한다
    private(set) var dropTargetNode: NavNode?

    /// 드롭 대상 행을 강조하거나(node) 해제한다(nil)
    func setDropTarget(_ node: NavNode?) {
        guard node !== dropTargetNode else { return }
        let previous = dropTargetNode
        dropTargetNode = node
        // 이전 대상은 강조 해제, 새 대상은 강조 — 화면에 보이는 행만 갱신하면 된다
        for candidate in [previous, node] {
            guard let candidate else { continue }
            let row = outlineView.row(forItem: candidate)
            guard row >= 0,
                  let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? NavRowView
            else { continue }
            rowView.isDropTarget = (candidate === dropTargetNode)
        }
    }

    // MARK: C-4: 드래그 삽입선 제어

    func showDropLine(afterRow row: Int) {
        guard row >= 0 else { hideDropLine(); return }
        let rowRect = outlineView.rect(ofRow: row)
        let x = rowRect.minX + 8
        dropLineView.frame = NSRect(x: x, y: rowRect.maxY - 3,
                                    width: rowRect.width - 8, height: 7)
        dropLineView.isHidden = false
        dropLineView.needsDisplay = true
    }

    func hideDropLine() {
        dropLineView.isHidden = true
    }

    // MARK: B-5: 중복 드롭 펄스 강조

    func pulseHighlight(id: UUID) {
        let nodeID = "fav_\(id.uuidString)"
        guard let node = favoritesNode.children?.first(where: { $0.nodeID == nodeID }) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0,
              let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.075
            ctx.allowsImplicitAnimation = true
            rowView.alphaValue = 0.3
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.075
                ctx.allowsImplicitAnimation = true
                rowView.alphaValue = 1.0
            }
        }
    }

    // MARK: 트리 초기 구조

    private static func buildRoots() -> [NavNode] {
        let fm   = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 홈 — children을 nil로 두어 펼칠 때 ~ 하위를 지연 로딩한다.
        // 알려진 폴더를 고정 나열하지 않으므로 ~/Projects 같은 사용자 폴더도 그대로 나타난다.
        let homeNode = NavNode(id: "home", label: "홈", icon: FluentIcons.home, url: home)

        // 위치 — 홈 하위에 둘 수 없는 항목(루트 볼륨·외장 디스크·iCloud)의 자리
        let volumes = (fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []).map { vol in
            NavNode(id: vol.path, label: fm.displayName(atPath: vol.path),
                    icon: FluentIcons.drive, url: vol)
        }

        // iCloud Drive는 ~/Library 하위라 홈 트리에서는 보이지 않으므로 위치 섹션에 둔다.
        // iCloud를 쓰지 않는 계정에서는 폴더 자체가 없으므로 노드를 만들지 않는다.
        let icloudURL = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var locationChildren = volumes
        if fm.fileExists(atPath: icloudURL.path) {
            locationChildren.append(
                NavNode(id: "icloud", label: "iCloud Drive", icon: FluentIcons.cloud, url: icloudURL)
            )
        }
        let locations = NavNode(id: "locations", label: "위치",
                                isSection: true, children: locationChildren)

        return [
            NavNode(id: "sep1",    label: "", isSeparator: true),
            homeNode,
            NavNode(id: "sep2",    label: "", isSeparator: true),
            locations,
            NavNode(id: "sep3",    label: "", isSeparator: true),
            NavNode(id: "network", label: "네트워크", isSection: true, children: []),
            NavNode(id: "trash",   label: "휴지통",   icon: FluentIcons.trash,
                    url: home.appendingPathComponent(".Trash")),
        ]
    }
}

// MARK: - 커스텀 셀 뷰 (C-6: 인라인 이름 바꾸기 지원)

final class NavCellView: NSView, NSTextFieldDelegate {
    private let iconView  = NSImageView()
    private let label     = NSTextField()
    /// 섹션 머리글·안내 문구는 선택되지 않으므로 선택 색을 입히지 않는다
    private var isSelectableNode = false

    /// C-6: 이름 바꾸기 완료 시 호출되는 핸들러
    private var onCommitRename: ((String) -> Void)?
    private var originalLabel: String = ""
    /// A-1: 편집 중 플래그 — updateFavorites → reloadItem이 편집 텍스트를 덮어쓰는 것 방지
    private var isRenaming = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // 기본 상태: 편집 불가 라벨처럼 동작
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.focusRingType = .none
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = false
        label.cell?.isScrollable = true
        label.translatesAutoresizingMaskIntoConstraints = false

        [iconView, label].forEach { addSubview($0) }

        NSLayoutConstraint.activate([
            // 선택 알약이 좌우로 paddingS만큼 들어오므로 아이콘도 그 안쪽에서 시작한다
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FluentMetrics.paddingS),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: FluentMetrics.treeIconSize),
            iconView.heightAnchor.constraint(equalToConstant: FluentMetrics.treeIconSize),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: FluentMetrics.paddingS),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FluentMetrics.paddingXS),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: C-6: 인라인 이름 바꾸기

    func startEditing(currentName: String, onCommit: @escaping (String) -> Void) {
        originalLabel = currentName
        onCommitRename = onCommit
        isRenaming = true
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.isBordered = true
        label.focusRingType = .exterior
        label.delegate = self
        // A-1: makeFirstResponder 먼저 → 필드 에디터 설치 후 selectText
        // 반대 순서(selectText → makeFirstResponder)이면 makeFirstResponder가
        // selectText가 시작한 편집 세션을 종료해 controlTextDidEndEditing이 즉시 발화됨
        window?.makeFirstResponder(label)
        label.selectText(nil)
    }

    private func endEditing(commit: Bool) {
        isRenaming = false
        let value = label.stringValue
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.backgroundColor = nil
        label.isBordered = false
        label.focusRingType = .none
        label.delegate = nil
        if commit, !value.trimmingCharacters(in: .whitespaces).isEmpty {
            onCommitRename?(value)
        } else {
            label.stringValue = originalLabel
        }
        onCommitRename = nil
    }

    /// A-1: 셀 재사용 전 편집 상태 초기화 — configure(node:)에서 호출
    private func resetEditingState() {
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.backgroundColor = nil
        label.isBordered = false
        label.focusRingType = .none
        label.delegate = nil
        onCommitRename = nil
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing(commit: true) }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            endEditing(commit: false)
            return true
        }
        return false
    }

    func configure(node: NavNode) {
        // A-1: 편집 중에는 configure를 건너뜀 — updateFavorites → reloadItem이
        // 진행 중인 인라인 편집 텍스트를 덮어쓰는 것을 방지
        guard !isRenaming else { return }
        resetEditingState()

        label.stringValue = node.label
        toolTip = nil
        isSelectableNode = false
        if node.isSection {
            // Finder 사이드바 머리글 — 작고 굵은 회색
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = FluentColors.textSecondary
            iconView.image = nil
        } else if node.nodeID == "fav_placeholder" {
            // C-3: 즐겨찾기 빈 상태 안내 문구
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = FluentColors.textSecondary
            iconView.image = nil
        } else if node.isUnavailable {
            // B-2: 경로를 찾을 수 없는 즐겨찾기 항목
            label.font = NSFont.systemFont(ofSize: 13)
            label.textColor = FluentColors.textDisabled
            iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                     accessibilityDescription: nil)
            iconView.contentTintColor = FluentColors.textDisabled
            toolTip = "찾을 수 없음"
        } else {
            label.font = NSFont.systemFont(ofSize: 13)
            iconView.image = node.icon.isEmpty ? nil :
                NSImage(systemSymbolName: node.icon, accessibilityDescription: nil)
            isSelectableNode = true
            setSelected(false, emphasized: false)
        }
    }

    /// Finder 사이드바 규칙 — 평소 아이콘은 회색, 선택되면 액센트,
    /// 액센트 알약이 깔린 상태(창에 포커스 있음)에서는 글자·아이콘 모두 흰색
    func setSelected(_ selected: Bool, emphasized: Bool) {
        guard isSelectableNode else { return }
        let onAccent = selected && emphasized
        label.textColor = onAccent ? FluentColors.selectionText : FluentColors.textPrimary
        iconView.contentTintColor = onAccent
            ? FluentColors.selectionText
            : (selected ? FluentColors.accent : FluentColors.textSecondary)
    }
}

// MARK: - 선택 행 뷰

final class NavRowView: NSTableRowView {
    /// 드래그가 이 행 위에 올라와 있고 드롭이 허용된 상태 — 대상 폴더를 강조한다
    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }

    override var isSelected: Bool {
        didSet { applySelectionToCell() }
    }
    /// 창·탐색 창에 포커스가 있는지 — 바뀌면 선택 알약과 글자색을 다시 그린다
    override var isEmphasized: Bool {
        didSet {
            guard isEmphasized != oldValue else { return }
            applySelectionToCell()
            needsDisplay = true
        }
    }
    /// 재사용 풀에서 꺼내 쓰므로 이전 행의 상태를 지우고 시작한다
    override func prepareForReuse() {
        super.prepareForReuse()
        isDropTarget = false
    }

    /// 셀이 행보다 늦게 붙는 경우(reveal이 먼저 선택하고 그 뒤에 행이 재생성될 때)
    /// isSelected의 didSet만으로는 셀에 상태가 전달되지 않는다
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        applySelectionToCell()
    }

    private func applySelectionToCell() {
        subviews.compactMap { $0 as? NavCellView }.first?
            .setSelected(isSelected, emphasized: isEmphasized)
    }
    override func drawBackground(in dirtyRect: NSRect) {
        guard isDropTarget else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: FluentMetrics.paddingXS, dy: 1),
                                xRadius: FluentMetrics.cornerRadiusRow,
                                yRadius: FluentMetrics.cornerRadiusRow)
        FluentColors.dropTargetFill.setFill()
        path.fill()
        FluentColors.dropTargetStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Finder 사이드바 — 좌우를 띄운 둥근 알약. 포커스가 없으면 회색으로 흐려진다
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: FluentMetrics.paddingS, dy: 1)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: FluentMetrics.cornerRadiusSidebarRow,
                                yRadius: FluentMetrics.cornerRadiusSidebarRow)
        (isEmphasized ? FluentColors.selectionFill
                      : FluentColors.selectionFillInactive).setFill()
        path.fill()
    }
}

// MARK: - C-4: 커스텀 드래그 삽입선

final class WinderOutlineView: NSOutlineView {
    /// 드래그 피드백(삽입선·드롭 대상 강조)을 지워야 할 때 호출된다
    var onDragFeedbackShouldClear: (() -> Void)?

    /// 선택 알약이 좌우로 paddingS만큼 들어와 있어서, 그대로 두면 최상위 행의 펼침 삼각형이
    /// 알약 경계에 걸친다. 행 내용 전체를 알약 안쪽으로 밀어 준다
    private static let contentLeftInset = FluentMetrics.paddingS

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var rect = super.frameOfOutlineCell(atRow: row)
        rect.origin.x += Self.contentLeftInset
        return rect
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var rect = super.frameOfCell(atColumn: column, row: row)
        rect.origin.x += Self.contentLeftInset
        rect.size.width = max(0, rect.width - Self.contentLeftInset)
        return rect
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragFeedbackShouldClear?()
    }

    /// 드롭 없이 끝난 드래그(취소·허용되지 않는 위치에서 놓기)는 draggingExited가 오지 않을 수 있다.
    ///
    /// super를 부르면 안 된다 — draggingEnded:는 NSView·NSOutlineView 어디에도 구현이 없는
    /// 선택 메서드라 상위로 보내면 unrecognized selector 예외가 난다. AppKit이 그 예외를
    /// 삼켜 앱은 살아남지만 드래그 관리자가 망가진 채 남아, 그 뒤로 SwiftUI 쪽
    /// .onDrag/.draggable(아이콘·목록·갤러리 보기)이 아예 시작되지 않는다
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragFeedbackShouldClear?()
    }
}

/// Win11 스타일 드래그 삽입 표시선 — 2pt 가로선 + 좌측 6pt 원
final class WinderDropLineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        FluentColors.accent.setFill()
        let circleSize: CGFloat = 6
        let lineH: CGFloat = 2
        let yLine = (bounds.height - lineH) / 2
        // 좌측 원
        NSBezierPath(ovalIn: NSRect(x: 0, y: (bounds.height - circleSize) / 2,
                                    width: circleSize, height: circleSize)).fill()
        // 가로선
        NSBezierPath.fill(NSRect(x: circleSize - 1, y: yLine,
                                  width: bounds.width - circleSize + 1, height: lineH))
    }
}

extension OutlineViewRepresentable {
    typealias Coordinator = NavOutlineCoordinator
}
