import Foundation
import Observation
import SwiftUI

// Finder 사이드바(NSKeyedArchiver .sfl3) 가져오기는 C 그룹에서 제거됨 —
// Apple 비공개 포맷 의존으로 OS 업데이트 시 깨질 위험이 있어 삭제하고
// 최초 실행 시 기본 즐겨찾기(바탕 화면·문서·다운로드)를 직접 시드합니다.

/// 즐겨찾기 저장소 — UserDefaults JSON 직렬화, 최초 실행 시 기본 항목 시드
@Observable
@MainActor
final class FavoritesStore {
    static let shared = FavoritesStore()

    private(set) var items: [FavoriteItem] = []

    // B-1: 북마크 해석 결과 캐시 — 뷰에서 매번 URL(resolvingBookmarkData:)를 호출하지 않도록
    private(set) var resolvedURLs: Set<URL> = []
    private(set) var resolvedByID: [UUID: URL] = [:]

    // P0: 뷰가 캐시 갱신을 관찰할 수 있도록 — rebuildCache() 완료 때마다 증가
    private(set) var cacheVersion: Int = 0

    // B-5: 중복 드롭 강조 (N-8: private(set) + pulse 메서드로만 변경)
    private(set) var highlightedID: UUID? = nil

    private let storageKey      = "com.tjuxta.winder.favorites"
    private let userModifiedKey = "com.tjuxta.winder.favoritesUserModified"

    private init() {
        load()
        // 북마크 해석은 메인 스레드 블로킹 없이 첫 프레임 이후로 미룸
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hadStale = self.rebuildCache()
            if hadStale { self.save(markModified: false) }
            // C-2: 저장된 즐겨찾기가 없는 최초 실행에만 기본 항목 시드
            self.seedDefaultsIfNeeded()
        }
    }

    // MARK: - 조회

    /// N-5: 해석 불가 항목도 lastKnownPath로 중복 검사
    func contains(url: URL) -> Bool {
        let std = url.standardizedFileURL
        return resolvedURLs.contains(std) ||
               items.contains { !$0.lastKnownPath.isEmpty && $0.lastKnownPath == std.path }
    }

    // MARK: - N-8: 중복 드롭 펄스

    func pulse(id: UUID) {
        Task { @MainActor in
            self.highlightedID = id
            try? await Task.sleep(for: .milliseconds(150))
            self.highlightedID = nil
        }
    }

    // MARK: - 추가 / 제거

    /// B-3: at 파라미터로 삽입 위치 지정 (nil 또는 범위 초과 시 맨 뒤)
    func add(url: URL, at index: Int? = nil) throws {
        guard !contains(url: url) else { return }
        let item = try FavoriteItem.make(url: url)
        if let index, index >= 0, index <= items.count {
            items.insert(item, at: index)
        } else {
            items.append(item)
        }
        rebuildCache()
        save(markModified: true)
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        rebuildCache()
        save(markModified: true)
    }

    func removeByURL(_ url: URL) {
        let std = url.standardizedFileURL
        items.removeAll { resolvedByID[$0.id] == std }
        rebuildCache()
        save(markModified: true)
    }

    // MARK: - 순서 변경 / 이름 바꾸기

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        rebuildCache()
        save(markModified: true)
    }

    func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].name = trimmed
        rebuildCache()
        save(markModified: true)
    }

    // MARK: - Private

    /// C-2: 저장된 즐겨찾기가 아예 없는 최초 실행에만 기본 항목(바탕 화면·문서·다운로드) 생성
    /// userModifiedKey가 설정된 경우(사용자가 전부 지운 뒤 재실행)에는 복원하지 않음
    private func seedDefaultsIfNeeded() {
        guard items.isEmpty,
              !UserDefaults.standard.bool(forKey: userModifiedKey) else { return }
        for folder in [KnownFolder.desktop, .documents, .downloads] {
            guard let item = try? FavoriteItem.make(url: folder.url) else { continue }
            items.append(item)
        }
        if !items.isEmpty {
            rebuildCache()
            // 기본값 생성은 사용자 수정으로 취급하지 않음 — userModifiedKey 설정 안 함
            save(markModified: false)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data) else { return }
        items = decoded
        // rebuildCache()는 init()의 Task에서 실행 — 메인 스레드 블로킹 방지
    }

    /// B-1 + B-9 + N-5: 캐시 재구성 — stale 북마크 갱신, lastKnownPath 백필
    /// N-7: save()는 호출하지 않음 — 호출자가 단 한 번만 저장하도록 Bool 반환
    @discardableResult
    private func rebuildCache() -> Bool {
        var urls = Set<URL>()
        var byID = [UUID: URL]()
        var needsSave = false

        for i in items.indices {
            let (url, isStale) = items[i].resolveAndCheckStale()
            guard let url else { continue }
            let std = url.standardizedFileURL
            urls.insert(std)
            byID[items[i].id] = std
            // N-5: lastKnownPath 백필 (기존 JSON에서 마이그레이션)
            if items[i].lastKnownPath != std.path {
                items[i].lastKnownPath = std.path
                needsSave = true
            }
            // B-9: stale 북마크를 해석된 URL로 새로 생성해 갱신
            if isStale,
               let freshData = try? url.bookmarkData(options: FavoriteItem.bookmarkCreationOptions,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
                items[i].bookmarkData = freshData
                needsSave = true
            }
        }
        resolvedURLs = urls
        resolvedByID = byID
        cacheVersion += 1   // P0: 뷰의 Observation 무효화 트리거
        return needsSave
    }

    private func save(markModified: Bool) {
        if markModified {
            UserDefaults.standard.set(true, forKey: userModifiedKey)
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
