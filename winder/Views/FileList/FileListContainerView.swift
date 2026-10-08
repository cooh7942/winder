import SwiftUI

/// 파일 목록 컨테이너 — Phase 3: 파일 작업 연동, 삭제 확인 다이얼로그
struct FileListContainerView: View {
    @Environment(PaneViewModel.self) var pane

    /// A-1: 300ms 지연 스피너 — 첫 로드에서만, 빠른 폴더는 깜빡임 없이 지나감
    @State private var showSpinner = false
    @State private var spinnerTask: Task<Void, Never>?

    private var tab: TabViewModel { pane.tab }

    /// 즐겨찾기 URL 집합 — B-1: 캐시 사용으로 매번 북마크 해석 불필요
    private var favoriteURLs: Set<URL> {
        FavoritesStore.shared.resolvedURLs
    }

    var body: some View {
        ZStack {
            Color.fluentContentBackground

            // A-2: 전체 디스크 접근 권한 안내 — 오류 배너 대신 전용 안내 화면 표시
            if tab.needsFullDiskAccess {
                fullDiskAccessGuidance
            } else {
                // A-1: DetailsView 항상 마운트 — NSTableView 파괴·재생성·스크롤 리셋 방지
                // 자세히 보기에서만 표시, 나머지는 opacity 0 + hitTest 차단
                let bindable = Bindable(tab)
                DetailsView(
                    items: tab.items,
                    contentVersion: tab.contentVersion,
                    // 숨어 있는 동안 이름 변경을 시작하면 보이지 않는 칸이 포커스를 가져간다 —
                    // 다른 보기의 편집 칸이 입력을 받지 못하게 된다
                    renamingItemID: isDetailsModeActive ? tab.renamingItemID : nil,
                    selectedIDs: bindable.selectedIDs,
                    sortDescriptor: tab.sortDescriptor,
                    favoriteURLs: favoriteURLs,
                    currentURL: tab.currentURL,
                    onSort: { key in tab.sort(by: key) },
                    onAction: { action in handleAction(action, tab: tab) }
                )
                // 빈 폴더에서도 표시한다 — 숨기면 드롭 대상 강조가 보이지 않는다.
                // "이 폴더는 비어 있습니다" 안내는 ZStack에서 이 뷰보다 뒤에 놓여 위에 그려진다
                .opacity(isDetailsModeActive ? 1 : 0)
                .allowsHitTesting(isDetailsModeActive)

                // 아이콘 보기 (작은·보통·큰 크기 공용)
                if isIconModeActive {
                    IconsGridView(
                        items: tab.items,
                        iconSize: tab.viewMode.iconSize,
                        renamingItemID: tab.renamingItemID,
                        selectedIDs: bindable.selectedIDs,
                        favoriteURLs: favoriteURLs,
                        currentURL: tab.currentURL,
                        onOpen: { tab.openItem($0) },
                        onAction: { action in handleAction(action, tab: tab) }
                    )
                }

                // 갤러리 보기 — 큰 미리보기 + 아래 필름스트립
                if tab.viewMode == .gallery {
                    GalleryView(
                        items: tab.items,
                        contentVersion: tab.contentVersion,
                        renamingItemID: tab.renamingItemID,
                        selectedIDs: bindable.selectedIDs,
                        favoriteURLs: favoriteURLs,
                        currentURL: tab.currentURL,
                        onOpen: { tab.openItem($0) },
                        onAction: { action in handleAction(action, tab: tab) }
                    )
                }

                // 목록 보기
                if tab.viewMode == .list {
                    ListModeView(
                        items: tab.items,
                        renamingItemID: tab.renamingItemID,
                        selectedIDs: bindable.selectedIDs,
                        favoriteURLs: favoriteURLs,
                        currentURL: tab.currentURL,
                        onOpen: { tab.openItem($0) },
                        onAction: { action in handleAction(action, tab: tab) }
                    )
                }

                // 빈 폴더 안내 — 로딩 완료 후에만
                if tab.items.isEmpty && !tab.isLoading {
                    emptyState
                }

                // 오류 배너
                if let error = tab.errorMessage {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                            Text(error).fluentBody()
                        }
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(FluentMetrics.cornerRadiusControl)
                        .padding()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A-1: 첫 로드에서 300ms 이상 걸릴 때만 스피너 — 재로딩(항목 있음)은 표시 안 함
        .overlay(alignment: .center) {
            if showSpinner {
                ProgressView().controlSize(.regular)
            }
        }
        .onChange(of: tab.isLoading) { _, newValue in
            if newValue && tab.items.isEmpty {
                // 항목 없는 상태에서 로딩 시작 → 300ms 후에도 진행 중이면 스피너 표시
                spinnerTask?.cancel()
                spinnerTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    showSpinner = true
                }
            } else {
                // 로딩 완료 또는 재로딩(항목 이미 있음) → 스피너 필요 없음
                spinnerTask?.cancel()
                spinnerTask = nil
                showSpinner = false
            }
        }
        // 삭제 확인 다이얼로그 (휴지통으로 이동)
        .confirmationDialog(deleteDialogTitle(tab: tab),
                            isPresented: Bindable(tab).confirmingDelete,
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                Task { await tab.trashSelected() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 항목이 휴지통으로 이동됩니다.")
        }
        // 영구 삭제 확인 다이얼로그 (⇧Delete)
        .confirmationDialog(deleteDialogTitle(tab: tab),
                            isPresented: Bindable(tab).confirmingPermanentDelete,
                            titleVisibility: .visible) {
            Button("영구 삭제", role: .destructive) {
                Task { await tab.permanentlyDeleteSelected() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 항목이 영구적으로 삭제되며 복구할 수 없습니다.")
        }
    }

    // MARK: - A-2: 전체 디스크 접근 권한 안내

    private var fullDiskAccessGuidance: some View {
        VStack(spacing: FluentMetrics.paddingL) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(.fluentTextSecondary)

            Text("이 폴더를 보려면 전체 디스크 접근 권한이 필요합니다")
                .fluentSubtitle()
                .multilineTextAlignment(.center)

            Text("시스템 설정에서 Winder에 권한을 허용한 뒤\n앱을 다시 실행해 주세요.")
                .fluentBody()
                .foregroundColor(.fluentTextSecondary)
                .multilineTextAlignment(.center)

            Button("시스템 설정 열기") {
                let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
                NSWorkspace.shared.open(url)
            }
            .controlSize(.large)
        }
        .padding(FluentMetrics.paddingL)
        .frame(maxWidth: 400)
    }

    // MARK: - Action 라우팅

    private func handleAction(_ action: DetailsAction, tab: TabViewModel) {
        switch action {
        case .open(let item):
            tab.openItem(item)
        case .rename(let item, let newName):
            if newName.isEmpty {
                // F2 또는 컨텍스트 메뉴 "이름 바꾸기" — 이름 변경 모드 진입
                tab.renamingItemID = item.id
            } else {
                // 이름 변경 텍스트 필드 커밋
                Task { await tab.renameItem(item, to: newName) }
            }
        case .renameCancelled:
            tab.renamingItemID = nil
        case .createFolder:
            Task { await tab.createFolder() }
        case .createTextFile:
            Task { await tab.createTextFile() }
        case .delete:
            tab.confirmingDelete = true
        case .permanentDelete:
            tab.confirmingPermanentDelete = true
        case .copy:
            tab.copySelected()
        case .cut:
            tab.cutSelected()
        case .paste:
            Task { await tab.paste() }
        case .selectAll:
            tab.selectAll()
        case .undo:
            tab.undoLastAction()
        case .properties(let item):
            PropertiesWindowController.show(for: item)
        case .addToFavorites(let item):
            try? FavoritesStore.shared.add(url: item.url)
        case .removeFromFavorites(let item):
            FavoritesStore.shared.removeByURL(item.url)
        case .dropItems(let urls, let destination):
            // 복사할지 이동할지 놓은 자리에서 묻는다 — 탐색 창 트리의 드롭과 같은 흐름
            performFileDrop(urls, into: destination)
        }
    }

    private func deleteDialogTitle(tab: TabViewModel) -> String {
        let n = tab.selectedIDs.count
        if n == 1, let item = tab.selectedItems.first {
            return "'\(item.displayName)' 삭제"
        }
        return "선택한 항목 \(n)개 삭제"
    }

    private var emptyState: some View {
        Text("이 폴더는 비어 있습니다.")
            .fluentBody()
            .foregroundColor(.fluentTextSecondary)
    }

    private var isDetailsModeActive: Bool {
        switch tab.viewMode {
        case .details: return true
        default: return false
        }
    }

    private var isIconModeActive: Bool {
        switch tab.viewMode {
        case .largeIcons, .mediumIcons, .smallIcons: return true
        default: return false
        }
    }
}
