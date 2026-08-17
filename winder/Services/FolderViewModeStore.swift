import Foundation

/// 폴더별 보기 모드 기억 — 폴더 경로 → ViewMode
///
/// 이전에는 보기 모드가 앱 전체에 하나뿐이라 한 폴더에서 갤러리로 바꾸면 모든 폴더가 갤러리로 열렸다.
/// 저장된 기록이 없는 폴더는 항상 기본값(자세히)으로 연다.
@MainActor
final class FolderViewModeStore {
    static let shared = FolderViewModeStore()

    private let storageKey = "com.tjuxta.winder.folderViewModes"
    /// 폴더별 저장 이전에 쓰던 전역 보기 모드 키 — 남아 있으면 정리한다
    private let legacyKey  = "com.tjuxta.winder.viewMode"
    /// 기록 상한 — 넘으면 사라진 폴더의 기록부터 정리한다
    private let maxEntries = 500

    /// 경로 → ViewMode.rawValue
    private var modes: [String: String] = [:]

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] {
            modes = saved
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    /// 저장된 보기 모드 — 기록이 없으면 기본값(자세히)
    func mode(for url: URL?) -> ViewMode {
        guard let url,
              let raw = modes[Self.key(for: url)],
              let mode = ViewMode(rawValue: raw) else { return .details }
        return mode
    }

    /// 폴더의 보기 모드 저장.
    /// 기본값(자세히)이면 기록을 지운다 — "설정하지 않음"과 결과가 같으므로 저장소를 키울 이유가 없다.
    func setMode(_ mode: ViewMode, for url: URL?) {
        guard let url else { return }
        let key = Self.key(for: url)

        if mode == .details {
            guard modes.removeValue(forKey: key) != nil else { return }
        } else {
            guard modes[key] != mode.rawValue else { return }
            modes[key] = mode.rawValue
            if modes.count > maxEntries { pruneMissingFolders() }
        }
        UserDefaults.standard.set(modes, forKey: storageKey)
    }

    /// 더 이상 존재하지 않는 폴더의 기록 제거 — 상한을 넘었을 때만 수행
    private func pruneMissingFolders() {
        modes = modes.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
