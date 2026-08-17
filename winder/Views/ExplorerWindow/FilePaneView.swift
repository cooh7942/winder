import SwiftUI

/// 파일 목록 창 하나 — 도구 막대 + 파일 목록 (+ 터미널).
///
/// 창을 둘로 나누면 이 뷰가 좌우로 두 개 놓인다.
/// 터미널은 이 뷰 안에서만 위아래로 나뉘므로 옆 창을 침범하지 않는다.
struct FilePaneView: View {
    let pane: PaneViewModel
    /// 왼쪽(기본) 창인지 — 창 나누기 버튼을 여기에만 둔다
    let isPrimary: Bool
    /// 사이드바 탐색 대상인지 — 나뉜 상태에서만 테두리로 표시한다
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CommandBarView(showsSplitToggle: isPrimary)
                .frame(height: FluentMetrics.commandBarHeight)

            Rectangle().fill(Color.fluentDivider).frame(height: 1)

            FileListContainerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if pane.isTerminalVisible {
                TerminalSplitter(height: Bindable(pane).terminalHeight)
                    .frame(height: FluentMetrics.splitterHitWidth)

                TerminalPanelView()
                    .frame(height: pane.terminalHeight)
            }
        }
        .environment(pane)
        // 어느 창을 클릭하든 그쪽이 사이드바 탐색 대상이 된다
        .background(PaneActivationDetector(onActivate: onActivate))
        .overlay(alignment: .top) {
            // 나뉜 상태에서만 어느 쪽이 활성인지 알려 준다
            if isActive {
                Rectangle()
                    .fill(Color.fluentAccent)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        // 폴더를 옮기면 이 창의 터미널도 cd로 따라간다 (명령 실행 중에는 끼어들지 않는다)
        .onChange(of: pane.tab.currentURL) { _, newValue in
            guard pane.isTerminalVisible else { return }
            pane.terminal.followFolder(newValue)
        }
    }
}

// MARK: - 창 활성화 감지

/// 창 안 아무 곳이나 누르면 그 창을 활성으로 만든다.
///
/// SwiftUI 탭 제스처는 파일 목록(AppKit 표 뷰)이 먼저 가져가 호출되지 않으므로
/// 이벤트 모니터로 직접 받는다. 이벤트는 소비하지 않고 원래 대상에게 그대로 넘긴다.
private struct PaneActivationDetector: NSViewRepresentable {
    let onActivate: () -> Void

    func makeNSView(context: Context) -> PaneActivationView {
        let view = PaneActivationView()
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ nsView: PaneActivationView, context: Context) {
        nsView.onActivate = onActivate
    }
}

final class PaneActivationView: NSView {
    var onActivate: (() -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { removeMonitor(); return }
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.onActivate?()
            }
            return event
        }
    }

    deinit { removeMonitor() }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
