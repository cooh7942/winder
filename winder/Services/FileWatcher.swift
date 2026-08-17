import Foundation
import CoreServices

/// FSEvents 기반 디렉토리 감시 — 외부 파일 변경을 AsyncStream으로 전달
/// 200 ms 디바운스: 연속 이벤트(파일 복사, 압축 해제 등)가 한꺼번에 발생해도
/// 마지막 변경 이후 200 ms가 지나야 리로드를 유발한다.
@MainActor
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Void>.Continuation?
    private var debounceTask: Task<Void, Never>?
    /// A-2: 직계 자식 필터용 — 정규화된 감시 경로 보관
    private var watchedPath: String = ""
    /// FSEvents 콜백 전용 직렬 큐 — 콜백은 곧바로 메인 액터 Task로 넘기므로 UI를 막지 않는다
    private let eventQueue = DispatchQueue(label: "com.tjuxta.winder.filewatcher", qos: .utility)

    // MARK: - Public API

    /// 지정된 URL을 감시하기 시작하고 변경 이벤트 스트림을 반환
    func watch(url: URL) -> AsyncStream<Void> {
        stop()  // 이전 감시 정리
        watchedPath = url.standardizedFileURL.path

        let stream = AsyncStream<Void> { [weak self] cont in
            self?.continuation = cont
            cont.onTermination = { [weak self] _ in
                // 약한 캡처를 Task 안에서 직접 쓰면 동시 실행 클로저가 var 캡처를 참조하게 되므로
                // 여기서 먼저 강한 참조로 바인딩한다 (FileWatcher는 @MainActor라 Sendable)
                guard let self else { return }
                Task { @MainActor in self.stopStream() }
            }
        }

        startStream(url: url)
        return stream
    }

    /// 감시 중단 및 스트림 종료 — 탭 닫기/이동 시 반드시 호출
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        stopStream()
        continuation?.finish()
        continuation = nil
        watchedPath = ""
    }

    // MARK: - Private

    private func startStream(url: URL) {
        let paths = [url.path] as CFArray
        // passRetained: FSEventStream이 FileWatcher를 강하게 참조하여
        // 스트림이 살아있는 동안 객체가 해제되지 않도록 보장 (UAF 방지)
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<FileWatcher>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileWatcherCallback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,  // latency: 100 ms (+ 200 ms 디바운스 = 최대 300 ms 지연)
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer    |
                // A-2: CFArray<CFString>으로 경로 전달받아 경로 비교 가능
                kFSEventStreamCreateFlagUseCFTypes |
                // A-2: Winder 자신이 만든 변경 이벤트 무시 — 자체 파일 작업으로 인한 리로드 감소
                kFSEventStreamCreateFlagIgnoreSelf
            )
        )

        guard let ref else { return }
        // ScheduleWithRunLoop는 macOS 13에서 deprecated — 디스패치 큐 방식으로 전달
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

    /// A-2: 이벤트 경로를 받아 직계 자식 변경만 통과시킨 뒤 200 ms 디바운스
    fileprivate func didReceiveEvents(paths: [String]) {
        let parent = watchedPath
        guard !parent.isEmpty else { return }

        // 감시 경로의 직계 자식(한 단계 하위)인 경우만 통과
        // 예: watchedPath = "/Users/alice" → "/Users/alice/Desktop"은 통과,
        //     "/Users/alice/Library/Caches/…"는 차단
        let relevant = paths.contains { path in
            URL(fileURLWithPath: path)
                .standardizedFileURL
                .deletingLastPathComponent()
                .path == parent
        }
        guard relevant else { return }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200 ms
            guard !Task.isCancelled else { return }
            continuation?.yield()
        }
    }
}

// MARK: - C 콜백 브릿지

// eventPaths는 FSEventStreamCallback에서 비옵셔널 UnsafeMutableRawPointer — guard let 불필요
private let fileWatcherCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

    // A-2: kFSEventStreamCreateFlagUseCFTypes → eventPaths가 CFArray<CFString>으로 전달됨
    // CFArray는 NSArray로 toll-free bridging 가능 → 안전하게 String 배열 추출
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let nsArray = cfArray as NSArray
    let paths = (0..<numEvents).compactMap { nsArray[$0] as? String }

    Task { @MainActor in watcher.didReceiveEvents(paths: paths) }
}
