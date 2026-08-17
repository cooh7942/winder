import SwiftUI

/// Windows 11 탐색기 브레드크럼 뷰
/// 표시 모드 ↔ 텍스트 편집 모드 전환, 셰브런 클릭으로 형제 폴더 드롭다운
struct BreadcrumbView: View {
    let segments: [PathSegment]
    @Binding var isEditing: Bool
    @Binding var inputText: String
    let onNavigate: (URL) -> Void
    let onCommitText: (String) -> Void

    @State private var siblingMenuURL: URL? = nil
    @State private var siblings: [URL] = []
    @State private var showSiblings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            if isEditing {
                editingField
            } else {
                breadcrumbs
            }
        }
        .padding(.horizontal, FluentMetrics.paddingM)
        .frame(maxWidth: .infinity, maxHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusControl)
                .fill(Color.fluentContentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusControl)
                        .stroke(isEditing ? Color.fluentAccent : Color.fluentDivider,
                                lineWidth: isEditing ? 2 : 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { enterEditMode() }
    }

    // MARK: - 브레드크럼 표시 모드

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { idx, segment in
                    HStack(spacing: 0) {
                        // 세그먼트 버튼
                        Button(action: {
                            guard let url = segment.url else { return }
                            onNavigate(url)
                        }) {
                            Text(segment.displayName)
                                .fluentBody()
                                .foregroundColor(.fluentTextPrimary)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(segment.url == nil)

                        // 셰브런 (마지막 세그먼트 제외)
                        if idx < segments.count - 1 {
                            Button(action: {
                                if let url = segment.url {
                                    loadSiblings(of: url)
                                }
                            }) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(.fluentTextSecondary)
                                    .padding(.horizontal, 2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showSiblings, arrowEdge: .bottom) {
                                siblingList
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - 텍스트 편집 모드

    private var editingField: some View {
        TextField("경로 입력", text: $inputText)
            .textFieldStyle(.plain)
            .fluentBody()
            .foregroundColor(.fluentTextPrimary)
            .focused($inputFocused)
            .onSubmit {
                onCommitText(inputText)
                isEditing = false
            }
            .onKeyPress(.escape) {
                isEditing = false
                return .handled
            }
    }

    // MARK: - 형제 폴더 드롭다운

    private var siblingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(siblings, id: \.path) { url in
                    Button(action: {
                        showSiblings = false
                        onNavigate(url)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                                .foregroundColor(.fluentTextSecondary)
                            Text(FileManager.default.displayName(atPath: url.path))
                                .fluentBody()
                                .foregroundColor(.fluentTextPrimary)
                        }
                        .padding(.horizontal, FluentMetrics.paddingM)
                        .frame(height: 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, FluentMetrics.paddingXS)
        }
        .frame(width: 200, height: min(CGFloat(siblings.count * 32 + 16), 300))
    }

    // MARK: - Private

    private func enterEditMode() {
        // 현재 경로를 입력 필드에 채운 후 편집 모드 진입
        if let url = segments.last?.url {
            inputText = url.path
        }
        isEditing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            inputFocused = true
        }
    }

    private func loadSiblings(of url: URL) {
        let parent = url.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]  // .skipsPackageDescendants는 contentsOfDirectory에서 무시됨
            )) ?? []
            let dirs = items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            await MainActor.run {
                siblings = dirs
                showSiblings = true
            }
        }
    }
}
