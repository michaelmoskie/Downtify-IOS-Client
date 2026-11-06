import SwiftUI

struct PodcastsView: View {
    let connection: ConnectionService
    let playback: PlaybackController
    private let api = PodcastsAPI()
    @State private var session: DeviceSession?
    @State private var connectionFailed = false
    @State private var navigationID = UUID()

    var body: some View {
        NavigationStack {
            if let session {
                PodcastShowsList(api: api, session: session, connection: connection, playback: playback)
            } else if connectionFailed {
                ContentUnavailableView("Podcasts unavailable", systemImage: "mic.slash",
                                       description: Text("Could not read the saved server connection."))
            } else {
                ProgressView("Checking connection…")
            }
        }
        .id(navigationID)
        .task {
            do {
                for await value in try await connection.sessionUpdates() {
                    guard !Task.isCancelled else { return }
                    if session != value { navigationID = UUID() }
                    session = value
                    connectionFailed = value == nil
                }
            } catch {
                connectionFailed = true
            }
        }
    }
}

private struct PodcastShowsList: View {
    let api: PodcastsAPI
    let session: DeviceSession
    let connection: ConnectionService
    let playback: PlaybackController
    @State private var shows: [PodcastShow]?
    @State private var unavailable = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if unavailable {
                ContentUnavailableView("Podcasts unavailable", systemImage: "mic.slash",
                                       description: Text("This server does not advertise podcast support."))
            } else if let shows, !shows.isEmpty {
                List {
                    ForEach(shows) { show in
                        NavigationLink {
                            PodcastEpisodesList(show: show, api: api, session: session,
                                                connection: connection, playback: playback)
                        } label: {
                            DowntifyMediaRow(title: show.name, subtitle: show.author ?? "") {
                                PodcastArtwork(show: show, size: 48)
                            } accessory: { EmptyView() }
                        }
                    }
                    if loadFailed { Text("Could not refresh podcasts. Pull to retry.").font(.footnote) }
                }
                .refreshable { await load() }
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Could not load podcasts", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else if shows != nil {
                List {
                    ContentUnavailableView("No subscribed shows", systemImage: "mic",
                                           description: Text("Subscribe from the Downtify web app."))
                }
                .refreshable { await load() }
            } else {
                ProgressView("Loading podcasts…")
            }
        }
        .navigationTitle("Podcasts")
        .task(id: session) {
            shows = nil
            unavailable = false
            loadFailed = false
            await load()
        }
    }

    private func load() async {
        do {
            let result = try await api.shows(session: session)
            guard !Task.isCancelled else { return }
            shows = result
            loadFailed = false
        } catch PodcastAPIError.unsupported {
            guard !Task.isCancelled else { return }
            shows = nil
            unavailable = true
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
            await verifyPodcastSession(error, connection: connection, session: session)
        }
    }
}

