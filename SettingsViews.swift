import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()
                Form {
                    monitoringSection
                    recordingSection
                    storageSection
                    advancedSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: app.settings) { _, _ in app.save() }
        }
    }

    private var monitoringSection: some View {
        @Bindable var app = app
        return Section("Monitoring (24/7)") {
            Toggle(isOn: $app.settings.keepAlive) {
                Label("Background keep-alive", systemImage: "waveform")
            }
            LabeledContent {
                Text("\(Int(app.settings.pollInterval))s")
            } label: {
                Slider(value: $app.settings.pollInterval, in: 15...120, step: 5) {
                    Text("Check interval")
                } minimumValueLabel: {
                    Text("15s")
                } maximumValueLabel: {
                    Text("120s")
                }
            }
            Toggle(isOn: $app.settings.notifications) {
                Label("Notifications", systemImage: "bell")
            }
            Toggle(isOn: $app.settings.keepScreenAwake) {
                Label("Keep screen awake (foreground)", systemImage: "display")
            }
            Toggle(isOn: $app.settings.wifiOnly) {
                Label("Record only on WiFi", systemImage: "wifi")
            }
        }
    }

    private var recordingSection: some View {
        @Bindable var app = app
        return Section("Recording") {
            Picker("Split into parts every", selection: $app.settings.splitMinutes) {
                Text("Never (single file)").tag(0)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            Picker("Max simultaneous recordings", selection: $app.settings.maxConcurrent) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
                Text("4").tag(4)
            }
            Toggle(isOn: $app.settings.saveToPhotos) {
                Label("Auto-save finished parts to Photos", systemImage: "photo.on.rectangle")
            }
            LabeledContent("Quality", value: "Source max (1080p / Original)")
        }
    }

    private var storageSection: some View {
        @Bindable var app = app
        return Section("Storage") {
            LabeledContent {
                Text("\(Int(app.settings.minFreeGB)) GB")
            } label: {
                Slider(value: $app.settings.minFreeGB, in: 1...20, step: 1) {
                    Text("Stop when free space below")
                } minimumValueLabel: {
                    Text("1")
                } maximumValueLabel: {
                    Text("20")
                }
            }
            LabeledContent("Saved so far", value: Format.size(app.totalRecordedBytes))
        }
    }

    private var advancedSection: some View {
        @Bindable var app = app
        return Section {
            TextField("sessionid=…; tt-target-idc=…", text: $app.settings.cookies, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Advanced")
        } footer: {
            Text("Optional: paste browser cookies when TikTok blocks requests from your region. Get them from Safari on tiktok.com (or your PC browser), including tt-target-idc if present. Leave empty for most regions.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "1.0.0")
            LabeledContent("Recording method", value: "HLS capture + lossless remux")
            LabeledContent("Design", value: iOS26DesignLabel)
            VStack(alignment: .leading, spacing: 6) {
                Text("Recordings are saved in the app's Documents/Recordings folder (also visible in the Files app → On My iPhone → Live Glass). Personal archiving only — respect creators and TikTok's terms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iOS26DesignLabel: String {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return "Native Liquid Glass" }
        return "Glass (iOS 26 look, iOS 17 build)"
        #else
        return "Glass (iOS 26 look, iOS 17 build)"
        #endif
    }
}
