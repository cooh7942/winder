import SwiftUI

/// "이동" 메뉴 — 도구 막대에서 탐색 버튼을 없앤 대신 macOS 관습대로 메뉴에 둔다.
///
/// 메뉴 키 등가는 키 이벤트가 뷰에 닿기 전에 처리되므로, 파일 목록에 포커스가 없거나
/// 아이콘·갤러리 보기처럼 자체 키 처리가 없는 모드에서도 그대로 동작한다.
struct NavigationCommands: Commands {
    @FocusedValue(\.explorerTab) private var focus

    var body: some Commands {
        CommandMenu("이동") {
            Button("뒤로") { focus?.tab.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(focus?.tab.canGoBack ?? false))

            Button("앞으로") { focus?.tab.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(focus?.tab.canGoForward ?? false))

            Button("상위 폴더") { focus?.tab.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(focus == nil)

            Divider()

            Button("새로 고침") { focus?.tab.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(focus == nil)
        }
    }
}

// MARK: - 포커스된 창의 탭 전달

/// TabViewModel을 그대로 넘기려면 Equatable이어야 하므로 객체 동일성만 비교하는 껍데기를 쓴다
struct ExplorerTabFocus: Equatable {
    let tab: TabViewModel

    static func == (lhs: ExplorerTabFocus, rhs: ExplorerTabFocus) -> Bool {
        lhs.tab === rhs.tab
    }
}

private struct ExplorerTabFocusKey: FocusedValueKey {
    typealias Value = ExplorerTabFocus
}

extension FocusedValues {
    var explorerTab: ExplorerTabFocus? {
        get { self[ExplorerTabFocusKey.self] }
        set { self[ExplorerTabFocusKey.self] = newValue }
    }
}
