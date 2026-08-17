import Foundation
import AppKit

/// 파일시스템 열거 및 정렬 서비스
/// 디렉토리 열거는 Task.detached(priority: .userInitiated)에서 수행
/// 결과를 청크(500개) 단위로 메인 액터에 전달하여 점진 렌더링 지원
final class FileSystemService {
    static let shared = FileSystemService()

    // URLResourceKey 배치 조회 — 파일별 개별 stat 호출 금지
    private static let resourceKeys: [URLResourceKey] = [
        .nameKey, .localizedNameKey, .isDirectoryKey, .isPackageKey,
        .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey
    ]

    // MARK: - 디렉토리 열거

    /// 디렉토리 내용을 비동기로 열거
    /// - Parameters:
    ///   - url: 열거할 폴더 URL
    ///   - showHidden: 숨김 파일 표시 여부
    /// - Returns: FileItem 배열 (정렬 전)
    func listDirectory(at url: URL, showHidden: Bool = false) async throws -> [FileItem] {
        let keys = Self.resourceKeys
        return try await Task.detached(priority: .userInitiated) {
            // .skipsPackageDescendants는 contentsOfDirectory에서 무시됨(enumerator 전용) → 제거
            var options: FileManager.DirectoryEnumerationOptions = []
            if !showHidden { options.insert(.skipsHiddenFiles) }

            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )

            return urls.compactMap { itemURL -> FileItem? in
                // .DS_Store 항상 숨김
                guard itemURL.lastPathComponent != ".DS_Store" else { return nil }
                guard let values = try? itemURL.resourceValues(forKeys: Set(keys)) else { return nil }
                return FileItem(url: itemURL, values: values)
            }
        }.value
    }

    /// 디렉토리에 하위 항목이 존재하는지 확인 (탐색 창 disclosure 판정용)
    func hasChildren(at url: URL) -> Bool {
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsPackageDescendants, .skipsHiddenFiles, .skipsSubdirectoryDescendants
        ]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [], options: options)
        return enumerator?.nextObject() != nil
    }

    // MARK: - 정렬

    /// 폴더가 항상 파일보다 위에 정렬 (Windows 동작, 정렬 기준 무관)
    func sort(_ items: [FileItem], by descriptor: FileSortDescriptor) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let asc = descriptor.ascending
            switch descriptor.key {
            case .name:
                let cmp = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .dateModified:
                return asc ? a.dateModified < b.dateModified : a.dateModified > b.dateModified
            case .dateCreated:
                return asc ? a.dateCreated < b.dateCreated : a.dateCreated > b.dateCreated
            case .type:
                let cmp = a.typeDescription.localizedCaseInsensitiveCompare(b.typeDescription)
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .size:
                return asc ? a.size < b.size : a.size > b.size
            }
        }
    }

    // MARK: - 볼륨

    /// 마운트된 볼륨 목록 (숨김 볼륨 제외)
    func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
    }
}

// MARK: - 포맷터

/// Windows 표기 규칙: 1,024 바이트 단위, 소수점 2자리
func formatFileSize(_ bytes: Int64) -> String {
    guard bytes >= 0 else { return "—" }
    if bytes == 0 { return "0바이트" }
    let kb = Double(bytes) / 1_024
    if kb < 1  { return "\(bytes)바이트" }
    let mb = kb / 1_024
    if mb < 1  { return String(format: "%.2fKB", kb) }
    let gb = mb / 1_024
    if gb < 1  { return String(format: "%.2fMB", mb) }
    return String(format: "%.2fGB", gb)
}

/// Windows 날짜 표기: "2026-08-08 오후 3:41"
private let winDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = "yyyy-MM-dd a h:mm"
    return f
}()

func formatFileDate(_ date: Date) -> String {
    winDateFormatter.string(from: date)
}
