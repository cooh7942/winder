import SwiftUI
import AppKit

// NSTableView로 자세히 보기를 구현 — SwiftUI List/LazyVStack으로는
// 수만 개 항목 성능, 컬럼 리사이즈/재정렬, 컬럼 헤더 정렬 표시를 재현할 수 없음

// MARK: - DetailsAction

enum DetailsAction {
    case open(FileItem)
    /// 이름 변경 모드 진입 요청 (newName == "") 또는 커밋 (newName != "")
    case rename(FileItem, String)
    /// 이름 변경 취소 (Esc) — 뷰모델의 진행 중 상태를 푼다
    case renameCancelled
    case delete
    /// ⇧Delete: 휴지통 없이 영구 삭제 — 확인 다이얼로그 경유
    case permanentDelete
    case copy
    case cut
    case paste
    case selectAll
    case undo
    case properties(FileItem)
    case createFolder
    case createTextFile
    /// 폴더를 즐겨찾기에 추가 (기능 1)
    case addToFavorites(FileItem)
    /// 즐겨찾기에서 제거 (기능 1)
    case removeFromFavorites(FileItem)
    /// 파일 목록으로 끌어다 놓기 — destination은 대상 폴더(빈 곳에 놓으면 현재 폴더)
    /// 끌어다 놓기 — 복사할지 이동할지는 놓은 뒤 메뉴로 묻는다 (performFileDrop)
    case dropItems(urls: [URL], destination: URL)
}

// MARK: - DetailsView

struct DetailsView: NSViewRepresentable {
    var items: [FileItem]
    var contentVersion: Int
    var renamingItemID: String?
    var selectedIDs: Binding<Set<String>>
    var sortDescriptor: FileSortDescriptor
    /// 즐겨찾기 URL 집합 — 컨텍스트 메뉴에서 추가/제거 토글에 사용 (기능 1)
    var favoriteURLs: Set<URL> = []
    /// 현재 보고 있는 폴더 — 목록 빈 곳에 드롭했을 때의 대상
    var currentURL: URL?
    let onSort: (SortKey) -> Void
    let onAction: (DetailsAction) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.tableView
        tv.dataSource = context.coordinator
        tv.delegate   = context.coordinator

        // 더블클릭 — 키 이벤트와 동일하게 onAction(.open) 경로로 처리
        tv.target       = context.coordinator
        tv.doubleAction = #selector(DetailsViewCoordinator.rowDoubleClicked(_:))

        // Finder 목록 보기 — 한 줄 걸러 옅은 줄무늬가 깔린다
        tv.style             = .plain
        tv.usesAlternatingRowBackgroundColors = true
        tv.backgroundColor   = FluentColors.contentBackground
        tv.rowHeight         = FluentMetrics.listRowHeight
        tv.intercellSpacing  = NSSize(width: 0, height: 0)
        tv.allowsMultipleSelection = true
        tv.allowsEmptySelection    = true
        tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        // 컬럼 정의 — 모두 사용자가 경계를 끌어 폭을 바꿀 수 있다
        addColumn(to: tv, id: "name",         title: "이름",        width: 200, min: 150)
        addColumn(to: tv, id: "dateModified", title: "수정일",  width: 140, min: 100)
        addColumn(to: tv, id: "type",         title: "종류",    width: 100, min: 80)
        addColumn(to: tv, id: "size",         title: "크기",         width: 80,  min: 60)

        tv.headerView?.wantsLayer = true
        // 헤더 경계선 더블클릭 → 내용 폭에 맞추기
        (tv.headerView as? WinTableHeaderView)?.onAutoFit = { [weak coord = context.coordinator] index in
            coord?.autoFitColumn(at: index)
        }

        // 컨텍스트 메뉴 — coordinator가 NSMenuDelegate로 항목을 동적 구성
        // autoenablesItems = false: AppKit이 isEnabled를 덮어쓰지 않도록 반드시 설정
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = context.coordinator
        tv.menu = contextMenu

        // 드래그 소스 마스크: 앱 내 이동/복사(B-4) + 외부 앱 복사/링크(기능 1)
        // N-6: forLocal: true를 명시 — 기본값(.every)에 묵시적으로 의존하지 않도록
        tv.setDraggingSourceOperationMask([.move, .copy, .link], forLocal: true)
        tv.setDraggingSourceOperationMask([.copy, .link], forLocal: false)

        // 드롭 수신 — 폴더 행 위에 놓으면 그 폴더로, 빈 곳에 놓으면 현재 폴더로
        tv.registerForDraggedTypes([.fileURL])
        // 시스템 강조 대신 트리와 같은 방식으로 직접 그린다
        tv.draggingDestinationFeedbackStyle = .none

        // 키보드 이벤트 핸들러 (WinTableView 서브클래스)
        tv.keyActionHandler = { [weak coord = context.coordinator] event in
            coord?.handleKeyEvent(event) ?? false
        }
        // 드래그가 목록을 벗어나거나 취소되면 강조를 지운다
        tv.onDragFeedbackShouldClear = { [weak coord = context.coordinator] in
            coord?.clearDropFeedback()
        }

