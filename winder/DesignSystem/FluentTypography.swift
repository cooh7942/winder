import SwiftUI

/// 글자 크기 — 파일 목록·트리는 Finder와 같은 13pt, 보조 문구는 12pt
enum FluentTypography {
    /// 보조 텍스트 — 12pt
    static let caption  = Font.system(size: 12, weight: .regular)
    /// 기본 UI 문자열 — 13pt
    static let body     = Font.system(size: 13, weight: .regular)
    /// 안내 화면 제목 — 16pt
    static let subtitle = Font.system(size: 16, weight: .semibold)
}

// MARK: - View 편의 수정자
extension View {
    func fluentCaption()  -> some View { font(FluentTypography.caption) }
    func fluentBody()     -> some View { font(FluentTypography.body) }
    func fluentSubtitle() -> some View { font(FluentTypography.subtitle) }
}
