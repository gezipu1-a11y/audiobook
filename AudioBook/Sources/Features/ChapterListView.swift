import SwiftUI

/// 章节列表，当前章高亮
struct ChapterListView: View {

    @EnvironmentObject private var player: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let book = player.currentBook {
                    ForEach(book.chapters.indices, id: \.self) { index in
                        let chapter = book.chapters[index]
                        Button {
                            guard chapter.isPlayable else { return }
                            player.jump(to: index)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chapter.title)
                                        .font(.body)
                                        .foregroundStyle(chapter.isPlayable ? Color.primary : Color.secondary)
                                        .lineLimit(2)
                                    if !chapter.isPlayable {
                                        Text("无法播放")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(timeText(chapter.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if index == player.chapterIndex {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!chapter.isPlayable)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("章节")
            .navigationBarTitleDisplayMode(.inline)
            // 章节可能随播放切换而增加，用 id 保证列表视图正确刷新
            .id(player.currentBook?.id ?? "")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
