import Foundation
import AVFoundation

/// 扫描 Audiobooks 目录，生成书单
final class LibraryScanner {

    /// 支持的音频格式白名单
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac"
    ]

    private let fm = FileManager.default

    /// 扫描并返回所有书。时长优先从缓存补齐，缺失的异步解析。
    func scanAll() async -> [Book] {
        AppPaths.ensureDirectories()

        let folders = (try? fm.contentsOfDirectory(
            at: AppPaths.audiobooks,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        // 一级文件夹 = 一本书
        let bookFolders = folders.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        var cache = DurationCache.load()
        var books: [Book] = []

        for folder in bookFolders {
            var chapters: [Chapter] = []

            for url in audioFiles(in: folder) {
                let key = "\(folder.lastPathComponent)/\(url.lastPathComponent)"
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

                var duration: Double = 0
                // 文件大小未变则复用缓存，避免每次启动重新解析
                if let entry = cache[key], entry.fileSize == size, entry.duration > 0 {
                    duration = entry.duration
                } else {
                    duration = await Self.loadDuration(for: url)
                    if duration > 0 {
                        cache[key] = DurationCacheEntry(fileSize: size, duration: duration)
                    }
                }

                chapters.append(Chapter(
                    id: key,
                    title: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    duration: duration,
                    isPlayable: duration > 0
                ))
            }

            // 空文件夹跳过，避免书架出现空白条目
            guard !chapters.isEmpty else { continue }
            books.append(Book(
                id: folder.lastPathComponent,
                title: folder.lastPathComponent,
                folderURL: folder,
                chapters: chapters
            ))
        }

        DurationCache.save(cache)

        // 按书名自然排序
        return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 取书文件夹内的音频文件，已按自然顺序排好。
    /// 嵌套子目录与非音频文件在此被过滤掉。
    private func audioFiles(in folder: URL) -> [URL] {
        let files = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let audio = files.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            return Self.audioExtensions.contains(url.pathExtension.lowercased())
        }

        // 自然排序：第2章 排在 第10章 之前
        return audio.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// 异步读取时长，失败返回 0 表示该章不可播
    private static func loadDuration(for url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(loaded)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}

/// 时长缓存读写，存 Application Support
enum DurationCache {
    static func load() -> [String: DurationCacheEntry] {
        guard let data = try? Data(contentsOf: AppPaths.durationCacheFile),
              let decoded = try? JSONDecoder().decode([String: DurationCacheEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ cache: [String: DurationCacheEntry]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: AppPaths.durationCacheFile, options: .atomic)
    }
}
