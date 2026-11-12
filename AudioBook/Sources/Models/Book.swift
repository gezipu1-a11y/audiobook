import Foundation

/// 单个章节：对应书文件夹内的一个音频文件
struct Chapter: Identifiable, Hashable {
    /// 稳定标识：书文件夹名/文件名
    let id: String
    /// 展示名称，取文件名去扩展名
    let title: String
    let url: URL
    /// 时长（秒），未解析完成时为 0
    var duration: Double
    /// 文件损坏或格式不支持时为 false
    var isPlayable: Bool
}

/// 一本书：对应 Audiobooks 下的一个一级文件夹
struct Book: Identifiable, Hashable {
    /// 稳定标识，使用文件夹名
    let id: String
    let title: String
    let folderURL: URL
    var chapters: [Chapter]

    var totalDuration: Double {
        chapters.reduce(0) { $0 + $1.duration }
    }

    var playableChapterCount: Int {
        chapters.filter(\.isPlayable).count
    }
}
