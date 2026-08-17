import SwiftUI
import Observation

/// 창 하나 — 파일 목록 창(PaneViewModel)을 하나 또는 둘 보유한다.
///
/// 둘로 나누면 두 폴더를 나란히 놓고 서로 끌어다 놓을 수 있다.
/// 탐색 창(사이드바)은 창 전체가 하나만 쓰며, 활성 창의 폴더를 바꾼다.
@Observable
@MainActor
final class ExplorerWindowViewModel {
    private(set) var panes: [PaneViewModel]

    /// 사이드바 탐색이 대상으로 삼는 창 — 마지막으로 손댄 쪽
    var activePaneID: UUID

    /// 오른쪽 창 폭 — 왼쪽 창이 남는 공간을 갖는다
    var secondaryPaneWidth: CGFloat = FluentMetrics.paneDefaultWidth

    init() {
        let pane = PaneViewModel()
        panes = [pane]
        activePaneID = pane.id
    }

    var activePane: PaneViewModel {
        panes.first { $0.id == activePaneID } ?? panes[0]
    }

    var isSplit: Bool { panes.count > 1 }

    /// 오른쪽에 같은 폴더를 보는 창을 하나 더 열거나, 이미 있으면 닫는다
    func toggleSplit() {
        if isSplit {
            let removed = panes.removeLast()
            removed.shutdown()
            if activePaneID == removed.id { activePaneID = panes[0].id }
        } else {
            let start = activePane.tab.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
            let pane = PaneViewModel(location: .path(start))
            panes.append(pane)
            activePaneID = pane.id
        }
    }

    /// 창 안을 클릭하면 그쪽이 사이드바 탐색 대상이 된다
    func activate(_ pane: PaneViewModel) {
        guard activePaneID != pane.id else { return }
        activePaneID = pane.id
    }
}
