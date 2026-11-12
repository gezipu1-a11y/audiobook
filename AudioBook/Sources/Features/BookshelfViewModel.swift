import SwiftUI

/// 书架数据源，负责扫描与刷新。
///
/// 线程约定：扫描在后台 Task 内完成，所有 @Published 状态的写入
/// 统一通过 DispatchQueue.main.async 回到主线程，避免并发隔离问题。
final class LibraryViewModel: ObservableObject {

    @Published private(set) var books: [Book] = []
    @Published private(set) var isScanning = false
    /// 书架排序偏好，true 为最近收听优先
    @Published var sortByRecent = true
    @Published var statusText: String?

    /// 进度快照，避免视图反复读磁盘
    @Published private(set) var progressMap: [String: BookProgress] = [:]

    private let scanner = LibraryScanner()

    var displayedBooks: [Book] {
        guard sortByRecent else { return books }
        return books.sorted { a, b in
            let da = progressMap[a.id]?.updatedAt ?? .distantPast
            let db = progressMap[b.id]?.updatedAt ?? .distantPast
            return da > db
        }
    }

    func progress(for bookId: String) -> BookProgress? {
        progressMap[bookId]
    }

    /// 从存储层重新读取进度并刷新书架
    func refreshProgress() {
        progressMap = ProgressStore.shared.allProgress()
    }

    /// 触发扫描。始终在主线程调用。
    func scan(onFinish: (() -> Void)? = nil) {
        // 正在扫描时立即回调，避免调用方的 continuation 永远不 resume
        guard !isScanning else {
            onFinish?()
            return
        }
        isScanning = true
        let oldIds = Set(books.map(\.id))

        Task { [weak self] in
            guard let self else { return }

            // 扫描与时长解析在后台执行
            let result = await self.scanner.scanAll()
            let newIds = Set(result.map(\.id))

            // 清理已删除书籍的孤立进度
            ProgressStore.shared.purgeOrphans(existingBookIds: newIds)

            let added = newIds.subtracting(oldIds).count
            let removed = oldIds.subtracting(newIds).count
            let status = (added > 0 || removed > 0)
                ? "新增 \(added) 本 · 移除 \(removed) 本"
                : "共 \(result.count) 本"

            DispatchQueue.main.async {
                self.books = result
                self.progressMap = ProgressStore.shared.allProgress()
                self.statusText = status
                self.isScanning = false
                onFinish?()
            }
        }
    }
}
