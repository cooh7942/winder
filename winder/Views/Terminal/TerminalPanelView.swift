import SwiftUI

/// 파일 목록 아래에 붙는 터미널 패널 — PTY 위에서 도는 실제 셸 화면
struct TerminalPanelView: View {
    @Environment(PaneViewModel.self) var pane

    private var terminal: TerminalViewModel { pane.terminal }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.fluentDivider).frame(height: 1)

            TerminalScreenView(
                emulator: terminal.emulator,
                revision: terminal.screenRevision,
                onInput: { text in terminal.send(text) },
                onResize: { columns, rows in terminal.resize(columns: columns, rows: rows) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(FluentColors.terminalBackground))
        .onAppear { terminal.activate(in: pane.tab.currentURL) }
    }

    private var header: some View {
        HStack(spacing: FluentMetrics.paddingS) {
            Image(systemName: FluentIcons.terminal)
                .font(.system(size: 12))
                .foregroundColor(.fluentTextSecondary)
            Text(title)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.fluentTextSecondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            iconButton(FluentIcons.close, "터미널 닫기") { pane.isTerminalVisible = false }
        }
        .padding(.horizontal, FluentMetrics.paddingS)
        .frame(height: FluentMetrics.terminalHeaderHeight)
    }

    /// 셸이 OSC로 알려주는 제목이 있으면 그걸, 없으면 시작 폴더를 보여준다
    private var title: String {
        shortPath(terminal.currentDirectory)
    }

    private func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.fluentTextSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
