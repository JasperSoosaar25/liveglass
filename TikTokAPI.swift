import Foundation

enum TikTokAPIError: LocalizedError {
    case invalidUsername
    case blocked(String)
    case noStreamData(String)

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return "Invalid username."
        case .blocked(let detail):
            return "TikTok is blocking this request (\(detail)). Try adding cookies in Settings → Advanced."
        case .noStreamData(let detail):
            return "Could not get stream data (\(detail))."
        }
    }
}

/// Extracts live status + stream pull URLs from TikTok, entirely on-device, free, no login.
///
/// Cascade (mirrors the approaches used by actively maintained OSS recorders, 2025-2026):
///  1. Scrape https://www.tiktok.com/@user/live  → room_id and/or direct m3u8/flv URLs
///     (from the `__UNIVERSAL_DATA_FOR_REHYDRATION__` JSON blob, with regex fallbacks).
///  2. webcast.tiktok.com/webcast/room/info/?aid=1988&room_id=… → full room payload incl.
///     quality tiers (`live_core_sdk_data.pull_data.stream_data`) and `hls_pull_url`.
///  3. tikrec.com sign mirror → signed /api-live/user/room/ path → room_id (when page is bot-walled).
///  4. Euler Stream public endpoint → room_id (rate limited free tier).
final class TikTokAPI: @unchecked Sendable {
    static let shared = TikTokAPI()

