import SwiftUI
import AVKit
import AVFoundation

// MARK: - Root

struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var newUsername = ""
    @State private var showSettings = false
    @State private var showRecordings = false
    @State private var preview: PreviewTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        headerCard
                        addCard
                        if app.users.isEmpty {
                            emptyState
                        } else {
                            GlassGroup {
                                VStack(spacing: 14) {
                                    ForEach(app.users) { user in
                                        UserRow(user: user,
                                                checking: app.isChecking(username: user.username),
                                                onCheck: { Task { await app.checkNow(username: user.username) } },
                                                onPreview: { preview = PreviewTarget(username: user.username) },
                                                onToggleAuto: { app.toggleAutoRecord(user.username) },
                                                onDelete: { app.removeUser(user.username) })
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .liquidScrollEdgeFix()
            .navigationTitle("Live Glass")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showRecordings = true } label: {
                        Image(systemName: "folder")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showRecordings) { RecordingsView() }
            .sheet(item: $preview) { target in
                PreviewSheet(username: target.username)
            }
        }
        .onAppear { app.resumeIfNeeded() }
    }

    private var headerCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.monitoringActive ? "Monitoring" : "Paused")
                        .font(.title2.weight(.bold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { app.monitoringActive },
                    set: { _ in app.toggleMonitoring() }
                ))
                .labelsHidden()
                .tint(.teal)
            }
            if app.monitoringActive {
                HStack(spacing: 14) {
                    statChip(icon: "person.2", text: "\(app.users.count)")
                    statChip(icon: "dot.radiowave.left.and.right.right", text: "\(app.liveCount) live")
                    statChip(icon: "record.circle", text: "\(app.recordingCount) rec")
                    if app.keepAliveActive {
                        statChip(icon: "waveform", text: "24/7 on")
                    }
                    Spacer()
                }
            }
        }
        .liquidGlass()
    }

    private var subtitle: String {
        if app.users.isEmpty { return "Add a TikTok username below to begin" }
        if !app.lastGlobalError.isEmpty { return app.lastGlobalError }
        if app.monitoringActive && app.keepAliveActive {
            return "Runs in the background 24/7 • keep-alive on"
        }
        return app.monitoringActive ? "Monitoring while the app is open" : "Toggle on to start watching"
    }

    private var addCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "at")
                .foregroundStyle(.secondary)
            TextField("username", text: $newUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .onSubmit(addUser)
            Button(action: addUser) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .disabled(newUsername.trimmingCharacters(in: .whitespaces).isEmpty)
            .buttonStyle(.plain)
        }
        .liquidGlass(cornerRadius: 22, padding: 14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No one is being watched yet")
                .font(.headline)
            Text("Enter a TikTok @username above. When they go live, Live Glass records the stream at max quality — even with the app in the background.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .liquidGlass(cornerRadius: 26, padding: 22)
    }

    private func addUser() {
        app.addUser(newUsername)
        newUsername = ""
    }

    private func statChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.14), in: Capsule())
    }
}

struct PreviewTarget: Identifiable {
    let id = UUID()
    let username: String
}

// MARK: - User row

