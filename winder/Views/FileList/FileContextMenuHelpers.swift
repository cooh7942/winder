import SwiftUI
import AppKit

// MARK: - 드롭 처리 (아이콘/목록/갤러리 보기 공용)

/// 끌어다 놓은 파일을 destination 폴더로 보낸다. destination이 nil이거나 규칙에 어긋나면 거부.
/// 복사할지 이동할지는 놓은 뒤 메뉴로 묻는다 (performFileDrop).
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
    onAction(.dropItems(urls: urls, destination: destination))
    return true
}

/// 끌어다 놓은 항목을 복사할지 이동할지 놓은 자리에 메뉴를 띄워 묻고, 고른 대로 처리한다.
///
/// 파일 목록(모든 보기)과 탐색 창 트리의 드롭이 모두 여기로 온다.
/// 드롭은 먼저 받아들이고 메뉴는 다음 런루프에서 띄운다 —
/// 드래그 세션 도중에 메뉴를 띄우면 드래그 이미지가 화면에 걸린 채 메뉴 추적이 시작된다.
@MainActor
func performFileDrop(_ urls: [URL], into destination: URL) {
    guard !urls.isEmpty else { return }
    DispatchQueue.main.async {
        guard let isCopy = askDropOperation(itemCount: urls.count, destination: destination) else { return }
        Task { @MainActor in
            do {
                if isCopy {
                    let created = try await FileOperationService.shared.copyItems(urls, to: destination)
                    guard !created.isEmpty else { return }
                    UndoService.shared.push(.init(description: "복사", affectedDirectories: [destination]) {
                        await Task.detached(priority: .userInitiated) {
                            for url in created {
                                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                            }
                        }.value
                    })
                } else {
                    let moved = try await FileOperationService.shared.moveItems(urls, to: destination)
                    guard !moved.isEmpty else { return }
                    UndoService.shared.push(.init(
                        description: "이동",
                        affectedDirectories: [destination] + moved.map { $0.from.deletingLastPathComponent() }
                    ) {
                        try await Task.detached(priority: .userInitiated) {
                            for pair in moved.reversed() {
                                try FileManager.default.moveItem(at: pair.to, to: pair.from)
                            }
                        }.value
                    })
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = isCopy ? "복사하지 못했습니다." : "이동하지 못했습니다."
                alert.informativeText = error.localizedDescription
                if let window = NSApp.keyWindow {
                    // 완료 처리기를 명시해야 async 판(응답을 기다리는 쪽)이 골라지지 않는다
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}

/// 놓은 자리(마우스 위치)에 "여기에 복사 / 여기로 이동 / 취소" 메뉴를 띄운다.
/// - Returns: true 복사, false 이동, nil 취소(Esc·바깥 클릭 포함)
@MainActor
private func askDropOperation(itemCount: Int, destination: URL) -> Bool? {
    let chooser = DropChoiceTarget()
    let menu = NSMenu()
    menu.autoenablesItems = false

    let name = FileManager.default.displayName(atPath: destination.path)
    let header = NSMenuItem(title: "\(itemCount)개 항목 → '\(name)'", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    menu.addItem(.separator())

    func addChoice(_ title: String, _ choice: DropChoiceTarget.Choice) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(DropChoiceTarget.choose(_:)), keyEquivalent: "")
        item.target = chooser
        item.tag = choice.rawValue
        menu.addItem(item)
        return item
    }
    let copyItem = addChoice("여기에 복사", .copy)
    _ = addChoice("여기로 이동", .move)
    menu.addItem(.separator())
    _ = addChoice("취소", .cancel)

    // 첫 선택지가 커서 바로 아래에 오게 띄운다 — 놓은 뒤 그대로 클릭하면 복사
    menu.popUp(positioning: copyItem, at: NSEvent.mouseLocation, in: nil)
    switch chooser.choice {
    case .copy:   return true
    case .move:   return false
    case .cancel, nil: return nil
    }
}

/// NSMenuItem은 target/action으로만 결과를 알려 주므로 고른 값을 받아 둘 객체
private final class DropChoiceTarget: NSObject {
    enum Choice: Int { case cancel, copy, move }
    private(set) var choice: Choice?

    @objc func choose(_ sender: NSMenuItem) {
        choice = Choice(rawValue: sender.tag)
    }
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
