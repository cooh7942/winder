import SwiftUI
import AppKit

/// 나뉜 두 파일 목록 창 사이의 세로 구분선.
///
/// 오른쪽 창의 폭을 조절한다 — 오른쪽으로 끌면 오른쪽 창이 좁아지므로 델타를 빼서 쓴다.
/// 끄는 부분은 SidebarSplitter와 같은 SplitterView를 그대로 쓴다.
struct PaneSplitter: NSViewRepresentable {
    @Binding var width: CGFloat

    /// 드래그를 시작할 때의 폭 — 매 이벤트마다 더하지 않고 시작점 기준으로 계산한다
    final class Coordinator { var startWidth: CGFloat = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitterView {
        let view = SplitterView()
        // 두 창의 배경색이 같아서 선이 없으면 어디까지가 어느 창인지 안 보인다
        view.showsLine = true
        let coordinator = context.coordinator
        view.onDragBegan = { coordinator.startWidth = width }
        view.onDrag = { totalDelta in
            let proposed = coordinator.startWidth - totalDelta
            width = max(FluentMetrics.paneMinWidth, proposed)
        }
        view.onDoubleClick = {
            width = FluentMetrics.paneDefaultWidth
        }
        return view
    }

    func updateNSView(_ nsView: SplitterView, context: Context) {}
}
