import SwiftUI

struct SettingsView: View {
    @Binding var appearance: DowntifyAppearance
    @Binding var language: String
    @State private var showingAbout = false

    private let languages: [(String, String)] = [
        ("system", "System default"), ("bg", "Български"), ("en", "English"),
        ("fr", "Français"), ("el", "Ελληνικά"), ("hu", "Magyar"),
        ("pt-BR", "Português (Brasil)"), ("es", "Español"), ("tr", "Türkçe")
    ]

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(DowntifyAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .accessibilityHint("Choose the app color appearance")
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
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showingAbout) {
            NavigationStack { AboutView(version: versionText) }
        }
    }

    @Environment(\.dismiss) private var dismiss
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downtify").font(.title.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            Section {
                Text("Michael Moskie")
            } header: {
                aboutSectionHeader("Author")
            }
            Section {
                Text("Version \(version)")
                    .font(.headline)
                ForEach(releaseNotes, id: \.self) { note in
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
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
              let notes = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [] }
        return notes[version] ?? []
    }
}
