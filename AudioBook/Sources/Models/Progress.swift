import Foundation

/// 单本书的播放进度
struct BookProgress: Codable, Equatable {
    var chapterIndex: Int
    /// 章内已播位置（秒）
    var position: Double
    var updatedAt: Date
}

/// 进度文件整体结构，落盘为 Documents/播放进度.json
struct ProgressFile: Codable {
    var version: Int
    var books: [String: BookProgress]

    static let empty = ProgressFile(version: 1, books: [:])
}

/// 时长缓存条目，按文件大小判断是否需要重新解析
struct DurationCacheEntry: Codable {
    var fileSize: Int64
    var duration: Double
}
