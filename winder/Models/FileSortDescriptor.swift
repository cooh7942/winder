import Foundation

/// 파일 목록 정렬 기준
enum SortKey: String, CaseIterable, Identifiable {
    case name         = "이름"
    case dateModified = "수정일"
    case dateCreated  = "만든 날짜"
    case type         = "종류"
    case size         = "크기"

    var id: String { rawValue }
}

/// 정렬 기준 + 방향
struct FileSortDescriptor: Equatable {
    var key: SortKey  = .name
    var ascending: Bool = true
}
