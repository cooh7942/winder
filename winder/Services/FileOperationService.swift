import Foundation
import AppKit

// MARK: - OperationProgress

/// 복사/이동 작업 진행 상태 — 100개 이상 항목 복사 시 진행 다이얼로그에 표시
struct OperationProgress: Sendable {
    let current: Int
    let total: Int
    let fileName: String

    var fraction: Double { total > 0 ? Double(current) / Double(total) : 0 }
    var isComplete: Bool { current >= total }
}

/// 파일 I/O 래퍼 — FileManager를 Task.detached에서 실행하여 메인 스레드 블로킹 방지
@MainActor
final class FileOperationService {
    static let shared = FileOperationService()

    // MARK: - 이름 바꾸기

    /// 파일/폴더 이름 변경
    /// - Returns: 변경 후 URL
    func rename(item: FileItem, to newName: String) async throws -> URL {
        let dst = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        let src = item.url
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(at: src, to: dst)
        }.value
        return dst
    }

    // MARK: - 삭제 (휴지통)

    /// 항목들을 휴지통으로 이동
    /// - Returns: 휴지통 내 실제 URL 배열 (되돌리기 복원에 사용)
    @discardableResult
    func trash(items: [FileItem]) async throws -> [URL] {
        let urls = items.map(\.url)
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
        return target
    }

    func createTextFile(in directory: URL, named baseName: String = "새 텍스트 문서.txt") async throws -> URL {
        let target = Self.uniqueURL(in: directory, name: baseName)
        try await Task.detached(priority: .userInitiated) {
            try "".write(to: target, atomically: true, encoding: .utf8)
        }.value
        return target
    }

    // MARK: - 복사

    /// 파일/폴더 복사
    /// - Parameters:
    ///   - progress: 각 파일 복사 완료 후 메인 액터에서 호출되는 진행률 핸들러 (100+ 항목 시 진행 다이얼로그용)
    /// - Returns: 실제로 생성된 URL 배열 — uniqueURL로 이름이 바뀔 수 있으므로 undo는 반드시 이 값을 사용
    @discardableResult
    func copyItems(
        _ urls: [URL],
        to destination: URL,
        progress progressHandler: (@MainActor (OperationProgress) -> Void)? = nil
    ) async throws -> [URL] {
        let dst = destination
        let total = urls.count
        var created: [URL] = []
        for (index, src) in urls.enumerated() {
            let srcName = src.lastPathComponent
            let target: URL = try await Task.detached(priority: .userInitiated) {
                let t = FileOperationService.uniqueURL(in: dst, name: srcName)
                try FileManager.default.copyItem(at: src, to: t)
                return t
            }.value
            created.append(target)
            progressHandler?(OperationProgress(current: index + 1, total: total, fileName: srcName))
        }
        return created
    }

    // MARK: - 이동 (잘라내기+붙여넣기)

    /// 파일/폴더 이동
    /// - Returns: (원본 URL, 이동 후 실제 URL) 쌍 배열 — undo는 반드시 이 값을 사용
    /// - 같은 위치로의 이동은 해당 항목을 건너뜀 (빈 배열 반환 시 undo 불필요)
    /// - 부분 실패 시 이미 이동된 항목을 역순 롤백
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

        return try await Task.detached(priority: .userInitiated) {
            var moved: [(from: URL, to: URL)] = []
            for src in toMove {
                let target = FileOperationService.uniqueURL(in: dst, name: src.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: src, to: target)
                    moved.append((from: src, to: target))
                } catch {
                    // 부분 이동 롤백 — 이미 이동된 항목을 역순으로 원위치
                    for pair in moved.reversed() {
                        try? FileManager.default.moveItem(at: pair.to, to: pair.from)
                    }
                    throw error
                }
            }
            return moved
        }.value
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
