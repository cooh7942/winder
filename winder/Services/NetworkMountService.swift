import Foundation
import NetFS

/// 네트워크 공유 마운트 — Keychain에 저장된 자격 증명이나 게스트 접근으로 조용히 붙인다.
///
/// 트리에서 서버를 누르면 다른 폴더처럼 바로 펼쳐지도록 하기 위한 것이다.
/// SMB는 마운트하지 않으면 내용을 읽을 수 없어서, 클릭 시점에 마운트를 시도한다.
/// 자격 증명이 없어 UI가 필요한 경우에는 실패로 처리하고 호출부가 시스템 대화상자로 넘긴다.
enum NetworkMountService {
    /// NetFS.h의 상수들은 CFSTR 매크로라 Swift로 넘어오지 않아 문자열을 직접 쓴다
    private enum Key {
        static let uiOption      = "UIOption"        // kNAUIOptionKey
        static let noUI          = "NoUI"            // kNAUIOptionNoUI
        static let allowSubMounts = "AllowSubMounts" // kNetFSAllowSubMountsKey
        static let softMount      = "SoftMount"      // kNetFSSoftMountKey
    }

    /// 마운트 시도. 성공하면 마운트된 경로들, 실패하면 nil.
    /// - Note: NetFSMountURLSync는 동기 호출이라 응답 없는 서버에서 오래 걸릴 수 있어
    ///         백그라운드 큐에서 실행한다.
    static func mount(_ url: URL) async -> [URL]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var mountpoints: Unmanaged<CFArray>?

                // UI 없이 — 자격 증명이 없으면 조용히 실패시킨다
                let openOptions: NSMutableDictionary = [Key.uiOption: Key.noUI]
                // 서버 주소만 준 경우 하위 공유까지 붙이도록 허용, 응답 없으면 포기(soft)
                let mountOptions: NSMutableDictionary = [
                    Key.allowSubMounts: true,
                    Key.softMount: true,
                ]

                let status = NetFSMountURLSync(url as CFURL, nil, nil, nil,
                                               openOptions as CFMutableDictionary,
                                               mountOptions as CFMutableDictionary,
                                               &mountpoints)

                let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []
                guard status == 0, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: paths.map { URL(fileURLWithPath: $0) })
            }
        }
    }
}