        // 빈 곳 드롭(= 현재 폴더) 표시용 테두리 — 표시 시점에 visibleRect로 프레임을 잡는다
        // (탐색 창의 삽입선과 같은 방식)
        tv.addSubview(context.coordinator.dropBorderView)

        let scrollView = NSScrollView()
        scrollView.documentView = tv
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.backgroundColor = FluentColors.contentBackground

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        let needsReload = coord.contentVersion != contentVersion
        coord.items = items
        coord.contentVersion = contentVersion
        coord.onSort        = onSort
        coord.onAction      = onAction
        coord.sortDescriptor = sortDescriptor
        coord.favoriteURLs  = favoriteURLs
        coord.currentURL    = currentURL
        coord.onSelectionChange = { selectedIDs.wrappedValue = $0 }

        if needsReload {
            coord.tableView.reloadData()
        }

        // 선택 상태 동기화 (뷰모델 → NSTableView)
        let tv = coord.tableView
        let desired = IndexSet(items.enumerated()
            .filter { selectedIDs.wrappedValue.contains($0.element.id) }
            .map(\.offset))
        if desired != tv.selectedRowIndexes {
            coord.isSyncingSelection = true
            tv.selectRowIndexes(desired, byExtendingSelection: false)
            coord.isSyncingSelection = false
        }

        // 인라인 이름 변경 트리거
        if coord.renamingItemID != renamingItemID {
            coord.renamingItemID = renamingItemID
            if let id = renamingItemID,
               let row = items.firstIndex(where: { $0.id == id }) {
                coord.beginRename(row: row)
            } else if renamingItemID == nil {
                // 다른 보기로 바뀌는 등 바깥에서 끝낸 경우 — 보이지 않는 칸에 포커스가 남지 않게 닫는다
                coord.cancelRenaming()
            }
        }

        updateSortIndicator(tv, descriptor: sortDescriptor)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Private helpers

    private func addColumn(to tv: NSTableView, id: String, title: String,
                           width: CGFloat, min: CGFloat) {
        let col = NSTableColumn(identifier: .init(id))
        // 바탕은 WinTableHeaderView가 도구 막대와 같은 색으로 칠한다 — 셀은 글자만 그린다
        let headerCell = WinTableHeaderCell(textCell: title)
        headerCell.leadingInset = id == "name"
            ? FluentMetrics.listNameTextInset : FluentMetrics.listColumnTextInset
        col.headerCell = headerCell
        col.title     = title
        col.width     = width
        col.minWidth  = min
        col.maxWidth  = 600
        col.resizingMask = [.userResizingMask]
        col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        tv.addTableColumn(col)
    }

    private func updateSortIndicator(_ tv: NSTableView, descriptor: FileSortDescriptor) {
        // 정렬 중인 열을 표시해 두면 WinTableHeaderView가 그 열 오른쪽에 갈매기표를 그린다.
        // setIndicatorImage는 이 헤더에서 그려지지 않아 직접 그린다.
        tv.highlightedTableColumn = tv.tableColumns.first {
            SortKey.forColumnID($0.identifier.rawValue) == descriptor.key
        }
        let header = tv.headerView as? WinTableHeaderView
        header?.sortAscending = descriptor.ascending
        header?.needsDisplay = true
    }
}

// MARK: - Coordinator

