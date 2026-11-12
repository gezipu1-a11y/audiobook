import SwiftUI

/// 书架：极简列表风
struct BookshelfView: View {

    @EnvironmentObject private var player: AudioPlayerManager
    @StateObject private var vm = LibraryViewModel()
    @State private var showPlayer = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.books.isEmpty {
                    emptyState
                } else {
                    bookList
                }
            }
            .navigationTitle("听书")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle("按最近收听排序", isOn: $vm.sortByRecent)
                        Button("重新扫描") {
                            vm.scan()
                        }
                        Button("设置") { showSettings = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .refreshable {
                await rescanAsync()
            }
            .task {
                vm.scan()
            }
            .sheet(isPresented: $showPlayer, onDismiss: {
                // 关闭播放页后刷新书架进度显示
                vm.refreshProgress()
            }) {
                PlayerView(onClose: {
                    showPlayer = false
                })
                .environmentObject(player)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(onChanged: {
                    vm.scan()
                })
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentBook != nil {
                    miniPlayerBar
                }
            }
        }
    }

    /// 下拉刷新需要 await，用 continuation 桥接回调式扫描
    private func rescanAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            vm.scan {
                continuation.resume()
            }
        }
        vm.refreshProgress()
    }

    // MARK: - 列表

    private var bookList: some View {
        List {
            ForEach(vm.displayedBooks) { book in
                Button {
                    player.open(book: book)
                    showPlayer = true
                } label: {
                    BookRow(book: book, progress: vm.progress(for: book.id))
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        ProgressStore.shared.clear(bookId: book.id)
                        vm.refreshProgress()
                    } label: {
                        Label("清除进度", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("书架是空的")
                    .font(.title3.weight(.medium))

                VStack(alignment: .leading, spacing: 8) {
                    Text("导入方法")
                        .font(.subheadline.weight(.medium))
                    Text("1. 手机连电脑，打开爱思助手")
                    Text("2. 进入「文件共享」→「听书」")
                    Text("3. 打开 Audiobooks 文件夹")
                    Text("4. 每本书新建一个文件夹，把 mp3 拖进去")
                    Text("5. 回到 App 下拉刷新")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if vm.isScanning {
                    ProgressView("扫描中…")
                } else {
                    Button("重新扫描") {
                        vm.scan()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let status = vm.statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    // MARK: - 迷你播放条

    private var miniPlayerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentBook?.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(currentChapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { showPlayer = true }

            Spacer()

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var currentChapterTitle: String {
        guard let book = player.currentBook,
              let chapter = book.chapters[safe: player.chapterIndex] else { return "" }
        return chapter.title
    }
}

/// 单本书行
private struct BookRow: View {
    let book: Book
    let progress: BookProgress?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let percent {
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let count = book.chapters.count
        guard let progress else { return "\(count) 章 · 未开始" }
        let chapterNo = min(progress.chapterIndex + 1, count)
        return "\(count) 章 · 听到第 \(chapterNo) 章"
    }

    /// 按已听时长占比估算
    private var percent: Int? {
        guard let progress,
              book.chapters.indices.contains(progress.chapterIndex) else { return nil }
        let listened = book.chapters
            .prefix(progress.chapterIndex)
            .reduce(0) { $0 + $1.duration } + progress.position
        let total = book.totalDuration
        guard total > 0 else { return nil }
        return Int(min(100, max(0, listened / total * 100)))
    }
}
