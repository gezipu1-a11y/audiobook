import SwiftUI

@main
struct AudioBookApp: App {
    /// 播放器是全局单例，用 StateObject 持有以便在整个视图树中观察变化
    @StateObject private var player = AudioPlayerManager.shared

    var body: some Scene {
        WindowGroup {
            BookshelfView()
                .environmentObject(player)
                .onAppear {
                    // 首次启动创建目录，保证爱思助手能立刻看到 Audiobooks
                    AppPaths.ensureDirectories()
                }
        }
    }
}