final class DetailsViewCoordinator: NSObject,
    NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    var items: [FileItem] = []
    var contentVersion: Int = -1
    var renamingItemID: String? = nil
    /// 이름 변경 칸을 띄운 셀 — 바깥에서 이름 변경이 끝났을 때 닫으려고 기억한다
    private weak var renamingCell: WinTableCellView?
    var sortDescriptor: FileSortDescriptor = FileSortDescriptor()
    /// 현재 즐겨찾기 URL 집합 — updateNSView가 매 렌더마다 동기화 (기능 1)
    var favoriteURLs: Set<URL> = []
    /// 현재 폴더 — 목록 빈 곳에 드롭했을 때의 대상
    var currentURL: URL?
    /// 강조 중인 폴더 행 (-1이면 없음)
    private var dropTargetRow: Int = -1
    /// 빈 곳 드롭 대상 표시용 테두리 — makeNSView에서 스크롤 뷰에 얹는다
    let dropBorderView = WinDropBorderView()
    var onSort: (SortKey) -> Void = { _ in }
    var onAction: (DetailsAction) -> Void = { _ in }
    var onSelectionChange: (Set<String>) -> Void = { _ in }
    var isSyncingSelection = false

    // 타입어헤드 버퍼
    private var typeAheadBuffer = ""
    // Timer 대신 Task.sleep 사용: Timer는 .eventTracking 런루프 모드에서 발화하지 않음
    private var typeAheadTask: Task<Void, Never>?

    let tableView: WinTableView = {
        let tv = WinTableView()
        tv.headerView = WinTableHeaderView()
        return tv
    }()

    // MARK: NSTableViewDataSource

    // MARK: NSTableViewDataSource — 드래그 소스

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count else { return nil }
        // 파일·폴더를 모두 드래그 소스로 허용한다 (Finder처럼 끌어서 복사/이동).
        // nil을 돌려주면 NSTableView가 그 행에서 시작한 드래그를 범위 선택으로 처리해
        // 마우스를 끄는 동안 여러 파일이 선택된다 — 드래그 앤 드롭이 이를 대신한다.
        // 여러 항목을 선택한 뒤 드래그하면 AppKit이 선택된 행마다 이 메서드를 호출한다.
        return items[row].url as NSURL
    }

    // MARK: NSTableViewDataSource — 드롭 수신

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // 반환 지점이 여러 곳이므로 강조는 defer로 한 번만 반영한다 (탐색 창 트리와 같은 방식)
        var feedbackRow = -1
        var wholeList = false
        defer { setDropFeedback(row: feedbackRow, wholeList: wholeList) }

        let urls = draggedURLs(from: info)
        guard !urls.isEmpty else { return [] }

        // 폴더 행 위 — 그 폴더 안으로
        if dropOperation == .on, row >= 0, row < items.count {
            let item = items[row]
            if item.isDirectory, !item.isPackage, isValidDrop(urls, into: item.url) {
                feedbackRow = row
                return dragOperation(for: info)
            }
        }

        // 그 밖(빈 곳·행 사이·파일 행) — 현재 폴더 안으로
        guard let destination = currentURL,
              isValidDrop(urls, into: destination),
              // 이미 이 폴더에 있는 항목이면 거부 — 같은 자리에 사본이 생기는 것을 막는다
              !urls.contains(where: {
                  $0.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL
              })
        else { return [] }

        // row -1 + .on = "목록 전체에 드롭"
        tableView.setDropRow(-1, dropOperation: .on)
        wholeList = true
        return dragOperation(for: info)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        clearDropFeedback()

        let urls = draggedURLs(from: info)
        guard !urls.isEmpty else { return false }

        let destination: URL
        if dropOperation == .on, row >= 0, row < items.count,
           items[row].isDirectory, !items[row].isPackage {
            destination = items[row].url
        } else if let current = currentURL {
            destination = current
        } else {
            return false
        }

        onAction(.dropItems(urls: urls, destination: destination))
        return true
    }

    private func draggedURLs(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 자기 자신 또는 자기 하위로 옮기는 드롭 차단 — 탐색 창 트리와 같은 규칙
    private func isValidDrop(_ urls: [URL], into destination: URL) -> Bool {
        let dst = destination.standardizedFileURL
        return !urls.contains { src in
            let srcStd = src.standardizedFileURL
            return dst.path.hasPrefix(srcStd.path + "/") || srcStd == dst
        }
    }

    /// 커서 배지 표시용 — 실제 복사·이동은 놓은 뒤 메뉴에서 고른다
    private func dragOperation(for info: NSDraggingInfo) -> NSDragOperation {
        info.draggingSourceOperationMask.contains(.copy) ? .copy : .move
    }

    // MARK: 드롭 대상 강조

    /// row >= 0이면 그 폴더 행을, wholeList면 목록 전체(현재 폴더)를 강조한다
    private func setDropFeedback(row: Int, wholeList: Bool) {
        if dropTargetRow != row {
            let previous = dropTargetRow
            dropTargetRow = row
            for candidate in [previous, row] where candidate >= 0 {
                (tableView.rowView(atRow: candidate, makeIfNecessary: false) as? WinTableRowView)?
                    .isDropTarget = (candidate == dropTargetRow)
            }
        }
        if wholeList {
            // 스크롤 위치와 무관하게 지금 보이는 영역을 감싸도록
            dropBorderView.frame = tableView.visibleRect
            dropBorderView.isHidden = false
            dropBorderView.needsDisplay = true
        } else {
            dropBorderView.isHidden = true
        }
    }

    func clearDropFeedback() { setDropFeedback(row: -1, wholeList: false) }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let colID = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        let cellID = NSUserInterfaceItemIdentifier(colID + "Cell")
        let cell: WinTableCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? WinTableCellView {
            cell = existing
        } else {
            cell = WinTableCellView()
            cell.identifier = cellID
        }
        configure(cell, item: item, columnID: colID)
        // 이름 열에서 이름 변경 커밋 핸들러 연결
        // renamingItemID는 여기서 초기화하지 않음 — tab.renameItem이 nil로 설정하면
        // updateNSView가 감지하여 자연스럽게 정리된다
        if colID == "name" {
            cell.onRenameCommit = { [weak self] newName in
                guard let self else { return }
                if let item = self.items.first(where: { $0.id == self.renamingItemID }) {
                    self.onAction(.rename(item, newName))
                }
            }
            cell.onRenameCancel = { [weak self] in
                self?.onAction(.renameCancelled)
            }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // 식별자를 붙여 AppKit 재사용 풀을 태운다 — 없으면 스크롤할 때마다 행 뷰가 새로 할당된다
        let rowID = NSUserInterfaceItemIdentifier("WinTableRow")
        let rowView: WinTableRowView
        if let reused = tableView.makeView(withIdentifier: rowID, owner: self) as? WinTableRowView {
            rowView = reused
        } else {
            rowView = WinTableRowView()
            rowView.identifier = rowID
        }
        // 드래그 중 스크롤로 행이 새로 만들어져도 강조가 유지되도록
        rowView.isDropTarget = (row == dropTargetRow)
        return rowView
    }

    // MARK: NSTableViewDelegate — 정렬

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first,
              let key = SortKey.forColumnID(first.key ?? "") else { return }
        onSort(key)
    }

    // MARK: NSTableViewDelegate — 선택

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let ids = tableView.selectedRowIndexes.compactMap { row -> String? in
            guard row < items.count else { return nil }
            return items[row].id
        }
        onSelectionChange(Set(ids))
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // MARK: 더블클릭

    @objc func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < items.count else { return }
        onAction(.open(items[row]))
    }

    // MARK: 인라인 이름 변경

    func beginRename(row: Int) {
        guard row >= 0, row < items.count else { return }
        let nameColIdx = tableView.column(withIdentifier: .init("name"))
        guard nameColIdx >= 0 else { return }
        // 셀이 화면에 렌더링된 후 포커스 이동
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let cell = self.tableView.view(atColumn: nameColIdx, row: row,
                                                  makeIfNecessary: true) as? WinTableCellView else { return }
            cell.startRenaming(currentName: self.items[row].displayName)
            self.renamingCell = cell
        }
    }

    /// 진행 중인 인라인 이름 변경을 확정하지 않고 닫는다
    func cancelRenaming() {
        renamingCell?.endRenaming(commit: false)
        renamingCell = nil
    }

    // MARK: 키보드 이벤트 (WinTableView 위임)

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        let noMods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask).isEmpty

        switch event.keyCode {
        case 36, 76:  // Return, Enter(numpad)
            let rows = tableView.selectedRowIndexes
            if let row = rows.first, row < items.count {
                onAction(.open(items[row]))
            }
            return true
        case 120:  // F2 — onAction으로 라우팅, updateNSView가 beginRename 호출
            let rows = tableView.selectedRowIndexes
            if let row = rows.first, row < items.count {
                onAction(.rename(items[row], ""))
            }
            return true
        case 51, 117:  // Delete, Forward Delete
            let onlyShift = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
            if noMods    { onAction(.delete);          return true }
            if onlyShift { onAction(.permanentDelete); return true }
        default:
            break
        }

        if cmd {
            switch event.charactersIgnoringModifiers {
            case "c": onAction(.copy);      return true
            case "x": onAction(.cut);       return true
            case "v": onAction(.paste);     return true
            case "a": onAction(.selectAll); return true
            case "z": onAction(.undo);      return true
            default: break
            }
        }

        // 타입어헤드 — 영숫자 단일 문자 입력 시 이름 일치 항목으로 스크롤
        // key.count == 1: IME 조합 중 다중 문자 이벤트 방지 (한글 등)
        if noMods,
           let key = event.characters, key.count == 1,
           let first = key.unicodeScalars.first,
           CharacterSet.letters.union(.decimalDigits).contains(first) {
            handleTypeAhead(key)
            return true
        }

        return false
    }

    private func handleTypeAhead(_ char: String) {
        typeAheadTask?.cancel()
        typeAheadBuffer += char.lowercased()
        if let row = items.firstIndex(where: {
            $0.displayName.lowercased().hasPrefix(typeAheadBuffer)
        }) {
            isSyncingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSyncingSelection = false
            tableView.scrollRowToVisible(row)
            onSelectionChange([items[row].id])
        }
        // Task.sleep: Timer와 달리 .eventTracking 런루프 모드에서도 동작
        // @MainActor: typeAheadBuffer는 항상 메인 스레드에서 접근
        typeAheadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.typeAheadBuffer = ""
        }
    }

    // MARK: NSMenuDelegate — 컨텍스트 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = tableView.clickedRow
        let selRows = tableView.selectedRowIndexes

        if clickedRow >= 0, clickedRow < items.count {
            // 클릭된 행이 선택 영역 밖이면 단독 선택으로 변경
            if !selRows.contains(clickedRow) {
                isSyncingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                isSyncingSelection = false
                onSelectionChange([items[clickedRow].id])
            }
            let multi = tableView.selectedRowIndexes.count > 1
            let item = items[clickedRow]

            addMenuItem(menu, title: "열기", action: #selector(ctxOpen))
            menu.addItem(.separator())
            addMenuItem(menu, title: "잘라내기", action: #selector(ctxCut))
            addMenuItem(menu, title: "복사", action: #selector(ctxCopy))
            menu.addItem(.separator())
            addMenuItem(menu, title: "이름 바꾸기", action: #selector(ctxRename),
                        enabled: !multi)
            addMenuItem(menu, title: "삭제", action: #selector(ctxDelete))
            // 폴더(패키지 제외)에만 즐겨찾기 메뉴 표시 (기능 1)
            if item.isDirectory && !item.isPackage && !multi {
                menu.addItem(.separator())
                let isFav = favoriteURLs.contains(item.url.standardizedFileURL)
                if isFav {
                    addMenuItem(menu, title: "즐겨찾기에서 제거",
                                action: #selector(ctxRemoveFromFavorites))
                } else {
                    addMenuItem(menu, title: "즐겨찾기에 추가",
                                action: #selector(ctxAddToFavorites))
                }
            }
            menu.addItem(.separator())
            addMenuItem(menu, title: "\(item.displayName) 속성", action: #selector(ctxProperties),
                        enabled: !multi)
        } else {
            // 빈 영역 클릭
            addMenuItem(menu, title: "붙여넣기", action: #selector(ctxPaste),
                        enabled: ClipboardService.shared.hasPasteContent)
            menu.addItem(.separator())
            addMenuItem(menu, title: "새 폴더", action: #selector(ctxNewFolder))
            addMenuItem(menu, title: "새 텍스트 문서", action: #selector(ctxNewFile))
            menu.addItem(.separator())
            addMenuItem(menu, title: "모두 선택", action: #selector(ctxSelectAll))
            // 커맨드바의 "..." 메뉴를 없앴으므로 실행 취소는 여기와 ⌘Z로 접근한다
            addMenuItem(menu, title: UndoService.shared.undoMenuTitle,
                        action: #selector(ctxUndo),
                        enabled: UndoService.shared.canUndo)
        }
    }

    private func addMenuItem(_ menu: NSMenu, title: String, action: Selector,
                              enabled: Bool = true) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
    }

    @objc private func ctxOpen() {
        let rows = tableView.selectedRowIndexes
        guard let row = rows.first, row < items.count else { return }
        onAction(.open(items[row]))
    }

    @objc private func ctxCut()        { onAction(.cut) }
    @objc private func ctxCopy()       { onAction(.copy) }
    @objc private func ctxPaste()      { onAction(.paste) }
    @objc private func ctxSelectAll()  { onAction(.selectAll) }
    @objc private func ctxUndo()       { onAction(.undo) }
    @objc private func ctxDelete()     { onAction(.delete) }
    @objc private func ctxNewFolder()  { onAction(.createFolder) }
    @objc private func ctxNewFile()    { onAction(.createTextFile) }

    @objc private func ctxRename() {
        let rows = tableView.selectedRowIndexes
        guard let row = rows.first, row < items.count else { return }
        onAction(.rename(items[row], ""))
    }

    @objc private func ctxProperties() {
        let rows = tableView.selectedRowIndexes
        guard let row = rows.first, row < items.count else { return }
        onAction(.properties(items[row]))
    }

    @objc private func ctxAddToFavorites() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onAction(.addToFavorites(items[row]))
    }

    @objc private func ctxRemoveFromFavorites() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onAction(.removeFromFavorites(items[row]))
    }

    // MARK: Private

    /// 컬럼에 표시되는 문자열 — 폭 자동 맞춤 계산에도 쓴다
    private func text(for item: FileItem, columnID: String) -> String {
        switch columnID {
        case "name":         return item.displayName
        case "dateModified": return formatFileDate(item.dateModified)
        case "type":         return item.typeDescription
        case "size":         return item.isDirectory ? "" : formatFileSize(item.size)
        default:             return ""
        }
    }

    /// 폭을 잴 때 훑는 최대 행 수.
    /// 글자 폭 계산은 항목당 수 마이크로초라 수만 개짜리 폴더에서 전부 재면 그동안 화면이 멈춘다.
    /// 화면에 보이는 범위를 반드시 포함하고 그 앞뒤로 이만큼만 본다
    private static let autoFitScanLimit = 1000

    /// 경계선 더블클릭 — 헤더와 행 내용을 재어 가장 긴 것에 맞춘다
    func autoFitColumn(at index: Int) {
        let table = tableView
        guard index >= 0, index < table.numberOfColumns else { return }
        let column = table.tableColumns[index]
        let columnID = column.identifier.rawValue

        let cellFont = NSFont.systemFont(ofSize: 13)
        let headerFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        // 글자가 시작하는 위치 + 오른쪽 여백
        let extra: CGFloat = (columnID == "name" ? FluentMetrics.listNameTextInset
                                                 : FluentMetrics.listColumnTextInset)
                             + FluentMetrics.paddingM

        var widest = (column.title as NSString)
            .size(withAttributes: [.font: headerFont]).width + FluentMetrics.paddingL
        for item in items[scanRange()] {
            let value = text(for: item, columnID: columnID)
            guard !value.isEmpty else { continue }
            let width = (value as NSString).size(withAttributes: [.font: cellFont]).width + extra
            if width > widest { widest = width }
        }

        column.width = min(max(widest.rounded(.up), column.minWidth), column.maxWidth)
    }

    /// 폭을 잴 구간 — 보고 있는 행을 가운데 두고 상한만큼 잡는다.
    /// 화면에 보이는 것이 잘리지 않는 것이 사용자가 체감하는 "맞춤"이다
    private func scanRange() -> Range<Int> {
        guard items.count > Self.autoFitScanLimit else { return items.indices }
        let visible = tableView.rows(in: tableView.visibleRect)
        let center = visible.length > 0 ? visible.location + visible.length / 2 : 0
        let half = Self.autoFitScanLimit / 2
        let lower = max(0, min(center - half, items.count - Self.autoFitScanLimit))
        return lower..<(lower + Self.autoFitScanLimit)
    }

    private func configure(_ cell: WinTableCellView, item: FileItem, columnID: String) {
        // 이름 변경 중인 셀의 이름 열은 건드리지 않음 — 입력 중인 텍스트 덮어쓰기 방지
        if columnID == "name" && cell.isRenaming { return }
        cell.applyColumnLayout(showsIcon: columnID == "name")
        switch columnID {
        case "name":
            cell.imageView?.image = item.icon
                ?? IconProvider.shared.icon(for: item.url, size: FluentMetrics.listIconSize)
            cell.imageView?.alphaValue = item.isCutPending ? 0.5 : 1.0
            cell.textField?.stringValue = item.displayName
            cell.textField?.alphaValue = item.isCutPending ? 0.5 : 1.0
        case "dateModified":
            cell.textField?.stringValue = formatFileDate(item.dateModified)
        case "type":
            cell.textField?.stringValue = item.typeDescription
        case "size":
            cell.textField?.stringValue = item.isDirectory ? "" : formatFileSize(item.size)
            cell.textField?.alignment = .right
        default: break
        }
    }
}

// MARK: - 컬럼 식별자 ↔ 정렬 키

extension SortKey {
    static func forColumnID(_ id: String) -> SortKey? {
        switch id {
        case "name":         return .name
        case "dateModified": return .dateModified
        case "dateCreated":  return .dateCreated
        case "type":         return .type
        case "size":         return .size
        default:             return nil
        }
    }
}

// MARK: - WinTableView (키보드 이벤트 라우팅)

final class WinTableView: NSTableView {
    /// keyDown 이벤트를 coordinator에 위임 — true를 반환하면 처리 완료로 간주
    var keyActionHandler: ((NSEvent) -> Bool)?
    /// 드롭 대상 강조를 지워야 할 때 호출된다
    var onDragFeedbackShouldClear: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if keyActionHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragFeedbackShouldClear?()
    }

    /// 드롭 없이 끝난 드래그(취소 등)는 draggingExited가 오지 않을 수 있다.
    ///
    /// super를 부르면 안 된다 — draggingEnded:는 NSView·NSTableView 어디에도 구현이 없는
    /// 선택 메서드라 상위로 보내면 unrecognized selector 예외가 난다. AppKit이 그 예외를
    /// 삼켜 앱은 살아남지만 드래그 관리자가 망가진 채 남아, 그 뒤로 SwiftUI 쪽
    /// .onDrag/.draggable(아이콘·목록·갤러리 보기)이 아예 시작되지 않는다
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragFeedbackShouldClear?()
    }

    /// 마지막 행 아래 빈 영역 — Finder는 여기에도 같은 리듬으로 둥근 띠를 잇는다.
    /// 기본 구현은 사각형으로 그리므로 통째로 대체한다 (행 위쪽은 각 행 뷰가 그린다)
    override func drawBackground(inClipRect clipRect: NSRect) {
        backgroundColor.setFill()
        clipRect.fill()

        let step = rowHeight + intercellSpacing.height
        guard usesAlternatingRowBackgroundColors, step > 0,
              let stripe = NSColor.alternatingContentBackgroundColors.last else { return }

        stripe.setFill()
        var index = numberOfRows
        var y = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0
        while y < clipRect.maxY {
            // 행 0이 바탕색, 행 1이 줄무늬 — 빈 영역도 그 교대를 이어 간다
            if index % 2 == 1, y + step > clipRect.minY {
                rowBandPath(in: NSRect(x: 0, y: y, width: bounds.width, height: step)).fill()
            }
            y += step
            index += 1
        }
    }
}

// MARK: - WinDropBorderView

/// 목록 빈 곳에 드롭할 때 "현재 폴더가 대상"임을 알리는 테두리
final class WinDropBorderView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 마우스·드래그 이벤트를 가로채면 아래 테이블의 드롭 추적이 끊긴다
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: FluentMetrics.cornerRadiusControl,
                                yRadius: FluentMetrics.cornerRadiusControl)
        FluentColors.dropTargetStroke.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

// MARK: - WinTableCellView

final class WinTableCellView: NSTableCellView {
    /// 이름 변경 커밋 핸들러 — coordinator가 연결
    var onRenameCommit: ((String) -> Void)?
    /// 이름 변경 취소 핸들러 — coordinator가 연결
    var onRenameCancel: (() -> Void)?
    /// 이름 변경을 시작할 때의 이름 — 취소하면 보이는 글자를 이걸로 되돌린다
    private var originalName: String = ""
    /// 인라인 이름 변경 진행 중 여부 — configure()가 편집 중인 텍스트를 덮어쓰지 않도록 보호
    private(set) var isRenaming: Bool = false

    private var textLeading: NSLayoutConstraint!

    /// 이름 열만 아이콘을 보여 준다. 나머지 열은 아이콘 자리를 비워 두지 않아야
    /// 열 머리글과 값의 왼쪽이 맞는다
    func applyColumnLayout(showsIcon: Bool) {
        imageView?.isHidden = !showsIcon
        let inset = showsIcon ? FluentMetrics.listNameTextInset
                              : FluentMetrics.listColumnTextInset
        if textLeading.constant != inset { textLeading.constant = inset }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 재사용 전에 이름 변경 상태 정리 (커밋하지 않고 취소)
        if isRenaming { endRenaming(commit: false) }
        onRenameCommit = nil
        onRenameCancel = nil
    }

    /// 액센트 색으로 채워진 행 위에서는 글자를 흰색으로 — Finder와 같은 동작.
    /// configure()에서 textColor를 직접 지정하지 않아야 이 규칙이 유지된다
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized
                ? FluentColors.selectionText : FluentColors.textPrimary
        }
    }

    private func setup() {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iv)
        imageView = iv

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = NSFont.systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingTail
        tf.drawsBackground = false
        tf.isBordered = false
        tf.isEditable = false
        tf.isSelectable = false
        addSubview(tf)
        textField = tf

        // 글자는 아이콘에 매달지 않고 셀 앞쪽에서 직접 잡는다 —
        // 아이콘 없는 열에서 빈 아이콘 자리만큼 밀리지 않도록
        textLeading = tf.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                  constant: FluentMetrics.listNameTextInset)

        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor,
                                        constant: FluentMetrics.listNameLeadingInset),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: FluentMetrics.listIconSize),
            iv.heightAnchor.constraint(equalToConstant: FluentMetrics.listIconSize),
            textLeading,
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FluentMetrics.paddingS),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// 인라인 이름 변경 시작 — textField를 편집 가능으로 전환하고 포커스 이동
    func startRenaming(currentName: String) {
        guard let tf = textField else { return }
        isRenaming = true
        originalName = currentName
        tf.stringValue = currentName
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBordered = true
        tf.backgroundColor = NSColor.textBackgroundColor
        tf.focusRingType = .exterior
        tf.delegate = self
        // selectText(_:)를 부르면 안 된다 — 내부에서 window.endEditingFor:로 필드 편집기를
        // 한 번 걷어내는데, 그 과정이 controlTextDidEndEditing을 부른다. 우리 구현은 그걸
        // "사용자가 편집을 끝냈다"로 보고 방금 켠 편집 모드를 도로 꺼 버렸다.
        // (그래서 이름 바꾸기·새 폴더에서 편집 칸이 뜨자마자 사라졌다)
        // makeFirstResponder만으로 편집기가 붙고 글자도 전체 선택된다.
        tf.window?.makeFirstResponder(tf)
    }

    fileprivate func endRenaming(commit: Bool) {
        guard isRenaming, let tf = textField else { return }
        isRenaming = false
        let newName = tf.stringValue.trimmingCharacters(in: .whitespaces)
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBordered = false
        tf.backgroundColor = .clear
        tf.focusRingType = .none
        tf.delegate = nil
        // Esc로 끝내면 필드 편집기가 첫 응답자로 남아 키 입력(화살표·⌘Z)을 계속 가져간다 —
        // 목록에 돌려준다. delegate를 먼저 끊었으므로 이 과정의 편집 종료 알림은 다시 오지 않는다
        if let window = tf.window, let editor = tf.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(enclosingScrollView?.documentView)
        }
        if commit, !newName.isEmpty, newName != originalName {
            onRenameCommit?(newName)
        } else {
            // 취소·빈 이름·그대로 — 보이던 글자를 되돌리고 뷰모델의 진행 상태도 푼다.
            // 풀지 않으면 renamingItemID가 남아 같은 항목을 다시 이름 변경할 수 없다
            tf.stringValue = originalName
            onRenameCancel?()
        }
    }
}

