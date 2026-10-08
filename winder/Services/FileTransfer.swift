import Foundation
import Darwin
import Observation

// MARK: - 작업 스레드 ↔ 메인 액터 공용 카운터

/// copyfile 콜백(작업 스레드)이 쓰고 메인 액터가 주기적으로 읽는 진행 카운터.
///
/// 콜백은 수 MB마다 불리므로 그때마다 메인 액터로 넘기지 않고 여기 누적만 한다.
/// 화면은 FileTransferCenter가 0.1초마다 읽어 간다.
nonisolated final class TransferCounter: @unchecked Sendable {
    struct Snapshot {
        var totalBytes: Int64?
        var copiedBytes: Int64
        var currentName: String
    }

    private let lock = NSLock()
    private var totalBytes: Int64?
    /// 끝난 최상위 항목들의 크기 합
    private var finishedItemsBytes: Int64 = 0
    /// 진행 중인 최상위 항목(폴더) 안에서 끝난 파일들의 크기 합
    private var finishedFilesBytes: Int64 = 0
    /// 지금 복사 중인 파일에서 복사된 양
    private var currentFileBytes: Int64 = 0
    private var currentName = ""
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func setTotal(_ bytes: Int64) { lock.withLock { totalBytes = bytes } }

    func beginFile(named name: String) {
        lock.withLock { currentName = name; currentFileBytes = 0 }
    }
    func updateCurrentFile(copied: Int64) { lock.withLock { currentFileBytes = copied } }
    func finishFile(size: Int64) {
        lock.withLock { finishedFilesBytes += size; currentFileBytes = 0 }
    }
    /// 최상위 항목 하나가 끝났다 — 콜백이 오지 않는 경우(복제·단일 파일)에도 진행률이 맞도록 크기로 확정한다
    func finishItem(size: Int64) {
        lock.withLock {
            finishedItemsBytes += size
            finishedFilesBytes = 0
            currentFileBytes = 0
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            var copied = finishedItemsBytes + finishedFilesBytes + currentFileBytes
            if let totalBytes { copied = min(copied, totalBytes) }
            return Snapshot(totalBytes: totalBytes, copiedBytes: copied, currentName: currentName)
        }
    }
}

// MARK: - 진행 중인 작업 하나

@Observable
@MainActor
final class FileTransfer: Identifiable {
    enum Kind { case copy, move }

    let id = UUID()
    let kind: Kind
    /// 첫 항목 이름과 개수 — "'a.mov' 외 2개"
    let firstItemName: String
    let itemCount: Int
    let destinationName: String
    @ObservationIgnored nonisolated let counter = TransferCounter()

    /// 금방 끝나는 작업은 깜빡이지 않도록 잠시 뒤에야 보인다
    fileprivate(set) var isVisible = false
    /// nil이면 아직 전체 크기를 세는 중
    private(set) var totalBytes: Int64?
    private(set) var copiedBytes: Int64 = 0
    private(set) var currentName = ""
    private(set) var isCancelling = false
    /// 최근 전송 속도(바이트/초) — 속도를 잴 만큼 진행되기 전에는 nil
    private(set) var bytesPerSecond: Double?
    /// 속도 측정용 (시각, 누적 바이트) 기록 — 최근 speedWindow 구간만 남긴다
    @ObservationIgnored private var samples: [(time: Date, bytes: Int64)] = []

    /// 속도를 재는 구간. 시작부터의 평균을 쓰면 중간에 느려지거나(네트워크·느린 디스크)
    /// 빨라져도 숫자가 거의 움직이지 않는다 — 최근 2초로 잰다
    private static let speedWindow: TimeInterval = 2
    /// 이보다 짧은 구간으로는 속도를 내지 않는다 — 처음 몇 번의 콜백은 들쭉날쭉하다
    private static let minimumSpan: TimeInterval = 0.5

    init(kind: Kind, items: [URL], destination: URL) {
        self.kind = kind
        self.firstItemName = items.first.map { FileManager.default.displayName(atPath: $0.path) } ?? ""
        self.itemCount = items.count
        self.destinationName = FileManager.default.displayName(atPath: destination.path)
    }

    var fraction: Double? {
        guard let totalBytes else { return nil }
        guard totalBytes > 0 else { return 1 }
        return Double(copiedBytes) / Double(totalBytes)
    }

    /// 남은 시간(초) — 표시 중인 속도와 어긋나지 않도록 같은 최근 속도로 계산한다
    var remainingSeconds: Double? {
        guard let totalBytes, let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(totalBytes - copiedBytes) / rate
    }

    func cancel() {
        isCancelling = true
        counter.cancel()
    }

    fileprivate func refresh() {
        let snap = counter.snapshot()
        totalBytes = snap.totalBytes
        copiedBytes = snap.copiedBytes
        currentName = snap.currentName
        updateSpeed()
    }

