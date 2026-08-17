import SwiftUI
import AppKit

/// 색상 토큰 — macOS Finder의 팔레트를 따른다
/// 되도록 시스템 의미 색을 그대로 써서 라이트/다크 모드와 사용자 액센트 설정에 자동으로 맞춘다
enum FluentColors {

    // MARK: - 배경
    // 파일 목록은 창 배경과 같은 색, 탐색 창은 한 단계 밝은 패널 —
    // 이 색 차이가 Finder에서 트리를 별도 상자처럼 보이게 하는 요소다.
    // (터미널만 아래쪽 terminalBackground로 검정을 유지한다)
    static let windowBackground  = NSColor.windowBackgroundColor
    static let contentBackground = NSColor.controlBackgroundColor
    /// 다크 모드 값은 시스템 underPageBackgroundColor(#282828)와 같다.
    /// 그 색을 그대로 쓰지 않는 이유는 라이트 모드에서 중간 회색(#969696)이라 사이드바에 맞지 않아서다.
    static let sidebarBackground = dynamic(
        light: NSColor(hex: "E9E9E9"),
        dark:  NSColor(hex: "282828")
    )

    // MARK: - 액센트
    // Finder와 같이 시스템 설정의 강조 색을 따른다
    static let accent = NSColor.controlAccentColor

    // MARK: - 텍스트
    static let textPrimary   = NSColor.labelColor
    static let textSecondary = NSColor.secondaryLabelColor
    static let textDisabled  = NSColor.tertiaryLabelColor

    // MARK: - 구분선 / 채우기
    static let divider = NSColor.separatorColor
    /// 도구 막대 컨트롤의 평상시 바탕 — Finder 툴바 알약과 같은 옅기(바탕보다 약 5단계 밝음)
    static let controlFill = dynamic(
        light: NSColor(white: 0, alpha: 0.030),
        dark:  NSColor(white: 1, alpha: 0.030)
    )
    /// 세그먼트 컨트롤에서 선택된 칸 — Finder는 액센트가 아니라 한 단계 밝은 회색으로 표시한다
    static let controlSelectedFill = dynamic(
        light: NSColor(white: 0, alpha: 0.120),
        dark:  NSColor(white: 1, alpha: 0.140)
    )
    static let hoverFill = dynamic(
        light: NSColor(white: 0, alpha: 0.039),
        dark:  NSColor(white: 1, alpha: 0.059)
    )

    // MARK: - 선택
    // Finder와 같은 규칙 — 목록에 포커스가 있으면 액센트 색으로 꽉 채우고,
    // 다른 곳에 포커스가 가면 회색으로 흐려진다
    static let selectionFill          = NSColor.selectedContentBackgroundColor
    static let selectionFillInactive  = NSColor.unemphasizedSelectedContentBackgroundColor
    /// 액센트로 채워진 행 위에 올라가는 글자·아이콘 색
    static let selectionText          = NSColor.alternateSelectedControlTextColor

    // MARK: - 터미널
    // 탐색 창 패널과 같은 바탕·글자색을 쓴다 — 창 안에서 따로 노는 검은 상자로 보이지 않도록
    static let terminalBackground = sidebarBackground
    static let terminalForeground = textPrimary
    static let terminalSelection  = NSColor(white: 1, alpha: 0.28)

    // MARK: - 드롭 대상 강조
    // 드래그가 지나가는 폴더 행. 액센트 계열이되 선택과 구분되도록 옅게 깔고 테두리를 두른다
    // 그릴 때마다 계산한다 — 카탈로그 색에 알파를 씌워 저장해 두면 그 시점 외양에 고정될 수 있다
    static var dropTargetFill:   NSColor { accent.withAlphaComponent(0.22) }
    static var dropTargetStroke: NSColor { accent.withAlphaComponent(0.80) }

    // MARK: - Private
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: return dark
            default:        return light
            }
        })
    }
}

// MARK: - NSColor hex 편의 초기화
extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >>  8) & 0xFF) / 255
        let b = CGFloat( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - SwiftUI Color 편의 접근자
extension Color {
    static let fluentWindowBackground     = Color(FluentColors.windowBackground)
    static let fluentContentBackground    = Color(FluentColors.contentBackground)
    static let fluentSidebarBackground    = Color(FluentColors.sidebarBackground)
    static let fluentAccent               = Color(FluentColors.accent)
    static let fluentTextPrimary          = Color(FluentColors.textPrimary)
    static let fluentTextSecondary        = Color(FluentColors.textSecondary)
    static let fluentTextDisabled         = Color(FluentColors.textDisabled)
    static let fluentDivider              = Color(FluentColors.divider)
    static let fluentControlFill          = Color(FluentColors.controlFill)
    static let fluentControlSelectedFill  = Color(FluentColors.controlSelectedFill)
    static let fluentHoverFill            = Color(FluentColors.hoverFill)
    static let fluentSelectionFill        = Color(FluentColors.selectionFill)
    // 액센트에서 파생된 색은 저장하지 않고 매번 만든다 (FluentColors 쪽 주석 참고)
    static var fluentDropTargetFill:   Color { Color(FluentColors.dropTargetFill) }
    static var fluentDropTargetStroke: Color { Color(FluentColors.dropTargetStroke) }
}
