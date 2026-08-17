import SwiftUI

/// 탐색 창 — Phase 2: NSOutlineView 기반 실제 파일시스템 트리
struct NavigationPaneView: View {
    @Environment(ExplorerWindowViewModel.self) var windowVM
    @State private var selectedURL: URL? = nil

    /// 사이드바는 창 전체에 하나뿐이라 활성 창의 폴더를 바꾼다
    private var tab: TabViewModel { windowVM.activePane.tab }

    var body: some View {
        ZStack {
            // Finder처럼 트리를 둥근 패널 안에 담는다.
            // 아웃라인 뷰 자체는 같은 색으로 불투명하게 칠하므로(잔상 방지) 모서리를 깎을 수 없다 —
            // 대신 아래 여백만큼 안쪽으로 들여 놓아 둥근 모서리를 침범하지 않게 한다.
            RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusPanel, style: .continuous)
                .fill(Color.fluentSidebarBackground)

            OutlineViewRepresentable(
                selectedURL: $selectedURL,
                currentURL: tab.currentURL,
                favorites: FavoritesStore.shared.items,
                favoritesCacheVersion: FavoritesStore.shared.cacheVersion,
                highlightedFavoriteID: FavoritesStore.shared.highlightedID,
                networkServers: NetworkBrowserService.shared.servers.map(\.name),
                onNavigate: { url in
                    tab.navigate(to: url)
                    selectedURL = url
                }
            )
            // 위쪽은 트래픽 라이트 자리 — 여기까지 목록이 올라오면 버튼과 겹친다
            .padding(.top, FluentMetrics.titleBarHeight)
            .padding(.bottom, FluentMetrics.cornerRadiusPanel)
            // 네트워크 서버 탐색 시작 — 트리의 "네트워크" 항목을 채운다
            .onAppear { NetworkBrowserService.shared.start() }
        }
        // 트리 위쪽 빈 자리가 타이틀바 역할을 한다 — 끌면 창이 움직이고 더블클릭하면 확대.
        // 트래픽 라이트와 겹치면 버튼 더블클릭까지 가로채므로 그만큼 비워 둔다
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: FluentMetrics.titleBarHeight)
                .padding(.leading, FluentMetrics.trafficLightAreaWidth)
        }
        // 패널을 창 가장자리에서 띄워 상자처럼 보이게 한다.
        // 오른쪽은 ExplorerWindow가 sidebarContentGap으로 따로 잡는다
        .padding(.leading, FluentMetrics.paddingS)
        .padding(.vertical, FluentMetrics.paddingS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