    /// 0.1초마다 들어오는 누적 바이트로 최근 구간 속도를 잰다
    private func updateSpeed() {
        // 크기를 세는 동안은 아직 아무것도 옮기지 않았다
        guard totalBytes != nil else { return }
        let now = Date()
        samples.append((now, copiedBytes))
        // 구간보다 오래된 기록은 버리되, 구간 시작을 덮는 가장 최근 것 하나는 남긴다
        while samples.count > 2, now.timeIntervalSince(samples[1].time) >= Self.speedWindow {
            samples.removeFirst()
        }
        guard let first = samples.first else { return }
        let span = now.timeIntervalSince(first.time)
        guard span >= Self.minimumSpan else { return }
        bytesPerSecond = Double(copiedBytes - first.bytes) / span
    }
}

// MARK: - 진행 중인 작업 목록

/// 창 아래 진행 패널이 보는 목록 — 복사·이동이 어디서 시작됐든(붙여넣기·끌어다 놓기·트리) 여기 모인다
@Observable
@MainActor
final class FileTransferCenter {
    static let shared = FileTransferCenter()

    private(set) var transfers: [FileTransfer] = []
    var visibleTransfers: [FileTransfer] { transfers.filter(\.isVisible) }

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// 이보다 빨리 끝나면 패널을 띄우지 않는다
    private static let showDelay: Duration = .milliseconds(400)

    func begin(_ kind: FileTransfer.Kind, items: [URL], destination: URL) -> FileTransfer {
        let transfer = FileTransfer(kind: kind, items: items, destination: destination)
        transfers.append(transfer)
        Task { [weak transfer] in
            try? await Task.sleep(for: Self.showDelay)
            transfer?.isVisible = true
        }
        startPolling()
        return transfer
    }

    func end(_ transfer: FileTransfer) {
        transfers.removeAll { $0 === transfer }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !self.transfers.isEmpty {
                for transfer in self.transfers { transfer.refresh() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.pollTask = nil
        }
    }
}

// MARK: - 복사 엔진

/// copyfile(3)로 복사한다 — FileManager.copyItem과 달리 파일마다 진행 콜백을 받을 수 있다.
/// 같은 APFS 볼륨이면 COPYFILE_CLONE으로 복제해 FileManager처럼 즉시 끝나고 공간도 쓰지 않는다
/// (복제가 안 되는 경우에만 실제로 데이터를 복사한다).
nonisolated enum FileCopyEngine {
    /// 복사가 사용자 취소로 멈췄다
    struct Cancelled: Error {}

    /// 항목마다의 크기(일반 파일 바이트 합) — 진행률의 분모
    static func sizes(of urls: [URL], counter: TransferCounter) throws -> [Int64] {
        try urls.map { url in
            if counter.isCancelled { throw Cancelled() }
            return itemSize(url, counter: counter)
        }
    }

    private static func itemSize(_ url: URL, counter: TransferCounter) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        // 심볼릭 링크는 링크 자체를 복사하므로 대상 크기를 세지 않는다
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            if counter.isCancelled { break }
            let v = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// src를 dst로 복사한다 (dst는 아직 없어야 한다).
    /// 취소되면 만들다 만 dst를 지우고 Cancelled를 던진다
    static func copy(_ src: URL, to dst: URL, counter: TransferCounter) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }

        // 콜백은 C 함수 포인터라 아무것도 캡처할 수 없다 — 카운터는 ctx로 넘긴다
        let callback: copyfile_callback_t = { what, stage, state, src, _, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            let counter = Unmanaged<TransferCounter>.fromOpaque(ctx).takeUnretainedValue()
            if counter.isCancelled { return COPYFILE_QUIT }

            switch (what, stage) {
            case (COPYFILE_RECURSE_FILE, COPYFILE_START):
                if let src { counter.beginFile(named: (String(cString: src) as NSString).lastPathComponent) }
            case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    counter.updateCurrentFile(copied: Int64(copied))
                }
            case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
                // 복제된 파일은 진행 콜백 없이 끝나므로 원본 크기로 확정한다
                var info = stat()
                if let src, lstat(src, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                    counter.finishFile(size: Int64(info.st_size))
                }
            case (_, COPYFILE_ERR):
                return COPYFILE_QUIT
            default:
                break
            }
            return COPYFILE_CONTINUE
        }

        let ctx = Unmanaged.passUnretained(counter).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx)

        counter.beginFile(named: src.lastPathComponent)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        // withExtendedLifetime: 콜백이 ctx로 쓰는 동안 카운터가 살아 있어야 한다
        let result = withExtendedLifetime(counter) {
            copyfile(src.path, dst.path, state, flags)
        }
        guard result != 0 else { return }

        let code = errno
        // 반쯤 만들어진 결과는 남기지 않는다
        try? FileManager.default.removeItem(at: dst)
        if counter.isCancelled { throw Cancelled() }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
