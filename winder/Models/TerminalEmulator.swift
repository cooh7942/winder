import Foundation
import AppKit

// 터미널 화면 모델 — PTY가 뱉는 xterm 제어 시퀀스를 해석해 셀 격자로 만든다.
// vim·top처럼 화면을 직접 그리는 프로그램이 돌아가려면 커서 이동·지우기·스크롤 영역·
// 대체 화면 버퍼까지 필요하므로 최소한의 VT100/xterm 집합을 직접 구현한다.

/// 셀 하나의 표시 속성
struct TerminalStyle: Equatable {
    enum Color: Equatable {
        case `default`
        case indexed(UInt8)      // 0-255 (0-15 ANSI, 16-255 팔레트)
        case rgb(UInt8, UInt8, UInt8)
    }
    var fg: Color = .default
    var bg: Color = .default
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
}

struct TerminalCell {
    var scalar: UnicodeScalar = " "
    var style = TerminalStyle()
    /// 폭 2인 문자(한글·한자·이모지)의 오른쪽 칸 — 그리지 않는다
    var isWideTrailer = false

    static let blank = TerminalCell()
}

@MainActor
final class TerminalEmulator {
    private(set) var rows: Int
    private(set) var cols: Int
    private(set) var screen: [[TerminalCell]]
    private(set) var scrollback: [[TerminalCell]] = []
    /// 상한을 넘겨 버린 스크롤백 줄 수 — 선택 영역이 절대 줄 번호를 쓰기 위한 기준점
    private(set) var discardedLines = 0
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private(set) var cursorVisible = true
    private(set) var title: String = ""
    /// 셸이 OSC 7로 알려준 현재 폴더
    private(set) var reportedDirectory: URL?
    /// 화면이 바뀔 때마다 증가 — 뷰가 다시 그릴지 판단하는 데 쓴다
    private(set) var revision = 0
    /// 대체 화면(vim 등) 사용 중인지 — 이때는 스크롤백을 쌓지 않는다
    private(set) var isAlternateScreen = false
    /// 커서 키가 애플리케이션 모드인지 (DECCKM) — 방향키 인코딩이 달라진다
    private(set) var applicationCursorKeys = false
    /// 붙여넣기를 감싸 보낼지 (bracketed paste)
    private(set) var bracketedPaste = false

    /// 터미널이 호스트에 회신해야 하는 바이트 (DA·DSR 응답)
    var onReply: ((String) -> Void)?

    private var style = TerminalStyle()
    private var savedCursor: (row: Int, col: Int, style: TerminalStyle)?
    private var savedScreen: [[TerminalCell]]?
    private var scrollTop = 0
    private var scrollBottom: Int
    private var autoWrap = true
    /// 다음 문자에서 줄바꿈해야 하는 상태 (오른쪽 끝에 문자를 찍은 직후)
    private var wrapPending = false
    private let maxScrollback = 3000

    // 파서 상태
    private enum State { case ground, escape, csi, osc, oscEscape, consumeOne }
    private var state: State = .ground
    private var csiParams = ""
    private var oscBuffer = ""
    /// UTF-8 조각 — 청크 경계에서 잘린 멀티바이트를 이어 붙인다
    private var pendingBytes: [UInt8] = []

