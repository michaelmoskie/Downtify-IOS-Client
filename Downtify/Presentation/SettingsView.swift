import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.downtifyPalette) private var palette
    @Binding var appearance: DowntifyAppearance
    @Binding var language: String
    @Binding var networkOperationLimit: Int
    @ObservedObject var playback: PlaybackController
    @AppStorage("debug.networkOverlay.enabled") private var networkOverlayEnabled = false
    @State private var showingAbout = false
    @AppStorage(DowntifyTheme.storageKey) private var themeJSON = ""
    @AppStorage("downtify.theme.imported") private var importedThemeJSON = ""
    @State private var importingTheme = false
    @State private var exportingTheme = false
    @State private var themeError: String?
    @State private var exportDocument = ThemeDocument(data: Data())

    private let languages: [(String, String)] = [
        ("system", "System default"), ("bg", "Български"), ("en", "English"),
        ("fr", "Français"), ("el", "Ελληνικά"), ("hu", "Magyar"),
        ("pt-BR", "Português (Brasil)"), ("es", "Español"), ("tr", "Türkçe"),
        ("de", "Deutsch")
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Autoplay", isOn: Binding(get: { playback.autoplay }, set: { playback.setAutoplay($0) }))
                    .tint(palette.brand)
                Text("When your music ends, keep playing similar songs.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Crossfade")
                        Spacer()
                        Group {
                            if playback.crossfade == 0 { Text("Off") } else { Text("\(Int(playback.crossfade)) s") }
                        }
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { playback.crossfade }, set: { playback.setCrossfade($0) }),
                           in: 0...PlaybackCrossfade.maximum, step: 1)
                        .tint(palette.brand)
                        .accessibilityLabel("Crossfade")
                        .accessibilityValue(playback.crossfade == 0 ? String(localized: "Off")
                                            : String(localized: "\(Int(playback.crossfade)) seconds"))
                }
                Text("Blends the end of each song into the next. Songs that follow each other on an album stay gapless.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Switch quality immediately", isOn: Binding(
                    get: { playback.immediateQualitySwitch },
                    set: { playback.setImmediateQualitySwitch($0) }
                ))
                Text("When off, the current song keeps its quality when possible. The next song uses the new network’s quality.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    EqualizerView(playback: playback)
                } label: {
                    LabeledContent("Equalizer") {
                        Text(LocalizedStringKey(!playback.equalizer.enabled ? "Off" : playback.equalizer.preset?.name ?? "Custom"))
                    }
                }
                .accessibilityIdentifier("settings.equalizer")
            } header: {
                Text("Playback")
            }
            Section("Diagnostics") {
                Toggle("Network debug overlay", isOn: $networkOverlayEnabled)
                Text("Shows active and waiting network work, playback queue depth, and offline transfer state.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Advanced") {
                Stepper("Concurrent network requests: \(networkOperationLimit)", value: $networkOperationLimit,
                        in: NetworkOperationCoordinator.allowedLimits)
                Text("Limits simultaneous network activity, including offline downloads. Changes apply immediately.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Appearance") {
                Picker("Color mode", selection: $appearance) {
                    ForEach(DowntifyAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .accessibilityHint("Choose the app color appearance")
                Picker("Theme", selection: Binding(get: { selectedTheme }, set: selectTheme)) {
                    Text("Original").tag("original")
                    Text("Redesign").tag("redesign")
                    if let importedTheme {
                        Text(importedTheme.name).tag("imported")
                    } else if selectedTheme == "imported", let currentTheme {
                        Text(currentTheme.name).tag("imported")
                    }
                }
                Button("Import theme…") { importingTheme = true }
                Button("Export selected theme…") {
                    do {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        exportDocument = ThemeDocument(data: try encoder.encode(currentTheme ?? DowntifyTheme.bundled("original")))
                        exportingTheme = true
                    } catch { themeError = "Could not prepare the theme file." }
                }
                Text("Import a JSON theme from Files. Changes apply immediately; OLED appearance keeps its black background.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("App language", selection: $language) {
                    ForEach(languages, id: \.0) { code, title in
                        Text(code == "system" ? String(localized: "System default") : title).tag(code)
                    }
                }
                .accessibilityHint("Choose the language used in the app")
                Text("Some server supplied content, including music titles and descriptions, stays in its original language.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("About") {
                Button("About Downtify") { showingAbout = true }
                LabeledContent("Version", value: versionText)
            }
        }
        .scrollContentBackground(palette.redesign("settings") ? .hidden : .automatic)
        .background(palette.background.ignoresSafeArea())
        .fileImporter(isPresented: $importingTheme, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 16_385) ?? Data()
                let theme = try DowntifyTheme.decode(data)
                let encoded = String(decoding: try JSONEncoder().encode(theme), as: UTF8.self)
                importedThemeJSON = encoded
                themeJSON = encoded
            } catch { themeError = "Could not import this theme. Check that it follows the documented theme format." }
        }
        .fileExporter(isPresented: $exportingTheme, document: exportDocument,
                      contentType: .json, defaultFilename: "Downtify Theme") { result in
            if case .failure = result { themeError = "Could not export the theme." }
        }
        .alert("Theme error", isPresented: Binding(get: { themeError != nil }, set: { if !$0 { themeError = nil } })) {
            Button("OK", role: .cancel) { themeError = nil }
        } message: { Text(themeError ?? "") }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showingAbout) {
            NavigationStack { AboutView(version: versionText) }
        }
    }

    @Environment(\.dismiss) private var dismiss
    private var currentTheme: DowntifyTheme? { try? DowntifyTheme.decode(Data(themeJSON.utf8)) }
    private var importedTheme: DowntifyTheme? { try? DowntifyTheme.decode(Data(importedThemeJSON.utf8)) }
    private var selectedTheme: String {
        guard let currentTheme else { return "original" }
        if currentTheme == (try? DowntifyTheme.bundled("original")) { return "original" }
        if currentTheme == (try? DowntifyTheme.bundled("redesign")) || currentTheme == .example { return "redesign" }
        return "imported"
    }
    private func selectTheme(_ name: String) {
        do {
            if name == "imported" {
                guard importedTheme != nil else { throw DowntifyTheme.ThemeError.invalid }
                themeJSON = importedThemeJSON
            } else {
                // Keep a previously imported theme when switching from older app versions.
                if selectedTheme == "imported", importedTheme == nil { importedThemeJSON = themeJSON }
                let theme = try DowntifyTheme.bundled(name)
                themeJSON = String(decoding: try JSONEncoder().encode(theme), as: UTF8.self)
            }
        } catch { themeError = "Could not load the selected theme." }
    }
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

