import Foundation

/// 파일 목록 보기 모드 — Windows 11 탐색기 대응
///
/// "특대 아이콘"(256pt)은 제거하고 갤러리로 대체했다. 사진을 크게 보려는 목적이 겹치는데,
/// 특대 아이콘은 파일 타입 아이콘을 확대할 뿐이고 갤러리는 실제 미리보기 썸네일을 보여준다.
enum ViewMode: String, CaseIterable, Identifiable {
    case largeIcons      = "큰 아이콘"
    case mediumIcons     = "보통 아이콘"
    case smallIcons      = "작은 아이콘"
    case list            = "목록"
    case details         = "자세히"  // 기본값
    case gallery         = "갤러리"

    var id: String { rawValue }

    /// 아이콘·썸네일 표시 크기
    var iconSize: CGFloat {
        switch self {
        case .largeIcons:                        return FluentMetrics.iconSizeLarge
        case .mediumIcons:                       return FluentMetrics.iconSizeMedium
        case .gallery:                           return FluentMetrics.iconSizeGallery
        case .smallIcons, .list, .details:        return FluentMetrics.iconSizeSmall
        }
    }

    var systemIcon: String {
        switch self {
        case .details:                           return FluentIcons.viewDetailsToggle
        case .largeIcons, .mediumIcons,
             .smallIcons:                        return FluentIcons.viewIconsToggle
        case .list:                              return FluentIcons.viewListMode
        case .gallery:                           return FluentIcons.gallery
        }
    }
}
