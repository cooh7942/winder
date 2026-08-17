import Foundation
import Observation

/// 터미널 패널 상태 — PTY 세션과 화면 에뮬레이터를 잇는다.
///
/// 진짜 의사 터미널 위에서 로그인 셸을 돌리므로 vim·top처럼 화면을 직접 그리는 프로그램,
/// Ctrl-C 같은 작업 제어, 색상·프롬프트가 모두 실제 터미널과 동일하게 동작한다.
@Observable
@MainActor
final class TerminalViewModel {
    @ObservationIgnored let emulator: TerminalEmulator
    private(set) var isRunning = false
    /// 셸이 시작된 폴더
    private(set) var startDirectory: URL
    /// 셸의 현재 폴더 — OSC 7을 보내지 않는 셸에서는 시작 폴더가 그대로 남는다
    private(set) var currentDirectory: URL
    /// 화면 갱신 횟수. TerminalEmulator는 셀 단위로 수없이 바뀌므로 @Observable을 붙이지 않고,
    /// 출력 덩어리를 처리할 때마다 이 값만 올려 뷰에 알린다.
    private(set) var screenRevision = 0
    /// 셸이 알려주는 창 제목 (OSC 0/2)
    private(set) var title = ""

    @ObservationIgnored private let session = PTYSession()
    @ObservationIgnored private var columns = 80
    @ObservationIgnored private var rows = 24

    init(workingDirectory: URL) {
        self.startDirectory = workingDirectory.standardizedFileURL
        self.currentDirectory = workingDirectory.standardizedFileURL
        self.emulator = TerminalEmulator(rows: rows, cols: columns)

        // PTY 출력 → 에뮬레이터 (읽기는 백그라운드 큐에서 온다)
        session.onOutput = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.emulator.feed(data)
                self.screenRevision &+= 1
                self.title = self.emulator.title
                // 셸의 현재 폴더를 커널에서 읽어 헤더·cd 판단에 쓴다
                if let cwd = self.session.currentDirectory, cwd != self.currentDirectory {
                    self.currentDirectory = cwd
                }
            }
        }
        session.onExit = { [weak self] in
            Task { @MainActor in self?.handleShellExit() }
        }
        // 터미널이 호스트에 회신해야 하는 응답(DA·커서 위치)
        emulator.onReply = { [weak self] text in
            self?.session.write(text)
        }
    }

    // MARK: - 수명 주기

    /// 패널을 열 때 호출 — 셸이 없으면 그 폴더에서 새로 띄우고,
    /// 이미 떠 있으면 지금 보고 있는 폴더로 이동시킨다.
    /// (셸은 패널을 닫아도 살아 있으므로, 닫은 사이에 옮긴 폴더를 여기서 따라잡는다)
    func activate(in directory: URL?) {
        startIfNeeded(in: directory)
        followFolder(directory)
    }

    /// 셸이 없으면 현재 폴더에서 새로 띄운다
    private func startIfNeeded(in directory: URL?) {
        guard !isRunning else { return }
        if let directory {
            startDirectory = directory.standardizedFileURL
            currentDirectory = startDirectory
        }
        emulator.reset()
        isRunning = session.start(directory: startDirectory, columns: columns, rows: rows)
        if !isRunning {
            feedNotice("셸을 시작할 수 없습니다")
        }
    }

    func terminate() {
        session.terminate()
    }

    private func handleShellExit() {
        isRunning = false
        feedNotice("\r\n[셸이 종료되었습니다 — 터미널을 다시 열면 새로 시작합니다]\r\n")
    }

    // MARK: - 입출력

    func send(_ text: String) {
        guard isRunning else { return }
        session.write(text)
    }

    func resize(columns newColumns: Int, rows newRows: Int) {
        guard newColumns != columns || newRows != rows else { return }
        columns = newColumns
        rows = newRows
        emulator.resize(rows: newRows, cols: newColumns)
        session.setWindowSize(columns: newColumns, rows: newRows)
        screenRevision &+= 1
    }

    /// 탐색기에서 폴더를 옮겼을 때 — 프롬프트에서 대기 중일 때만 cd를 보낸다.
    /// 명령이 돌고 있는데 끼어들면 그 프로그램의 입력이 되어 버린다.
    func followFolder(_ url: URL?) {
        guard let url, isRunning, session.isAtPrompt else { return }
        let target = url.standardizedFileURL
        guard target != currentDirectory else { return }
        currentDirectory = target
        // Ctrl-U로 입력 중이던 줄을 비우고 cd 실행
        session.write("\u{15}cd \(Self.quoted(target.path))\n")
    }

    // MARK: - 보조

    /// 셸을 거치지 않고 화면에만 문구를 넣는다
    private func feedNotice(_ text: String) {
        emulator.feed(Data(text.utf8))
        screenRevision &+= 1
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
