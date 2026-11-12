import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// 播放器状态与持久化的唯一入口。
/// UI 只订阅这里的 @Published 属性，不直接操作 AVPlayer。
///
/// 线程约定：AVPlayer 的时间观察回调与通知都投递到主队列，
/// 因此所有状态变更天然在主线程，无需额外加锁。
final class AudioPlayerManager: ObservableObject {

    static let shared = AudioPlayerManager()

    // MARK: - 对外状态

    @Published private(set) var currentBook: Book?
    @Published private(set) var chapterIndex: Int = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    /// 拖动进度条期间置 true，此时不写盘、不刷新 elapsed
    @Published var isScrubbing: Bool = false
    /// 睡眠定时剩余秒数，nil 表示未开启倒计时
    @Published private(set) var sleepRemaining: Double?
    /// 是否处于「本章播完停止」模式
    @Published private(set) var stopAtChapterEnd = false

    /// 记住的倍速，新书沿用
    @Published var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            // defaultRate 决定 play() 被调用时采用的速率
            player.defaultRate = rate
            // 暂停状态不设置 rate，否则会意外触发播放
            if isPlaying { player.rate = rate }
        }
    }

    // MARK: - 内部

    private let player = AVPlayer()
    private var timeObserver: Any?
    /// 上次写盘时间，把 0.5 秒的 UI 刷新节流为 3 秒一次落盘
    private var lastPersistTime: Date = .distantPast
    private let persistInterval: TimeInterval = 3
    /// 睡眠定时的截止时刻。用绝对时间而非倒计时秒数，
    /// 因为 App 进入后台后 Timer 会被挂起，而时间观察回调仍在跑。
    private var sleepDeadline: Date?
    private var observers: [NSObjectProtocol] = []

    private static let rateKey = "playback.rate"

    private var currentChapter: Chapter? {
        guard let book = currentBook,
              book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    private init() {
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = saved > 0 ? saved : 1.0

        // 初始化期间不会触发 didSet，这里手动同步一次
        player.defaultRate = rate

        configureAudioSession()
        setupRemoteCommands()
        setupTimeObserver()
        setupNotifications()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 音频会话

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // .spokenAudio 适合有声内容，后台播放稳定
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    // MARK: - 加载与播放

    /// 打开一本书并从上次进度处恢复
    func open(book: Book, autoPlay: Bool = true) {
        // 切换书籍前先把上一本的进度落盘
        persistNow()

        let saved = ProgressStore.shared.progress(for: book.id)
        currentBook = book

        var index = saved?.chapterIndex ?? 0
        var position = saved?.position ?? 0

        // 章节可能已被删除，越界或不可播则回退到第一个可播章
        if !book.chapters.indices.contains(index) || !book.chapters[index].isPlayable {
            index = book.chapters.firstIndex(where: { $0.isPlayable }) ?? 0
            position = 0
        }

        // 距结尾不足 5 秒视为已读完，下次从该章开头开始
        if let d = book.chapters[safe: index]?.duration, d > 0, d - position < 5 {
            position = 0
        }

        chapterIndex = index
        loadCurrentChapter(seekTo: position, autoPlay: autoPlay)
    }

    /// 切到指定章节
    func jump(to index: Int) {
        guard let book = currentBook,
              book.chapters.indices.contains(index),
              book.chapters[index].isPlayable else { return }

        persistNow()
        chapterIndex = index
        loadCurrentChapter(seekTo: 0, autoPlay: true)
    }

    private func loadCurrentChapter(seekTo position: Double, autoPlay: Bool) {
        guard let chapter = currentChapter else { return }

        let item = AVPlayerItem(url: chapter.url)
        // 保音调变速，1.5 倍速下不会变尖细
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        duration = chapter.duration
        // 先把 elapsed 置于目标位置，保证任何时刻的对外状态与落盘值都一致
        elapsed = position

        if position > 0 {
            let time = CMTime(seconds: position, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.elapsed = position
                    if autoPlay { self.play() }
                }
            }
        } else if autoPlay {
            play()
        }

        // 切章后立刻落盘，避免刚切换就杀进程时还停留在上一章末尾
        persistNow()
        updateNowPlayingInfo()
    }

    func play() {
        guard currentChapter != nil else { return }
        // 已播到结尾则从头再来
        if duration > 0, elapsed >= duration - 0.5 {
            player.seek(to: .zero)
            elapsed = 0
        }
        // play() 会把速率重置为 defaultRate，所以要先设 defaultRate 再 play
        player.defaultRate = rate
        player.play()
        try? AVAudioSession.sharedInstance().setActive(true)
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        // 暂停是关键节点，立刻落盘
        persistNow()
        updateNowPlayingInfo()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    // MARK: - 跳转

    /// 快进/快退，秒数可为负
    func skip(by seconds: Double) {
        guard duration > 0 else { return }
        seek(to: elapsed + seconds)
        persistNow()
    }

    /// 跳转到指定位置，供拖动进度条结束和锁屏拖动调用
    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(0, duration))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = clamped
        updateNowPlayingInfo()
    }

    func nextChapter() {
        guard let next = nextPlayableIndex(after: chapterIndex) else {
            pause()
            return
        }
        persistNow()
        chapterIndex = next
        loadCurrentChapter(seekTo: 0, autoPlay: true)
    }

    func previousChapter() {
        // 已播过 3 秒以上，先回到本章开头
        if elapsed > 3 {
            seek(to: 0)
            persistNow()
            return
        }
        guard let prev = previousPlayableIndex(before: chapterIndex) else {
            seek(to: 0)
            return
        }
        persistNow()
        chapterIndex = prev
        loadCurrentChapter(seekTo: 0, autoPlay: true)
    }

    private func nextPlayableIndex(after index: Int) -> Int? {
        guard let book = currentBook else { return nil }
        var i = index + 1
        while i < book.chapters.count {
            if book.chapters[i].isPlayable { return i }
            i += 1
        }
        return nil
    }

    private func previousPlayableIndex(before index: Int) -> Int? {
        guard let book = currentBook else { return nil }
        var i = index - 1
        while i >= 0 {
            if book.chapters[i].isPlayable { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - 时间观察与节流落盘

    private func setupTimeObserver() {
        // 0.5 秒刷新 UI，足够顺滑又不浪费
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handleTick(time)
        }
    }

    private func handleTick(_ time: CMTime) {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }

        if !isScrubbing {
            elapsed = seconds
        }

        if let itemDuration = player.currentItem?.duration, itemDuration.isNumeric {
            let d = CMTimeGetSeconds(itemDuration)
            if d.isFinite, d > 0 { duration = d }
        }

        // 播放中每 3 秒落盘一次，这是防强杀的核心兜底
        if isPlaying, !isScrubbing, Date().timeIntervalSince(lastPersistTime) >= persistInterval {
            persistNow()
        }

        updateSleepCountdown()

        // 锁屏信息只在播放中刷新，暂停时由状态变更点更新
        if isPlaying {
            updateNowPlayingInfo()
        }
    }

    /// 睡眠定时用「截止时间」判断，而不是依赖 Timer。
    /// 后台播放时 Timer 会被系统挂起，但播放器的时间观察回调仍然会跑。
    private func updateSleepCountdown() {
        guard let deadline = sleepDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            cancelSleepTimer()
            pause()
        } else {
            sleepRemaining = remaining
        }
    }

    /// 立刻把当前进度写盘
    private func persistNow() {
        guard let book = currentBook, currentChapter != nil else { return }
        lastPersistTime = Date()
        ProgressStore.shared.update(
            bookId: book.id,
            chapterIndex: chapterIndex,
            position: elapsed
        )
    }

    // MARK: - 通知

    private func setupNotifications() {
        let center = NotificationCenter.default

        // 本章播完自动进下一章（通知可能来自任意线程，统一回主队列）
        observers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleItemEnded()
        })

        // 进入后台：系统仍给少量时间，同步落盘
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.persistNow()
            ProgressStore.shared.flushSync()
        })

        // 来电等打断：立即暂停并落盘
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })

        // 拔耳机：立即暂停并落盘
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
    }

    private func handleItemEnded() {
        // 播完是关键节点，先落盘
        persistNow()

        // 睡眠定时选了「本章播完停止」
        if stopAtChapterEnd {
            cancelSleepTimer()
            pause()
            return
        }

        if let next = nextPlayableIndex(after: chapterIndex) {
            chapterIndex = next
            loadCurrentChapter(seekTo: 0, autoPlay: true)
        } else {
            // 全书播完
            pause()
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        if type == .began {
            pause()
        }
        // 结束后不自动恢复，避免用户没戴耳机时突然出声
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        if reason == .oldDeviceUnavailable {
            pause()
        }
    }

    // MARK: - 锁屏控制（回调线程不确定，统一切回主队列）

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.nextChapter() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previousChapter() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async {
                self?.seek(to: e.positionTime)
                self?.persistNow()
            }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skip(by: 30) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skip(by: -15) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let book = currentBook, let chapter = currentChapter else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 睡眠定时

    /// 开启定时，minutes 为分钟数；传 nil 表示「本章播完停止」
    func startSleepTimer(minutes: Int?) {
        cancelSleepTimer()

        if let minutes {
            sleepDeadline = Date().addingTimeInterval(Double(minutes * 60))
            sleepRemaining = Double(minutes * 60)
        } else {
            stopAtChapterEnd = true
            sleepRemaining = nil
        }
    }

    func cancelSleepTimer() {
        sleepDeadline = nil
        sleepRemaining = nil
        stopAtChapterEnd = false
    }

    // MARK: - 退出

    /// 离开播放页时调用：强制把进度同步写到磁盘
    func persistImmediately() {
        persistNow()
        ProgressStore.shared.flushSync()
    }
}