extension WinTableCellView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        // returnKeyType은 구분하지 않음 — 모든 종료는 커밋으로 처리
        endRenaming(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endRenaming(commit: false)
            return true
        }
        return false
    }
}

// MARK: - 행 띠 모양

/// Finder 목록의 행 배경 모양 — 좌우를 들이고 모서리를 둥글린 띠.
/// 줄무늬·선택·hover·드롭 대상이 모두 같은 모양을 쓴다.
private func rowBandPath(in rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect.insetBy(dx: FluentMetrics.listRowBandInset, dy: 0),
                 xRadius: FluentMetrics.listRowBandRadius,
                 yRadius: FluentMetrics.listRowBandRadius)
}

// MARK: - WinTableRowView

final class WinTableRowView: NSTableRowView {
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?
    /// 드래그가 이 폴더 행 위에 올라와 있고 드롭이 허용된 상태
    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTrackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovering = false
        isDropTarget = false
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true;  needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { isHovering = false; needsDisplay = true }

    override func drawBackground(in dirtyRect: NSRect) {
        // 한 줄 걸러 깔리는 줄무늬 색은 NSTableView가 행마다 backgroundColor로 넣어 준다.
        // super는 그걸 행 전체 사각형으로 칠하므로, 대신 둥근 띠로 직접 그린다
        backgroundColor.setFill()
        rowBandPath(in: bounds).fill()

        // 드롭 대상 표시가 hover·선택보다 우선한다
        if isDropTarget {
            let path = rowBandPath(in: bounds)
            FluentColors.dropTargetFill.setFill()
            path.fill()
            FluentColors.dropTargetStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
            return
        }
        if isHovering && !isSelected {
            FluentColors.hoverFill.setFill()
            rowBandPath(in: bounds).fill()
        }
    }

