import SwiftUI
import AppKit

/// 파일 목록과 터미널 패널 사이의 가로 구분선 — SidebarSplitter의 세로 방향 판
/// 위로 끌면 터미널이 커지므로 델타 부호를 뒤집어 쓴다.
struct TerminalSplitter: NSViewRepresentable {
    @Binding var height: CGFloat

    /// 드래그를 시작할 때의 높이 — 사이드바 스플리터와 같은 이유로 시작점 기준 계산
    final class Coordinator { var startHeight: CGFloat = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HorizontalSplitterView {
        let view = HorizontalSplitterView()
        let coordinator = context.coordinator
        view.onDragBegan = { coordinator.startHeight = height }
        view.onDrag = { totalDelta in
            // AppKit 좌표는 위로 갈수록 y가 커진다 → 위로 끌면 터미널 높이 증가
            let proposed = coordinator.startHeight + totalDelta
            height = max(FluentMetrics.terminalMinHeight,
                         min(FluentMetrics.terminalMaxHeight, proposed))
        }
        view.onDoubleClick = {
            height = FluentMetrics.terminalDefaultHeight
        }
        return view
    }

    func updateNSView(_ nsView: HorizontalSplitterView, context: Context) {}
}

final class HorizontalSplitterView: NSView {
    /// 드래그 시작 알림 — 이 시점의 높이를 기준으로 잡는다
    var onDragBegan: (() -> Void)?
    /// 드래그 시작점 기준 누적 이동량
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    private var dragOriginY: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: FluentMetrics.splitterHitWidth)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
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
        NSCursor.resizeUpDown.set()
    }

    override func mouseDown(with event: NSEvent) {
        // 창 좌표 기준 — 뷰가 드래그와 함께 움직이므로 뷰 좌표로 재면 기준이 흔들린다
        dragOriginY = event.locationInWindow.y
        if event.clickCount == 2 { onDoubleClick?() } else { onDragBegan?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.y - dragOriginY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1).fill()
    }
}
