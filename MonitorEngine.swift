import Foundation
import SwiftUI
import UIKit
import AVFoundation
import UserNotifications
import Network
import Photos

// MARK: - Persisted state

struct PersistedState: Codable {
    var settings: AppSettings = .default
    var users: [WatchedUser] = []
    var recordings: [RecordingItem] = []
    var monitoringActive: Bool = false
}

// MARK: - Silent-audio background keep-alive
//
// iOS suspends apps seconds after they go background — unless an audio session is
// actively playing. A near-silent looping tone keeps the process alive indefinitely,
// which is what makes 24/7 monitoring possible. This is fine for sideloaded apps
// (only App Store review would object).

final class KeepAliveAudio {
    static let shared = KeepAliveAudio()

    private var player: AVAudioPlayer?
    private(set) var isActive = false

    private var wavURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keepalive_silence.wav")
    }

    func start() {
        guard !isActive else { return }
        Self.writeSilenceWavIfNeeded(to: wavURL)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: wavURL)
            p.numberOfLoops = -1
            p.volume = 0.01
            p.prepareToPlay()
            if p.play() {
                player = p
                isActive = true
            }
        } catch {
            // Keep-alive is best effort; monitoring still works in foreground.
            isActive = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 1 second of near-silent 16-bit PCM mono @ 22050 Hz.
    private static func writeSilenceWavIfNeeded(to url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let sampleRate = 22050
        let seconds = 1
        let dataBytes = sampleRate * seconds * 2
        var data = Data()

        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func appendU32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        append("RIFF"); appendU32(UInt32(36 + dataBytes)); append("WAVE")
        append("fmt "); appendU32(16); appendU16(1); appendU16(1)
        appendU32(UInt32(sampleRate)); appendU32(UInt32(sampleRate * 2)); appendU16(2); appendU16(16)
        append("data"); appendU32(UInt32(dataBytes))
        data.append(Data(repeating: 0x00, count: dataBytes))
        try? data.write(to: url)
    }
}

// MARK: - Local notifications

enum Notifier {
    static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(_ title: String, _ body: String, enabled: Bool) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - App state / monitor engine

@MainActor
@Observable
final class AppState {
    var settings: AppSettings = .default
    var users: [WatchedUser] = []
    var recordings: [RecordingItem] = []
    var monitoringActive = false
    var keepAliveActive = false
    var lastGlobalError = ""

    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var recordTasks: [String: Task<Void, Never>] = [:]
    private var checking: Set<String> = []
    private var lowStorageWarned = false
    private var pathMonitor = NWPathMonitor()
    private var currentPathAvailable = true
    private var currentPathIsWiFi = true
    private var resumed = false

    init() {
        load()
        startPathMonitor()
    }

    // MARK: Persistence

    func save() {
        let state = PersistedState(settings: settings, users: users,
                                   recordings: recordings, monitoringActive: monitoringActive)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Paths.stateFileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        settings = state.settings
        users = state.users
        // Drop in-progress rows from a previous session; the files themselves were
        // never finalized, and their temp folders are cleaned below. Interrupted
        // conversions go back to ready (the original file is kept until a convert
        // succeeds, so nothing is lost).
        recordings = state.recordings
            .map { rec -> RecordingItem in
                var r = rec
                if r.state == .converting { r.state = .ready }
                return r
            }
            .filter { $0.state != .recording }
        monitoringActive = false // actual resume happens in resumeIfNeeded()
    }

    func resumeIfNeeded() {
        guard !resumed else { return }
        resumed = true
        cleanupOrphanWorkDirs()
        // Auto-resume monitoring if it was running when the app last quit/crashed.
        if let data = try? Data(contentsOf: Paths.stateFileURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data),
           state.monitoringActive {
            Task { await startMonitoring() }
        }
    }

