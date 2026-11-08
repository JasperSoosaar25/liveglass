import Foundation

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var pollInterval: Double = 30          // seconds between live checks (15-120)
    var notifications: Bool = true         // local notifications for live/recording events
    var keepAlive: Bool = true             // silent-audio background keep-alive (24/7 monitoring)
    var wifiOnly: Bool = false             // only auto-record on WiFi
    var keepScreenAwake: Bool = false      // disable auto-lock while app is foreground
    var splitMinutes: Int = 0              // split recording into parts every N minutes (0 = off)
    var minFreeGB: Double = 5              // stop recording if free storage drops below this
    var maxConcurrent: Int = 2             // how many lives to record at once (1-4)
    var cookies: String = ""               // optional raw Cookie header for stubborn regions
    var saveToPhotos: Bool = false         // auto-add finished mp4/mov parts to Photos

    static let `default` = AppSettings()
}

// MARK: - Watched user

struct WatchedUser: Codable, Identifiable, Equatable {
    var username: String
    var nickname: String = ""
    var isLive: Bool = false
    var viewerCount: Int = 0
    var qualityLabel: String = ""
    var lastChecked: Date?
    var lastLiveAt: Date?
    var lastError: String = ""
    var autoRecord: Bool = true

    var id: String { username }

    var statusLine: String {
        if !lastError.isEmpty { return lastError }
        if isLive {
            var s = "LIVE"
            if viewerCount > 0 { s += " • \(Self.shortCount(viewerCount)) watching" }
            if !qualityLabel.isEmpty { s += " • \(qualityLabel)" }
            return s
        }
        if let t = lastChecked {
            let ago = Int(Date().timeIntervalSince(t))
            let agoStr: String
            if ago < 60 { agoStr = "\(max(ago, 0))s ago" }
            else if ago < 3600 { agoStr = "\(ago / 60)m ago" }
            else { agoStr = "\(ago / 3600)h ago" }
            return "Offline • checked \(agoStr)"
        }
        return "Not checked yet"
    }

    static func shortCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Recording item

struct RecordingItem: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case recording
        case ready
        case converting
        case failed
    }

    var id: UUID = UUID()
    var username: String
    var fileName: String = ""
    var relativePath: String = ""          // path relative to Documents
    var bytes: Int64 = 0
    var startedAt: Date = Date()
    var endedAt: Date?
    var durationSeconds: Double = 0
    var format: String = "mp4"             // mp4 | ts | flv
    var quality: String = ""
    var state: State = .recording
    var note: String = ""

    // .ts is natively decodable by AVPlayer (H.264/AAC MPEG-TS), so it plays in-app
    // too. Only .flv needs an external player like VLC.
    var isVideoPlayableInApp: Bool { state == .ready && ["mp4", "mov", "ts"].contains(format) }
}

// MARK: - Live info returned by TikTokAPI

struct LiveInfo: Sendable {
    var username: String
    var isLive: Bool
    var definitive: Bool = false           // true when the data source explicitly knows the status
    var nickname: String = ""
    var avatarURL: String = ""
    var viewerCount: Int = 0
    var roomId: String = ""
    var hlsURL: String = ""                // master or media playlist (absolute)
    var flvURL: String = ""                // raw fallback
    var qualityLabel: String = ""
    var source: String = ""
}

// MARK: - Shared helpers

enum Paths {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var recordingsRoot: URL {
        documentsURL.appendingPathComponent("Recordings", isDirectory: true)
    }
    static var stateFileURL: URL {
        documentsURL.appendingPathComponent("liveglass_state.json")
    }
    static func absoluteURL(forRelativePath rel: String) -> URL {
        documentsURL.appendingPathComponent(rel)
    }
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: d)
    }

    static func sanitizeUsername(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(raw.filter { allowed.contains($0) })
    }
}

enum UserNormalization {
    /// "https://www.tiktok.com/@SomeUser/live?x=1" -> "someuser"
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "tiktok.com/@") {
            s = String(s[range.upperBound...])
        }
        if s.hasPrefix("@") { s.removeFirst() }
        if let idx = s.firstIndex(where: { $0 == "?" || $0 == "/" || $0 == " " }) {
            s = String(s[..<idx])
        }
        return s.lowercased()
    }
}
