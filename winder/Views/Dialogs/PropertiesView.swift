import SwiftUI
import AppKit

// MARK: - PropertiesWindowController

/// 파일 속성 패널 컨트롤러 — 항목별 패널을 재사용하고 중복 표시 방지
@MainActor
final class PropertiesWindowController {
    private static var openPanels: [String: NSPanel] = [:]
    /// NSObjectProtocol 토큰 보유 — 토큰을 버리면 즉시 옵저버가 제거되므로 반드시 유지
    private static var observerTokens: [String: NSObjectProtocol] = [:]

    static func show(for item: FileItem) {
        // 이미 열려 있으면 최전면으로 이동
        if let existing = openPanels[item.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(item.displayName) 속성"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentViewController = NSHostingController(rootView: PropertiesView(item: item))
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        let itemID = item.id
        openPanels[itemID] = panel

        // 토큰을 observerTokens에 보관 — 토큰 반환값을 버리면 옵저버가 즉시 해제됨
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            Task { @MainActor in
                openPanels.removeValue(forKey: itemID)
                observerTokens.removeValue(forKey: itemID)
            }
        }
        observerTokens[itemID] = token
    }
}

// MARK: - PropertiesView

struct PropertiesView: View {
    let item: FileItem
    @State private var selectedTab = 0
    @State private var permissions: String = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(item: item)
                .tabItem { Label("일반", systemImage: "doc.text") }
                .tag(0)

            SecurityTab(item: item, permissions: permissions)
                .tabItem { Label("보안", systemImage: "lock") }
                .tag(1)

            DetailsTab(item: item)
                .tabItem { Label("자세히", systemImage: "list.bullet") }
                .tag(2)
        }
        .frame(width: 380, height: 460)
        .padding()
        .task {
            permissions = await loadPermissions(url: item.url)
        }
    }

    private func loadPermissions(url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let posixPerms = attrs[.posixPermissions] as? Int else { return "알 수 없음" }
            return String(format: "%o", posixPerms)
        }.value
    }
}

// MARK: - 일반 탭

private struct GeneralTab: View {
    let item: FileItem
    @State private var calculatedSize: String? = nil

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: item.icon ?? NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable().frame(width: 48, height: 48)
                    Text(item.displayName)
                        .font(.title3.bold())
                }
                .padding(.vertical, 4)
            }

            Section("정보") {
                LabeledContent("종류", value: item.typeDescription)
                LabeledContent("위치", value: item.url.deletingLastPathComponent().path)

                if item.isDirectory {
                    LabeledContent("크기") {
                        if let s = calculatedSize {
                            Text(s)
                        } else {
                            HStack {
                                ProgressView().controlSize(.mini)
                                Text("계산 중...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    LabeledContent("크기", value: formatFileSize(item.size))
                }
            }

            Section("날짜") {
                LabeledContent("만든 날짜", value: formatFileDate(item.dateCreated))
                LabeledContent("수정일", value: formatFileDate(item.dateModified))
            }
        }
        .formStyle(.grouped)
        .task {
            if item.isDirectory {
                calculatedSize = await calcFolderSize(url: item.url)
            }
        }
    }

    private func calcFolderSize(url: URL) async -> String {
        // formatFileSize는 메인 스레드에서 호출, Task.detached는 바이트 수만 반환
        let bytes: Int64 = await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return Int64(-1) }
            // for...in 대신 nextObject()를 사용 — Swift 6에서 makeIterator가 async context에서 불가
            while let fileURL = enumerator.nextObject() as? URL {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
            return total
        }.value
        return bytes < 0 ? "계산 실패" : formatFileSize(bytes)
    }
}

// MARK: - 보안 탭

private struct SecurityTab: View {
    let item: FileItem
    let permissions: String

    var body: some View {
        Form {
            Section("소유자 및 권한") {
                LabeledContent("소유자", value: ownerName)
                LabeledContent("그룹", value: groupName)
                LabeledContent("POSIX 권한", value: permissions.isEmpty ? "알 수 없음" : permissions)
                LabeledContent("권한 문자열", value: permissionString)
            }
        }
        .formStyle(.grouped)
    }

    private var ownerName: String {
        (try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.ownerAccountName] as? String ?? "알 수 없음"
    }

    private var groupName: String {
        (try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.groupOwnerAccountName] as? String ?? "알 수 없음"
    }

    private var permissionString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let posix = attrs[.posixPermissions] as? Int else { return "?" }
        var s = ""
        s += posix & 0o400 != 0 ? "r" : "-"
        s += posix & 0o200 != 0 ? "w" : "-"
        s += posix & 0o100 != 0 ? "x" : "-"
        s += posix & 0o040 != 0 ? "r" : "-"
        s += posix & 0o020 != 0 ? "w" : "-"
        s += posix & 0o010 != 0 ? "x" : "-"
        s += posix & 0o004 != 0 ? "r" : "-"
        s += posix & 0o002 != 0 ? "w" : "-"
        s += posix & 0o001 != 0 ? "x" : "-"
        return s
    }
}

// MARK: - 자세히 탭

private struct DetailsTab: View {
    let item: FileItem

    var body: some View {
        Form {
            Section("파일 시스템 정보") {
                LabeledContent("파일 이름", value: item.name)
                LabeledContent("표시 이름", value: item.displayName)
                LabeledContent("전체 경로", value: item.url.path)
                LabeledContent("숨김 파일", value: item.isHidden ? "예" : "아니오")
                LabeledContent("심볼릭 링크", value: item.isSymlink ? "예" : "아니오")
                LabeledContent("패키지", value: item.isPackage ? "예" : "아니오")
            }
        }
        .formStyle(.grouped)
    }
}
