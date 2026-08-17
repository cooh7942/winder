import SwiftUI

// MARK: - 드롭 처리 (아이콘/목록/갤러리 보기 공용)

/// 끌어다 놓은 파일을 destination 폴더로 보낸다. destination이 nil이거나 규칙에 어긋나면 거부.
/// SwiftUI dropDestination에는 수정자 키 정보가 없어 항상 복사로 처리한다
/// (⌘를 눌러 이동하는 동작은 자세히 보기에서만 지원).
@MainActor
func handleFileListDrop(_ urls: [URL], into destination: URL?,
                        onAction: (DetailsAction) -> Void) -> Bool {
    guard let destination, !urls.isEmpty else { return false }
    let dst = destination.standardizedFileURL
    let invalid = urls.contains { src in
        let srcStd = src.standardizedFileURL
        // 자기 자신·자기 하위로 옮기기, 이미 그 폴더에 있는 항목은 거부
        return dst.path.hasPrefix(srcStd.path + "/")
            || srcStd == dst
            || srcStd.deletingLastPathComponent() == dst
    }
    guard !invalid else { return false }
    onAction(.dropItems(urls: urls, destination: destination, isCopy: true))
    return true
}

/// 폴더 항목이면 그 폴더, 아니면 nil — 셀 드롭 대상 판정
func fileListDropDestination(for item: FileItem) -> URL? {
    (item.isDirectory && !item.isPackage) ? item.url : nil
}

// MARK: - 파일 항목 컨텍스트 메뉴 (아이콘/목록 보기 공용)

@ViewBuilder
func fileItemContextMenu(
    for item: FileItem,
    isMulti: Bool,
    favoriteURLs: Set<URL>,
    onAction: @escaping (DetailsAction) -> Void
) -> some View {
    Button("열기") { onAction(.open(item)) }

    Divider()

    Button("잘라내기") { onAction(.cut) }
    Button("복사")     { onAction(.copy) }

    Divider()

    Button("이름 바꾸기") { onAction(.rename(item, "")) }
        .disabled(isMulti)
    Button("삭제") { onAction(.delete) }

    if !isMulti && item.isDirectory && !item.isPackage {
        Divider()
        let isFav = favoriteURLs.contains(item.url.standardizedFileURL)
        if isFav {
            Button("즐겨찾기에서 제거") { onAction(.removeFromFavorites(item)) }
        } else {
            Button("즐겨찾기에 추가") { onAction(.addToFavorites(item)) }
        }
    }

    Divider()

    Button("\(item.displayName) 속성") { onAction(.properties(item)) }
        .disabled(isMulti)
}

// MARK: - 빈 영역 컨텍스트 메뉴

@ViewBuilder
func emptyAreaContextMenu(onAction: @escaping (DetailsAction) -> Void) -> some View {
    Button("붙여넣기") { onAction(.paste) }

    Divider()

    Button("새 폴더")       { onAction(.createFolder) }
    Button("새 텍스트 문서") { onAction(.createTextFile) }

    Divider()

    Button("모두 선택") { onAction(.selectAll) }
    Button(UndoService.shared.undoMenuTitle) { onAction(.undo) }
        .disabled(!UndoService.shared.canUndo)
}