    init(rows: Int = 24, cols: Int = 80) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.screen = Array(repeating: Array(repeating: TerminalCell.blank, count: self.cols),
                            count: self.rows)
        self.scrollBottom = self.rows - 1
    }

    // MARK: - 입력 처리

    func feed(_ data: Data) {
        pendingBytes.append(contentsOf: data)
        var index = 0
        let bytes = pendingBytes

        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                handle(UnicodeScalar(byte))
                index += 1
                continue
            }
            // 멀티바이트 — 길이를 보고 완성되었을 때만 소비한다
            let need: Int
            switch byte {
            case 0xC0...0xDF: need = 2
            case 0xE0...0xEF: need = 3
            case 0xF0...0xF7: need = 4
            default:          need = 1     // 잘못된 선두 바이트는 버린다
            }
            guard index + need <= bytes.count else { break }
            let slice = Array(bytes[index..<(index + need)])
            if let scalar = String(bytes: slice, encoding: .utf8)?.unicodeScalars.first {
                handle(scalar)
            }
            index += need
        }
        pendingBytes.removeFirst(index)
        revision &+= 1
    }

    // MARK: - 크기 변경

    func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(1, newRows), c = max(1, newCols)
        guard r != rows || c != cols else { return }

        var resized = screen.map { row -> [TerminalCell] in
            var line = row
            if line.count > c { line.removeSubrange(c...) }
            if line.count < c { line.append(contentsOf: Array(repeating: .blank, count: c - line.count)) }
            return line
        }

        // 화면은 아래쪽(프롬프트·커서 쪽)을 기준으로 붙잡는다.
        // 위쪽을 기준으로 늘리고 줄이면 마지막 줄이 위로 밀려 올라간 것처럼 보인다.
        if resized.count > r {
            let excess = resized.count - r
            if !isAlternateScreen { pushScrollback(Array(resized.prefix(excess))) }
            resized.removeFirst(excess)
            cursorRow -= excess                      // 지운 만큼 커서도 함께 올린다
        } else if resized.count < r {
            var missing = r - resized.count
            // 늘어난 만큼 스크롤백에서 되가져와 내용이 아래에 붙어 있게 한다
            if !isAlternateScreen {
                let restored = min(missing, scrollback.count)
                if restored > 0 {
                    let lines = scrollback.suffix(restored).map { line -> [TerminalCell] in
                        var copy = line
                        if copy.count > c { copy.removeSubrange(c...) }
                        if copy.count < c {
                            copy.append(contentsOf: Array(repeating: .blank, count: c - copy.count))
                        }
                        return copy
                    }
                    scrollback.removeLast(restored)
                    resized.insert(contentsOf: lines, at: 0)
                    cursorRow += restored
                    missing -= restored
                }
            }
            if missing > 0 {
                resized.append(contentsOf: Array(repeating: Array(repeating: TerminalCell.blank, count: c),
                                                 count: missing))
            }
        }

        screen = resized
        rows = r
        cols = c
        scrollTop = 0
        scrollBottom = r - 1
        cursorRow = max(0, min(cursorRow, r - 1))
        cursorCol = min(cursorCol, c - 1)
        wrapPending = false
        revision &+= 1
    }

    func reset() {
        screen = Array(repeating: Array(repeating: TerminalCell.blank, count: cols), count: rows)
        scrollback.removeAll()
        cursorRow = 0; cursorCol = 0
        style = TerminalStyle()
        scrollTop = 0; scrollBottom = rows - 1
        autoWrap = true; wrapPending = false
        cursorVisible = true
        isAlternateScreen = false
        savedScreen = nil
        revision &+= 1
    }

    // MARK: - 파서

    private func handle(_ scalar: UnicodeScalar) {
        switch state {
        case .ground:      ground(scalar)
        case .escape:      escape(scalar)
        case .csi:         csi(scalar)
        case .osc:         osc(scalar)
        case .oscEscape:   state = .ground          // ESC \ 의 '\'
        case .consumeOne:  state = .ground          // 문자셋 지정 등 한 글자 소비
        }
    }

    private func ground(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x1B: state = .escape
        case 0x07: break                                   // BEL
        case 0x08: cursorCol = max(0, cursorCol - 1); wrapPending = false
        case 0x09: tab()
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorCol = 0; wrapPending = false
        case 0x00...0x06, 0x0E...0x1A, 0x1C...0x1F: break   // 그 외 제어문자 무시
        default: put(scalar)
        }
    }

    private func escape(_ scalar: UnicodeScalar) {
        state = .ground
        switch scalar {
        case "[": csiParams = ""; state = .csi
        case "]": oscBuffer = ""; state = .osc
        case "7": savedCursor = (cursorRow, cursorCol, style)
        case "8": restoreCursor()
        case "D": index()
        case "M": reverseIndex()
        case "E": cursorCol = 0; index()
        case "c": reset()
        case "(", ")", "*", "+", "#", "%": state = .consumeOne
        case "=", ">": break                                // 키패드 모드 — 무시
        default: break
        }
    }

    private func csi(_ scalar: UnicodeScalar) {
        // 파라미터·중간 바이트는 모아 두고 최종 바이트(0x40...0x7E)에서 실행
        if scalar.value >= 0x40 && scalar.value <= 0x7E {
            state = .ground
            execute(final: Character(scalar))
        } else {
            csiParams.unicodeScalars.append(scalar)
        }
    }

    private func osc(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x07:                                    // BEL로 종료
            finishOSC(); state = .ground
        case 0x1B:
            finishOSC(); state = .oscEscape
        default:
            oscBuffer.unicodeScalars.append(scalar)
        }
    }

    private func finishOSC() {
        let parts = oscBuffer.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        defer { oscBuffer = "" }
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "0", "2":
            title = String(parts[1])
        case "7":
            // OSC 7 — 셸이 알려주는 현재 폴더 (macOS 기본 zshrc가 chpwd에서 보낸다)
            if let url = URL(string: String(parts[1])), url.isFileURL {
                reportedDirectory = url.standardizedFileURL
            }
        default: break
        }
    }

    // MARK: - CSI 실행

    private func execute(final: Character) {
        let isPrivate = csiParams.hasPrefix("?")
        let body = isPrivate ? String(csiParams.dropFirst()) : csiParams
        let params = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func param(_ i: Int, _ fallback: Int = 1) -> Int {
            guard i < params.count, params[i] > 0 else { return fallback }
            return params[i]
        }

        switch final {
        case "A": cursorRow = max(scrollTop, cursorRow - param(0)); wrapPending = false
        case "B": cursorRow = min(scrollBottom, cursorRow + param(0)); wrapPending = false
        case "C": cursorCol = min(cols - 1, cursorCol + param(0)); wrapPending = false
        case "D": cursorCol = max(0, cursorCol - param(0)); wrapPending = false
        case "E": cursorRow = min(scrollBottom, cursorRow + param(0)); cursorCol = 0
        case "F": cursorRow = max(scrollTop, cursorRow - param(0)); cursorCol = 0
        case "G", "`": cursorCol = clampCol(param(0) - 1)
        case "d": cursorRow = clampRow(param(0) - 1)
        case "H", "f":
            cursorRow = clampRow(param(0) - 1)
            cursorCol = clampCol(param(1) - 1)
            wrapPending = false
        case "J": eraseInDisplay(params.first ?? 0)
        case "K": eraseInLine(params.first ?? 0)
        case "L": insertLines(param(0))
        case "M": deleteLines(param(0))
        case "P": deleteChars(param(0))
        case "@": insertChars(param(0))
        case "X": eraseChars(param(0))
        case "S": scrollUp(param(0))
        case "T": scrollDown(param(0))
        case "m": applySGR(params.isEmpty ? [0] : params)
        case "r":
            scrollTop = clampRow(param(0) - 1)
            scrollBottom = clampRow(param(1, rows) - 1)
            if scrollTop >= scrollBottom { scrollTop = 0; scrollBottom = rows - 1 }
            cursorRow = scrollTop; cursorCol = 0
        case "s": savedCursor = (cursorRow, cursorCol, style)
        case "u": restoreCursor()
        case "h": setMode(params, private: isPrivate, enabled: true)
        case "l": setMode(params, private: isPrivate, enabled: false)
        case "c": onReply?("\u{1B}[?6c")                        // VT102 응답
        case "n":
            if params.first == 6 { onReply?("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R") }
        default: break
        }
    }

    private func setMode(_ params: [Int], private isPrivate: Bool, enabled: Bool) {
        guard isPrivate else { return }
        for mode in params {
            switch mode {
            case 1:    applicationCursorKeys = enabled
            case 7:    autoWrap = enabled
            case 25:   cursorVisible = enabled
            case 2004: bracketedPaste = enabled
            case 47, 1047, 1049:
                if enabled { enterAlternateScreen(saveCursor: mode == 1049) }
                else { leaveAlternateScreen(restoreCursor: mode == 1049) }
            default: break                                       // 마우스 보고 등은 무시
            }
        }
    }

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0:  style = TerminalStyle()
            case 1:  style.bold = true
            case 2:  style.dim = true
            case 3:  style.italic = true
            case 4:  style.underline = true
            case 7:  style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37:   style.fg = .indexed(UInt8(code - 30))
            case 39:        style.fg = .default
            case 40...47:   style.bg = .indexed(UInt8(code - 40))
            case 49:        style.bg = .default
            case 90...97:   style.fg = .indexed(UInt8(code - 90 + 8))
            case 100...107: style.bg = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                // 38;5;n (팔레트) / 38;2;r;g;b (트루컬러)
                guard i + 1 < params.count else { i = params.count; break }
                let isForeground = code == 38
                if params[i + 1] == 5, i + 2 < params.count {
                    let color = TerminalStyle.Color.indexed(UInt8(clamping: params[i + 2]))
                    if isForeground { style.fg = color } else { style.bg = color }
                    i += 2
                } else if params[i + 1] == 2, i + 4 < params.count {
                    let color = TerminalStyle.Color.rgb(UInt8(clamping: params[i + 2]),
                                                        UInt8(clamping: params[i + 3]),
                                                        UInt8(clamping: params[i + 4]))
                    if isForeground { style.fg = color } else { style.bg = color }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    // MARK: - 화면 조작

    private func put(_ scalar: UnicodeScalar) {
        let width = Self.displayWidth(of: scalar)
        guard width > 0 else { return }               // 결합 문자 등은 생략

        if wrapPending || cursorCol + width > cols {
            if autoWrap {
                cursorCol = 0
                lineFeed()
            } else {
                cursorCol = min(cursorCol, cols - width)
            }
            wrapPending = false
        }

        screen[cursorRow][cursorCol] = TerminalCell(scalar: scalar, style: style, isWideTrailer: false)
        if width == 2, cursorCol + 1 < cols {
            screen[cursorRow][cursorCol + 1] = TerminalCell(scalar: " ", style: style, isWideTrailer: true)
        }
        cursorCol += width
        if cursorCol >= cols {
            cursorCol = cols - 1
            wrapPending = true
        }
    }

    private func tab() {
        let next = ((cursorCol / 8) + 1) * 8
        cursorCol = min(cols - 1, next)
    }

    private func lineFeed() {
        wrapPending = false
        index()
    }

    private func index() {
        if cursorRow == scrollBottom { scrollUp(1) }
        else { cursorRow = min(rows - 1, cursorRow + 1) }
    }

    private func reverseIndex() {
        if cursorRow == scrollTop { scrollDown(1) }
        else { cursorRow = max(0, cursorRow - 1) }
    }

    private func scrollUp(_ count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        let removed = Array(screen[scrollTop..<(scrollTop + n)])
        // 전체 화면을 쓰는 일반 버퍼에서만 스크롤백에 쌓는다
        if !isAlternateScreen && scrollTop == 0 && scrollBottom == rows - 1 {
            pushScrollback(removed)
        }
        screen.removeSubrange(scrollTop..<(scrollTop + n))
        screen.insert(contentsOf: Array(repeating: blankLine(), count: n), at: scrollBottom - n + 1)
    }

    private func scrollDown(_ count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        screen.removeSubrange((scrollBottom - n + 1)...scrollBottom)
        screen.insert(contentsOf: Array(repeating: blankLine(), count: n), at: scrollTop)
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        screen.removeSubrange((scrollBottom - n + 1)...scrollBottom)
        screen.insert(contentsOf: Array(repeating: blankLine(), count: n), at: cursorRow)
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursorRow + 1)
        screen.removeSubrange(cursorRow..<(cursorRow + n))
        screen.insert(contentsOf: Array(repeating: blankLine(), count: n), at: scrollBottom - n + 1)
    }

    private func insertChars(_ count: Int) {
        let n = min(count, cols - cursorCol)
        guard n > 0 else { return }
        screen[cursorRow].removeSubrange((cols - n)..<cols)
        screen[cursorRow].insert(contentsOf: Array(repeating: styledBlank(), count: n), at: cursorCol)
    }

    private func deleteChars(_ count: Int) {
        let n = min(count, cols - cursorCol)
        guard n > 0 else { return }
        screen[cursorRow].removeSubrange(cursorCol..<(cursorCol + n))
        screen[cursorRow].append(contentsOf: Array(repeating: styledBlank(), count: n))
    }

    private func eraseChars(_ count: Int) {
        let end = min(cols, cursorCol + count)
        for col in cursorCol..<end { screen[cursorRow][col] = styledBlank() }
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: for col in cursorCol..<cols { screen[cursorRow][col] = styledBlank() }
        case 1: for col in 0...min(cursorCol, cols - 1) { screen[cursorRow][col] = styledBlank() }
        case 2: screen[cursorRow] = blankLine()
        default: break
        }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows { screen[row] = blankLine() }
            }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow { screen[row] = blankLine() }
        case 2, 3:
            screen = Array(repeating: blankLine(), count: rows)
            if mode == 3 { scrollback.removeAll() }
        default: break
        }
    }

    // MARK: - 대체 화면

    private func enterAlternateScreen(saveCursor: Bool) {
        guard !isAlternateScreen else { return }
        if saveCursor { savedCursor = (cursorRow, cursorCol, style) }
        savedScreen = screen
        screen = Array(repeating: blankLine(), count: rows)
        isAlternateScreen = true
        cursorRow = 0; cursorCol = 0
    }

    private func leaveAlternateScreen(restoreCursor shouldRestore: Bool) {
        guard isAlternateScreen, let saved = savedScreen else { return }
        screen = saved
        savedScreen = nil
        isAlternateScreen = false
        if shouldRestore { restoreCursor() }
    }

    private func restoreCursor() {
        guard let saved = savedCursor else { return }
        cursorRow = clampRow(saved.row)
        cursorCol = clampCol(saved.col)
        style = saved.style
        wrapPending = false
    }

    // MARK: - 보조

    private func blankLine() -> [TerminalCell] {
        Array(repeating: TerminalCell.blank, count: cols)
    }

    /// 현재 배경색을 유지한 공백 — 지우기 연산은 배경색을 남기는 것이 맞다
    private func styledBlank() -> TerminalCell {
        var cell = TerminalCell.blank
        cell.style.bg = style.bg
        return cell
    }

    private func pushScrollback(_ lines: [[TerminalCell]]) {
        scrollback.append(contentsOf: lines)
        if scrollback.count > maxScrollback {
            let excess = scrollback.count - maxScrollback
            scrollback.removeFirst(excess)
            discardedLines += excess
        }
    }

    /// 스크롤백 + 현재 화면을 이어 붙인 가상 버퍼에서 index번째 줄
    func line(at index: Int) -> [TerminalCell]? {
        if index < 0 { return nil }
        if index < scrollback.count { return scrollback[index] }
        let screenIndex = index - scrollback.count
        return screenIndex < screen.count ? screen[screenIndex] : nil
    }

    /// 가상 버퍼의 전체 줄 수
    var totalLines: Int { scrollback.count + screen.count }

    private func clampRow(_ value: Int) -> Int { max(0, min(rows - 1, value)) }
    private func clampCol(_ value: Int) -> Int { max(0, min(cols - 1, value)) }

    /// 표시 폭 — 한글·CJK·이모지는 2칸을 차지한다.
    /// wcwidth는 setlocale(LC_CTYPE) 상태에 따라 비ASCII에 -1을 돌려주므로 쓰지 않고
    /// East Asian Wide/Fullwidth 범위를 직접 판정한다. 셀 격자와 커서 위치가 여기에 달려 있다.
    static func displayWidth(of scalar: UnicodeScalar) -> Int {
        let value = scalar.value
        if value == 0 { return 0 }
        if value < 0x0300 { return 1 }                       // ASCII·라틴 확장

        // 결합 문자(악센트·한글 자모 결합 등)는 앞 글자에 붙으므로 0칸
        switch value {
        case 0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD,
             0x200B...0x200F, 0xFE00...0xFE0F, 0xFE20...0xFE2F:
            return 0
        default: break
        }

        switch value {
        case 0x1100...0x115F,        // 한글 자모
             0x2E80...0x303E,        // CJK 부수·기호
             0x3041...0x33FF,        // 히라가나·가타카나·한글 호환 자모·CJK 기호
             0x3400...0x4DBF,        // CJK 확장 A
             0x4E00...0x9FFF,        // CJK 통합 한자
             0xA000...0xA4CF,        // 이 문자
             0xAC00...0xD7A3,        // 한글 음절
             0xF900...0xFAFF,        // CJK 호환 한자
             0xFE10...0xFE19, 0xFE30...0xFE6F,
             0xFF00...0xFF60,        // 전각 형태
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,      // 이모지
             0x1F900...0x1F9FF,
             0x20000...0x3FFFD:      // CJK 확장 B 이상
            return 2
        default:
            return 1
        }
    }
}
