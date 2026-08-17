import SwiftUI
import AppKit

/// 사이드바 구분선 — AppKit 기반 드래그·커서 처리
/// SwiftUI SidebarResizeHandle 대체: NSCursor.push/pop 스택 불균형 없이 resetCursorRects 사용
struct SidebarSplitter: NSViewRepresentable {
    @Binding var width: CGFloat

    /// 드래그를 시작할 때의 폭 — 매 이벤트마다 더하지 않고 시작점 기준으로 계산한다
    final class Coordinator { var startWidth: CGFloat = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitterView {
        let view = SplitterView()
        let coordinator = context.coordinator
        view.onDragBegan = { coordinator.startWidth = width }
        view.onDrag = { totalDelta in
            let proposed = coordinator.startWidth + totalDelta
            width = max(FluentMetrics.sidebarMinWidth, min(FluentMetrics.sidebarMaxWidth, proposed))
        }
        view.onDoubleClick = {
            width = FluentMetrics.sidebarDefaultWidth
        }
        return view
    }

    func updateNSView(_ nsView: SplitterView, context: Context) {}
}

final class SplitterView: NSView {
    /// 드래그 시작 알림 — 이 시점의 폭을 기준으로 잡는다
    var onDragBegan: (() -> Void)?
    /// 드래그 시작점 기준 누적 이동량
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    /// 가운데 세로 구분선을 그릴지 — 탐색 창 쪽은 색 차이로 경계가 보여 끄고,
    /// 나뉜 두 파일 목록 창 사이는 배경색이 같아 선이 있어야 구분된다
    var showsLine = false {
        didSet { if showsLine != oldValue { needsDisplay = true } }
    }

    private var dragOriginX: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(width: FluentMetrics.splitterHitWidth, height: NSView.noIntrinsicMetric)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let new = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .cursorUpdate, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(new)
        trackingArea = new
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        // 창 좌표를 쓴다 — 드래그 도중 이 뷰 자체가 함께 움직이므로
        // 뷰 좌표로 델타를 재면 기준점이 흔들려 사이드바가 좌우로 떨린다
        dragOriginX = event.locationInWindow.x
        if event.clickCount == 2 { onDoubleClick?() } else { onDragBegan?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - dragOriginX)
    }

    // 탐색 창 쪽(showsLine = false)은 패널과 창 배경의 색 차이로 경계가 보이므로
    // 선을 그리지 않는다. 이 뷰는 끌어서 폭을 바꾸는 영역과 커서 모양을 담당한다
    override func draw(_ dirtyRect: NSRect) {
        guard showsLine else { return }
        FluentColors.divider.setFill()
        NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
    }
}
