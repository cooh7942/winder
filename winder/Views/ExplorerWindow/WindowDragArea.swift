import SwiftUI
import AppKit

/// 타이틀바 대신 쓰는 빈 자리 — 끌면 창이 움직이고, 더블클릭하면 타이틀바처럼 동작한다.
/// 타이틀바를 없앴으므로(fullSizeContentView) 이 역할을 할 곳이 따로 필요하다.
/// 지금은 탐색 창 위쪽(트리 위 빈 곳)에 놓여 있다.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaView { DragAreaView() }
    func updateNSView(_ nsView: DragAreaView, context: Context) {}
}

final class DragAreaView: NSView {
    /// 창 이동은 창 서버가 처리한다 — 시스템 창 이동과 동작·성능이 같다
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}

    private var doubleClickMonitor: Any?

    /// mouseDownCanMoveWindow가 켜져 있으면 AppKit이 mouseDown을 창 이동에 써 버려
    /// 이 뷰의 mouseDown도, 위에 얹은 SwiftUI 탭 제스처도 호출되지 않는다.
    /// 그래서 더블클릭만 이벤트 모니터로 직접 받는다.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { removeMonitor(); return }
        guard doubleClickMonitor == nil else { return }

        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, let window = self.window,
                  event.clickCount == 2, event.window === window else { return event }
            // 이 뷰는 컨트롤이 없는 빈 자리에만 놓이므로 영역 안이면 곧 "빈 곳 더블클릭"이다
            guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                return event
            }
            self.performDoubleClickAction(on: window)
            return nil          // 창 이동으로 넘어가지 않도록 여기서 소비한다
        }
    }

    deinit { removeMonitor() }

    private func removeMonitor() {
        guard let monitor = doubleClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        doubleClickMonitor = nil
    }

    /// 시스템 설정 "제목 막대를 이중 클릭하여 …"를 따른다 (확대 / 최소화 / 아무것도 안 함)
    private func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None":     break
        default:         window.zoom(nil)   // 설정이 없으면 macOS 기본값인 확대
        }
    }
}
