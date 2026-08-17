import SwiftUI

@main
struct WinderApp: App {
    var body: some Scene {
        WindowGroup {
            ExplorerWindow()
        }
        // hiddenTitleBar: 기본 titlebar 영역 제거, fullSizeContentView 포함
        // ⌘N(새 창) / ⌘W(창 닫기)는 SwiftUI/AppKit 기본 동작으로 처리
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands { NavigationCommands() }
    }
}
