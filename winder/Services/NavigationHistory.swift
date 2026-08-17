import Foundation

/// 탭별 뒤로/앞으로 히스토리 스택 (최대 50개)
struct NavigationHistory {
    private static let maxDepth = 50

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private(set) var current: URL

    init(initial: URL) {
        self.current = initial
    }

    var canGoBack: Bool    { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// 뒤로 히스토리 목록 (최신 순)
    var backList: [URL] { backStack.reversed() }

    /// 앞으로 히스토리 목록
    var forwardList: [URL] { forwardStack.reversed() }

    /// 새 위치로 이동 — 앞으로 스택 초기화
    mutating func navigate(to url: URL) {
        guard url != current else { return }
        backStack.append(current)
        if backStack.count > Self.maxDepth { backStack.removeFirst() }
        forwardStack.removeAll()
        current = url
    }

    /// 뒤로 이동
    @discardableResult
    mutating func goBack() -> URL? {
        guard let prev = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = prev
        return prev
    }

    /// 앞으로 이동
    @discardableResult
    mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        if backStack.count > Self.maxDepth { backStack.removeFirst() }
        current = next
        return next
    }
}
