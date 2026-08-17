import Foundation

/// 즐겨찾기 항목 — URL 북마크 기반으로 폴더 이동·이름 변경 후에도 안정적으로 해석
struct FavoriteItem: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var bookmarkData: Data
    /// N-5: 북마크 해석 실패 시에도 경로 기반 중복 검사를 위한 마지막 알려진 경로
    var lastKnownPath: String

    init(id: UUID = UUID(), name: String, bookmarkData: Data, lastKnownPath: String = "") {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
    }

    /// 기존 JSON(lastKnownPath 없음) 하위 호환 디코딩
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,   forKey: .id)
        name          = try c.decode(String.self, forKey: .name)
        bookmarkData  = try c.decode(Data.self,   forKey: .bookmarkData)
        lastKnownPath = try c.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bookmarkData, lastKnownPath
    }

    /// 외부에서 URL만 필요할 때 사용 (캐시 미사용)
    func resolvedURL() -> URL? {
        var isStale = false
        // ①: 네트워크 볼륨 마운트 UI·블로킹 방지
        return try? URL(resolvingBookmarkData: bookmarkData,
                       options: [.withoutUI, .withoutMounting],
                       relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    /// FavoritesStore 캐시 재구성 시 stale 여부도 함께 반환 (B-9 북마크 갱신에 사용)
    func resolveAndCheckStale() -> (url: URL?, isStale: Bool) {
        var isStale = false
        // ①: 네트워크 볼륨 마운트 UI·블로킹 방지
        let url = try? URL(resolvingBookmarkData: bookmarkData,
                          options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// P2-4: 북마크 생성 옵션 상수 — 샌드박스 활성화 시 .withSecurityScope 추가 필요
    static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []

    /// URL로 새 FavoriteItem 생성 — 북마크 데이터를 즉시 캡처
    static func make(url: URL, customName: String? = nil) throws -> FavoriteItem {
        let data = try url.bookmarkData(options: Self.bookmarkCreationOptions,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        let name = customName ?? FileManager.default.displayName(atPath: url.path)
        return FavoriteItem(id: UUID(), name: name, bookmarkData: data,
                            lastKnownPath: url.standardizedFileURL.path)
    }
}
