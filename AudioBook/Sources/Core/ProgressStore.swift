import Foundation

/// 进度持久化。
/// 设计要点：
/// 1. 所有写入走同一条串行队列，杜绝并发写坏文件
/// 2. 每次落盘用 .atomic 原子替换，写到一半崩溃也不会损坏旧文件
/// 3. 内存里始终保留一份，读取不碰磁盘
final class ProgressStore {

    static let shared = ProgressStore()

    /// 串行队列，保证写入顺序
    private let queue = DispatchQueue(label: "com.diy.audiobook.progress")

    private var cache: ProgressFile = .empty

    private init() {
        cache = Self.readFromDisk()
    }

    // MARK: - 读取

    /// 取某本书的进度，没有记录返回 nil
    func progress(for bookId: String) -> BookProgress? {
        queue.sync { cache.books[bookId] }
    }

    /// 全部进度，供书架展示
    func allProgress() -> [String: BookProgress] {
        queue.sync { cache.books }
    }

    // MARK: - 写入

    /// 更新单本书进度，立即落盘。
    /// 在暂停、切章、拖动结束、播放完毕、进入后台、被打断时调用。
    func update(bookId: String, chapterIndex: Int, position: Double) {
        queue.async {
            self.cache.books[bookId] = BookProgress(
                chapterIndex: chapterIndex,
                position: max(0, position),
                updatedAt: Date()
            )
            self.writeToDisk()
        }
    }

    /// 定时写盘（播放中每 3 秒一次）。
    /// 与 update 的区别只是语义，逻辑一致，单独命名便于日后调整节流策略。
    func tick(bookId: String, chapterIndex: Int, position: Double) {
        update(bookId: bookId, chapterIndex: chapterIndex, position: position)
    }

    /// 清除单本书进度
    func clear(bookId: String) {
        queue.async {
            self.cache.books.removeValue(forKey: bookId)
            self.writeToDisk()
        }
    }

    /// 清空全部进度
    func clearAll() {
        queue.async {
            self.cache = .empty
            self.writeToDisk()
        }
    }

    /// 扫描后清理已不存在的书的孤立记录
    func purgeOrphans(existingBookIds: Set<String>) {
        queue.async {
            let stale = self.cache.books.keys.filter { !existingBookIds.contains($0) }
            guard !stale.isEmpty else { return }
            stale.forEach { self.cache.books.removeValue(forKey: $0) }
            self.writeToDisk()
        }
    }

    /// 进入后台等场景需要同步落盘，确保在系统冻结前写完
    func flushSync() {
        queue.sync {
            self.writeToDisk()
        }
    }

    // MARK: - 磁盘

    /// 统一用 ISO8601 编码时间，保证导出的 json 人眼可读
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func writeToDisk() {
        guard let data = try? Self.encoder.encode(cache) else { return }
        try? data.write(to: AppPaths.progressFile, options: .atomic)
    }

    private static func readFromDisk() -> ProgressFile {
        guard let data = try? Data(contentsOf: AppPaths.progressFile),
              let decoded = try? decoder.decode(ProgressFile.self, from: data)
        else { return .empty }
        return decoded
    }
}