    /// Finder 목록 보기 — 좌우를 들인 둥근 띠. 포커스가 없으면 회색으로 흐려진다.
    /// 위아래로 이어진 선택은 바깥쪽 모서리만 둥글려 한 덩어리로 보이게 한다
    override func drawSelection(in dirtyRect: NSRect) {
        let radius = FluentMetrics.listRowBandRadius
        let topExtend    = isPreviousRowSelected ? radius : 0
        let bottomExtend = isNextRowSelected     ? radius : 0

        // 맞닿은 쪽으로 띠를 늘려 그 모서리를 행 밖으로 밀어낸 뒤, 이 행 범위로 잘라 낸다
        var rect = bounds
        rect.origin.y -= isFlipped ? topExtend : bottomExtend
        rect.size.height += topExtend + bottomExtend

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        (isEmphasized ? FluentColors.selectionFill
                      : FluentColors.selectionFillInactive).setFill()
        rowBandPath(in: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - WinTableHeaderCell

/// 글자만 그리는 머리글 셀 — 바탕과 열 경계선은 WinTableHeaderView가 맡는다.
/// 기본 셀이 칠하는 밝은 바탕이 도구 막대와 어긋나 보이는 것을 막는다
final class WinTableHeaderCell: NSTableHeaderCell {
    /// 글자가 시작하는 위치 — 같은 열 값의 왼쪽과 맞춘다 (Finder도 머리글과 값을 맞춘다)
    var leadingInset: CGFloat = FluentMetrics.listColumnTextInset

    /// drawInterior는 자체 여백을 더하고 글자를 위쪽에 붙여 그려 위치를 정확히 잡을 수 없다 —
    /// 잘림 처리만 문단 스타일로 넘기고 직접 그린다
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: FluentColors.textPrimary,
            .paragraphStyle: paragraph,
        ]
        let title = stringValue as NSString
        let textHeight = title.size(withAttributes: attributes).height
        // 오른쪽 끝에는 정렬 갈매기표가 그려지므로 그만큼 비워 둔다
        let width = cellFrame.width - leadingInset - FluentMetrics.paddingL
        guard width > 0 else { return }

        title.draw(in: NSRect(x: cellFrame.minX + leadingInset,
                              y: cellFrame.midY - textHeight / 2,
                              width: width, height: textHeight),
                   withAttributes: attributes)
    }
}

// MARK: - WinTableHeaderView

final class WinTableHeaderView: NSTableHeaderView {
    /// 경계선 더블클릭 — 엑셀처럼 내용에 맞춰 폭을 맞춘다
    var onAutoFit: ((Int) -> Void)?

