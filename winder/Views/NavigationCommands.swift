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

/// "편집" 메뉴 — 잘라내기·복사·붙여넣기·실행 취소.
///
/// SwiftUI가 기본으로 넣는 편집 메뉴는 파일 목록에 포커스가 있을 때 이 항목들이 전부
/// 비활성이면서도 ⌘X/⌘C/⌘V/⌘Z를 차지한다. 메뉴 키 등가는 keyDown보다 먼저 처리되므로
/// 파일 목록의 키 처리(DetailsView.handleKeyEvent)까지 키가 닿지 못해 단축키가 죽어 있었다.
/// 그래서 그 묶음을 갈아 끼운다.
///
/// 다만 표준 메뉴가 하던 **응답자 연쇄 전달**은 그대로 흉내 낸다 —
/// 터미널(copy:/paste:/selectAll: 구현)과 이름 변경·주소창 편집기가 자기 몫을 먼저 가져가고,
/// 아무도 받지 않을 때만 파일 목록 동작으로 떨어진다.
/// 활성 여부는 메뉴를 그린 시점의 값이라 최신이 아닐 수 있으므로 넉넉하게 켜 두고,
/// 실제 판단은 항상 최신인 실행 시점(응답자 확인)에 한다.
///
/// 삭제(⌫)는 넣지 않는다 — 수정자 없는 키 등가는 이름 변경 중인 텍스트 편집기보다
/// 먼저 가로채므로, 지금처럼 keyDown에서 처리하는 편이 안전하다.
struct EditCommands: Commands {
    @FocusedValue(\.explorerTab) private var focus

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(UndoService.shared.undoMenuTitle) {
                // 글자를 고치는 중이면 그쪽 실행 취소가 우선
                if NSApp.keyWindow?.firstResponder is NSText {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    focus?.tab.undoLastAction()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(focus == nil || !(UndoService.shared.canUndo || isEditingText))
        }

        CommandGroup(replacing: .pasteboard) {
            Button("잘라내기") {
                route(#selector(NSText.cut(_:))) { $0.cutSelected() }
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(focus == nil)

            Button("복사") {
                route(#selector(NSText.copy(_:))) { $0.copySelected() }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(focus == nil)

            Button("붙여넣기") {
                route(#selector(NSText.paste(_:))) { tab in Task { await tab.paste() } }
            }
            .keyboardShortcut("v", modifiers: .command)
            // 파일 URL뿐 아니라 글자도 대상 — 터미널·이름 편집기가 받을 수 있다
            .disabled(focus == nil || !ClipboardService.shared.hasAnyContent)

            Divider()

            Button("모두 선택") {
                route(#selector(NSResponder.selectAll(_:))) { $0.selectAll() }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(focus == nil)
        }
    }

    /// 이름 변경·주소창 편집이 진행 중인지 — 그 동안에는 실행 취소가 편집기 몫이어야 한다
    private var isEditingText: Bool {
        guard let tab = focus?.tab else { return false }
        return tab.renamingItemID != nil || tab.isEditingAddress
    }

    /// 응답자 연쇄에 먼저 넘기고, 받는 곳이 없을 때만 활성 창의 파일 목록에 적용한다
    private func route(_ selector: Selector, fallback: (TabViewModel) -> Void) {
        guard !NSApp.sendAction(selector, to: nil, from: nil) else { return }
        guard let tab = focus?.tab else { return }
        fallback(tab)
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
