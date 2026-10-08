import Foundation
import Observation

/// 파일 작업 취소 스택 (최대 10개 항목)
/// 각 Operation은 취소 클로저를 캡처하여 역방향으로 재생한다.
@Observable
@MainActor
final class UndoService {
    static let shared = UndoService()

    struct Operation {
        let description: String
        /// 되돌리면 내용이 바뀌는 폴더 — 되돌리기는 FileManager를 직접 쓰므로
        /// 열려 있는 목록·탐색 창 트리에 따로 알려야 한다
        var affectedDirectories: [URL] = []
        let undo: () async throws -> Void
    }

    private var stack: [Operation] = []
    private let maxCount = 10

    var canUndo: Bool { !stack.isEmpty }

    var undoMenuTitle: String {
        guard let op = stack.last else { return "취소" }
        return "\(op.description) 취소"
    }

    func push(_ op: Operation) {
        stack.append(op)
        if stack.count > maxCount { stack.removeFirst() }
    }

    func performUndo() async {
        guard let op = stack.popLast() else { return }
        try? await op.undo()
        FileOperationService.shared.announceChange(to: op.affectedDirectories)
    }

    func clearAll() { stack.removeAll() }
}
