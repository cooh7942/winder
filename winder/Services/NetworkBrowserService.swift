import Foundation
import Network
import Observation

/// 네트워크 공유 탐색 — Bonjour로 SMB 서버를 찾는다.
///
/// 탐색기의 "네트워크" 항목은 원래 아무것도 보여주지 않았다.
/// 마운트된 네트워크 볼륨은 파일 시스템에서 바로 알 수 있지만,
/// 아직 연결하지 않은 서버(예: Finder에 보이는 NAS)는 mDNS로 찾아야 한다.
@Observable
@MainActor
final class NetworkBrowserService {
    static let shared = NetworkBrowserService()

    struct Server: Identifiable, Hashable {
        /// Bonjour 서비스 이름 (예: "cooh")
        let name: String
        var id: String { name }
        /// 연결에 사용할 주소 — Finder의 "서버에 연결"과 같은 형식
        var url: URL? { URL(string: "smb://\(name)._smb._tcp.local") }
    }

    private(set) var servers: [Server] = []

    @ObservationIgnored private var browser: NWBrowser?

    private init() {}

    /// 탐색 시작 — 이미 돌고 있으면 아무것도 하지 않는다
    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return name
            }
            let unique = Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            Task { @MainActor [weak self] in
                self?.servers = unique.map { Server(name: $0) }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            // 실패하면 브라우저를 놓아 다음 새로 고침에서 다시 시도할 수 있게 한다
            if case .failed = state {
                Task { @MainActor [weak self] in self?.browser = nil }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// 다시 훑기 — 트리의 "새로 고침"에서 호출
    func refresh() {
        browser?.cancel()
        browser = nil
        servers = []
        start()
    }

    /// 현재 마운트된 네트워크 볼륨 (로컬 디스크가 아닌 것)
    static func mountedNetworkVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
        }
    }
}
