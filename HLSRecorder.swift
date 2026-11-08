import Foundation
import AVFoundation

enum RecorderEvent: Sendable {
    case status(String)
    case progress(bytes: Int64, seconds: Double)
    case partFinished(path: String, bytes: Int64, duration: Double, format: String, quality: String)
    case done(reason: String)
}

struct PartSummary {
    var path: String
    var bytes: Int64
    var duration: Double
    var format: String
}

enum RecorderError: LocalizedError {
    case noData(String)

    var errorDescription: String? {
        switch self {
        case .noData(let reason):
            return "Nothing captured (\(reason))."
        }
    }
}

/// Records a TikTok live by downloading the HLS stream (TS/fMP4 segments) at the highest
/// available quality, then remuxing losslessly (passthrough, no re-encode) into a single
/// MP4 file using AVFoundation. Falls back to a raw .ts (or .flv) file when passthrough
/// export is not possible. Pure system frameworks — no FFmpeg, small IPA.
actor StreamRecorder {

    private let username: String
    private let masterURL: URL?
    private let flvURL: URL?
    private let headers: [String: String]
    private let splitMinutes: Int
    private let qualityLabel: String
    private let isStillLive: @Sendable () async -> Bool

    private let http: URLSession
    private var downloadedBytes: Int64 = 0
    private var priorSeconds: Double = 0

    init(username: String, live: LiveInfo, headers: [String: String], splitMinutes: Int,
         isStillLive: @escaping @Sendable () async -> Bool) {
        self.username = username
        self.masterURL = live.hlsURL.isEmpty ? nil : URL(string: live.hlsURL)
        self.flvURL = live.flvURL.isEmpty ? nil : URL(string: live.flvURL)
        self.headers = headers
        self.splitMinutes = splitMinutes
        self.qualityLabel = live.qualityLabel
        self.isStillLive = isStillLive

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        var allHeaders = headers
        allHeaders["Accept"] = "*/*"
        cfg.httpAdditionalHeaders = allHeaders
        self.http = URLSession(configuration: cfg)
    }

    // MARK: - Main loop

    func run(onEvent: @escaping @Sendable (RecorderEvent) -> Void) async throws {
        if masterURL != nil {
            var partIndex = 1
            while true {
                do {
                    let summary = try await recordPart(partIndex: partIndex, onEvent: onEvent)
                    _ = summary
                } catch RecorderError.noData(let reason) {
                    if partIndex == 1 {
                        onEvent(.done(reason: "No data captured (\(reason))"))
                        return
                    }
                    break
                }
                // After a part we either split (continue) or the stream ended / user stopped.
                if Task.isCancelled { break }
                if !(await isStillLive()) { break }
                partIndex += 1
            }
            onEvent(.done(reason: Task.isCancelled ? "Stopped" : "Stream ended"))
        } else if flvURL != nil {
            try await recordFLV(onEvent: onEvent)
            onEvent(.done(reason: Task.isCancelled ? "Stopped" : "Stream ended"))
        } else {
            onEvent(.done(reason: "No usable stream URL"))
        }
    }

    // MARK: - HLS part recording

    private func recordPart(partIndex: Int, onEvent: @escaping @Sendable (RecorderEvent) -> Void) async throws -> PartSummary {
        guard let master = masterURL else { throw RecorderError.noData("no HLS url") }

        let workRoot = Paths.recordingsRoot
        let workDir = workRoot.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        var lastSeq = -1
        var files: [(name: String, dur: Double)] = []
        var mapFile: String?
        var targetDuration = 2.0
        var endReason = "stream ended"
        var staleRounds = 0
        var netErrorRounds = 0
        var mediaFailCount = 0
        var cachedMediaURL: URL?
        var lastGrowth = Date()
        let partStart = Date()
        var lastProgressEmit = Date.distantPast

        onEvent(.status("Connecting…"))

        loop: while true {
            if Task.isCancelled { endReason = "stopped by user"; break }

            do {
                // Re-resolve the master playlist only when the cached variant fails,
                // so we don't double-fetch on every poll round.
                let mediaURL: URL
                if let cached = cachedMediaURL, mediaFailCount < 3 {
                    mediaURL = cached
                } else {
                    mediaURL = try await resolveBestMediaURL(from: master)
                    cachedMediaURL = mediaURL
                    mediaFailCount = 0
                }
                let text = try await httpGetText(mediaURL)
                mediaFailCount = 0
                let playlist = Self.parseMediaPlaylist(text, baseURL: mediaURL)
                targetDuration = max(playlist.targetDuration, 0.5)
                netErrorRounds = 0

                // Init segment for fMP4-based HLS.
                if let mapURI = playlist.mapURI, mapFile == nil,
                   let mapURL = URL(string: mapURI, relativeTo: mediaURL) {
                    if (try await downloadTo(mapURL, dest: workDir.appendingPathComponent("init.m4s"))) != nil {
                        mapFile = "init.m4s"
                    }
                }

                var newSegments = 0
                for seg in playlist.segments where seg.seq > lastSeq {
                    if Task.isCancelled { endReason = "stopped by user"; break }
                    let name = "seg\(seg.seq).\(seg.ext)"
                    if let size = try await downloadTo(seg.url, dest: workDir.appendingPathComponent(name)) {
                        files.append((name, seg.duration))
                        lastSeq = seg.seq
                        downloadedBytes += size
                        newSegments += 1
                        let now = Date()
                        if now.timeIntervalSince(lastProgressEmit) > 1.5 {
                            lastProgressEmit = now
                            onEvent(.progress(bytes: downloadedBytes,
                                              seconds: priorSeconds + now.timeIntervalSince(partStart)))
                        }
                    } else {
                        // Segment failed after retries — skip it (small gap) and move on.
                        lastSeq = seg.seq
                    }
                }

                if playlist.hasEndList { endReason = "stream ended"; break loop }

                if newSegments == 0 {
                    staleRounds += 1
                    if staleRounds >= 8 {
                        onEvent(.status("Checking if still live…"))
                        if await isStillLive() == false {
                            endReason = "stream ended"
                            break loop
                        }
                        staleRounds = 0
                    }
                } else {
                    staleRounds = 0
                    lastGrowth = Date()
                }

                // Absolute stall cap: CDN stalled but the room still reports live.
                if Date().timeIntervalSince(lastGrowth) > 600 {
                    endReason = "stream stalled"
                    break loop
                }

                if splitMinutes > 0 && !files.isEmpty,
                   Date().timeIntervalSince(partStart) >= Double(splitMinutes) * 60 {
                    endReason = "part limit reached"
                    break loop
                }

                if !Task.isCancelled {
                    onEvent(.status(files.isEmpty ? "Waiting for stream data…" : "Recording…"))
                    let sleepSeconds = min(2.5, max(1.0, targetDuration / 2))
                    try await Task.sleep(for: .seconds(sleepSeconds))
                }
            } catch is CancellationError {
                endReason = "stopped by user"
                break loop
            } catch {
                netErrorRounds += 1
                mediaFailCount += 1
                if netErrorRounds >= 6 {
                    endReason = "connection lost"
                    break loop
                }
                if Task.isCancelled { endReason = "stopped by user"; break loop }
                try? await Task.sleep(for: .seconds(3))
            }
        }

        guard !files.isEmpty else {
            try? FileManager.default.removeItem(at: workDir)
            throw RecorderError.noData(endReason)
        }

        onEvent(.status("Finalizing…"))
        let summary = try await finalize(workDir: workDir, files: files, mapFile: mapFile,
                                         fallbackDuration: targetDuration, partIndex: partIndex,
                                         partStart: partStart, endReason: endReason, onEvent: onEvent)
        return summary
    }

    /// Fetches the playlist; if it is a master playlist, returns the highest-bandwidth
    /// variant (true max quality). Media playlists are returned as-is.
    private func resolveBestMediaURL(from master: URL) async throws -> URL {
        let text = try await httpGetText(master)
        guard text.contains("#EXT-X-STREAM-INF") else { return master }

        var variants: [(bandwidth: Double, url: URL)] = []
        var lastBandwidth = 0.0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                lastBandwidth = Self.attributeValue("BANDWIDTH", in: line).flatMap { Double($0) } ?? 0
            } else if !line.isEmpty && !line.hasPrefix("#") {
                if let u = URL(string: line, relativeTo: master) {
                    variants.append((lastBandwidth, u.absoluteURL))
                }
                lastBandwidth = 0
            }
        }
        guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else { return master }
        return best.url
    }

    private func httpGetText(_ url: URL) async throws -> String {
        let (data, resp) = try await http.data(from: url)
        if let httpResp = resp as? HTTPURLResponse, !(200..<300).contains(httpResp.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func downloadTo(_ url: URL, dest: URL) async throws -> Int64? {
        for attempt in 1...2 {
            do {
                let (data, resp) = try await http.data(from: url)
                if let httpResp = resp as? HTTPURLResponse, !(200..<300).contains(httpResp.statusCode) {
                    throw URLError(.badServerResponse)
                }
                try data.write(to: dest, options: .atomic)
                return Int64(data.count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == 2 { return nil }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return nil
    }

    // MARK: - Finalization (passthrough remux)

    private func finalize(workDir: URL, files: [(name: String, dur: Double)], mapFile: String?,
                          fallbackDuration: Double, partIndex: Int, partStart: Date,
                          endReason: String, onEvent: @escaping @Sendable (RecorderEvent) -> Void) async throws -> PartSummary {

        // Build a local VOD HLS playlist that references the downloaded segments.
        let maxDur = max(max(files.map { $0.dur }.max() ?? fallbackDuration, fallbackDuration), 1)
        // fMP4 playlists require version >= 6 for #EXT-X-MAP — getting this wrong makes
        // AVAssetExportSession reject the asset (the #1 cause of .ts fallbacks).
        let hlsVersion = mapFile != nil ? 6 : 3
        var m3u8 = "#EXTM3U\n#EXT-X-VERSION:\(hlsVersion)\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        m3u8 += "#EXT-X-TARGETDURATION:\(Int(ceil(maxDur)))\n"
        m3u8 += "#EXT-X-MEDIA-SEQUENCE:0\n"
        m3u8 += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        if let mapFile {
            m3u8 += "#EXT-X-MAP:URI=\"\(mapFile)\"\n"
        }
        var totalDuration = 0.0
        for f in files {
            let d = f.dur > 0 ? f.dur : fallbackDuration
            totalDuration += d
            m3u8 += "#EXTINF:\(String(format: "%.3f", d)),\n\(f.name)\n"
        }
        m3u8 += "#EXT-X-ENDLIST\n"

        let playlistURL = workDir.appendingPathComponent("local.m3u8")
        try m3u8.data(using: .utf8)?.write(to: playlistURL)

        try FileManager.default.createDirectory(at: Paths.recordingsRoot, withIntermediateDirectories: true)
        let baseName = "\(Format.sanitizeUsername(username))_\(Format.fileStamp(partStart))_p\(partIndex)"

        // Adopts a finished MP4 sitting in the work dir: move it to its final name,
        // emit the part event, clean up. Returns nil when the move fails.
        func adoptMP4(from tmp: URL) -> PartSummary? {
            let finalURL = Paths.recordingsRoot.appendingPathComponent("\(baseName).mp4")
            try? FileManager.default.removeItem(at: finalURL)
            guard (try? FileManager.default.moveItem(at: tmp, to: finalURL)) != nil else { return nil }
            let bytes = fileSize(at: finalURL)
            try? FileManager.default.removeItem(at: workDir)
            onEvent(.partFinished(path: finalURL.path, bytes: bytes, duration: totalDuration,
                                  format: "mp4", quality: qualityLabel))
            priorSeconds += totalDuration
            return PartSummary(path: finalURL.path, bytes: bytes, duration: totalDuration, format: "mp4")
        }

        // Attempt 1: lossless passthrough remux of the local playlist into MP4
        // (no re-encode, original quality).
        let exportA = workDir.appendingPathComponent("export-a.mp4")
        try? FileManager.default.removeItem(at: exportA)
        if await passthroughExport(assetURL: playlistURL, output: exportA),
           let summary = adoptMP4(from: exportA) {
            return summary
        }

        // Attempts 2 and 3 work on the raw concatenated stream (no playlist involved).
        // fMP4 sources concatenate into a valid fragmented MP4; TS into MPEG-TS.
        let concatURL = workDir.appendingPathComponent("concat.\(mapFile != nil ? "mp4" : "ts")")
        try concatFiles(in: workDir, names: (mapFile.map { [$0] } ?? []) + files.map { $0.name }, to: concatURL)

        // Attempt 2: passthrough export straight from the raw stream.
        let exportB = workDir.appendingPathComponent("export-b.mp4")
        try? FileManager.default.removeItem(at: exportB)
        if await passthroughExport(assetURL: concatURL, output: exportB),
           let summary = adoptMP4(from: exportB) {
            return summary
        }

        // Attempt 3: sample-level passthrough remux (AVAssetReader/Writer). Handles
        // streams the export session refuses — still without re-encoding.
        let exportC = workDir.appendingPathComponent("export-c.mp4")
        try? FileManager.default.removeItem(at: exportC)
        if await Self.remuxToMP4(inputURL: concatURL, outputURL: exportC),
           let summary = adoptMP4(from: exportC) {
            return summary
        }

        // Attempt 4: keep the raw stream. fMP4 sources are already valid MP4 data
        // (fragmented) and play natively; TS keeps .ts for VLC / Infuse. Players sniff
        // the container, so the extension just sets expectations.
        let format = mapFile != nil ? "mp4" : "ts"
        let rawURL = Paths.recordingsRoot.appendingPathComponent("\(baseName).\(format)")
        try? FileManager.default.removeItem(at: rawURL)
        try FileManager.default.moveItem(at: concatURL, to: rawURL)
        let bytes = fileSize(at: rawURL)
        try? FileManager.default.removeItem(at: workDir)
        onEvent(.partFinished(path: rawURL.path, bytes: bytes, duration: totalDuration,
                              format: format, quality: qualityLabel))
        priorSeconds += totalDuration
        return PartSummary(path: rawURL.path, bytes: bytes, duration: totalDuration, format: format)
    }

    private func passthroughExport(assetURL: URL, output: URL) async -> Bool {
        let asset = AVURLAsset(url: assetURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        // Watchdog: never let a stuck export block the recorder forever.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(600))
            if session.status == .exporting { session.cancelExport() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        watchdog.cancel()

        return session.status == .completed && FileManager.default.fileExists(atPath: output.path)
    }

    // MARK: - Lossless remux fallback

    /// Container-level remux of any AVFoundation-readable file (raw .ts, fragmented
    /// .mp4, local HLS) into a plain progressive .mp4 — compressed samples are passed
    /// through untouched (no re-encode, original quality). Static so one-off UI
    /// conversions (legacy .ts recordings) can use it too. Returns false on any
    /// problem; the caller then falls back to keeping the original file.
    static func remuxToMP4(inputURL: URL, outputURL: URL) async -> Bool {
        let asset = AVURLAsset(url: inputURL)
        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return false
        }

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { return false }

        var outputs: [AVAssetReaderTrackOutput] = []
        var inputs: [AVAssetWriterInput] = []
        let trackPairs = videoTracks.map { ($0, AVMediaType.video) }
            + audioTracks.map { ($0, AVMediaType.audio) }
        for (track, mediaType) in trackPairs {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // passthrough
            let hint = (try? await track.load(.formatDescriptions))?.first
            let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil,
                                           sourceFormatHint: hint)
            guard reader.canAdd(out), writer.canAdd(input) else { continue }
            reader.add(out)
            writer.add(input)
            outputs.append(out)
            inputs.append(input)
        }
        guard inputs.count == trackPairs.count, !inputs.isEmpty else { return false }

        reader.startReading()
        writer.startWriting()

        // Prime one sample per track so the writer session can start at the earliest PTS.
        var primed: [CMSampleBuffer?] = outputs.map { $0.copyNextSampleBuffer() }
        guard primed.allSatisfy({ $0 != nil }) else {
            reader.cancelReading()
            writer.cancelWriting()
            return false
        }
        let startPTS = primed.compactMap { $0 }
            .map { CMSampleBufferGetPresentationTimeStamp($0) }
            .min() ?? .zero
        writer.startSession(atSourceTime: startPTS)

        // Pump loop: pull compressed samples and push them into the MP4 untouched.
        var done = Array(repeating: false, count: inputs.count)
        var appendFailed = false
        let deadline = Date().addingTimeInterval(1800)   // absolute anti-hang cap
        while !Task.isCancelled {
            for i in inputs.indices where !done[i] {
                let input = inputs[i]
                while input.isReadyForMoreMediaData {
                    let buf = primed[i] ?? outputs[i].copyNextSampleBuffer()
                    primed[i] = nil
                    guard let buf else {
                        input.markAsFinished()
                        done[i] = true
                        break
                    }
                    if input.append(buf) {
                        // keep pumping while the input is ready
                    } else {
                        input.markAsFinished()
                        done[i] = true
                        appendFailed = true
                        break
                    }
                }
            }
            if appendFailed || done.allSatisfy({ $0 }) || Date() > deadline { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        if appendFailed || Task.isCancelled || done.contains(false) {
            reader.cancelReading()
            writer.cancelWriting()
            return false
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        let ok = writer.status == .completed && FileManager.default.fileExists(atPath: outputURL.path)
        if !ok { try? FileManager.default.removeItem(at: outputURL) }
        return ok
    }

    private func concatFiles(in root: URL, names: [String], to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        for name in names {
            let fileURL = root.appendingPathComponent(name)
            guard let input = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? input.close() }
            while true {
                let chunk = try input.read(upToCount: 1 << 20)
                guard let chunk, !chunk.isEmpty else { break }
                try out.write(contentsOf: chunk)
            }
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - FLV fallback (rare: room exposes no HLS at all)

    private func recordFLV(onEvent: @escaping @Sendable (RecorderEvent) -> Void) async throws {
        guard let flv = flvURL else { return }

        var req = URLRequest(url: flv)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let sink = DataSink(request: req)
        sink.start()
        onEvent(.status("Recording (FLV)…"))

        var lastBytes: Int64 = 0
        var lastGrowth = Date()
        while true {
            if Task.isCancelled { sink.stop(); break }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                sink.stop()
                break
            }
            let current = sink.totalBytes
            if current != lastBytes {
                lastBytes = current
                lastGrowth = Date()
                onEvent(.progress(bytes: current, seconds: priorSeconds + Date().timeIntervalSince(sink.startedAt)))
            } else if Date().timeIntervalSince(lastGrowth) > 45 {
                sink.stop()
                break
            }
            if sink.isFinished {
                break
            }
        }
        sink.stop()

        // Give the delegate a moment to flush, but never wait forever.
        var waited = 0.0
        while !sink.isFinished && waited < 10 {
            try? await Task.sleep(for: .seconds(0.5))
            waited += 0.5
        }

        let bytes = sink.totalBytes
        guard bytes > 0 else {
            sink.cleanup()
            throw RecorderError.noData("FLV connection closed with no data")
        }

        try FileManager.default.createDirectory(at: Paths.recordingsRoot, withIntermediateDirectories: true)
        let finalURL = Paths.recordingsRoot
            .appendingPathComponent("\(Format.sanitizeUsername(username))_\(Format.fileStamp(Date())).flv")
        try? FileManager.default.removeItem(at: finalURL)
        try sink.finishAndMove(to: finalURL)
        onEvent(.partFinished(path: finalURL.path, bytes: bytes,
                              duration: Date().timeIntervalSince(sink.startedAt), format: "flv", quality: qualityLabel))
    }

    // MARK: - Playlist parsing

    struct SegmentInfo {
        var seq: Int
        var url: URL
        var duration: Double
        var ext: String
    }

    struct MediaPlaylistInfo {
        var targetDuration: Double = 2
        var mediaSequence = 0
        var hasEndList = false
        var mapURI: String?
        var segments: [SegmentInfo] = []
    }

    static func parseMediaPlaylist(_ text: String, baseURL: URL) -> MediaPlaylistInfo {
        var info = MediaPlaylistInfo()
        var pendingDuration: Double?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                info.targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 2
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                info.mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                info.hasEndList = true
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attributeValue("URI", quoted: true, in: line) {
                    info.mapURI = uri
                }
            } else if line.hasPrefix("#EXTINF:") {
                let raw = line.dropFirst("#EXTINF:".count)
                let durText = raw.split(separator: ",").first.map(String.init) ?? String(raw)
                pendingDuration = Double(durText.trimmingCharacters(in: .whitespaces))
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: baseURL) else {
                    pendingDuration = nil
                    continue
                }
                var ext = url.pathExtension.lowercased()
                if ext.isEmpty || ext.count > 4 { ext = "ts" }
                let seq = info.mediaSequence + info.segments.count
                let dur = pendingDuration ?? 0
                info.segments.append(SegmentInfo(seq: seq, url: url.absoluteURL, duration: dur, ext: ext))
                pendingDuration = nil
            }
        }
        return info
    }

    private static func attributeValue(_ key: String, quoted: Bool = false, in line: String) -> String? {
        let pattern = quoted ? "\(key)=\"([^\"]+)\"" : "\(key)=(\\d+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

// MARK: - FLV stream sink (delegate-based, memory safe)

private final class DataSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let startedAt = Date()
    private(set) var totalBytes: Int64 = 0
    private(set) var isFinished = false

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var workFile: URL
    private var handle: FileHandle?

    init(request: URLRequest) {
        let tmp = Paths.recordingsRoot.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        workFile = tmp.appendingPathComponent("stream.flv")
        FileManager.default.createFile(atPath: workFile.path, contents: nil)
        handle = try? FileHandle(forWritingTo: workFile)
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: request)
    }

    func start() { task?.resume() }
    func stop() { task?.cancel() }

    func finishAndMove(to dest: URL) throws {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: workFile, to: dest)
        let dir = workFile.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        session?.invalidateAndCancel() // release the URLSession<->delegate retain cycle
        session = nil
    }

    func cleanup() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: workFile.deletingLastPathComponent())
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        totalBytes += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        isFinished = true
    }
}
