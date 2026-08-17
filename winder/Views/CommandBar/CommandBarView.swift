import SwiftUI

/// 상단 도구 막대 — 두 줄로 나뉜다.
/// 위: [뒤로·앞으로] [보기 모드 4칸] [보기 옵션] [터미널]
/// 아래: 경로 상자 (한 줄을 통째로 써서 깊은 경로도 잘리지 않는다)
///
/// 각 묶음은 둥근 알약 하나에 담기고 칸 사이에는 구분선을 둔다.
/// 파일 작업(복사·붙여넣기·삭제 등)은 우클릭 메뉴와 단축키로 한다.
struct CommandBarView: View {
    @Environment(ExplorerWindowViewModel.self) var windowVM
    @Environment(PaneViewModel.self) var pane
    /// 창 나누기 버튼은 왼쪽 창에만 둔다 — 양쪽에 있으면 어느 쪽을 닫는지 헷갈린다
    let showsSplitToggle: Bool

    private var tab: TabViewModel { pane.tab }

    var body: some View {
        VStack(spacing: 0) {
            iconRow
                .frame(height: FluentMetrics.toolbarRowHeight)

            // 경로는 아이콘과 폭을 다투지 않도록 아래 줄을 통째로 쓴다 —
            // 깊은 경로도 끝까지 보인다
            BreadcrumbView(
                segments: tab.pathSegments,
                isEditing: Bindable(tab).isEditingAddress,
                inputText: Bindable(tab).addressInput,
                onNavigate: { url in tab.navigate(to: url) },
                onCommitText: { text in
                    let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
                    tab.navigate(to: url)
                }
            )
            .frame(height: FluentMetrics.pathBarHeight)
        }
        .padding(.horizontal, FluentMetrics.paddingS)
        .padding(.bottom, FluentMetrics.paddingS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconRow: some View {
        HStack(spacing: FluentMetrics.paddingS) {
            HistoryGroup(tab: tab)
            ViewModeGroup(tab: tab)
            ViewOptionsMenuButton(tab: tab)

            // 터미널 패널 토글 — 켜면 이 창의 파일 목록 아래가 터미널로 나뉜다
            FluentButton(icon: FluentIcons.terminal,
                         label: pane.isTerminalVisible ? "터미널 닫기" : "터미널 열기",
                         isActive: pane.isTerminalVisible) {
                pane.isTerminalVisible.toggle()
            }

            Spacer(minLength: 0)

            // 오른쪽 끝 — 창을 둘로 나눠 두 폴더를 나란히 놓는다
            if showsSplitToggle {
                FluentButton(icon: FluentIcons.splitPane,
                             label: windowVM.isSplit ? "창 나누기 끄기" : "창 나누기",
                             isActive: windowVM.isSplit) {
                    windowVM.toggleSplit()
                }
            }
        }
    }
}

// MARK: - 뒤로 / 앞으로

private struct HistoryGroup: View {
    let tab: TabViewModel

    var body: some View {
        ToolbarGroup {
            ToolbarIconButton(icon: FluentIcons.back, help: "뒤로 (⌘[)",
                              isEnabled: tab.canGoBack) { tab.goBack() }
            ToolbarGroupDivider()
            ToolbarIconButton(icon: FluentIcons.forward, help: "앞으로 (⌘])",
                              isEnabled: tab.canGoForward) { tab.goForward() }
        }
    }
}

// MARK: - 보기 모드 4칸

private struct ViewModeGroup: View {
    let tab: TabViewModel

    /// Finder는 아이콘·목록·열·갤러리 네 칸을 둔다.
    /// 열 보기는 이 앱에 없으므로 그 자리에 목록 보기를 넣었다.
    /// 아이콘 칸은 크기와 무관하게 하나로 묶고, 크기는 보기 옵션 메뉴에서 고른다.
    private static let segments: [(icon: String, mode: ViewMode)] = [
        (FluentIcons.viewIconsToggle,   .mediumIcons),
        (FluentIcons.viewDetailsToggle, .details),
        (FluentIcons.viewListMode,      .list),
        (FluentIcons.gallery,           .gallery),
    ]

    var body: some View {
        ToolbarGroup {
            ForEach(Array(Self.segments.enumerated()), id: \.element.mode) { index, segment in
                if index > 0 { ToolbarGroupDivider() }
                ToolbarIconButton(icon: segment.icon,
                                  help: segment.mode.rawValue,
                                  isSelected: isSelected(segment.mode)) {
                    tab.viewMode = segment.mode
                }
            }
        }
    }

    /// 아이콘 칸은 작은·보통·큰 아이콘 중 어느 것이어도 선택으로 본다
    private func isSelected(_ mode: ViewMode) -> Bool {
        guard mode == .mediumIcons else { return tab.viewMode == mode }
        switch tab.viewMode {
        case .smallIcons, .mediumIcons, .largeIcons: return true
        default:                                     return false
        }
    }
}

// MARK: - 보기 옵션 메뉴

/// 정렬 기준 · 아이콘 크기 · 숨김 항목 — 세그먼트에 담지 않은 보기 설정을 모은다
private struct ViewOptionsMenuButton: View {
    let tab: TabViewModel
    @State private var isHovered = false

    private static let iconSizes: [ViewMode] = [.smallIcons, .mediumIcons, .largeIcons]

    var body: some View {
        Menu {
            Section("정렬 기준") {
                ForEach(SortKey.allCases) { key in
                    Button(action: { tab.sort(by: key) }) {
                        if tab.sortDescriptor.key == key {
                            Label(key.rawValue, systemImage: tab.sortDescriptor.ascending
                                  ? "arrow.up" : "arrow.down")
                        } else {
                            Text(key.rawValue)
                        }
                    }
                }
            }

            Section("아이콘 크기") {
                ForEach(Self.iconSizes) { mode in
                    Button(action: { tab.viewMode = mode }) {
                        if tab.viewMode == mode {
                            Label(mode.rawValue, systemImage: FluentIcons.checkmark)
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                }
            }

            Divider()

            Toggle(isOn: Bindable(tab).showHiddenFiles) {
                Text("숨김 항목 표시")
            }
            .onChange(of: tab.showHiddenFiles) { _, _ in tab.reload() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: FluentIcons.sort)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: FluentIcons.chevronDown)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.fluentTextSecondary)
            }
            .foregroundColor(.fluentTextPrimary)
            .padding(.horizontal, FluentMetrics.paddingS)
            .frame(height: FluentMetrics.toolbarControlHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        // Menu 자체 높이는 label에 준 프레임보다 작다 — 알약이 다른 묶음보다 납작해지므로
        // 가로만 내용에 맞추고 세로는 도구 막대 높이로 고정한다
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: FluentMetrics.toolbarControlHeight)
        // Menu의 label 안에 넣은 배경은 borderlessButton 스타일이 그려 주지 않아 바깥에 씌운다
        .background(
            RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusToolbarControl,
                             style: .continuous)
                .fill(isHovered ? Color.fluentHoverFill : Color.fluentControlFill)
        )
        .onHover { isHovered = $0 }
        .help("보기 옵션")
    }
}

// MARK: - 알약 묶음 / 구분선 / 아이콘 버튼

/// 여러 컨트롤을 둥근 알약 하나에 담는다 — Finder 툴바의 묶음과 같은 모양
private struct ToolbarGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusToolbarControl,
                                 style: .continuous)
                    .fill(Color.fluentControlFill)
            )
    }
}

/// 알약 안 칸 사이 구분선
private struct ToolbarGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.fluentDivider)
            .frame(width: 1, height: 16)
    }
}

private struct ToolbarIconButton: View {
    let icon: String
    let help: String
    var isEnabled: Bool = true
    /// 세그먼트에서 현재 선택된 칸
    var isSelected: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: { guard isEnabled else { return }; action() }) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: FluentMetrics.toolbarSegmentWidth,
                       height: FluentMetrics.toolbarControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(foreground)
        .background(fill)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(help)
    }

    /// 선택·hover 표시는 알약 안쪽에 들어가도록 조금 작은 곡률을 쓴다
    @ViewBuilder private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusToolbarControl - 2,
                                     style: .continuous)
        if isSelected {
            shape.fill(Color.fluentControlSelectedFill)
        } else if isHovered && isEnabled {
            shape.fill(Color.fluentHoverFill)
        }
    }

    private var foreground: Color {
        if !isEnabled { return .fluentTextDisabled }
        return .fluentTextPrimary
    }
}
