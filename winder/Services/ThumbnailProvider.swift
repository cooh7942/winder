import AppKit
import QuickLookThumbnailing

/// QuickLook 썸네일 캐시 — 갤러리 보기에서 사진·동영상의 실제 미리보기를 제공한다.
/// IconProvider(NSWorkspace 파일 타입 아이콘)와 목적이 다르므로 별도 캐시를 쓴다.
///
/// 썸네일 생성은 QuickLook 데몬(별도 프로세스)에서 이뤄지므로 메인 액터를 막지 않는다.
@MainActor
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    /// "path@160" → NSImage
    private let cache = NSCache<NSString, NSImage>()
    /// 같은 파일에 대한 중복 생성 요청 병합 — 스크롤로 셀이 재생성돼도 한 번만 만든다
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    /// 지정 URL의 썸네일 반환 — 생성 실패 시 nil(호출부에서 대체 아이콘 표시)
    /// - Parameters:
    ///   - url: 썸네일을 만들 파일 URL
    ///   - size: 타일 한 변 크기(pt)
    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = "\(url.path)@\(Int(size))"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let task = Task { () -> NSImage? in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: scale,
                // .all — 썸네일을 못 만드는 파일은 QuickLook이 아이콘 표현으로 대체해준다
                representationTypes: .all
            )
            guard let rep = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request) else { return nil }
            let cg = rep.cgImage
            // 픽셀 크기를 backing scale로 나눠 포인트 크기로 환산 — 레티나에서 2배로 커지는 것 방지
            return NSImage(cgImage: cg,
                           size: NSSize(width: CGFloat(cg.width) / scale,
                                        height: CGFloat(cg.height) / scale))
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            let pixels = Int(size * scale)
            cache.setObject(image, forKey: key as NSString, cost: pixels * pixels * 4)
        }
        return image
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}
