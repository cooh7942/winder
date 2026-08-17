import SwiftUI
import AppKit

/// 갤러리 보기 — Finder와 같은 구성.
/// 위쪽에 선택한 항목의 큰 미리보기, 아래쪽에 폴더 전체를 담은 가로 필름스트립.
///
/// 사진만 걸러내지 않고 폴더·문서까지 모두 보여준다 (Finder와 동일).
/// 미리보기를 만들 수 없는 항목은 파일 아이콘으로 대체한다.
struct GalleryView: View {
    let items: [FileItem]
    /// 목록 갱신 감지용 — 폴더가 바뀌면 미리보기 대상을 첫 항목으로 되돌린다
    let contentVersion: Int
    @Binding var selectedIDs: Set<String>
    let favoriteURLs: Set<URL>
    /// 현재 폴더 — 빈 곳에 끌어다 놓으면 여기로 들어온다
    let currentURL: URL?
    let onOpen: (FileItem) -> Void
    let onAction: (DetailsAction) -> Void

    /// 큰 미리보기에 띄울 항목 — 필름스트립에서 마지막으로 고른 것
    @State private var currentID: String?
    /// shift 범위 선택 기준점
    @State private var anchorIndex: Int?
    @State private var isAreaDropTargeted = false
    @FocusState private var isFocused: Bool

    private var current: FileItem? {
        items.first { $0.id == currentID } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            preview

            Rectangle()
                .fill(Color.fluentDivider)
                .frame(height: 1)

            filmstrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow)  { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1);  return .handled }
        .onKeyPress(.return)     { if let current { onOpen(current) }; return .handled }
        .contextMenu { emptyAreaContextMenu(onAction: onAction) }
        // 끌어다 놓으면 현재 폴더로
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
        .onAppear { syncCurrent() }
        .onChange(of: contentVersion) { _, _ in
            currentID = nil
            anchorIndex = nil
            syncCurrent()
        }
        // 다른 곳(목록·트리)에서 선택이 바뀌면 미리보기도 따라간다
        .onChange(of: selectedIDs) { _, ids in
            if let id = currentID, ids.contains(id) { return }
            // Set은 순서가 없다 — 목록에 놓인 순서로 첫 번째를 고른다
            currentID = items.first { ids.contains($0.id) }?.id ?? currentID
        }
    }

    // MARK: - 큰 미리보기

    @ViewBuilder private var preview: some View {
        if let current {
            GalleryPreview(item: current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 필름스트립

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FluentMetrics.paddingS) {
                    ForEach(items) { item in
                        GalleryThumbnail(item: item,
                                         isSelected: selectedIDs.contains(item.id),
                                         isCurrent: item.id == current?.id)
                            .id(item.id)
                            .onTapGesture(count: 2) { onOpen(item) }
                            .onTapGesture { handleTap(item) }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
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
                .padding(FluentMetrics.paddingS)
            }
            // 화살표로 옮기면 그 썸네일이 보이도록 따라 스크롤한다
            .onChange(of: current?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: FluentMetrics.animStandard)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: FluentMetrics.galleryStripHeight)
        .background(Color.fluentWindowBackground)
    }

    // MARK: - 선택

    private func syncCurrent() {
        guard currentID == nil || !items.contains(where: { $0.id == currentID }) else { return }
        guard let first = items.first else { currentID = nil; return }
        // 다른 보기에서 이미 고른 항목이 있으면 그걸 이어받는다 (목록 순서 기준)
        currentID = items.first { selectedIDs.contains($0.id) }?.id ?? first.id
    }

    private func handleTap(_ item: FileItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
                anchorIndex = index
            }
        } else if mods.contains(.shift), let anchor = anchorIndex {
            let range = min(anchor, index)...max(anchor, index)
            for i in range where i < items.count { selectedIDs.insert(items[i].id) }
        } else {
            selectedIDs = [item.id]
            anchorIndex = index
        }
        currentID = item.id
        isFocused = true
    }

    /// 화살표 키로 앞뒤 항목으로 이동 — Finder와 같이 선택도 함께 옮긴다
    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == current?.id } ?? 0
        let next = min(max(index + delta, 0), items.count - 1)
        guard next != index else { return }
        selectedIDs = [items[next].id]
        anchorIndex = next
        currentID = items[next].id
    }
}

// MARK: - 큰 미리보기

private struct GalleryPreview: View {
    let item: FileItem

    @State private var image: NSImage?
    /// 로딩 중(스피너)과 미리보기 없음(아이콘 대체)을 구분한다
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: FluentMetrics.paddingM) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(item.isCutPending ? 0.5 : 1.0)

            VStack(spacing: 2) {
                Text(item.displayName)
                    .fluentBody()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .fluentCaption()
                    .foregroundColor(.fluentTextSecondary)
            }
        }
        .padding(FluentMetrics.paddingL)
        .task(id: item.id) {
            image = nil
            didLoad = false
            // 폴더·패키지는 QuickLook도 아이콘을 돌려줄 뿐이라 크게 키우면 거칠어진다 —
            // 아예 요청하지 않고 아이콘 그대로 보여준다
            if !item.isDirectory, !item.isPackage {
                image = await ThumbnailProvider.shared.thumbnail(
                    for: item.url, size: FluentMetrics.galleryPreviewSize)
            }
            didLoad = true
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // 만들어 둔 썸네일보다 크게 늘리면 흐려진다
                .frame(maxWidth: FluentMetrics.galleryPreviewSize,
                       maxHeight: FluentMetrics.galleryPreviewSize)
        } else if didLoad {
            // 미리보기가 없는 항목(폴더·실행 파일 등)은 파일 아이콘으로
            Image(nsImage: item.icon
                  ?? IconProvider.shared.icon(for: item.url, size: FluentMetrics.iconSizeLarge))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: FluentMetrics.iconSizeGallery,
                       height: FluentMetrics.iconSizeGallery)
        } else {
            ProgressView().controlSize(.regular)
        }
    }

    private var subtitle: String {
        item.isDirectory ? item.typeDescription
                         : "\(item.typeDescription) — \(formatFileSize(item.size))"
    }
}

// MARK: - 필름스트립 썸네일

private struct GalleryThumbnail: View {
    let item: FileItem
    let isSelected: Bool
    /// 큰 미리보기에 떠 있는 항목 — 선택 중에서도 하나만 테두리로 강조한다
    let isCurrent: Bool

    @State private var thumbnail: NSImage?
    @State private var didLoad = false

    private let size = FluentMetrics.galleryThumbSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusControl)
                .fill(isSelected ? Color.fluentSelectionFill : Color.fluentControlFill)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusControl))
            } else if didLoad {
                Image(nsImage: item.icon
                      ?? IconProvider.shared.icon(for: item.url, size: FluentMetrics.iconSizeMedium))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size / 2, height: size / 2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .opacity(item.isCutPending ? 0.5 : 1.0)
        .overlay(
            RoundedRectangle(cornerRadius: FluentMetrics.cornerRadiusControl)
                .strokeBorder(isCurrent ? Color.fluentAccent : Color.clear, lineWidth: 2)
        )
        .help(item.displayName)
        .task(id: item.id) {
            // 뷰가 재사용되면 이전 항목의 썸네일이 한 프레임 남는다 — 먼저 비운다
            thumbnail = nil
            didLoad = false
            thumbnail = await ThumbnailProvider.shared.thumbnail(for: item.url, size: size)
            didLoad = true
        }
    }
}
