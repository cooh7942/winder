import SwiftUI

/// 도구 막대 버튼 — Finder 툴바처럼 항상 둥근 알약 바탕을 깔고, hover에서 조금 더 밝아진다
struct FluentButton: View {
    let icon: String
    /// 툴팁 문구 — 버튼에는 아이콘만 그린다
    let label: String?
    var isEnabled: Bool = true
    /// 토글 버튼이 켜진 상태 — 선택 배경 + 강조색으로 표시
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: { guard isEnabled else { return }; action() }) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 16, height: 16)
                .padding(.horizontal, FluentMetrics.paddingS)
                .frame(height: FluentMetrics.toolbarControlHeight)
                .background(
                    RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusToolbarControl,
                                     style: .continuous)
                        .fill(isActive ? Color.fluentSelectionFill
                                       : (isHovered ? Color.fluentHoverFill : Color.fluentControlFill))
                )
        }
        .buttonStyle(.plain)
        .foregroundColor(foreground)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: FluentMetrics.animStandard)) {
                isHovered = hovering
            }
        }
        .help(label ?? "")
    }

    private var foreground: Color {
        if !isEnabled { return .fluentTextDisabled }
        return isActive ? .fluentAccent : .fluentTextPrimary
    }
}