struct AboutView: View {
    let version: String
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .center, spacing: 8) {
                    Text("Downtify").font(.title.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
            }
            Section {
                Text("Michael Moskie")
                    .frame(maxWidth: .infinity, alignment: .center)
            } header: {
                aboutSectionHeader("Author")
            }
            Section {
                Text("Version \(version)")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                ForEach(Array(releaseNotes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                aboutSectionHeader("What's new in this build")
            }
            Section {
                Link("iOS client repository", destination: URL(string: "https://github.com/michaelmoskie/Downtify-IOS-Client")!)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                Link("Server source code", destination: URL(string: "https://github.com/henriquesebastiao/downtify")!)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                Link("Report a bug", destination: URL(string: "https://github.com/michaelmoskie/Downtify-IOS-Client/issues")!)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } header: {
                aboutSectionHeader("Project")
            }
            Section {
                Text("Downtify for iOS is an independent client for the Downtify server. Artwork, names, and media are supplied by your server and their respective rights holders.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("The iOS and Android clients are licensed under GNU GPL v3. The Downtify server is licensed under GNU AGPL v3.")
                    .fixedSize(horizontal: false, vertical: true)
                Link("iOS client license (GPL-3.0)", destination: URL(string: "https://github.com/michaelmoskie/Downtify-IOS-Client/blob/main/LICENSE")!)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                Link("Server license (AGPL-3.0)", destination: URL(string: "https://github.com/henriquesebastiao/downtify/blob/main/LICENSE")!)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                Link("Android reference app license (GPL-3.0)", destination: URL(string: "https://github.com/henriquesebastiao/downtify-android/blob/100be83e49c3250424e6326670a73bff69325b73/LICENSE")!)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } header: {
                aboutSectionHeader("Acknowledgments and licenses")
            }
            Section {
                Text("Downtify is provided as-is. Availability and playback depend on your server and its media sources.")
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                aboutSectionHeader("Disclaimer")
            }
        }
        .navigationTitle("About")
        .downtifyScrollEndClearance()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func aboutSectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var releaseNotes: [String] {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return notes
    }
}

private struct ThemeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
