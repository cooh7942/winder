import Foundation
import Darwin

/// 의사 터미널(PTY) 위에서 로그인 셸을 실행하는 세션.
///
/// forkpty를 쓰는 이유: BSD(macOS)에서는 슬레이브를 여는 것만으로 제어 터미널이 되지 않고
/// 자식에서 setsid + ioctl(TIOCSCTTY)를 직접 호출해야 한다. posix_spawn은 ioctl을 끼워 넣을 수 없다.
/// 제어 터미널이 있어야 작업 제어(Ctrl-C·Ctrl-Z), SIGWINCH, tcgetpgrp가 모두 정상 동작한다.
/// fork와 exec 사이에서는 async-signal-safe 호출(chdir·execve)만 쓰고,
/// argv·envp는 fork 전에 C 배열로 만들어 둔다.
final class PTYSession: @unchecked Sendable {
    /// 마스터에서 읽은 출력 (백그라운드 큐에서 호출)
    var onOutput: ((Data) -> Void)?
    /// 셸 종료
    var onExit: (() -> Void)?

    private(set) var childPID: pid_t = -1
    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "com.tjuxta.winder.pty", qos: .userInitiated)

    var isRunning: Bool { childPID > 0 }

    /// 포그라운드 프로세스 그룹이 셸 자신인지 — 프롬프트에서 대기 중인지 판단하는 용도
    var isAtPrompt: Bool {
        guard masterFD >= 0, childPID > 0 else { return false }
        return tcgetpgrp(masterFD) == childPID
    }

    /// 셸의 현재 작업 폴더를 커널에서 직접 읽는다.
    /// 셸 설정(OSC 7 전송)에 의존하지 않으므로 어떤 셸에서도 동작한다.
    var currentDirectory: URL? {
        guard childPID > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        // PROC_PIDVNODEPATHINFO — libproc.h의 값(9). Swift로 직접 노출되지 않아 상수로 쓴다
        guard proc_pidinfo(childPID, 9, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL
    }

    // MARK: - 시작 / 종료

    @discardableResult
    func start(directory: URL, columns: Int, rows: Int) -> Bool {
        guard !isRunning else { return true }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // 로그인 셸(-l)로 띄워 사용자 프로파일을 그대로 쓴다
        let argv = [(shell as NSString).lastPathComponent, "-l"]

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "Winder"
        if env["LANG"] == nil { env["LANG"] = "ko_KR.UTF-8" }
        // 부모가 물려준 값은 창 크기와 어긋날 수 있어 제거한다 (셸이 tty에서 직접 읽는다)
        env["COLUMNS"] = nil
        env["LINES"] = nil
        let envp = env.map { "\($0.key)=\($0.value)" }

        // fork 이후에는 Swift 런타임을 쓰지 않도록 문자열을 미리 C 배열로 만든다
        var argvPointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var envpPointers: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        let shellPath = strdup(shell)
        let directoryPath = strdup(directory.path)
        defer {
            argvPointers.forEach { free($0) }
            envpPointers.forEach { free($0) }
            free(shellPath)
            free(directoryPath)
        }

        var master: Int32 = -1
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)),
                           ws_xpixel: 0, ws_ypixel: 0)

        // forkpty: 자식에서 setsid + TIOCSCTTY + dup2(슬레이브, 0/1/2)까지 처리해 준다
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // 자식 — async-signal-safe 호출만 사용
            _ = chdir(directoryPath)
            _ = execve(shellPath, &argvPointers, &envpPointers)
            _exit(127)                                  // execve 실패
        }
        guard pid > 0, master >= 0 else {
            if master >= 0 { close(master) }
            return false
        }

        masterFD = master
        childPID = pid
        startReading()
        watchExit(pid: pid)
        return true
    }

    func terminate() {
        guard isRunning else { return }
        kill(childPID, SIGHUP)
    }

    // MARK: - 입출력

    func write(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        let fd = masterFD
        queue.async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    func write(_ text: String) { write(Data(text.utf8)) }

    /// 화면 크기 변경 통지 — 자식에게 SIGWINCH가 전달된다
    func setWindowSize(columns: Int, rows: Int) {
        guard masterFD >= 0, columns > 0, rows > 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    // MARK: - Private

    private func startReading() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else {
                // EOF — 셸 종료
                if count == 0 { self?.finish() }
                return
            }
            self?.onOutput?(Data(buffer[0..<count]))
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            close(self.masterFD)
            self.masterFD = -1
        }
        readSource = source
        source.resume()
    }

    private func watchExit(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            self?.finish()
        }
        exitSource = source
        source.resume()
    }

    private func finish() {
        guard childPID > 0 else { return }
        childPID = -1
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        onExit?()
    }

}