    private let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private let iphoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    // Benign best-effort hint (which UA worked last); races between concurrent
    // checks only flip between two valid UAs, never crash — by design.
    private var preferredUAIndex = 0
    private let http: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        http = URLSession(configuration: cfg)
    }

    // MARK: - Public entry point

    func fetchLiveInfo(username rawUsername: String, cookies: String) async throws -> LiveInfo {
        let username = UserNormalization.normalize(rawUsername)
        guard !username.isEmpty, username.count <= 40 else { throw TikTokAPIError.invalidUsername }

        var lastError: Error?

        // --- Strategy 1 + 2: live page -> room id -> room info
        for uaIndex in [preferredUAIndex, preferredUAIndex == 0 ? 1 : 0] {
            let ua = uaIndex == 0 ? desktopUA : iphoneUA
            do {
                let html = try await fetchLivePage(username: username, ua: ua, cookies: cookies)
                preferredUAIndex = uaIndex

                let parsed = Self.parseLivePage(html)

                if let hls = parsed.hlsURL, !hls.isEmpty {
                    var info = LiveInfo(username: username, isLive: true, definitive: true, source: "live page")
                    info.hlsURL = hls
                    info.flvURL = parsed.flvURL ?? ""
                    info.roomId = parsed.roomId ?? ""
                    info.qualityLabel = parsed.preferredQualityLabel
                    if info.qualityLabel.isEmpty { info.qualityLabel = parsed.or4Found ? "Original (_or4)" : "" }
                    return info
                }

                if let roomId = parsed.roomId {
                    if let info = try await fetchRoomInfo(roomId: roomId, username: username, cookies: cookies) {
                        return info
                    }
                }

                if parsed.looksLikeOfflinePage {
                    return LiveInfo(username: username, isLive: false, definitive: true, source: "live page")
                }
                // Page loaded but contained nothing useful — keep trying other strategies.
            } catch {
                lastError = error
            }
        }

        // --- Strategy 3: tikrec sign mirror -> /api-live/user/room/
        if let roomId = try? await fetchRoomIdViaTikRec(username: username, cookies: cookies) {
            if let info = try? await fetchRoomInfo(roomId: roomId, username: username, cookies: cookies) {
                return info
            }
        }

        // --- Strategy 4: Euler Stream public room_info (free, IP-rate-limited)
        if let roomId = try? await fetchRoomIdViaEuler(username: username) {
            if let info = try? await fetchRoomInfo(roomId: roomId, username: username, cookies: cookies) {
                return info
            }
        }

        if let err = lastError {
            throw err
        }
        // Everything ran without hard errors but produced nothing -> assume offline.
        return LiveInfo(username: username, isLive: false, definitive: false, source: "fallback")
    }

    func isUserLive(username: String, cookies: String) async -> Bool {
        guard let info = try? await fetchLiveInfo(username: username, cookies: cookies) else { return false }
        return info.isLive
    }

    // MARK: - Strategy 1: live page HTML

    private func fetchLivePage(username: String, ua: String, cookies: String) async throws -> String {
        guard let url = URL(string: "https://www.tiktok.com/@\(username)/live") else {
            throw TikTokAPIError.invalidUsername
        }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        if !cookies.isEmpty {
            req.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        let (data, resp) = try await http.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let html = String(data: data, encoding: .utf8) ?? ""

        if status == 403 || status == 429 {
            throw TikTokAPIError.blocked("HTTP \(status)")
        }
        if html.count < 2500 {
            throw TikTokAPIError.blocked("suspiciously small page (\(html.count) bytes)")
        }
        return html
    }

    struct ParsedLivePage {
        var roomId: String?
        var hlsURL: String?
        var flvURL: String?
        var or4Found = false
        var looksLikeOfflinePage = false
        var preferredQualityLabel: String = ""
    }

    static func parseLivePage(_ html: String) -> ParsedLivePage {
        var out = ParsedLivePage()

        // 1) The rehydration JSON blob contains the live room state when the user is live.
        if let openTag = html.range(of: "__UNIVERSAL_DATA_FOR_REHYDRATION__"),
           let scriptOpen = html[openTag.upperBound...].range(of: ">"),
           let scriptClose = html[scriptOpen.upperBound...].range(of: "</script>") {
            let jsonText = String(html[scriptOpen.upperBound..<scriptClose.lowerBound])
            if let data = jsonText.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                var hls: String?
                var flv: String?
                walkJSON(obj, roomId: &out.roomId, hls: &hls, flv: &flv)
                out.hlsURL = hls
                out.flvURL = flv
            }
        }

        // 2) Regex fallbacks on a flattened copy of the HTML (handles \/ and \u0026 escapes).
        let flat = html
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")

        if out.roomId == nil,
           let m = Self.firstMatch(pattern: "\"room_?[iI]d\"\\s*:\\s*\"?(\\d{6,})\"?", in: flat) {
            out.roomId = m
        }
        if out.hlsURL == nil {
            let urls = Self.allMatches(pattern: "https?://[^\\s\"'<>]+\\.m3u8[^\\s\"'<>]*", in: flat)
            if let best = Self.preferQuality(urls) {
                out.hlsURL = best
                out.or4Found = best.contains("_or4")
            }
        }
        if out.flvURL == nil {
            let urls = Self.allMatches(pattern: "https?://[^\\s\"'<>]+\\.flv[^\\s\"'<>]*", in: flat)
            if let best = Self.preferQuality(urls) {
                out.flvURL = best
                out.or4Found = out.or4Found || best.contains("_or4")
            }
        }

        // Offline heuristic: page rendered fine but only references an ended room.
        if out.hlsURL == nil, flat.contains("\"status\":4"), out.roomId != nil {
            out.looksLikeOfflinePage = true
        }
        if out.or4Found && out.preferredQualityLabel.isEmpty {
            out.preferredQualityLabel = "Original"
        }
        return out
    }

    private static func preferQuality(_ urls: [String]) -> String? {
        if let or4 = urls.first(where: { $0.contains("_or4") }) { return or4 }
        if let uhd = urls.first(where: { $0.contains("_uhd") }) { return uhd }
        return urls.first
    }

    /// Recursively walks the rehydration JSON looking for room id / stream pull URLs.
    private static func walkJSON(_ obj: Any, roomId: inout String?, hls: inout String?, flv: inout String?) {
        if let dict = obj as? [String: Any] {
            for (key, value) in dict {
                if roomId == nil, key == "roomId" || key == "room_id" {
                    if let s = value as? String, s.count >= 5, s.allSatisfy({ $0.isNumber }) {
                        roomId = s
                    } else if let n = value as? NSNumber {
                        roomId = n.stringValue
                    }
                }
                if key == "streamUrl", let sd = value as? [String: Any] {
                    if hls == nil { hls = sd["hls_pull_url"] as? String }
                    if flv == nil { flv = sd["rtmp_pull_url"] as? String }
                }
                if hls == nil || roomId == nil {
                    walkJSON(value, roomId: &roomId, hls: &hls, flv: &flv)
                }
            }
        } else if let arr = obj as? [Any] {
            for value in arr {
                if hls == nil || roomId == nil {
                    walkJSON(value, roomId: &roomId, hls: &hls, flv: &flv)
                }
            }
        }
    }

    // MARK: - Strategy 2: webcast room/info

    private func fetchRoomInfo(roomId: String, username: String, cookies: String) async throws -> LiveInfo? {
        guard let url = URL(string: "https://webcast.tiktok.com/webcast/room/info/?aid=1988&room_id=\(roomId)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue(preferredUAIndex == 0 ? desktopUA : iphoneUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        if !cookies.isEmpty {
            req.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        let (data, _) = try await http.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["data"] as? [String: Any] else {
            return nil
        }

        let status = (payload["status"] as? NSNumber)?.intValue ?? 0
        var info = LiveInfo(username: username, isLive: status == 2, definitive: true, source: "room info")
        info.roomId = roomId

        if let owner = payload["owner"] as? [String: Any] {
            info.nickname = owner["nickname"] as? String ?? (owner["display_id"] as? String ?? "")
            if let av = owner["avatar_thumb"] as? [String: Any],
               let urls = av["url_list"] as? [String], let first = urls.first {
                info.avatarURL = first
            }
        }
        info.viewerCount = (payload["user_count"] as? NSNumber)?.intValue ?? 0

        guard status == 2 else { return info }

        guard let streamURL = payload["stream_url"] as? [String: Any] else {
            throw TikTokAPIError.noStreamData("room is live but no stream_url")
        }
        let picked = Self.pickStreams(from: streamURL)
        if let hls = picked.hls { info.hlsURL = hls }
        if let flv = picked.flv { if info.flvURL.isEmpty { info.flvURL = flv } }
        if let label = picked.label { info.qualityLabel = label }

        if info.hlsURL.isEmpty && info.flvURL.isEmpty {
            throw TikTokAPIError.noStreamData("no hls/flv pull urls")
        }
        return info
    }

    /// Chooses the best quality pull URLs out of the room payload.
    /// Priority: `live_core_sdk_data.pull_data.stream_data` tiers (origin/uhd/hd/sd/ld)
    /// then plain `hls_pull_url`, and for FLV: `rtmp_pull_url` / `flv_pull_url.FULL_HD1`.
    static func pickStreams(from streamURL: [String: Any]) -> (hls: String?, flv: String?, label: String?) {
        var hls: String?
        var flv: String?
        var label: String?

        if let sdk = streamURL["live_core_sdk_data"] as? [String: Any],
           let pull = sdk["pull_data"] as? [String: Any],
           let sdString = pull["stream_data"] as? String,
           let sdData = sdString.data(using: .utf8),
           let sdObj = try? JSONSerialization.jsonObject(with: sdData) as? [String: Any],
           let tiers = sdObj["data"] as? [String: Any] {

            let tierOrder = ["origin", "uhd", "hd", "sd", "ld"]
            let tierNames = ["origin": "Original", "uhd": "UHD", "hd": "HD", "sd": "SD", "ld": "LD"]
            for key in tierOrder {
                guard let tier = tiers[key] as? [String: Any],
                      let main = tier["main"] as? [String: Any] else { continue }
                if hls == nil, let h = main["hls"] as? String, !h.isEmpty {
                    hls = h
                    label = tierNames[key]
                }
                if flv == nil, let f = main["flv"] as? String, !f.isEmpty {
                    flv = f
                    if label == nil { label = tierNames[key] }
                }
                if hls != nil && flv != nil { break }
            }
            if let opts = pull["options"] as? [String: Any],
               let dq = opts["default_quality"] as? [String: Any],
               let nm = dq["name"] as? String, hls != nil {
                label = nm
            }
        }

        if hls == nil, let direct = streamURL["hls_pull_url"] as? String, !direct.isEmpty {
            hls = direct
            if label == nil { label = "HLS" }
        }
        if flv == nil {
            if let rtmp = streamURL["rtmp_pull_url"] as? String, !rtmp.isEmpty {
                flv = rtmp
            } else if let dict = streamURL["flv_pull_url"] as? [String: Any],
                      let fullHd = dict["FULL_HD1"] as? String, !fullHd.isEmpty {
                flv = fullHd
                if label == nil { label = "FULL HD" }
            }
        }
        return (hls, flv, label)
    }

    // MARK: - Strategy 3: tikrec sign mirror

    private func fetchRoomIdViaTikRec(username: String, cookies: String) async throws -> String {
        guard let url = URL(string: "https://tikrec.com/tiktok/room/api/sign?unique_id=\(username)") else {
            throw TikTokAPIError.blocked("tikrec url")
        }
        let (data, _) = try await http.data(from: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signedPath = obj["signed_path"] as? String, !signedPath.isEmpty else {
            throw TikTokAPIError.blocked("tikrec sign unavailable")
        }
        let full: URL
        if signedPath.hasPrefix("http") {
            guard let u = URL(string: signedPath) else { throw TikTokAPIError.blocked("tikrec: bad url") }
            full = u
        } else {
            guard let u = URL(string: "https://www.tiktok.com\(signedPath)") else {
                throw TikTokAPIError.blocked("tikrec: bad url")
            }
            full = u
        }
        var req = URLRequest(url: full)
        req.setValue(preferredUAIndex == 0 ? desktopUA : iphoneUA, forHTTPHeaderField: "User-Agent")
        if !cookies.isEmpty { req.setValue(cookies, forHTTPHeaderField: "Cookie") }
        let (roomData, _) = try await http.data(for: req)
        guard let roomObj = try? JSONSerialization.jsonObject(with: roomData) as? [String: Any],
              let payload = roomObj["data"] as? [String: Any],
              let user = payload["user"] as? [String: Any] else {
            throw TikTokAPIError.blocked("tikrec room lookup failed")
        }
        if let rid = user["roomId"] as? String, !rid.isEmpty { return rid }
        if let n = user["roomId"] as? NSNumber { return n.stringValue }
        throw TikTokAPIError.blocked("tikrec: no roomId")
    }

    // MARK: - Strategy 4: Euler Stream public endpoint

    private func fetchRoomIdViaEuler(username: String) async throws -> String {
        guard let url = URL(string: "https://tiktok.eulerstream.com/webcast/room_info?unique_id=\(username)") else {
            throw TikTokAPIError.blocked("euler url")
        }
        let (data, _) = try await http.data(from: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["data"] as? [String: Any],
              let roomInfo = payload["room_info"] as? [String: Any] else {
            throw TikTokAPIError.blocked("euler unavailable")
        }
        if let rid = roomInfo["id"] as? String, !rid.isEmpty { return rid }
        if let n = roomInfo["id"] as? NSNumber { return n.stringValue }
        throw TikTokAPIError.blocked("euler: no room id")
    }

    // MARK: - Regex helpers

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        guard m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard m.numberOfRanges > 0 else { return nil }
            return ns.substring(with: m.range(at: 0))
        }
    }
}