    private func cleanupOrphanWorkDirs() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: Paths.recordingsRoot, includingPropertiesForKeys: nil) else { return }
        for item in contents where item.lastPathComponent.hasPrefix(".work-") {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: Network path

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.currentPathAvailable = available
                self?.currentPathIsWiFi = wifi
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "liveglass.pathmonitor"))
    }

    // MARK: Monitoring control

    func startMonitoring() async {
        guard !monitoringActive else { return }
        if settings.notifications { await Notifier.requestPermissionIfNeeded() }
        monitoringActive = true
        lowStorageWarned = false
        applyIdleTimer()
        if settings.keepAlive {
            KeepAliveAudio.shared.start()
            keepAliveActive = KeepAliveAudio.shared.isActive
        }
        for user in users where pollTasks[user.username] == nil {
            startPollLoop(for: user.username)
        }
        save()
        Notifier.post("Live Glass", "Monitoring started for \(users.count) user(s).", enabled: settings.notifications)
    }

    func stopMonitoring() async {
        monitoringActive = false
        for (_, task) in pollTasks { task.cancel() }
        pollTasks.removeAll()
        for task in recordTasks.values { task.cancel() }
        recordTasks.removeAll()
        KeepAliveAudio.shared.stop()
        keepAliveActive = false
        applyIdleTimer()
        save()
    }

    func toggleMonitoring() {
        Task {
            if monitoringActive { await stopMonitoring() } else { await startMonitoring() }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        applyIdleTimer()
        if phase == .background && monitoringActive && settings.keepAlive && !KeepAliveAudio.shared.isActive {
            KeepAliveAudio.shared.start()
            keepAliveActive = KeepAliveAudio.shared.isActive
        }
    }

    func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = monitoringActive && settings.keepScreenAwake
    }

    // MARK: Watchlist

    func addUser(_ raw: String) {
        let username = UserNormalization.normalize(raw)
        guard !username.isEmpty else { return }
        guard !users.contains(where: { $0.username == username }) else { return }
        users.append(WatchedUser(username: username))
        save()
        if monitoringActive {
            startPollLoop(for: username)
        }
        Task { await checkNow(username: username) }
    }

    func removeUser(_ username: String) {
        pollTasks[username]?.cancel()
        pollTasks.removeValue(forKey: username)
        recordTasks[username]?.cancel()
        recordTasks.removeValue(forKey: username)
        users.removeAll { $0.username == username }
        save()
    }

    func toggleAutoRecord(_ username: String) {
        guard let idx = users.firstIndex(where: { $0.username == username }) else { return }
        users[idx].autoRecord.toggle()
        save()
    }

    func startPollLoop(for username: String) {
        guard pollTasks[username] == nil else { return }
        pollTasks[username] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow(username: username)
                if Task.isCancelled { break }
                let interval = self?.settings.pollInterval ?? 30
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: Live checks

    func checkNow(username: String) async {
        guard !checking.contains(username) else { return }
        checking.insert(username)
        defer { checking.remove(username) }

        do {
            let info = try await TikTokAPI.shared.fetchLiveInfo(username: username, cookies: settings.cookies)
            applyLiveInfo(info)
            lastGlobalError = ""

            if info.isLive && monitoringActive {
                await maybeStartRecording(for: info)
            }
        } catch {
            if let idx = users.firstIndex(where: { $0.username == username }) {
                users[idx].lastError = error.localizedDescription
                users[idx].lastChecked = Date()
            }
        }
        save()
    }

    private func applyLiveInfo(_ info: LiveInfo) {
        guard let idx = users.firstIndex(where: { $0.username == info.username }) else { return }
        users[idx].lastError = ""
        users[idx].lastChecked = Date()
        if info.definitive || info.isLive {
            users[idx].isLive = info.isLive
            users[idx].viewerCount = info.viewerCount
            users[idx].qualityLabel = info.qualityLabel
            if info.isLive {
                if users[idx].lastLiveAt == nil || Date().timeIntervalSince(users[idx].lastLiveAt ?? .distantPast) > 600 {
                    users[idx].lastLiveAt = Date()
                }
            }
            if !info.nickname.isEmpty { users[idx].nickname = info.nickname }
        }
    }

    private func freeDiskGB() -> Double {
        let values = try? Paths.documentsURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let bytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return Double(bytes) / 1_000_000_000
    }

    private func maybeStartRecording(for info: LiveInfo) async {
        guard recordTasks[info.username] == nil else { return }

        // Capacity: usually one stream at a time, configurable.
        if recordTasks.count >= max(settings.maxConcurrent, 1) {
            if let idx = users.firstIndex(where: { $0.username == info.username }) {
                users[idx].qualityLabel = "waiting for a slot"
            }
            return
        }
        // WiFi-only policy.
        if settings.wifiOnly && !currentPathIsWiFi {
            if let idx = users.firstIndex(where: { $0.username == info.username }) {
                users[idx].qualityLabel = "waiting for WiFi"
            }
            return
        }
        // Storage guard.
        if freeDiskGB() < settings.minFreeGB {
            if !lowStorageWarned {
                lowStorageWarned = true
                Notifier.post("Live Glass — low storage",
                              "Less than \(Int(settings.minFreeGB)) GB free. Not starting new recordings.",
                              enabled: settings.notifications)
            }
            return
        }

        let user = users.first { $0.username == info.username }
        guard user?.autoRecord != false else { return }

        startRecording(for: info)
    }

    private func startRecording(for info: LiveInfo) {
        let username = info.username
        guard recordTasks[username] == nil else { return }

        var item = RecordingItem(username: username)
        item.state = .recording
        item.quality = info.qualityLabel
        recordings.append(item)

        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "Referer": "https://www.tiktok.com/"
        ]
        if !settings.cookies.isEmpty { headers["Cookie"] = settings.cookies }

        let split = settings.splitMinutes
        let cookies = settings.cookies
        let notifications = settings.notifications
        let saveToPhotos = settings.saveToPhotos

        recordTasks[username] = Task { [weak self] in
            let recorder = StreamRecorder(username: username, live: info, headers: headers,
                                          splitMinutes: split) {
                let stillLive = await TikTokAPI.shared.isUserLive(username: username, cookies: cookies)
                return stillLive
            }
            do {
                try await recorder.run { event in
                    Task { @MainActor [weak self] in
                        self?.handleRecorderEvent(username: username, event: event,
                                                  notifications: notifications, saveToPhotos: saveToPhotos)
                    }
                }
            } catch is CancellationError {
                self?.finishRecordingItem(username: username, failed: false)
            } catch {
                Task { @MainActor [weak self] in
                    self?.failRecordingItem(username: username, message: error.localizedDescription,
                                            notifications: notifications)
                }
            }
            Task { @MainActor [weak self] in
                self?.recordTasks.removeValue(forKey: username)
                self?.save()
            }
        }
        Notifier.post("Recording started", "@\(username) is live — capturing at \(info.qualityLabel.isEmpty ? "max" : info.qualityLabel) quality.",
                      enabled: notifications)
    }

    private func handleRecorderEvent(username: String, event: RecorderEvent,
                                     notifications: Bool, saveToPhotos: Bool) {
        switch event {
        case .status(let text):
            if let idx = users.firstIndex(where: { $0.username == username }) {
                users[idx].qualityLabel = text
            }
        case .progress(let bytes, let seconds):
            if let idx = recordings.lastIndex(where: { $0.username == username && $0.state == .recording }) {
                recordings[idx].bytes = bytes
                recordings[idx].durationSeconds = seconds
            }
        case .partFinished(let path, let bytes, let duration, let format, let quality):
            let url = URL(fileURLWithPath: path)
            if let idx = recordings.lastIndex(where: { $0.username == username && $0.state == .recording }) {
                recordings[idx].state = .ready
                recordings[idx].fileName = url.lastPathComponent
                recordings[idx].relativePath = path.replacingOccurrences(of: Paths.documentsURL.path + "/", with: "")
                recordings[idx].bytes = bytes
                recordings[idx].durationSeconds = duration
                recordings[idx].format = format
                recordings[idx].quality = quality
                recordings[idx].endedAt = Date()
                // Keep the "recording" row going while more parts may follow.
                if monitoringActive && recordTasks[username] != nil {
                    var next = RecordingItem(username: username)
                    next.state = .recording
                    next.quality = quality
                    recordings.append(next)
                }
            }
            Notifier.post("Part saved", "\(url.lastPathComponent) • \(Format.size(bytes)) • \(Format.duration(duration))",
                          enabled: notifications)
            if saveToPhotos && (format == "mp4" || format == "mov") {
                Task { await Self.saveVideoToPhotos(path: path) }
            }
        case .done(let reason):
            let wasEmpty = reason.contains("No data")
            finishRecordingItem(username: username, failed: wasEmpty)
            Notifier.post(wasEmpty ? "Recording ended" : "Recording finished",
                          "@\(username) — \(reason).", enabled: notifications)
        }
        save()
    }

    private func finishRecordingItem(username: String, failed: Bool) {
        guard let idx = recordings.lastIndex(where: { $0.username == username && $0.state == .recording }) else { return }
        if recordings[idx].bytes == 0 {
            if failed {
                recordings[idx].state = .failed
                recordings[idx].note = "Nothing captured"
                recordings[idx].endedAt = Date()
            } else {
                // Empty stub row (parts already saved) — drop it.
                recordings.remove(at: idx)
            }
        } else {
            recordings[idx].state = .ready
            recordings[idx].endedAt = Date()
        }
    }

    private func failRecordingItem(username: String, message: String, notifications: Bool) {
        if let idx = recordings.lastIndex(where: { $0.username == username && $0.state == .recording }) {
            recordings[idx].state = .failed
            recordings[idx].note = message
            recordings[idx].endedAt = Date()
        }
        Notifier.post("Recording error", "@\(username): \(message)", enabled: notifications)
        save()
    }

    func stopRecording(username: String) {
        recordTasks[username]?.cancel()
    }

    // MARK: Photos export

    static func saveVideoToPhotos(path: String) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        let url = URL(fileURLWithPath: path)
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    // MARK: Stats for UI

    func isChecking(username: String) -> Bool { checking.contains(username) }

    var liveCount: Int { users.filter(\.isLive).count }
    var recordingCount: Int { recordTasks.count }
    var totalRecordedBytes: Int64 {
        recordings.filter { $0.state == .ready }.reduce(0) { $0 + $1.bytes }
    }
}