private struct PodcastEpisodesList: View {
    let show: PodcastShow
    let api: PodcastsAPI
    let session: DeviceSession
    let connection: ConnectionService
    let playback: PlaybackController
    @State private var content: PodcastShowEpisodes?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let content {
                List {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            PodcastArtwork(show: content.show, size: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                if let author = content.show.author, !author.isEmpty {
                                    Text(author).font(.headline)
                                }
                                if let description = content.show.description, !description.isEmpty {
                                    Text(podcastDescription(description)).font(.subheadline)
                                }
                            }
                        }
                    }
                    Section("Episodes") {
                        if content.episodes.isEmpty { Text("No episodes available.") }
                        ForEach(content.episodes) { episode in
                            NavigationLink {
                                PodcastEpisodeView(show: content.show, episode: episode, api: api, session: session,
                                                   connection: connection, playback: playback) { updated in
                                    guard let current = self.content else { return }
                                    self.content = PodcastShowEpisodes(show: current.show, episodes: current.episodes.map {
                                        $0.id == updated.id ? updated : $0
                                    })
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(episode.title).font(.headline)
                                    PodcastEpisodeMetadata(episode: episode)
                                    if episode.isDownloaded {
                                        Label("Downloaded on server", systemImage: "checkmark.circle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if loadFailed { Text("Could not refresh episodes. Pull to retry.").font(.footnote) }
                }
                .refreshable { await load() }
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Could not load episodes", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ProgressView("Loading episodes…")
            }
        }
        .navigationTitle(show.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if content == nil { await load() } }
    }

    private func load() async {
        do {
            let result = try await api.episodes(showID: show.id, session: session)
            guard !Task.isCancelled else { return }
            content = result
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
            await verifyPodcastSession(error, connection: connection, session: session)
        }
    }
}

private struct PodcastEpisodeView: View {
    let show: PodcastShow
    @State var episode: PodcastEpisode
    let api: PodcastsAPI
    let session: DeviceSession
    let connection: ConnectionService
    @ObservedObject var playback: PlaybackController
    let didDownload: (PodcastEpisode) -> Void
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadFailed = false

    private var isSelected: Bool { playback.podcast?.episode.id == episode.id }
    private var isPlaying: Bool {
        isSelected && [.loading, .playing, .buffering].contains(playback.phase)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
                PodcastArtwork(show: show, size: 120)
                    .accessibilityHidden(true)
                Text(episode.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(show.name).font(.headline).foregroundStyle(.secondary)
                PodcastEpisodeMetadata(episode: episode)
                if isSelected, case .failed(let failure) = playback.phase {
                    Label(playbackFailureMessage(failure, isPodcast: true), systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(DowntifyStyle.error)
                } else if isPlaying {
                    Text("Current episode").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    let progress = playback.podcastProgress(for: episode)
                    if progress.played == true {
                        Text("Played").font(.subheadline).foregroundStyle(.secondary)
                    } else if progress.position > 0 {
                        Text("Resume at \(spokenDuration(progress.position))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if episode.isDownloaded || episode.publisherAudioURL != nil {
                    Button(isPlaying ? "Pause" : "Play episode", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                        if isPlaying { playback.pause() }
                        else { playback.playEpisode(episode, from: show, session: session) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("No supported audio source is available. Try downloading the episode to your server.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if episode.isDownloaded {
                    Label("Downloaded on server", systemImage: "checkmark.circle")
                } else if downloadTask != nil {
                    ProgressView("Downloading to server…")
                } else {
                    Button("Download to server", systemImage: "arrow.down.circle") { download() }
                        .buttonStyle(.bordered)
                }
                if downloadFailed {
                    Text("Could not download this episode. Try again.").font(.footnote).foregroundStyle(DowntifyStyle.error)
                }
                if let description = episode.description, !description.isEmpty {
                    Text("Episode notes").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(podcastDescription(description)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private func download() {
        guard downloadTask == nil else { return }
        downloadFailed = false
        downloadTask = Task {
            defer { if !Task.isCancelled { downloadTask = nil } }
            do {
                let updated = try await api.download(episodeID: episode.id, session: session)
                guard !Task.isCancelled else { return }
                episode = updated
                didDownload(updated)
            } catch {
                guard !Task.isCancelled else { return }
                downloadFailed = true
                await verifyPodcastSession(error, connection: connection, session: session)
            }
        }
    }
}

struct PodcastArtwork: View {
    let show: PodcastShow
    let size: CGFloat

    var body: some View {
        let url = show.artworkURL.flatMap { URL(string: $0) }.flatMap {
            $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil ? $0 : nil
        }
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.14))
                    Image(systemName: "mic.fill").font(.system(size: size / 3)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

private struct PodcastEpisodeMetadata: View {
    let episode: PodcastEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let season = episode.seasonNumber, let number = episode.episodeNumber {
                Text("Season \(season), episode \(number)")
            } else if let number = episode.episodeNumber {
                Text("Episode \(number)")
            }
            if let publishedAt = episode.publishedAt, let date = publishedDate(publishedAt) {
                Text(date, format: .dateTime.year().month().day())
            }
            if let duration = episode.durationSeconds, duration > 0 {
                Text(spokenDuration(duration))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func publishedDate(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

private func podcastDescription(_ html: String) -> String {
    html.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/li)>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func verifyPodcastSession(_ error: Error, connection: ConnectionService, session: DeviceSession) async {
    if case APIError.httpStatus(401, _) = error {
        _ = try? await connection.verifySession(expected: session)
    }
}
