import SwiftUI
import AppKit

/// Winder 메인 창
///
/// 레이아웃: 왼쪽 탐색 창이 창 전체 높이를 차지하고,
/// 오른쪽은 파일 목록 창(FilePaneView)이 하나 또는 둘 놓인다.
/// 트래픽 라이트는 탐색 창 위쪽 여백에 겹쳐 놓는다(fullSizeContentView).
struct ExplorerWindow: View {
    @State private var windowVM = ExplorerWindowViewModel()
    @State private var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "com.tjuxta.winder.sidebarWidth")
        guard saved > 0 else { return FluentMetrics.sidebarDefaultWidth }
        return max(FluentMetrics.sidebarMinWidth, min(FluentMetrics.sidebarMaxWidth, saved))
    }()

    var body: some View {
        ZStack {
            Color.fluentWindowBackground
                .ignoresSafeArea()

            HStack(spacing: 0) {
                // ① 탐색 창 — 창 전체 높이. 위쪽은 트래픽 라이트 자리를 비워 둔다
                NavigationPaneView()
                    .frame(width: sidebarWidth)

                // 이 폭이 곧 두 창 사이의 빈 공간이다
                Color.clear
                    .frame(width: FluentMetrics.sidebarContentGap)
                    .overlay {
                        // 잡기 편하도록 히트 영역은 간격보다 넓게 두고,
                        // 패널 오른쪽 끝선이 그 가운데 오도록 왼쪽으로 당긴다
                        SidebarSplitter(width: $sidebarWidth)
                            .frame(width: FluentMetrics.splitterHitWidth)
                            .offset(x: -FluentMetrics.sidebarContentGap / 2)
                    }

                // ② 파일 목록 창 — 나누면 오른쪽에 하나 더 붙는다
                filePanes
            }
        }
        // 복사·이동 진행 — 카드 영역만 차지하므로 나머지 화면 클릭은 그대로 통과한다
        .overlay(alignment: .bottomTrailing) {
            TransferProgressPanel()
        }
        // 최소 크기를 주지 않으면 창이 콘텐츠 최소치까지 쪼그라든다
        .frame(minWidth: 900, minHeight: 560)
        .background(WindowAccessor())
        .ignoresSafeArea()
        .onChange(of: sidebarWidth) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "com.tjuxta.winder.sidebarWidth")
        }
        // ExplorerWindowViewModel을 환경으로 주입 — 모든 자식 뷰가 접근 가능
        .environment(windowVM)
        // "이동" 메뉴는 지금 앞에 있는 창의, 그중에서도 활성 파일 목록 창을 대상으로 한다
        .focusedSceneValue(\.explorerTab, ExplorerTabFocus(tab: windowVM.activePane.tab))
    }

    /// 파일 목록 창 하나 또는 둘 — 나뉜 상태에서는 가운데 구분자로 폭을 조절한다
    @ViewBuilder private var filePanes: some View {
        let panes = windowVM.panes
        HStack(spacing: 0) {
            pane(panes[0], isPrimary: true)
                .frame(maxWidth: .infinity)
                .frame(minWidth: FluentMetrics.paneMinWidth)

            if panes.count > 1 {
                PaneSplitter(width: Bindable(windowVM).secondaryPaneWidth)
                    .frame(width: FluentMetrics.splitterHitWidth)

                pane(panes[1], isPrimary: false)
                    .frame(width: windowVM.secondaryPaneWidth)
            }
        }
    }

    private func pane(_ model: PaneViewModel, isPrimary: Bool) -> some View {
        FilePaneView(
            pane: model,
            isPrimary: isPrimary,
            // 창이 하나뿐이면 활성 표시가 의미 없다
            isActive: windowVM.isSplit && windowVM.activePaneID == model.id,
            onActivate: { windowVM.activate(model) }
        )
    }
}

// MARK: - WindowAccessor

/// 창이 만들어진 뒤 NSWindow를 잡아 외양을 설정한다
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAttachView {
        // makeNSView·updateNSView 시점에는 view.window가 아직 nil이라 놓칠 수 있다.
        // 창에 실제로 붙는 순간을 viewDidMoveToWindow로 정확히 잡는다
        let view = WindowAttachView()
        view.onAttach = { window in
            configure(window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachView, context: Context) {}

    private func configure(_ window: NSWindow, coordinator: Box) {
        guard !coordinator.configured else { return }
        coordinator.configured = true

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = true
        window.backgroundColor = FluentColors.windowBackground
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 720, height: 480)

        // 타이틀바 영역을 titleBarHeight까지 넓히는 더미 accessory.
        // 이게 없으면 기본 타이틀바 높이(약 30pt)에서 트래픽 라이트를 아래로 내렸을 때
        // 버튼이 잘려 아예 보이지 않는다 — TrafficLightPositioner가 동작할 공간을 만든다
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        let accessoryView = NSView()
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accessoryView.widthAnchor.constraint(equalToConstant: 1),
            accessoryView.heightAnchor.constraint(equalToConstant: FluentMetrics.titleBarHeight),
        ])
        accessory.view = accessoryView
        window.addTitlebarAccessoryViewController(accessory)

        // 위 설정으로 타이틀바가 다시 배치된 뒤에 버튼 위치를 잡는다 —
        // 배치 전에 재면 기준 위치를 잘못 기억한다
        DispatchQueue.main.async { coordinator.trafficLights.attach(to: window) }
    }

    func makeCoordinator() -> Box { Box() }
    final class Box {
        var configured = false
        let trafficLights = TrafficLightPositioner()
    }
}

/// 창에 붙는 순간을 알려 주는 빈 뷰
final class WindowAttachView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onAttach?(window) }
    }
}

// MARK: - 트래픽 라이트 위치

/// 트래픽 라이트를 탐색 창 패널 안쪽으로 들여 놓는다 — 기본 위치에서는 버튼이 패널의
/// 둥근 모서리를 파고든다. AppKit이 타이틀바를 다시 배치하면 원래 자리로 돌아가므로
/// 창 크기 변경·전체 화면 전환 때마다 다시 맞춘다.
private final class TrafficLightPositioner {
    /// AppKit이 놓은 원래 위치 — 여기에 여백을 더해 목표 위치를 계산한다.
    /// 현재 위치를 기준으로 더하면 다시 맞출 때마다 계속 밀려난다
    private var groupOrigin: NSPoint?
    private var observers: [NSObjectProtocol] = []

    func attach(to window: NSWindow) {
        apply(to: window)
        let names: [NSNotification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self, weak window] _ in
                    guard let window else { return }
                    self?.apply(to: window)
                }
            )
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func apply(to window: NSWindow) {
        // 전체 화면에서는 OS가 버튼을 따로 관리한다 — 건드리지 않는다
        guard !window.styleMask.contains(.fullScreen) else { return }
        let inset = FluentMetrics.trafficLightInset

        guard let group = window.standardWindowButton(.closeButton)?.superview else { return }
        let base = groupOrigin ?? group.frame.origin
        groupOrigin = base
        // 타이틀바는 뒤집히지 않은 좌표계 — 아래로 내리려면 y를 줄인다
        let target = NSPoint(x: base.x + inset, y: base.y - inset)
        if group.frame.origin != target { group.setFrameOrigin(target) }
    }
}

#Preview {
    ExplorerWindow()
        .frame(width: 1100, height: 700)
}
