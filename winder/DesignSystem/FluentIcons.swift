/// SF Symbols 아이콘 이름 모음
/// 뷰 코드에서 문자열 리터럴 직접 사용 금지 — 이 enum 참조
enum FluentIcons {

    // MARK: - 도구 막대
    static let back        = "chevron.left"
    static let forward     = "chevron.right"
    /// 보기 옵션 메뉴(정렬 기준·아이콘 크기·숨김 항목)
    static let sort        = "arrow.up.arrow.down"
    static let chevronDown = "chevron.down"
    static let terminal    = "apple.terminal"
    /// 창 나누기 — 좌우로 갈린 사각형
    static let splitPane   = "rectangle.split.2x1"

    // MARK: - 보기 모드 (도구 막대 세그먼트 · ViewMode.systemIcon)
    static let viewIconsToggle   = "square.grid.2x2"
    static let viewDetailsToggle = "rectangle.grid.1x2"
    static let viewListMode      = "list.bullet"
    /// 큰 미리보기 아래 필름스트립 — Finder 갤러리 보기 아이콘과 같은 모양
    static let gallery           = "squares.below.rectangle"

    // MARK: - 탐색 창 위치
    static let home       = "house"
    static let cloud      = "cloud"
    static let desktop    = "desktopcomputer"
    static let documents  = "doc.text"
    static let downloads  = "arrow.down.circle"
    static let music      = "music.note"
    static let pictures   = "photo"
    static let videos     = "film"
    static let folder     = "folder"
    static let drive      = "internaldrive"
    static let network    = "network"
    static let trash      = "trash"

    // MARK: - 파일 작업 진행 패널
    static let transferCopy = "doc.on.doc"
    static let transferMove = "arrow.right.doc.on.clipboard"

    // MARK: - 일반 UI
    static let close     = "xmark"
    static let checkmark = "checkmark"
}
