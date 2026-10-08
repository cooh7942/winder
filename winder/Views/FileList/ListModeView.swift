import SwiftUI
import AppKit

/// 목록 보기 — 세로 흐름(LazyHGrid), 가로 스크롤
/// 항목이 세로로 채워진 후 다음 열로 넘어가는 Windows 11 목록 모드와 동일한 레이아웃
struct ListModeView: View {
    let items: [FileItem]
    /// 인라인 이름 변경 중인 항목 — 새 폴더를 만들면 바로 이 상태로 들어온다
    let renamingItemID: String?
    @Binding var selectedIDs: Set<String>
    let favoriteURLs: Set<URL>
    /// 현재 폴더 — 빈 곳에 드롭했을 때의 대상
    let currentURL: URL?
    let onOpen: (FileItem) -> Void
    let onAction: (DetailsAction) -> Void

    @State private var lastSelectedIndex: Int? = nil
    @State private var hoveredID: String? = nil
    /// 드래그가 올라가 있는 폴더 셀
    @State private var dropTargetID: String? = nil
    /// 빈 곳(= 현재 폴더)이 드롭 대상인 상태
    @State private var isAreaDropTargeted = false

    private let cellWidth: CGFloat = 200
    private let rowHeight: CGFloat = FluentMetrics.listRowHeight

    var body: some View {
        GeometryReader { geo in
            let numRows = max(1, Int(geo.size.height / rowHeight))
            let rows = Array(repeating: GridItem(.fixed(rowHeight), spacing: 0), count: numRows)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHGrid(rows: rows, alignment: .top, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            ListModeCell(
                                item: item,
                                isSelected: selectedIDs.contains(item.id),
                                isHovered: hoveredID == item.id,
                                isDropTarget: dropTargetID == item.id,
                                isRenaming: renamingItemID == item.id,
                                onAction: onAction
                            )
                            .frame(width: cellWidth, height: rowHeight)
                            .onTapGesture(count: 2) { onOpen(item) }
                            .onTapGesture { handleTap(item: item, index: idx) }
                            .onHover { hoveredID = $0 ? item.id : nil }
                            // Finder처럼 끌어서 복사 — 자세히 보기와 동작을 맞춘다
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .dropDestination(for: URL.self) { urls, _ in
                                handleFileListDrop(urls, into: fileListDropDestination(for: item),
                                                   onAction: onAction)
                            } isTargeted: { targeted in
                                if targeted, fileListDropDestination(for: item) != nil {
                                    dropTargetID = item.id
                                } else if dropTargetID == item.id {
                                    dropTargetID = nil
                                }
                            }
                            .contextMenu {
                                fileItemContextMenu(
                                    for: item,
                                    isMulti: selectedIDs.count > 1 && selectedIDs.contains(item.id),
                                    favoriteURLs: favoriteURLs,
                                    onAction: onAction
                                )
                            }
                        }
                    }
                    .padding(.horizontal, FluentMetrics.paddingXS)
                }
                // 이름을 바꿀 항목이 화면 밖이면 칸이 만들어지지 않는다 — 먼저 보이게 한다
                .onChange(of: renamingItemID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu { emptyAreaContextMenu(onAction: onAction) }
        // 빈 곳에 놓으면 현재 폴더로
        .dropDestination(for: URL.self) { urls, _ in
            handleFileListDrop(urls, into: currentURL, onAction: onAction)
        } isTargeted: { isAreaDropTargeted = $0 }
        .overlay {
            if isAreaDropTargeted {
                RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusControl)
                    .strokeBorder(Color.fluentDropTargetStroke, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleTap(item: FileItem, index: Int) {
        endInlineRenameIfNeeded(renamingItemID)
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id); lastSelectedIndex = index }
        } else if mods.contains(.shift), let last = lastSelectedIndex {
            let lo = min(last, index); let hi = max(last, index)
            for i in lo...hi where i < items.count { selectedIDs.insert(items[i].id) }
        } else {
            selectedIDs = [item.id]
            lastSelectedIndex = index
        }
    }
}

// MARK: - 셀

private struct ListModeCell: View {
    let item: FileItem
    let isSelected: Bool
    let isHovered: Bool
    let isDropTarget: Bool
    let isRenaming: Bool
    let onAction: (DetailsAction) -> Void

    @State private var icon: NSImage? = nil

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let img = icon {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                        .resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .opacity(item.isCutPending ? 0.5 : 1.0)

            if isRenaming {
                InlineRenameField(item: item, fontSize: 12, onAction: onAction)
            } else {
                Text(item.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FluentMetrics.paddingXS)
        .background(
            RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusRow)
                .fill(cellBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusRow)
                        .strokeBorder(isDropTarget ? Color.fluentDropTargetStroke : .clear,
                                      lineWidth: 1)
                )
        )
        .task {
            icon = IconProvider.shared.icon(for: item.url, size: 16)
        }
    }

    private var cellBackground: Color {
        // 드롭 대상 표시가 선택·hover보다 우선한다
        if isDropTarget { return .fluentDropTargetFill }
        if isSelected   { return .fluentSelectionFill }
        if isHovered    { return .fluentHoverFill }
        return .clear
    }
}
