import Foundation

/// Windows 11 Fluent Design 레이아웃 메트릭 상수
/// 뷰 코드에서 매직 넘버 사용 금지 — 반드시 이 enum 참조
enum FluentMetrics {

    // MARK: - 영역 높이
    static let titleBarHeight:     CGFloat = 40
    /// 도구 막대는 두 줄 — 위는 아이콘 묶음, 아래는 경로 상자
    static let toolbarRowHeight:   CGFloat = 48
    static let pathBarHeight:      CGFloat = 36
    static let commandBarHeight:   CGFloat = toolbarRowHeight + pathBarHeight
    /// 도구 막대 컨트롤(알약) 높이와 아이콘 한 칸의 폭
    static let toolbarControlHeight: CGFloat = 36
    static let toolbarSegmentWidth:  CGFloat = 34
    /// 트래픽 라이트가 차지하는 폭 (창 왼쪽 끝 기준, 실측 초록 버튼 오른쪽 끝 78pt + 여유).
    /// 탐색 창 위쪽을 창 잡는 자리로 쓸 때 버튼과 겹치지 않도록 이만큼 비운다
    static let trafficLightAreaWidth: CGFloat = 86

    // MARK: - 목록 행 높이
    // Finder 실측값 — 목록 보기(아이콘 16 / 글자 13) 행 20pt, 사이드바 행 32pt에 섹션 머리글 19pt.
    // 글자 크기는 Finder 설정의 textSize=13과 같으므로 셀 폰트는 13pt를 그대로 쓴다.
    static let listRowHeight:        CGFloat = 20
    static let listIconSize:         CGFloat = 16
    /// 목록 행 띠(줄무늬·선택·hover) — Finder는 사각형이 아니라 좌우를 들인 둥근 띠로 그린다.
    /// 실측: 좌우 10pt, 모서리 반경 8pt, 세로는 행 높이 그대로
    static let listRowBandInset:     CGFloat = 10
    static let listRowBandRadius:    CGFloat = 8
    /// 이름 열 아이콘이 시작하는 위치 — 아이콘이 띠 밖으로 삐져나오지 않도록 띠 안쪽에서 시작한다.
    /// Finder도 띠 왼쪽 끝에서 약 18pt 안쪽에 아이콘을 놓는다
    static let listNameLeadingInset: CGFloat = listRowBandInset + paddingS
    /// 이름 열에서 글자가 시작하는 위치 (아이콘 뒤). Finder 실측 약 44pt와 같은 자리다
    static let listNameTextInset:    CGFloat = listNameLeadingInset + listIconSize + paddingS
    /// 이름 외 열에서 글자가 시작하는 위치 — 아이콘이 없으므로 자리를 잡지 않는다
    static let listColumnTextInset:  CGFloat = 12
    static let treeRowHeight:        CGFloat = 32
    static let treeSectionRowHeight: CGFloat = 20

    // MARK: - 코너 반경
    /// 탐색 창을 감싸는 둥근 패널 — Finder 사이드바와 같은 곡률
    static let cornerRadiusPanel:   CGFloat = 10
    /// 트래픽 라이트를 기본 위치에서 안쪽으로 들여 놓는 양.
    /// 그냥 두면 버튼이 패널의 둥근 모서리를 파고든다 — Finder도 같은 만큼 들여 놓는다(실측)
    static let trafficLightInset:   CGFloat = 10
    static let cornerRadiusControl: CGFloat = 4
    /// 도구 막대 컨트롤 — Finder 툴바의 둥근 알약(33pt 높이에 반경 약 12pt) 실측에 맞춘다
    static let cornerRadiusToolbarControl: CGFloat = 12
    static let cornerRadiusRow:     CGFloat = 4
    /// 탐색 창 선택 알약 — Finder 사이드바와 같은 곡률
    static let cornerRadiusSidebarRow: CGFloat = 6
    // MARK: - 패딩
    static let paddingXS: CGFloat = 4
    static let paddingS:  CGFloat = 8
    static let paddingM:  CGFloat = 12
    static let paddingL:  CGFloat = 16

    // MARK: - 탐색 창
    static let sidebarDefaultWidth: CGFloat = 220
    static let sidebarMinWidth:     CGFloat = 160
    static let sidebarMaxWidth:     CGFloat = 400
    static let splitterHitWidth:    CGFloat = 6   // AppKit SidebarSplitter 히트 영역 폭
    /// 탐색 창 패널과 오른쪽 내용 사이의 빈 공간
    static let sidebarContentGap:   CGFloat = 5

    // MARK: - 파일 목록 창 (둘로 나눴을 때)
    static let paneDefaultWidth: CGFloat = 480
    static let paneMinWidth:     CGFloat = 320

    // MARK: - 터미널 패널
    static let terminalHeaderHeight:  CGFloat = 28
    static let terminalDefaultHeight: CGFloat = 240
    static let terminalMinHeight:     CGFloat = 120
    static let terminalMaxHeight:     CGFloat = 700

    // MARK: - 세부 정보 창

    // MARK: - 트리
    static let treeIndentWidth: CGFloat = 16
    static let treeIconSize:    CGFloat = 16

    // MARK: - 아이콘 크기 (보기 모드별)
    /// 갤러리 타일 한 변 — 썸네일이 정사각형으로 채워진다
    static let iconSizeGallery:    CGFloat = 160

    // MARK: - 갤러리 보기 (큰 미리보기 + 아래 필름스트립)
    static let galleryStripHeight:  CGFloat = 100
    static let galleryThumbSize:    CGFloat = 64
    /// 큰 미리보기용 썸네일 생성 크기 — 화면에서는 남는 공간에 맞춰 늘어난다
    static let galleryPreviewSize:  CGFloat = 512
    static let iconSizeLarge:      CGFloat = 96
    static let iconSizeMedium:     CGFloat = 48
    static let iconSizeSmall:      CGFloat = 16

    // MARK: - 애니메이션 (초)
    static let animStandard: Double = 0.15   // hover, 선택, 버튼 상태
}
