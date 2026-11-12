import SwiftUI

/// 播放页：极简列表风，白底 + 大标题 + 细进度条
struct PlayerView: View {

    @EnvironmentObject private var player: AudioPlayerManager
    let onClose: () -> Void

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var showChapters = false
    @State private var showSleepMenu = false

    private let rates: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                chapterTitle
                Spacer(minLength: 8)
                progressSection
                Spacer(minLength: 8)
                controlSection
                Spacer(minLength: 8)
                bottomBar
                Spacer(minLength: 16)
            }
            .padding(.horizontal, 24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        // 关闭播放页时强制同步落盘
                        player.persistImmediately()
                        onClose()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showChapters = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            .sheet(isPresented: $showChapters) {
                ChapterListView()
                    .environmentObject(player)
            }
            .confirmationDialog("睡眠定时", isPresented: $showSleepMenu, titleVisibility: .visible) {
                Button("15 分钟") { player.startSleepTimer(minutes: 15) }
                Button("30 分钟") { player.startSleepTimer(minutes: 30) }
                Button("60 分钟") { player.startSleepTimer(minutes: 60) }
                Button("本章播完停止") { player.startSleepTimer(minutes: nil) }
                if player.sleepRemaining != nil || player.stopAtChapterEnd {
                    Button("关闭定时", role: .destructive) { player.cancelSleepTimer() }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(player.currentBook?.title ?? "")
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            Text("第 \(player.chapterIndex + 1) / \(totalChapters) 章")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }

    private var chapterTitle: some View {
        Text(currentChapterTitle)
            .font(.title3.weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 进度

    private var progressSection: some View {
        VStack(spacing: 8) {
            Slider(
                value: sliderBinding,
                in: 0...sliderUpperBound,
                onEditingChanged: handleScrub
            )
            .tint(.primary)
            .disabled(player.duration <= 0)

            HStack {
                Text(timeText(isScrubbing ? scrubValue : player.elapsed))
                Spacer()
                Text(timeText(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var sliderUpperBound: Double {
        max(player.duration, 0.1)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: {
                let v = isScrubbing ? scrubValue : player.elapsed
                // 防止越界导致 Slider 断言
                return min(max(0, v), sliderUpperBound)
            },
            set: { newValue in
                // 手指一动就进入拖动态，避免滑块被播放进度顶回去
                isScrubbing = true
                player.isScrubbing = true
                scrubValue = newValue
            }
        )
    }

    private func handleScrub(_ editing: Bool) {
        if editing {
            isScrubbing = true
            scrubValue = player.elapsed
            player.isScrubbing = true
        } else {
            // 拖动结束才 seek 并落盘，避免写出中间值
            player.seek(to: scrubValue)
            player.isScrubbing = false
            isScrubbing = false
            player.persistImmediately()
        }
    }

    // MARK: - 控制

    private var controlSection: some View {
        HStack(spacing: 0) {
            Button {
                player.previousChapter()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity)

            Button {
                player.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title)
            }
            .frame(maxWidth: .infinity)

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .frame(maxWidth: .infinity)

            Button {
                player.skip(by: 30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title)
            }
            .frame(maxWidth: .infinity)

            Button {
                player.nextChapter()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(rates, id: \.self) { r in
                    Button {
                        player.rate = r
                    } label: {
                        if player.rate == r {
                            Label(rateText(r), systemImage: "checkmark")
                        } else {
                            Text(rateText(r))
                        }
                    }
                }
            } label: {
                bottomItem(rateText(player.rate))
            }

            Button {
                showChapters = true
            } label: {
                bottomItem("章节")
            }

            Button {
                showSleepMenu = true
            } label: {
                bottomItem(sleepLabel)
            }
        }
        .buttonStyle(.plain)
    }

    private func bottomItem(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
    }

    // MARK: - 辅助

    private var totalChapters: Int {
        player.currentBook?.chapters.count ?? 0
    }

    private var currentChapterTitle: String {
        guard let book = player.currentBook,
              let chapter = book.chapters[safe: player.chapterIndex] else { return "" }
        return chapter.title
    }

    private var sleepLabel: String {
        if player.stopAtChapterEnd { return "本章停" }
        guard let remaining = player.sleepRemaining else { return "定时" }
        let minutes = Int((remaining / 60).rounded(.up))
        return "定时 \(minutes)分"
    }

    private func rateText(_ r: Float) -> String {
        // 1.0 → 1.0x，1.25 → 1.25x
        if r == round(r) {
            return String(format: "%.1fx", r)
        }
        return String(format: "%.2fx", r)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
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
