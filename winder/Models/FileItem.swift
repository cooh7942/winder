import Foundation
import AppKit
import Observation

/// 파일/폴더 도메인 모델
/// URLResourceKey 배치 조회로 생성 — 파일별 개별 stat 호출 금지
///
/// nonisolated: 프로젝트 기본 격리가 MainActor이지만, 이 모델은 FileSystemService가
/// 백그라운드에서 대량 생성해 메인 액터로 넘기는 것이 전제다(아래 @unchecked Sendable).
/// 메인 액터로 격리하면 생성 자체를 메인 스레드에서 해야 해 대용량 폴더 열거가 UI를 막는다.
@Observable
nonisolated final class FileItem: Identifiable {
    /// ⚠️ UUID()를 쓰면 안 됨. 목록을 새로 고칠 때마다 id가 바뀌어
    /// 선택 상태가 전부 날아가고 diff 비교도 항상 "변경됨"이 된다.
    /// 경로는 같은 폴더 안에서 유일하므로 안정적인 식별자로 적합하다.
    let id: String
    let url: URL
    var name: String
    var displayName: String
    var isDirectory: Bool
    var isPackage: Bool      // .app, .bundle 등 패키지
    var isSymlink: Bool
    var isHidden: Bool
    var size: Int64          // 폴더는 -1 (미계산), 파일은 바이트
    var dateModified: Date
    var dateCreated: Date
    var typeDescription: String  // "파일 폴더", "Markdown 문서" 등
    var icon: NSImage? = nil     // 지연 로딩 (IconProvider)
    var isCutPending: Bool = false  // 잘라내기 대기 상태 → 50% 불투명도로 표시

    init(url: URL, values: URLResourceValues) {
        self.id = url.path
        self.url = url
        self.name = values.name ?? url.lastPathComponent
        self.displayName = values.localizedName ?? values.name ?? url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
        self.isPackage = values.isPackage ?? false
        self.isSymlink = values.isSymbolicLink ?? false
        // 점 접두사 또는 시스템 hidden 플래그 둘 다 확인
        self.isHidden = url.lastPathComponent.hasPrefix(".") || (values.isHidden ?? false)
        self.dateModified = values.contentModificationDate ?? Date()
        self.dateCreated = values.creationDate ?? Date()
        if values.isDirectory ?? false {
            self.typeDescription = "파일 폴더"
            self.size = -1
        } else {
            self.typeDescription = values.localizedTypeDescription ?? "파일"
            self.size = Int64(values.fileSize ?? 0)
        }
    }
}

extension FileItem: Hashable {
    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// 백그라운드 Task에서 생성 후 메인 액터로 전달하기 위한 Sendable 선언
extension FileItem: @unchecked Sendable {}
