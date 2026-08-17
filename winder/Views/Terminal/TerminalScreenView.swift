import SwiftUI
import AppKit

/// 터미널 화면 — 셀 격자를 직접 그리고 키 입력을 PTY 바이트로 인코딩한다.
/// SwiftUI Text로 셀을 그리면 정렬·성능 모두 감당이 안 되므로 NSView에서 직접 그린다.
struct TerminalScreenView: NSViewRepresentable {
    let emulator: TerminalEmulator
    /// 화면 갱신 횟수 — 상위 뷰의 body에서 읽어 전달해야 SwiftUI가 변화를 감지한다.
    /// updateNSView 안에서 emulator.revision을 읽는 것만으로는 의존성이 생기지 않는다.
    let revision: Int
    /// 키 입력을 셸로 보낸다
    let onInput: (String) -> Void
    /// 뷰 크기에서 계산한 격자 크기 통지
    let onResize: (Int, Int) -> Void

    func makeNSView(context: Context) -> TerminalRenderView {
        let view = TerminalRenderView()
        view.emulator = emulator
        view.onInput = onInput
        view.onResize = onResize
        return view
    }

    func updateNSView(_ view: TerminalRenderView, context: Context) {
        view.emulator = emulator
        view.onInput = onInput
        view.onResize = onResize
        view.refresh(revision: revision)
    }
}

// MARK: - 렌더 뷰

