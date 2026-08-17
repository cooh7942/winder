import SwiftUI
import Observation

/// 파일 목록 창 하나 — 폴더 위치와 터미널을 각자 갖는다.
///
/// 창을 둘로 나누면 이 모델이 두 개 생기고 서로 간섭하지 않는다.
/// 한쪽에서 폴더를 옮기거나 터미널을 열어도 다른 쪽은 그대로다.
@Observable
@MainActor
final class PaneViewModel: Identifiable {
    let id = UUID()

    let tab: TabViewModel
    /// 터미널 패널 — 숨겼다 다시 열어도 출력·히스토리가 남도록 창이 보유한다
    let terminal: TerminalViewModel

    /// 파일 목록 아래 터미널 패널 표시 여부
    var isTerminalVisible = false {
        didSet {
            guard isTerminalVisible, isTerminalVisible != oldValue else { return }
            // 열 때 현재 폴더에서 시작 — 이미 떠 있는 셸이면 그 폴더로 이동시킨다
            terminal.activate(in: tab.currentURL)
        }
    }

    /// 터미널 패널 높이 — 나뉜 창마다 따로 조절한다 (저장값은 하나를 공유)
    var terminalHeight: CGFloat = PaneViewModel.savedTerminalHeight {
        didSet {
            UserDefaults.standard.set(terminalHeight, forKey: Self.terminalHeightKey)
        }
    }

    init(location: ShellLocation = .home) {
        tab = TabViewModel(location: location)
        terminal = TerminalViewModel(
            workingDirectory: tab.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        )
        tab.reload()
    }

    /// 창을 닫을 때 셸을 정리한다 — 안 하면 보이지 않는 셸이 계속 남는다
    func shutdown() {
        terminal.terminate()
    }

    // MARK: - 저장값

    private static let terminalHeightKey = "com.tjuxta.winder.terminalHeight"

    private static var savedTerminalHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: terminalHeightKey)
        guard saved > 0 else { return FluentMetrics.terminalDefaultHeight }
        return max(FluentMetrics.terminalMinHeight, min(FluentMetrics.terminalMaxHeight, saved))
    }
}
