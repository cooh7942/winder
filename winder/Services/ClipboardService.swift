import AppKit
import Observation

/// NSPasteboard 기반 파일 클립보드 — Finder 상호운용
/// .fileURL 타입을 사용하므로 Finder에서 복사한 파일도 붙여넣기 가능
@Observable
@MainActor
final class ClipboardService {
    static let shared = ClipboardService()

    /// 잘라내기 대기 중인 항목 — 50% 불투명도 표시용
    private(set) var cutItems: [FileItem] = []

    /// 붙여넣기 가능 여부 — NSPasteboard.changeCount 폴링으로 갱신 (@Observable 추적 가능)
    private(set) var hasPasteContent: Bool = false

    private var lastChangeCount: Int = 0
    private var pollTimer: Timer?

    // MARK: - 초기화

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        hasPasteContent = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
        // 0.5초마다 클립보드 변경 감지 (버튼 활성화 상태 갱신)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPasteboardChanges() }
        }
    }

    // MARK: - 복사

    func copy(items: [FileItem]) {
        clearCutState()
        write(urls: items.map(\.url))
        lastChangeCount = NSPasteboard.general.changeCount  // 우리가 쓴 것임을 기록
        hasPasteContent = true
    }

    // MARK: - 잘라내기

    func cut(items: [FileItem]) {
        clearCutState()
        write(urls: items.map(\.url))
        cutItems = items
        items.forEach { $0.isCutPending = true }
        lastChangeCount = NSPasteboard.general.changeCount  // 우리가 쓴 것임을 기록
        hasPasteContent = true
    }

    // MARK: - 붙여넣기

    /// 클립보드에서 파일 URL 목록 반환 (Finder 호환)
    func pasteURLs() -> [URL] {
        NSPasteboard.general
            .readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap { $0 as? URL } ?? []
    }

    var isCutOperation: Bool { !cutItems.isEmpty }

    // MARK: - 상태 초기화

    func clearCutState() {
        cutItems.forEach { $0.isCutPending = false }
        cutItems.removeAll()
    }

    // MARK: - Private

    private func checkPasteboardChanges() {
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        hasPasteContent = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
        // 다른 앱이 클립보드를 덮어쓰면 잘라내기 대기 상태 해제
        if !cutItems.isEmpty { clearCutState() }
    }

    private func write(urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }
}
