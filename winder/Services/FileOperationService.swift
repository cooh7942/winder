import Foundation
import AppKit

extension Notification.Name {
    /// Winder가 스스로 폴더 내용을 바꿨다 —
    /// userInfo[FileOperationService.changedDirectoriesKey]에 바뀐 폴더 URL이 Set<URL>로 들어 있다
    static let winderDirectoriesDidChange = Notification.Name("com.tjuxta.winder.directoriesDidChange")
}

/// 파일 I/O 래퍼 — FileManager를 Task.detached에서 실행하여 메인 스레드 블로킹 방지
@MainActor
final class FileOperationService {
    static let shared = FileOperationService()

    /// winderDirectoriesDidChange의 userInfo 키
    /// (알림은 어느 격리 문맥에서든 읽으므로 nonisolated)
    nonisolated static let changedDirectoriesKey = "directories"

    // MARK: - 이름 바꾸기

    /// 파일/폴더 이름 변경
    /// - Returns: 변경 후 URL
    func rename(item: FileItem, to newName: String) async throws -> URL {
        try await rename(at: item.url, to: newName)
    }

    /// URL로 이름 변경 — 탐색 창 트리처럼 FileItem이 없는 곳에서 쓴다
    /// - Returns: 변경 후 URL
    func rename(at src: URL, to newName: String) async throws -> URL {
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(at: src, to: dst)
        }.value
        announceChange(to: [src.deletingLastPathComponent()])
        return dst
    }

    /// 새 이름으로 쓸 수 없는 이유 — 쓸 수 있으면 nil.
    /// 같은 이름이 이미 있는지는 부르는 쪽이 판단한다 (목록에서 대소문자 무시 비교 등)
    nonisolated static func invalidNameReason(_ name: String) -> String? {
        if name.contains("/") || name.contains(":") {
            return "파일 이름에 '/' 또는 ':'를 사용할 수 없습니다."
        }
        // 255바이트 제한 (대부분 파일 시스템 공통 제한)
        if name.utf8.count > 255 {
            return "파일 이름이 너무 깁니다. (최대 255바이트)"
        }
        return nil
    }

    // MARK: - 삭제 (휴지통)

    /// 항목들을 휴지통으로 이동
    /// - Returns: 휴지통 내 실제 URL 배열 (되돌리기 복원에 사용)
    @discardableResult
    func trash(items: [FileItem]) async throws -> [URL] {
        let urls = items.map(\.url)
        defer { announceChange(to: urls.map { $0.deletingLastPathComponent() }) }
        return try await Task.detached(priority: .userInitiated) {
            var results: [URL] = []
            for url in urls {
                var trashURL: NSURL? = nil
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
                if let t = trashURL { results.append(t as URL) }
            }
            return results
        }.value
    }

    // MARK: - 만들기

    func createFolder(in directory: URL, named baseName: String = "새 폴더") async throws -> URL {
        let target = Self.uniqueURL(in: directory, name: baseName)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }.value
        announceChange(to: [directory])
        return target
    }

    func createTextFile(in directory: URL, named baseName: String = "새 텍스트 문서.txt") async throws -> URL {
        let target = Self.uniqueURL(in: directory, name: baseName)
        try await Task.detached(priority: .userInitiated) {
            try "".write(to: target, atomically: true, encoding: .utf8)
        }.value
        announceChange(to: [directory])
        return target
    }

    // MARK: - 복사

    /// 파일/폴더 복사 — 진행 상황은 FileTransferCenter에 올라가 창 아래 패널에 보인다
    /// - Returns: 실제로 생성된 URL 배열 — uniqueURL로 이름이 바뀔 수 있으므로 undo는 반드시 이 값을 사용.
    ///   사용자가 취소하면 그때까지 끝난 항목만 돌려준다 (만들다 만 항목은 지운다)
    @discardableResult
    func copyItems(_ urls: [URL], to destination: URL) async throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        let transfer = FileTransferCenter.shared.begin(.copy, items: urls, destination: destination)
        defer {
            FileTransferCenter.shared.end(transfer)
            announceChange(to: [destination])
        }
        let counter = transfer.counter
        let dst = destination
        return try await Task.detached(priority: .userInitiated) {
            var created: [URL] = []
            do {
                let sizes = try FileCopyEngine.sizes(of: urls, counter: counter)
                counter.setTotal(sizes.reduce(0, +))
                for (src, size) in zip(urls, sizes) {
                    if counter.isCancelled { throw FileCopyEngine.Cancelled() }
                    let target = FileOperationService.uniqueURL(in: dst, name: src.lastPathComponent)
                    try FileCopyEngine.copy(src, to: target, counter: counter)
                    counter.finishItem(size: size)
                    created.append(target)
                }
            } catch is FileCopyEngine.Cancelled {
                // 취소는 오류가 아니다 — 끝난 항목까지만 반영한다
            }
            return created
        }.value
    }

    // MARK: - 이동 (잘라내기+붙여넣기)

    /// 파일/폴더 이동
    /// - Returns: (원본 URL, 이동 후 실제 URL) 쌍 배열 — undo는 반드시 이 값을 사용
    /// - 같은 위치로의 이동은 해당 항목을 건너뜀 (빈 배열 반환 시 undo 불필요)
    /// - 같은 볼륨 안은 이름만 바꾸므로 즉시 끝난다. 다른 볼륨으로는 복사한 뒤 원본을 지우며,
    ///   이때 진행 상황이 창 아래 패널에 보인다
    /// - 오류가 나면 이미 이동된 항목을 역순 롤백, 사용자가 취소하면 끝난 항목은 그대로 둔다
    @discardableResult
    func moveItems(_ urls: [URL], to destination: URL) async throws -> [(from: URL, to: URL)] {
        let dst = destination.standardizedFileURL

        // 프리-플라이트 검사
        var toMove: [URL] = []
        for src in urls {
            let srcStd = src.standardizedFileURL
            // 부모 → 자식 폴더로의 이동 방지 (무한 재귀 가능성)
            if dst.path.hasPrefix(srcStd.path + "/") {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: "폴더를 자신의 하위 폴더로 이동할 수 없습니다."]
                )
            }
            // 이미 같은 위치에 있으면 건너뜀
            if srcStd.deletingLastPathComponent() == dst { continue }
            toMove.append(src)
        }
        guard !toMove.isEmpty else { return [] }

        let transfer = FileTransferCenter.shared.begin(.move, items: toMove, destination: dst)
        // 받는 폴더와 보낸 폴더가 모두 바뀐다 — 창을 나눠 쓸 때 양쪽 다 다시 읽혀야 한다
        defer {
            FileTransferCenter.shared.end(transfer)
            announceChange(to: [dst] + toMove.map { $0.deletingLastPathComponent() })
        }
        let counter = transfer.counter

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let crossVolume = toMove.map { !FileOperationService.isSameVolume($0, dst) }
            // 다른 볼륨으로 가는 것만 실제로 데이터를 옮긴다 — 진행률도 그 크기만 센다
            var sizes = Array(repeating: Int64(0), count: toMove.count)
            var moved: [(from: URL, to: URL)] = []
            do {
                let crossing = zip(toMove, crossVolume).filter(\.1).map(\.0)
                let crossingSizes = try FileCopyEngine.sizes(of: crossing, counter: counter)
                var next = crossingSizes.makeIterator()
                for i in toMove.indices where crossVolume[i] { sizes[i] = next.next() ?? 0 }
                counter.setTotal(crossingSizes.reduce(0, +))

                for (i, src) in toMove.enumerated() {
                    if counter.isCancelled { throw FileCopyEngine.Cancelled() }
                    let target = FileOperationService.uniqueURL(in: dst, name: src.lastPathComponent)
                    if crossVolume[i] {
                        try FileCopyEngine.copy(src, to: target, counter: counter)
                        try fm.removeItem(at: src)
                        counter.finishItem(size: sizes[i])
                    } else {
                        try fm.moveItem(at: src, to: target)
                    }
                    moved.append((from: src, to: target))
                }
            } catch is FileCopyEngine.Cancelled {
                // 취소는 오류가 아니다 — 끝난 항목은 옮겨진 채로 둔다
            } catch {
                // 부분 이동 롤백 — 이미 이동된 항목을 역순으로 원위치
                for pair in moved.reversed() {
                    try? fm.moveItem(at: pair.to, to: pair.from)
                }
                throw error
            }
            return moved
        }.value
    }

    /// 두 위치가 같은 볼륨인지 — 같으면 이동이 이름 바꾸기로 끝난다
    nonisolated private static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: key).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: key).volumeIdentifier as? NSObject
        else { return false }
        return va.isEqual(vb)
    }

    // MARK: - 변경 알림

    /// 내용이 바뀐 폴더를 열려 있는 창들에 알린다.
    ///
    /// FileWatcher는 kFSEventStreamCreateFlagIgnoreSelf로 Winder 자신이 만든 변경을 무시한다 —
    /// 그래서 알려 주지 않으면 다른 앱이 그 폴더를 건드릴 때까지 목록이 낡은 채로 남는다
    /// (파일을 끌어다 놓았는데 상대 창에 나타나지 않던 문제)
    /// 되돌리기처럼 이 서비스를 거치지 않고 FileManager를 직접 쓰는 곳도 이걸로 알린다
    func announceChange(to directories: [URL]) {
        let dirs = Set(directories.map(\.standardizedFileURL))
        guard !dirs.isEmpty else { return }
        NotificationCenter.default.post(
            name: .winderDirectoriesDidChange,
            object: nil,
            userInfo: [Self.changedDirectoriesKey: dirs]
        )
    }

    // MARK: - Private

    /// 충돌 방지: "이름 (2)", "이름 (3)"... 패턴으로 고유 URL 생성
    /// nonisolated: Task.detached 내부에서 호출하기 위해 MainActor 격리 없음
    nonisolated static func uniqueURL(in dir: URL, name: String) -> URL {
        var target = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return target }
        let base = (name as NSString).deletingPathExtension
        let ext  = (name as NSString).pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            target = dir.appendingPathComponent(candidate)
            n += 1
        } while FileManager.default.fileExists(atPath: target.path)
        return target
    }
}
