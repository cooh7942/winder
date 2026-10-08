import SwiftUI
import AppKit

/// 아이콘·목록·갤러리 보기의 인라인 이름 변경 칸 — 자세히 보기(WinTableCellView)와 같은 규칙.
///
/// Return과 포커스 잃음은 확정, Esc는 취소. 이름이 비었거나 그대로면 취소로 처리해
/// 뷰모델의 renamingItemID를 풀어 준다 — 풀지 않으면 같은 항목을 다시 이름 변경할 수 없고,
/// 메뉴의 실행 취소도 계속 "편집 중"으로 판단돼 막힌다.
struct InlineRenameField: View {
    let item: FileItem
    var fontSize: CGFloat = 12
    var alignment: TextAlignment = .leading
    let onAction: (DetailsAction) -> Void

    @State private var text = ""
    /// 확정·취소를 한 번만 보낸다 — Return 뒤에 포커스 잃음이 한 번 더 들어온다
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .padding(.horizontal, 2)
            .background(Color.fluentContentBackground)
            .overlay(
                RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusRow)
                    .strokeBorder(Color.fluentAccent, lineWidth: 1)
            )
            .focused($isFocused)
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: isFocused) { _, focused in
                if !focused { finish(commit: true) }
            }
            .onAppear {
                text = item.displayName
                // 칸이 창에 붙은 다음에 포커스를 줘야 필드 편집기가 붙고 글자가 전체 선택된다
                DispatchQueue.main.async { isFocused = true }
            }
            // 스크롤로 셀이 사라지거나 보기를 바꾸면 자세히 보기의 셀 재사용과 같이 취소한다
            .onDisappear { finish(commit: false) }
    }

    private func finish(commit: Bool) {
        guard !isFinished else { return }
        isFinished = true
        let name = text.trimmingCharacters(in: .whitespaces)
        if commit, !name.isEmpty, name != item.displayName {
            onAction(.rename(item, name))
        } else {
            onAction(.renameCancelled)
        }
    }
}

/// 다른 항목을 누르면 진행 중인 이름 변경을 확정한다 (Finder와 같은 동작).
/// SwiftUI 탭 제스처는 첫 응답자를 가져가지 않아서, 직접 내려놓아야 칸이 포커스를 잃는다
@MainActor
func endInlineRenameIfNeeded(_ renamingItemID: String?) {
    guard renamingItemID != nil else { return }
    NSApp.keyWindow?.makeFirstResponder(nil)
}
