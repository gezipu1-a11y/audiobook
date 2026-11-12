import Foundation

/// 集中管理所有沙盒路径，避免各处散落拼接
enum AppPaths {

    /// 小说根目录：Documents/Audiobooks
    /// 放在 Documents 下，爱思助手才能看到并导入
    static var audiobooks: URL {
        documents.appendingPathComponent("Audiobooks", isDirectory: true)
    }

    /// 进度文件放在 Documents 根目录，方便直接用爱思助手拷出备份
    static var progressFile: URL {
        documents.appendingPathComponent("播放进度.json")
    }

    /// 时长缓存放在 Application Support，用户不需要看到
    static var durationCacheFile: URL {
        support.appendingPathComponent("durations.json")
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 首次启动时创建目录，已存在则直接复用，不覆盖任何用户文件
    @discardableResult
    static func ensureDirectories() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: audiobooks.path) {
            try? fm.createDirectory(at: audiobooks, withIntermediateDirectories: true)
        }
        return audiobooks
    }
}
