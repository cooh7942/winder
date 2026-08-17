import AppKit

/// NSWorkspace 아이콘 캐시 — 크기별 복사본, 500 MB 총비용 제한
/// 아이콘 크기가 보기 모드마다 다르므로 캐시 키에 크기를 포함해야 한다.
/// NSWorkspace.icon(forFile:)은 공유 NSImage를 반환하므로
/// size를 직접 변경하면 같은 아이콘을 공유하는 모든 곳이 깨진다 → 반드시 copy() 후 변경.
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    /// "path@16" → NSImage (크기별 독립 복사본)
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        // 개수가 아닌 픽셀 바이트 비용 기반 제한 (500 MB)
        cache.totalCostLimit = 500 * 1024 * 1024
    }

    // MARK: - 단건 조회

    /// 파일 아이콘 반환 — 캐시 미스 시 NSWorkspace에서 로딩 후 복사본 저장
    /// - Parameters:
    ///   - url: 아이콘을 조회할 파일 URL
    ///   - size: 렌더링 크기(pt) — 기본 16 (자세히 보기)
    func icon(for url: URL, size: CGFloat = 16) -> NSImage {
        let key = "\(url.path)@\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // ⚠️ NSWorkspace는 내부 캐시의 공유 인스턴스를 반환하므로 copy 필수
        let shared = NSWorkspace.shared.icon(forFile: url.path)
        let copy   = shared.copy() as! NSImage
        copy.size  = NSSize(width: size, height: size)

        // 비용 = 픽셀 수 × 4바이트(RGBA)
        let scale  = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int(size * scale)
        let cost   = pixels * pixels * 4
        cache.setObject(copy, forKey: key, cost: cost)
        return copy
    }

    // MARK: - 배치 로딩 (스크롤 뷰 표시 시점)

    /// 주어진 FileItem 목록의 아이콘을 배치로 로딩한다.
    /// 이미 icon이 할당된 항목은 건너뛴다.
    /// NSWorkspace.icon은 디스크 I/O를 포함하므로 Task.detached에서 실행
    func loadIcons(for items: [FileItem], size: CGFloat = 16) async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int(size * scale)
        let cost = pixels * pixels * 4

        for item in items {
            guard item.icon == nil else { continue }
            let url = item.url
            let key = "\(url.path)@\(Int(size))" as NSString

            // 캐시 히트: 즉시 설정 (메인 스레드에서 안전)
            if let cached = cache.object(forKey: key) {
                item.icon = cached
                continue
            }

            // 캐시 미스: NSWorkspace 디스크 I/O를 백그라운드로 오프로딩
            let loaded = await Task.detached(priority: .utility) {
                let shared = NSWorkspace.shared.icon(forFile: url.path)
                let copy = shared.copy() as! NSImage
                copy.size = NSSize(width: size, height: size)
                return copy
            }.value

            // 메인 액터로 돌아와서 캐시 저장 및 아이콘 할당
            cache.setObject(loaded, forKey: key, cost: cost)
            item.icon = loaded
        }
    }

    /// 단건 즉시 로딩 — TabViewModel.loadVisibleIcons() 호출용
    func loadIcon(for item: FileItem, size: CGFloat = 16) {
        guard item.icon == nil else { return }
        item.icon = icon(for: item.url, size: size)
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}