    /// 정렬 방향 — 표시할 열은 tableView.highlightedTableColumn으로 정한다
    var sortAscending: Bool = true

    /// 경계선 판정 여유 (pt)
    private let dividerSlop: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2,
           let column = columnForDivider(at: convert(event.locationInWindow, from: nil)) {
            onAutoFit?(column)
            return
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit 기본 머리글은 한 단계 밝게 칠해져 도구 막대와 어긋난다.
        // super는 자기 바탕을 먼저 칠해 우리 색을 덮으므로 부르지 않고 셀까지 직접 그린다
        FluentColors.windowBackground.setFill()
        dirtyRect.fill()

        if let tv = tableView {
            for index in 0..<tv.numberOfColumns {
                let rect = headerRect(ofColumn: index)
                guard rect.intersects(dirtyRect) else { continue }
                tv.tableColumns[index].headerCell.draw(withFrame: rect, in: self)
            }
        }
        drawColumnSeparators()
        drawSortIndicator()
    }

    /// 기본 셀 바탕을 없앤 대신 열 경계선을 직접 그린다
    private func drawColumnSeparators() {
        guard let tv = tableView, tv.numberOfColumns > 1 else { return }
        FluentColors.divider.setFill()
        // 마지막 열 오른쪽에는 그리지 않는다 — Finder도 열 사이에만 둔다
        for index in 0..<(tv.numberOfColumns - 1) {
            let edge = headerRect(ofColumn: index).maxX
            NSRect(x: edge - 1, y: FluentMetrics.paddingXS,
                   width: 1, height: bounds.height - FluentMetrics.paddingS).fill()
        }
    }