final class TerminalRenderView: NSView, NSTextInputClient {
    var emulator: TerminalEmulator?
    var onInput: ((String) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    /// 스크롤백을 얼마나 거슬러 올라갔는지 (0이면 현재 화면)
    private var scrollOffset = 0
    private var lastRevision = -1
    /// IME 조합 중인 문자열
    private var markedText = ""

    // 선택 영역 — 줄 번호는 버려진 스크롤백까지 포함한 절대값이라 출력이 밀려도 안 흔들린다
    private struct Point: Comparable {
        let line: Int
        let col: Int
        static func < (a: Point, b: Point) -> Bool {
            a.line != b.line ? a.line < b.line : a.col < b.col
        }
    }
    private var selectionAnchor: Point?
    private var selectionHead: Point?
    private var isDraggingSelection = false

    /// 터미널 글꼴 — Monaco. 없는 환경에서는 시스템 고정폭으로 되돌린다
    private let font: NSFont = NSFont(name: "Monaco", size: 12)
        ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// 기울인 판이 없는 글꼴용 가짜 이탤릭 — 만들 때마다 새로 그리지 않도록 모아 둔다
    private var skewedFonts: [String: NSFont] = [:]
    private lazy var naturalAdvance: CGFloat = {
        NSAttributedString(string: "M", attributes: [.font: font]).size().width
    }()
    private lazy var cellWidth: CGFloat = ceil(naturalAdvance * 2) / 2  // 0.5pt 단위로 맞춰 흔들림 방지
    /// 격자 폭과 글꼴 본래 자간의 차. 런을 그릴 때 이만큼 벌리지 않으면
    /// 글자가 칸보다 촘촘히 나아가 줄이 길수록 커서와 어긋난다 (Monaco 기준 칸 7.5 / 자간 7.2)
    private lazy var kerning: CGFloat = cellWidth - naturalAdvance
    private lazy var cellHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 갱신 / 크기

    func refresh(revision: Int) {
        guard revision != lastRevision else { return }
        lastRevision = revision
        scrollOffset = 0                       // 새 출력이 오면 맨 아래로
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        notifyGridSize()
    }

    private func notifyGridSize() {
        let cols = max(20, Int(bounds.width / cellWidth))
        let rows = max(4, Int(bounds.height / cellHeight))
        onResize?(cols, rows)
    }

    /// 화면에 보이는 첫 줄의 절대 번호와 줄 수
    private func visibleWindow(_ emulator: TerminalEmulator) -> (first: Int, count: Int) {
        let visibleRows = max(1, Int(bounds.height / cellHeight))
        let end = max(visibleRows, emulator.totalLines - scrollOffset)
        let start = max(0, end - visibleRows)
        return (emulator.discardedLines + start, visibleRows)
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        FluentColors.terminalBackground.setFill()
        bounds.fill()

        guard let emulator else { return }
        let window = visibleWindow(emulator)
        let selection = normalizedSelection()

        for row in 0..<window.count {
            let absoluteLine = window.first + row
            guard let cells = emulator.line(at: absoluteLine - emulator.discardedLines) else { continue }
            drawLine(cells, atY: CGFloat(row) * cellHeight, absoluteLine: absoluteLine, selection: selection)
        }

        // 커서 — 스크롤백을 보고 있을 때는 그리지 않는다
        let cursorRow = emulator.scrollback.count + emulator.cursorRow + emulator.discardedLines - window.first
        if emulator.cursorVisible, scrollOffset == 0, cursorRow >= 0, cursorRow < window.count {
            let rect = NSRect(x: CGFloat(emulator.cursorCol) * cellWidth,
                              y: CGFloat(cursorRow) * cellHeight,
                              width: cellWidth, height: cellHeight)
            // 커서는 글자와 같은 색 — 포커스가 없으면 흐리게
            FluentColors.terminalForeground
                .withAlphaComponent(isFirstResponderNow ? 0.85 : 0.35).setFill()
            rect.fill()
            if let cell = emulator.line(at: emulator.scrollback.count + emulator.cursorRow)?[safe: emulator.cursorCol],
               cell.scalar != " " {
                draw(String(Character(cell.scalar)), at: rect.origin,
                     color: FluentColors.terminalBackground, style: cell.style)
            }

            // IME 조합 중 문자열
            if !markedText.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: FluentColors.terminalForeground,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .kern: kerning,
                ]
                NSAttributedString(string: markedText, attributes: attributes).draw(at: rect.origin)
            }
        }
    }

    private func drawLine(_ line: [TerminalCell], atY y: CGFloat,
                          absoluteLine: Int, selection: (start: Point, end: Point)?) {
        var col = 0
        while col < line.count {
            let cell = line[col]
            if cell.isWideTrailer { col += 1; continue }

            // 같은 속성이 이어지는 구간을 한 번에 그린다 (폭 2 문자·선택 경계에서 끊는다)
            let isWide = TerminalEmulator.displayWidth(of: cell.scalar) == 2
            let selected = isSelected(line: absoluteLine, col: col, selection: selection)
            var end = col + 1
            if !isWide {
                while end < line.count,
                      !line[end].isWideTrailer,
                      line[end].style == cell.style,
                      isSelected(line: absoluteLine, col: end, selection: selection) == selected,
                      TerminalEmulator.displayWidth(of: line[end].scalar) == 1 {
                    end += 1
                }
            }

            let text = String(String.UnicodeScalarView(line[col..<end].map(\.scalar)))
            let width = CGFloat(isWide ? 2 : end - col) * cellWidth
            let origin = NSPoint(x: CGFloat(col) * cellWidth, y: y)
            let rect = NSRect(x: origin.x, y: origin.y, width: width, height: cellHeight)

            let (foreground, background) = colors(for: cell.style)
            if let background {
                background.setFill()
                rect.fill()
            }
            if selected {
                FluentColors.terminalSelection.setFill()
                rect.fill()
            }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                draw(text, at: origin, color: foreground, style: cell.style)
            }
            col = isWide ? col + 2 : end
        }
    }

    private func draw(_ text: String, at point: NSPoint, color: NSColor, style: TerminalStyle) {
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        var drawFont = traits.isEmpty ? font
            : NSFontManager.shared.convert(font, toHaveTrait: traits)

        // Monaco처럼 굵은·기울인 판이 없는 글꼴은 convert가 원본을 그대로 돌려준다.
        // 그대로 두면 볼드·이탤릭이 보통 글자와 구분되지 않으므로 직접 흉내 낸다 —
        // 두 방식 모두 자간을 바꾸지 않아 고정폭 격자가 흐트러지지 않는다
        let actual = NSFontManager.shared.traits(of: drawFont)
        let needsFauxBold = style.bold && !actual.contains(.boldFontMask)
        if style.italic, !actual.contains(.italicFontMask) {
            drawFont = fauxItalic(drawFont)
        }

        let textColor = style.dim ? color.withAlphaComponent(0.6) : color
        var attributes: [NSAttributedString.Key: Any] = [
            .font: drawFont,
            .foregroundColor: textColor,
            .kern: kerning,
        ]
        if needsFauxBold {
            // 음수 굵기 = 채우기 + 같은 색 외곽선 → 획만 두꺼워진다
            attributes[.strokeWidth] = -3.0
            attributes[.strokeColor] = textColor
        }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        NSAttributedString(string: text, attributes: attributes).draw(at: point)
    }

    /// 글꼴 행렬에 기울기를 넣어 만든 가짜 이탤릭
    private func fauxItalic(_ base: NSFont) -> NSFont {
        if let cached = skewedFonts[base.fontName] { return cached }
        let size = base.pointSize
        let matrix = AffineTransform(m11: size, m12: 0, m21: 0.22 * size, m22: size, tX: 0, tY: 0)
        let made = NSFont(descriptor: base.fontDescriptor.withMatrix(matrix), size: 0) ?? base
        skewedFonts[base.fontName] = made
        return made
    }

    /// 전경/배경 색 — inverse면 서로 바꾼다. 배경이 기본색이면 칠하지 않는다(nil).
    private func colors(for style: TerminalStyle) -> (NSColor, NSColor?) {
        var foreground = color(style.fg) ?? FluentColors.terminalForeground
        var background = color(style.bg)
        if style.inverse {
            let newForeground = background ?? FluentColors.terminalBackground
            let newBackground = color(style.fg) ?? FluentColors.terminalForeground
            foreground = newForeground
            background = newBackground
        }
        if style.bold, case .indexed(let index) = style.fg, index < 8 {
            foreground = Self.palette[Int(index) + 8]      // 굵게는 밝은 색으로
        }
        return (foreground, background)
    }

    private func color(_ value: TerminalStyle.Color) -> NSColor? {
        switch value {
        case .default:            return nil
        case .indexed(let index): return Self.palette[Int(index)]
        case .rgb(let r, let g, let b):
            return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// xterm 256색 팔레트
    private static let palette: [NSColor] = {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        var colors: [NSColor] = [
            rgb(0, 0, 0), rgb(194, 54, 33), rgb(37, 188, 36), rgb(173, 173, 39),
            rgb(73, 46, 225), rgb(211, 56, 211), rgb(51, 187, 200), rgb(203, 204, 205),
            rgb(129, 131, 131), rgb(252, 57, 31), rgb(49, 231, 34), rgb(234, 236, 35),
            rgb(88, 51, 255), rgb(249, 53, 248), rgb(20, 240, 240), rgb(233, 235, 235),
        ]
        let levels = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { colors.append(rgb(r, g, b)) } } }
        for step in 0..<24 {
            let value = 8 + step * 10
            colors.append(rgb(value, value, value))
        }
        return colors
    }()

    private var isFirstResponderNow: Bool { window?.firstResponder === self }

    // MARK: 선택

    private func normalizedSelection() -> (start: Point, end: Point)? {
        guard let anchor = selectionAnchor, let head = selectionHead, anchor != head || isDraggingSelection
        else { return nil }
        return anchor <= head ? (anchor, head) : (head, anchor)
    }

    private func isSelected(line: Int, col: Int, selection: (start: Point, end: Point)?) -> Bool {
        guard let selection else { return false }
        let point = Point(line: line, col: col)
        return point >= selection.start && point <= selection.end
    }

    /// 마우스 위치 → 절대 줄/칸
    private func point(for event: NSEvent) -> Point? {
        guard let emulator else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let window = visibleWindow(emulator)
        let row = max(0, min(window.count - 1, Int(local.y / cellHeight)))
        let col = max(0, min(emulator.cols - 1, Int(local.x / cellWidth)))
        return Point(line: window.first + row, col: col)
    }

    override func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        guard let start = point(for: event) else { return }

        switch event.clickCount {
        case 2:                       // 단어 선택
            if let range = wordRange(at: start) {
                selectionAnchor = range.start
                selectionHead = range.end
            }
            isDraggingSelection = false
        case 3:                       // 줄 전체 선택
            selectionAnchor = Point(line: start.line, col: 0)
            selectionHead = Point(line: start.line, col: (emulator?.cols ?? 1) - 1)
            isDraggingSelection = false
        default:
            selectionAnchor = start
            selectionHead = start
            isDraggingSelection = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection, let head = point(for: event) else { return }
        selectionHead = head
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingSelection = false
        // 끌지 않고 클릭만 했으면 선택 해제
        if let anchor = selectionAnchor, let head = selectionHead, anchor == head {
            selectionAnchor = nil
            selectionHead = nil
            needsDisplay = true
        }
    }

    /// 더블클릭한 자리의 단어 범위 — 경로·옵션도 한 덩어리로 잡히도록 기호 일부를 포함한다
    private func wordRange(at point: Point) -> (start: Point, end: Point)? {
        guard let emulator,
              let cells = emulator.line(at: point.line - emulator.discardedLines),
              point.col < cells.count else { return nil }
        func isWordCharacter(_ scalar: UnicodeScalar) -> Bool {
            if CharacterSet.alphanumerics.contains(scalar) { return true }
            return "._-/~:@+".unicodeScalars.contains(scalar)
        }
        guard isWordCharacter(cells[point.col].scalar) else { return (point, point) }
        var start = point.col, end = point.col
        while start > 0, isWordCharacter(cells[start - 1].scalar) { start -= 1 }
        while end + 1 < cells.count, isWordCharacter(cells[end + 1].scalar) { end += 1 }
        return (Point(line: point.line, col: start), Point(line: point.line, col: end))
    }

    /// 선택 영역의 텍스트 — 줄 끝 공백은 버리고 줄바꿈으로 잇는다
    private func selectedText() -> String? {
        guard let emulator, let selection = normalizedSelection() else { return nil }
        var lines: [String] = []
        for absoluteLine in selection.start.line...selection.end.line {
            guard let cells = emulator.line(at: absoluteLine - emulator.discardedLines) else { continue }
            let from = absoluteLine == selection.start.line ? selection.start.col : 0
            let to = absoluteLine == selection.end.line ? min(selection.end.col, cells.count - 1)
                                                       : cells.count - 1
            guard from <= to else { lines.append(""); continue }
            let text = cells[from...to]
                .filter { !$0.isWideTrailer }
                .map { String(Character($0.scalar)) }
                .joined()
            lines.append(String(text.reversed().drop { $0 == " " }.reversed()))
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func copySelection() {
        guard let text = selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func pasteFromClipboard() {
        guard let emulator, let text = NSPasteboard.general.string(forType: .string) else { return }
        let payload = emulator.bracketedPaste
            ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        onInput?(payload)
    }

    private func selectAllText() {
        guard let emulator else { return }
        selectionAnchor = Point(line: emulator.discardedLines, col: 0)
        selectionHead = Point(line: emulator.discardedLines + emulator.totalLines - 1,
                              col: emulator.cols - 1)
        needsDisplay = true
    }

    // MARK: 표준 편집 액션
    // ⌘C·⌘V는 메인 메뉴(편집)가 먼저 가져가므로 keyDown이 아니라 이 액션들로 처리해야 한다

    @objc func copy(_ sender: Any?) { copySelection() }
    @objc func paste(_ sender: Any?) { pasteFromClipboard() }
    override func selectAll(_ sender: Any?) { selectAllText() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return normalizedSelection() != nil
        default: return true
        }
    }

    private func clearSelection() {
        guard selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        needsDisplay = true
    }

    // MARK: 포커스 / 스크롤

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func scrollWheel(with event: NSEvent) {
        guard let emulator, !emulator.isAlternateScreen else { return }
        let lines = Int(event.scrollingDeltaY / 3)
        guard lines != 0 else { return }
        scrollOffset = max(0, min(emulator.scrollback.count, scrollOffset + lines))
        needsDisplay = true
    }

    // MARK: 키 입력

    override func keyDown(with event: NSEvent) {
        guard let emulator else { return }

        // 메뉴가 처리하지 못하고 내려온 ⌘ 조합에 대한 대비책
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c": copySelection()
            case "v": pasteFromClipboard()
            case "a": selectAllText()
            default:  super.keyDown(with: event)
            }
            return
        }

        clearSelection()      // 입력하면 선택은 해제한다

        // 방향키·기능키
        if let special = specialKey(for: event, applicationCursor: emulator.applicationCursorKeys) {
            onInput?(special)
            return
        }

        // Ctrl 조합 — Ctrl-C, Ctrl-D, Ctrl-Z 등
        if event.modifierFlags.contains(.control) {
            // macOS가 이미 제어 문자로 바꿔 주는 경우가 많다 (Ctrl-C → 0x03)
            if let scalar = event.characters?.unicodeScalars.first, scalar.value < 0x20 {
                onInput?(String(scalar))
                return
            }
            if let base = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
                if base.value >= 0x61 && base.value <= 0x7A {
                    onInput?(String(UnicodeScalar(base.value - 0x60)!))
                    return
                }
                switch base {
                case "[":  onInput?("\u{1B}"); return
                case "\\": onInput?("\u{1C}"); return
                case "]":  onInput?("\u{1D}"); return
                case " ":  onInput?("\u{0}");  return
                default: break
                }
            }
        }

        // 한글 등 IME는 NSTextInputClient 경로로 처리한다
        interpretKeyEvents([event])
    }

    private func specialKey(for event: NSEvent, applicationCursor: Bool) -> String? {
        let cursorPrefix = applicationCursor ? "\u{1B}O" : "\u{1B}["
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:    return cursorPrefix + "A"
        case NSDownArrowFunctionKey:  return cursorPrefix + "B"
        case NSRightArrowFunctionKey: return cursorPrefix + "C"
        case NSLeftArrowFunctionKey:  return cursorPrefix + "D"
        case NSHomeFunctionKey:       return "\u{1B}[H"
        case NSEndFunctionKey:        return "\u{1B}[F"
        case NSPageUpFunctionKey:     return "\u{1B}[5~"
        case NSPageDownFunctionKey:   return "\u{1B}[6~"
        case NSDeleteFunctionKey:     return "\u{1B}[3~"
        case NSF1FunctionKey:         return "\u{1B}OP"
        case NSF2FunctionKey:         return "\u{1B}OQ"
        case NSF3FunctionKey:         return "\u{1B}OR"
        case NSF4FunctionKey:         return "\u{1B}OS"
        case 0x7F:                    return "\u{7F}"      // Delete(백스페이스)
        case 0x0D:                    return "\r"
        case 0x1B:                    return "\u{1B}"
        case 0x09:                    return event.modifierFlags.contains(.shift) ? "\u{1B}[Z" : "\t"
        default: return nil
        }
    }

    // MARK: NSTextInputClient — 한글 입력(조합) 지원

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        onInput?(text)
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        needsDisplay = true
    }

    func unmarkText() { markedText = ""; needsDisplay = true }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.count)
    }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func doCommandBy(_ selector: Selector) {
        // Return·Tab 등은 keyDown에서 이미 처리했다
    }

    /// IME 후보창 위치 — 커서 자리에 뜨도록
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let emulator else { return .zero }
        let local = NSRect(x: CGFloat(emulator.cursorCol) * cellWidth,
                           y: CGFloat(emulator.cursorRow) * cellHeight,
                           width: cellWidth, height: cellHeight)
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? .zero
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
