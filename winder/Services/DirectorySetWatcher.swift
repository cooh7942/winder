import Foundation
import CoreServices

/// 여러 폴더의 "내용 변경"을 한 FSEvents 스트림으로 감시한다 — 탐색 창 트리용.
///
/// 트리는 한 번 읽은 하위 폴더 목록을 캐시해 두므로, 터미널·Finder 같은 다른 프로세스가
/// 폴더를 만들거나 지워도 알 수 없다. 자식을 읽어 둔 폴더들을 여기 맡겨 두면 바뀐 폴더를 알려 준다.
///
/// FileWatcher와 다른 점
/// - 폴더 하나가 아니라 집합을 감시한다 (펼친 폴더가 늘거나 줄 때마다 update로 갈아 끼운다)
/// - 파일 단위가 아닌 폴더 단위 이벤트를 쓴다 — "어느 폴더의 목록이 바뀌었나"만 필요하다
/// - Winder 자신의 변경은 무시한다 (그건 winderDirectoriesDidChange 알림으로 이미 받는다).
///   내장 터미널의 셸은 별도 프로세스라 무시 대상이 아니다
///
/// FSEvents는 항상 하위까지 재귀로 감시하므로 감시 루트 아래의 모든 변경이 들어온다.
/// 들어온 경로가 감시 집합에 있을 때만 통과시킨다 (집합 조회라 이벤트가 많아도 가볍다).
/// 네트워크 볼륨은 이 Mac에서 일어난 변경만 들어온다 — 서버 쪽 변경은 FSEvents가 알 수 없다.
@MainActor
final class DirectorySetWatcher {
    /// 내용이 바뀐 폴더 경로(update에 넘긴 형태 그대로) — 200 ms 디바운스 후 한 번에 전달
    var onChange: ((Set<String>) -> Void)?

    private var stream: FSEventStreamRef?
    /// 넘겨받은 감시 경로 — 같은 집합이면 스트림을 다시 만들지 않는다
    private var requestedPaths: Set<String> = []
    /// 실제 경로(심볼릭 링크 해석) → 넘겨받은 경로들.
    /// FSEvents는 실제 경로로 알려 주므로(/tmp → /private/tmp) 되돌려 줄 때 이 표를 쓴다
    private var originalsByRealPath: [String: Set<String>] = [:]
    /// update가 연달아 오면 마지막 것만 반영한다 — 경로 해석이 비동기라 순서가 뒤바뀔 수 있다
    private var generation = 0

    private var pendingPaths: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    /// FSEvents 콜백 전용 직렬 큐 — 콜백은 곧바로 메인 액터 Task로 넘긴다
    private let eventQueue = DispatchQueue(label: "com.tjuxta.winder.treewatcher", qos: .utility)

    // MARK: - Public API

    /// 감시할 폴더 집합을 바꾼다. 빈 집합이면 감시를 멈춘다
    func update(paths: Set<String>) {
        guard paths != requestedPaths else { return }
        requestedPaths = paths
        generation += 1
        let current = generation

        // 심볼릭 링크 해석은 경로 구성 요소마다 디스크에 묻는다 —
        // 네트워크 볼륨이면 느릴 수 있어 메인 스레드 밖에서 한다
        Task.detached(priority: .utility) {
            var table: [String: Set<String>] = [:]
            for path in paths {
                let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                table[real, default: []].insert(path)
            }
            let resolved = table
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                self.originalsByRealPath = resolved
                self.restartStream(roots: Array(resolved.keys))
            }
        }
    }

    /// 감시 중단 — 스트림이 이 객체를 붙잡고 있으므로 버릴 때는 반드시 부른다
    func stop() {
        requestedPaths = []
        generation += 1
        originalsByRealPath = [:]
        debounceTask?.cancel()
        debounceTask = nil
        pendingPaths = []
        stopStream()
    }

    // MARK: - 스트림

    private func restartStream(roots: [String]) {
        stopStream()
        guard !roots.isEmpty else { return }

        // passRetained: 스트림이 살아 있는 동안 이 객체가 해제되지 않게 한다 (FileWatcher와 같은 이유)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<DirectorySetWatcher>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            directorySetWatcherCallback,
            &ctx,
            Self.minimalRoots(roots) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,   // latency 200 ms + 디바운스 200 ms
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer   |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagIgnoreSelf
            )
        )
        guard let ref else { return }
        FSEventStreamSetDispatchQueue(ref, eventQueue)
        FSEventStreamStart(ref)
        stream = ref
    }

    private func stopStream() {
        guard let ref = stream else { return }
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        stream = nil
    }

    /// 다른 루트 아래에 있는 경로는 빼고 넘긴다 — FSEvents는 어차피 재귀라 상위 하나로 충분하다
    private static func minimalRoots(_ paths: [String]) -> [String] {
        let sorted = paths.sorted()
        var result: [String] = []
        for path in sorted {
            if let last = result.last {
                let prefix = last.hasSuffix("/") ? last : last + "/"
                if path.hasPrefix(prefix) { continue }
            }
            result.append(path)
        }
        return result
    }

    // MARK: - 이벤트

    /// 폴더 단위 이벤트의 경로는 "목록이 바뀐 폴더" 자신이다.
    /// mustScanSubDirs는 이벤트가 너무 많아 하위를 뭉뚱그렸다는 뜻 — 그 아래 감시 폴더를 모두 바뀐 것으로 본다
    fileprivate func didReceive(paths: [String], mustScanSubDirs: [Bool]) {
        var changed: Set<String> = []
        for (path, rescan) in zip(paths, mustScanSubDirs) {
            let real = URL(fileURLWithPath: path).standardizedFileURL.path
            if let originals = originalsByRealPath[real] {
                changed.formUnion(originals)
            }
            if rescan {
                let prefix = real.hasSuffix("/") ? real : real + "/"
                for (watched, originals) in originalsByRealPath where watched.hasPrefix(prefix) {
                    changed.formUnion(originals)
                }
            }
        }
        guard !changed.isEmpty else { return }

        pendingPaths.formUnion(changed)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            let batch = self.pendingPaths
            self.pendingPaths = []
            self.onChange?(batch)
        }
    }
}

// MARK: - C 콜백 브릿지

private let directorySetWatcherCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let watcher = Unmanaged<DirectorySetWatcher>.fromOpaque(info).takeUnretainedValue()

    // kFSEventStreamCreateFlagUseCFTypes → eventPaths는 CFArray<CFString>
    let nsArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    var paths: [String] = []
    var rescans: [Bool] = []
    for i in 0..<numEvents {
        guard let path = nsArray[i] as? String else { continue }
        paths.append(path)
        rescans.append(eventFlags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0)
    }
    Task { @MainActor in watcher.didReceive(paths: paths, mustScanSubDirs: rescans) }
}