struct UserRow: View {
    let user: WatchedUser
    let checking: Bool
    let onCheck: () -> Void
    let onPreview: () -> Void
    let onToggleAuto: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                statusDot
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.nickname.isEmpty ? "@\(user.username)" : user.nickname)
                        .font(.headline)
                    Text("@\(user.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if user.isLive || !user.lastError.isEmpty {
                    StatusPill(text: pillText, kind: user.pillKind)
                }
            }
            HStack {
                Text(user.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            HStack(spacing: 10) {
                rowButton(icon: checking ? "hourglass" : "arrow.clockwise", label: checking ? "Checking" : "Check") { onCheck() }
                    .disabled(checking)
                rowButton(icon: user.isLive ? "play.tv.fill" : "play.tv", label: "Preview") { onPreview() }
                rowButton(icon: user.autoRecord ? "record.circle.fill" : "record.circle",
                          label: user.autoRecord ? "Auto-rec ON" : "Auto-rec off",
                          prominent: user.autoRecord) { onToggleAuto() }
                Spacer()
            }
        }
        .liquidGlass(cornerRadius: 26, padding: 16)
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: {
                Label("Stop watching", systemImage: "trash")
            }
        }
    }

    private var pillText: String {
        if user.isLive && appIsRecording { return "REC" }
        if user.isLive { return "LIVE" }
        return "ERR"
    }

    private var appIsRecording: Bool {
        user.qualityLabel.hasPrefix("Recording")
    }

    @ViewBuilder
    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(user.isLive ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            if appIsRecording {
                Image(systemName: "record.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            }
        }
    }

    private func rowButton(icon: String, label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(prominent ? Color.teal.opacity(0.25) : Color.secondary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live preview

struct PreviewSheet: View {
    let username: String
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var errorText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else if loading {
                    ProgressView("Connecting to @\(username)…")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(errorText.isEmpty ? "User is not live right now." : errorText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("@\(username)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: URL(string: "https://www.tiktok.com/@\(username)/live")!) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadStream() }
        .onDisappear { player?.pause() }
    }

    private func loadStream() async {
        do {
            let info = try await TikTokAPI.shared.fetchLiveInfo(username: username, cookies: app.settings.cookies)
            guard info.isLive, !info.hlsURL.isEmpty, let url = URL(string: info.hlsURL) else {
                loading = false
                return
            }
            let p = AVPlayer(url: url)
            player = p
            loading = false
            p.play()
        } catch {
            errorText = error.localizedDescription
            loading = false
        }
    }
}

// MARK: - Recordings list

struct RecordingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var playing: RecordingItem?
    @State private var shareItem: RecordingItem?
    @State private var confirmDelete: RecordingItem?

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        if app.recordings.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "tray")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.secondary)
                                Text("No recordings yet")
                                    .font(.headline)
                                Text("Finished recordings appear here — inside the app's Documents/Recordings folder, also visible in the Files app.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .liquidGlass(cornerRadius: 26, padding: 22)
                            .padding(.top, 30)
                        } else {
                            GlassGroup {
                                VStack(spacing: 12) {
                                    ForEach(app.recordings.sorted { $0.startedAt > $1.startedAt }) { item in
                                        RecordingRow(item: item,
                                                     onPlay: playing == nil ? { playing = item } : nil,
                                                     onShare: { shareItem = item },
                                                     onDelete: { confirmDelete = item })
                                    }
                                }
                            }
                            Text("Total saved: \(Format.size(app.totalRecordedBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $playing) { item in
                FilePlayerSheet(item: item)
            }
            .sheet(item: $shareItem) { item in
                let url = Paths.absoluteURL(forRelativePath: item.relativePath)
                ShareSheet(items: [url])
            }
            .confirmationDialog("Delete this recording?", isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let item = confirmDelete { app.deleteRecording(item) }
                    confirmDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            }
        }
    }
}

// MARK: - Recording row

struct RecordingRow: View {
    let item: RecordingItem
    let onPlay: (() -> Void)?
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if item.state == .recording {
                    ProgressView()
                        .controlSize(.small)
                } else if item.state == .ready {
                    Image(systemName: iconForFormat)
                        .font(.title3)
                        .foregroundStyle(.teal)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.state == .recording ? "@\(item.username) — capturing…" : (item.fileName.isEmpty ? "@\(item.username)" : item.fileName))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                    Text(metaLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.state == .recording {
                    StatusPill(text: "REC", kind: .recording)
                }
            }
            HStack(spacing: 14) {
                if let onPlay, item.isVideoPlayableInApp {
                    action(icon: "play.fill", text: "Play") { onPlay() }
                }
                if item.state == .ready && !item.relativePath.isEmpty {
                    action(icon: "square.and.arrow.up", text: "Share") { onShare() }
                }
                if item.state != .recording {
                    action(icon: "trash", text: "Delete") { onDelete() }
                }
                Spacer()
                if item.state == .ready && !item.isVideoPlayableInApp {
                    Text("Open in VLC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !item.note.isEmpty {
                HStack {
                    Text(item.note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }
        }
        .liquidGlass(cornerRadius: 24, padding: 14)
    }

    private var iconForFormat: String {
        item.format == "flv" ? "film.stack" : "video"
    }

    private var metaLine: String {
        var parts: [String] = []
        parts.append(Format.date(item.startedAt))
        if item.durationSeconds > 0 { parts.append(Format.duration(item.durationSeconds)) }
        if item.bytes > 0 { parts.append(Format.size(item.bytes)) }
        if !item.quality.isEmpty { parts.append(item.quality) }
        parts.append(item.format.uppercased())
        return parts.joined(separator: " • ")
    }

    private func action(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(text)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Players & share sheet

struct FilePlayerSheet: View {
    let item: RecordingItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(item.fileName)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                let url = Paths.absoluteURL(forRelativePath: item.relativePath)
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension AppState {
    func deleteRecording(_ item: RecordingItem) {
        let url = Paths.absoluteURL(forRelativePath: item.relativePath)
        try? FileManager.default.removeItem(at: url)
        recordings.removeAll { $0.id == item.id }
        save()
    }
}