    /// Finder처럼 정렬 중인 열 오른쪽 끝에 작은 갈매기표를 그린다
    private func drawSortIndicator() {
        guard let tv = tableView, let sorted = tv.highlightedTableColumn else { return }
        let colIdx = tv.column(withIdentifier: sorted.identifier)
        guard colIdx >= 0 else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [FluentColors.textSecondary]))
        guard let chevron = NSImage(systemSymbolName: sortAscending ? "chevron.up" : "chevron.down",
                                    accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        let rect = headerRect(ofColumn: colIdx)
        let size = chevron.size
        chevron.draw(in: NSRect(x: rect.maxX - size.width - FluentMetrics.paddingS,
                                y: (rect.height - size.height) / 2,
                                width: size.width, height: size.height))
    }

    /// 주어진 지점이 어떤 컬럼의 오른쪽 경계선 위인지 — 엑셀과 같이 왼쪽 컬럼을 맞춘다
    private func columnForDivider(at point: NSPoint) -> Int? {
        guard let tableView else { return nil }
        for index in 0..<tableView.numberOfColumns {
            let edge = headerRect(ofColumn: index).maxX
            if abs(point.x - edge) <= dividerSlop { return index }
        }
        return nil
    }

}

// MARK: - NSViewRepresentable Coordinator 연결

extension DetailsView {
    typealias Coordinator = DetailsViewCoordinator
}

