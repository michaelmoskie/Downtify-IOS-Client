import SwiftUI

struct LibraryHomeView: View {
    let server: SessionPresentationCoordinator.ServerSummary
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @Binding var appearance: DowntifyAppearance
    let connection: ConnectionService
    let serverDownloadQueue: ServerDownloadQueue
    let serverDownloads: ServerDownloadPresentationModel
    let signOut: @MainActor () async throws -> Void
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @EnvironmentObject private var catalogPresentation: CatalogPresentationModel
    @Environment(\.openURL) private var openURL
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("library.sort") private var sort = LibrarySort.recentlyAdded
    @AppStorage("library.descending") private var descending = true
    @AppStorage("library.grid") private var grid = true
    @AppStorage("downtify.language") private var language = "system"
    @AppStorage("debug.networkOverlay.enabled") private var networkOverlayEnabled = false
    @State private var category = Category.albums
    @State private var searchText = ""
    @State private var showingSignOutConfirmation = false
    @State private var signOutError: LocalizedStringKey?
    @State private var tab = Tab.home
    @State private var trashTrack: LibraryTrack?
    @State private var showingSettings = false
    @State private var showingCreatePlaylist = false
    @State private var newPlaylistName = ""

    private enum Tab { case home, library, search, discover, downloads, podcasts, adminTrash, more }
    private enum Category: String, CaseIterable, Identifiable {
        case songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists"
        var id: Self { self }
    }

    private func actionDescription(_ action: PendingCollectionAction) -> LocalizedStringKey {
        switch action.target {
        case .like(let id):
            let title = library.tracks.first(where: { $0.id == id })?.title ?? id
            return action.desiredValue ? "Like song: \(title)" : "Unlike song: \(title)"
        case .favorite(let name, _, _):
            return action.desiredValue ? "Favorite playlist: \(name)" : "Unfavorite playlist: \(name)"
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                browsePage(title: "Home") { homeContent }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Home", systemImage: "house") }.tag(Tab.home)

            NavigationStack {
                browsePage(title: "Library") { libraryContent }
                    .searchable(text: $searchText, prompt: "Filter your library")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Library", systemImage: "books.vertical") }.tag(Tab.library)

            NavigationStack {
                browsePage(title: "Search") { searchContent }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)

            NavigationStack {
                browsePage(title: "Discover") { discoveryContent }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("Discover", systemImage: "sparkles") }.tag(Tab.discover)

            DownloadsView(connection: connection, queue: serverDownloadQueue, serverDownloads: serverDownloads,
                          playback: playback)
                .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(Tab.downloads)

            PodcastsView(connection: connection, playback: playback)
                .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
                .tabItem { Label("Podcasts", systemImage: "mic") }.tag(Tab.podcasts)

            if server.role?.lowercased() == "admin" {
                NavigationStack {
                    AdminTrashView(connection: connection, role: server.role,
                                   pairingID: "\(server.serverID):\(server.deviceID):\(server.username ?? ""):\(server.role ?? "")")
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
                .tabItem { Label("Trash", systemImage: "trash") }.tag(Tab.adminTrash)
            }

            NavigationStack {
                Form {
                    Section("Pending Actions") {
                        if let error = collections.actionError {
                            Text(error).foregroundStyle(.red)
                            Button("Dismiss") { collections.clearError() }
                        }
                        if collections.pendingActions.isEmpty {
                            Text("No actions yet").foregroundStyle(.secondary)
                        }
                        ForEach(collections.pendingActions) { action in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(actionDescription(action))
                                switch action.status {
                                case .queued: Text("Queued").foregroundStyle(.secondary)
                                case .sent: Text("Sent").foregroundStyle(.secondary)
                                case .failed:
                                    Text(action.failure ?? String(localized: "Action failed")).foregroundStyle(.red)
                                }
                                if action.status != .queued {
                                    Button("Dismiss") { Task { await collections.dismissAction(action.id) } }
                                }
                            }
                        }
                    }
                    Section("Diagnostics") {
                        Toggle("Network debug overlay", isOn: $networkOverlayEnabled)
                        Text("Shows active and waiting network work, playback queue depth, and offline transfer state.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("About") {
                        NavigationLink("About Downtify") { AboutView(version: versionText) }
                        LabeledContent("Version", value: versionText)
                    }
                }
                .navigationTitle("More")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PlaybackDock(playback: playback) }
            .tabItem { Label("More", systemImage: "ellipsis") }.tag(Tab.more)
        }
        .confirmationDialog("Sign out of \(server.name)?", isPresented: $showingSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    do { try await signOut() } catch { signOutError = "Could not sign out. Please try again." }
                }
            }
        } message: {
            Text("You can reconnect to this server at any time.")
        }
        .alert("Sign out failed", isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
            Button("OK", role: .cancel) { signOutError = nil }
        } message: { if let signOutError { Text(signOutError) } }
        .overlay(alignment: .topTrailing) {
            if networkOverlayEnabled && tab != .more {
                NetworkDebugOverlay(playback: playback)
                    .padding(.top, 54)
                    .padding(.trailing, 8)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
        }
        .sheet(item: $trashTrack) { track in
            NavigationStack {
                MoveToTrashConfirmationView(track: track, connection: connection) {
                    trashTrack = nil
                    await refresh()
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(appearance: $appearance, language: $language)
            }
        }
        .sheet(isPresented: $showingCreatePlaylist, onDismiss: { newPlaylistName = "" }) {
            NavigationStack {
                Form {
                    TextField("Playlist name", text: $newPlaylistName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Playlist name")
                    PlaylistMutationFeedbackRow()
                }
                .navigationTitle("New Playlist")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingCreatePlaylist = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await collections.createPlaylist(name: name)
                                if collections.playlistMutationError == nil {
                                    showingCreatePlaylist = false
                                }
                            }
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  collections.mutationBusy)
                    }
                }
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private func browsePage<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: tab == .library && category == .songs ? .leading : .center, spacing: DowntifyStyle.Space.regular) {
                syncStatus
                content()
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .downtifyScrollEndClearance()
        .refreshable { await refresh() }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(title)
        .toolbarBackground(palette.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { accountMenu }
        }
        .navigationDestination(for: LibraryContext.self) { context in
            LibraryContextView(context: context, library: library, playback: playback,
                               serverDownloads: serverDownloads,
                               onMoveToTrash: server.role?.lowercased() == "admin" ? { trashTrack = $0 } : nil)
        }
    }

    private var accountMenu: some View {
        Menu {
            if let username = server.username {
                Label("Signed in as \(username)", systemImage: "person.crop.circle")
            }
            Picker("Appearance", selection: $appearance) {
                ForEach(DowntifyAppearance.allCases) { option in Text(option.label).tag(option) }
            }
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
            Button("Refresh library", systemImage: "arrow.clockwise") { Task { await refresh() } }
            Button("Sign out", role: .destructive) { showingSignOutConfirmation = true }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account options")
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func openProviderURL(_ value: String?) {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https" else { return }
        openURL(url)
    }
    private var likedEntry: LibraryBrowseEntry {
        LibraryBrowseEntry(id: "", context: .liked, title: String(localized: "Liked songs"), artist: "",
                           added: 0, count: collections.likedIDs?.count ?? 0,
                           artwork: collections.likedIDs?.lazy.compactMap { library.catalog.tracksByID[$0] }.first(where: \.hasCover))
    }

    private func playlistEntry(_ playlist: LibraryPlaylist) -> LibraryBrowseEntry {
        LibraryBrowseEntry(id: playlist.id, context: .playlist(playlist.name), title: playlist.title,
                           artist: playlist.mine == false ? playlist.owner ?? "" : "", added: 0,
                           count: playlist.trackIDs.count,
                           artwork: playlist.trackIDs.lazy.compactMap { library.catalog.tracksByID[$0] }.first(where: \.hasCover),
                           playlistCover: playlist.cover)
    }

    private func entry(_ context: LibraryContext) -> LibraryBrowseEntry? {
        switch context {
        case .album(let id): library.catalog.albumsByID[id]
        case .artist(let id): library.catalog.artistsByID[id]
        case .playlist(let name): collections.playlist(named: name).map(playlistEntry)
        case .liked: likedEntry
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        let newest = library.latestAlbums
        let recents = collections.recents.compactMap(entry)
        let fallback = (likedEntry.count > 0 ? [likedEntry] : []) + newest
        let jump = recents.isEmpty ? Array(fallback.prefix(12)) : recents
        let favorites = LibrarySort.alphabetical.ordered(
            (collections.playlists ?? []).filter { $0.favorite == true && $0.liked != true }.map(playlistEntry),
            descending: false
        )
        if !jump.isEmpty { shelf("Jump back in", entries: jump) }
        if !newest.isEmpty { shelf("Recently added", entries: newest) }
        if !favorites.isEmpty { shelf("Favorite playlists", entries: favorites) }
        if jump.isEmpty && newest.isEmpty && favorites.isEmpty {
            if library.tracks.isEmpty { emptyTracks }
            else {
                DowntifyUnavailableView(title: "Nothing to jump back into yet", symbol: "clock",
                                        message: Text("Play an artist or collection to see it here."))
            }
        }
        if collections.playlistState == .unavailable || collections.likesState == .unavailable {
            collectionStatus(.unavailable, cached: collections.playlists != nil || collections.likedIDs != nil,
                             title: "Likes or playlists could not be refreshed.")
        }
    }

    private func shelf(_ title: LocalizedStringKey, entries: [LibraryBrowseEntry]) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: entries, grid: !dynamicTypeSize.isAccessibilitySize)
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        ViewThatFits(in: .horizontal) {
            Picker("Library category", selection: $category) {
                ForEach(Category.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            Picker("Library category", selection: $category) {
                ForEach(Category.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
        }
        HStack {
            if category != .playlists { sortMenu }
            Spacer()
            if category != .songs && !dynamicTypeSize.isAccessibilitySize {
                Button { grid.toggle() } label: {
                    Image(systemName: grid ? "list.bullet" : "square.grid.2x2").downtifyControlTarget()
                }
                .accessibilityLabel(grid ? "Show as list" : "Show as grid")
            }
        }
        switch category {
        case .songs:
            let tracks = library.songs(sort: sort, descending: descending, query: query)
            if library.tracks.isEmpty { emptyTracks }
            else if tracks.isEmpty { ContentUnavailableView.search(text: searchText) }
            else { LibraryTrackList(tracks: tracks, context: nil, playback: playback,
                                    onMoveToTrash: server.role?.lowercased() == "admin" ? { trashTrack = $0 } : nil) }
        case .albums:
            browseGroups(Array(library.catalog.albumsByID.values), emptyTitle: "No albums")
        case .artists:
            browseGroups(Array(library.catalog.artistsByID.values), emptyTitle: "No artists")
        case .playlists:
            playlistContent
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        CatalogSearchView(catalog: catalogPresentation, library: library, playback: playback,
                          onDownloadAlbum: { url, tracks in Task { await serverDownloads.requestAlbum(url: url, expected: tracks) } },
                          albumDownloadState: { serverDownloads.actionState(forAlbumURL: $0) },
                          onDownload: { song in Task { await serverDownloads.request(song: song) } },
                          downloadState: { serverDownloads.actionState(for: $0) })
    }

    private var discoveryContent: some View {
        CatalogDiscoverView(
            catalog: catalogPresentation,
            libraryTracks: library.tracks,
            libraryArtists: discoveryLibraryArtists,
            libraryAlbums: Array(library.catalog.albumsByID.values).map {
                CatalogLibraryAlbum(artist: $0.artist, title: $0.title)
            },
            playlistNames: (collections.playlists ?? []).filter { $0.liked != true }.map(\.name),
            playlistIDs: (collections.playlists ?? []).filter { $0.liked != true }.map(\.id),
            shownArtists: [],
            onPlay: { song in playCatalogSong(song) },
            onDownload: { song in Task { await serverDownloads.request(song: song) } },
            onDownloadAlbum: { url, tracks in Task { await serverDownloads.requestAlbum(url: url, expected: tracks) } },
            downloadState: { serverDownloads.actionState(for: $0) },
            albumDownloadState: { serverDownloads.actionState(forAlbumURL: $0) },
            onOpenURL: { openProviderURL($0.absoluteString) }
        )
    }

    private var discoveryLibraryArtists: [CatalogLibraryArtist] {
        Dictionary(grouping: library.tracks, by: LibraryCatalog.artistName(_:)).map { name, tracks in
            CatalogLibraryArtist(name: name, tracks: tracks.count,
                                 liked: tracks.filter { collections.likedSet.contains($0.id) }.count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func playCatalogSong(_ song: CatalogSong) {
        if song.source == "library" {
            guard let track = song.libraryTrack(in: library.tracks) else { return }
            playback.replaceQueue([.library(track)])
        } else {
            playback.replaceQueue([.catalog(song)])
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { sort }, set: {
                guard sort != $0 else { return }
                sort = $0
                descending = $0.descendingByDefault
            })) {
                ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
            }
            Picker("Sort order", selection: $descending) {
                Text("Ascending").tag(false)
                Text("Descending").tag(true)
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down").padding(.vertical, 10)
        }
        .accessibilityLabel("Library sort, \(sort.label)")
    }

    @ViewBuilder
    private func browseGroups(_ entries: [LibraryBrowseEntry], emptyTitle: LocalizedStringKey) -> some View {
        let filtered = matching(entries)
        if library.tracks.isEmpty { emptyTracks }
        else if filtered.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: searchText) }
        else if filtered.isEmpty { ContentUnavailableView(emptyTitle, systemImage: "music.note") }
        else {
            LibraryEntryList(entries: sort.ordered(filtered, descending: descending),
                             grid: grid && !dynamicTypeSize.isAccessibilitySize)
        }
    }

    private func matching(_ entries: [LibraryBrowseEntry]) -> [LibraryBrowseEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) }
    }

    @ViewBuilder
    private var playlistContent: some View {
        collectionStatus(collections.playlistState, cached: collections.playlists != nil, title: "Playlists could not be refreshed.")
        if collections.supportsPlaylistEditing {
            Button("Create Playlist", systemImage: "plus") {
                showingCreatePlaylist = true
            }
            .disabled(collections.mutationBusy)
            .accessibilityHint("Create a new manual playlist")
        }
        if collections.likesState == .unavailable && collections.likedIDs == nil {
            collectionStatus(.unavailable, cached: false, title: "Liked songs are unavailable.")
        }
        let lists = (collections.playlists ?? []).filter { $0.liked != true }
        let own = matching(lists.filter { $0.mine != false }.map(playlistEntry))
        let shared = matching(lists.filter { $0.mine == false && $0.sharedWithMe == true }.map(playlistEntry))
        let others = matching(lists.filter { $0.mine == false && $0.sharedWithMe != true }.map(playlistEntry))
        let liked = collections.likedIDs == nil ? [] : matching([likedEntry])
        let favoriteIDs = Set(lists.filter { $0.favorite == true }.map(\.id))
        let pinned = own.filter { favoriteIDs.contains($0.id) } + liked + own.filter { !favoriteIDs.contains($0.id) }
        let useGrid = grid && !dynamicTypeSize.isAccessibilitySize
        if !pinned.isEmpty { LibraryEntryList(entries: pinned, grid: useGrid) }
        if !shared.isEmpty {
            Text("Shared with me").font(.headline).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: shared, grid: useGrid)
        }
        if !others.isEmpty {
            Text("Public playlists").font(.headline).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: others, grid: useGrid)
        }
        if pinned.isEmpty && shared.isEmpty && others.isEmpty && collections.playlistState == .ready {
            if !query.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView("No playlists", systemImage: "music.note.list")
            }
        }
    }

    @ViewBuilder
    private func collectionStatus(_ state: LibraryCollectionsModel.State, cached: Bool, title: LocalizedStringKey) -> some View {
        if state == .loading && !cached {
            ProgressView("Loading playlists and likes…")
        } else if state == .unavailable {
            Label(title, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Retry") { Task { await collections.refresh() } }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if library.state == .refreshing { ProgressView("Refreshing library…") }
        if !library.tracks.isEmpty {
            switch library.state {
            case .cachedError(let message), .storageFailure(let message):
                Label(LocalizedStringKey(message), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Showing saved music.").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var emptyTracks: some View {
        switch library.state {
        case .loading, .refreshing:
            ProgressView("Loading your library…").frame(maxWidth: .infinity, minHeight: 150)
        case .empty, .ready:
            DowntifyUnavailableView(title: "Your library is empty", symbol: "music.note.list",
                                    message: Text("Music saved on this server will appear here."),
                                    retry: { Task { await refresh() } })
        case .cachedError(let message), .storageFailure(let message):
            DowntifyUnavailableView(title: "Library unavailable", symbol: "exclamationmark.triangle",
                                    message: Text(LocalizedStringKey(message)), retry: { Task { await refresh() } })
        }
    }

    private func refresh() async {
        async let music: Void = library.refresh()
        async let lists: Void = collections.refresh()
        _ = await (music, lists)
    }
}

struct NetworkDebugOverlay: View {
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject private var downloads: OfflineDownloads
    @State private var network = NetworkOperationSnapshot(active: 0, maximum: 2, queued: 0,
                                                          foregroundActive: 0, backgroundActive: 0,
                                                          foregroundQueued: 0, backgroundQueued: 0,
                                                          recentFailures: [])

    var body: some View {
        let activeTransfers = downloads.currentDownloads.filter { $0.state == .transferring }.count
        let pausedTransfers = downloads.currentDownloads.filter { $0.state == .paused }.count
        VStack(alignment: .leading, spacing: 3) {
            Text("NET  \(network.active)/\(network.maximum)  ·  wait \(network.queued)")
            Text("FG \(network.foregroundActive) (+\(network.foregroundQueued))  BG \(network.backgroundActive) (+\(network.backgroundQueued))")
            Text("AHEAD \(playback.queue.upcomingCount)  ·  DL \(activeTransfers) active / \(pausedTransfers) paused")
            Text("PLAY  \(playbackStatus)")
            if !network.recentFailures.isEmpty {
                Divider().overlay(.secondary.opacity(0.25))
                Text("RECENT FAILURES · SAVED")
                    .foregroundStyle(.red)
                ForEach(Array(network.recentFailures.suffix(3).reversed()), id: \.self) { failure in
                    Text(failure)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5))
        .task {
            while !Task.isCancelled {
                network = await NetworkOperationCoordinator.shared.snapshot()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var playbackStatus: String {
        switch playback.phase {
        case .idle: "idle"
        case .loading: "loading"
        case .paused: "paused"
        case .playing: "playing"
        case .buffering: "buffering"
        case .ended: "ended"
        case .failed(let error): "failed: \(String(describing: error))"
        }
    }
}

private struct LibraryEntryList: View {
    let entries: [LibraryBrowseEntry]
    let grid: Bool

    var body: some View {
        if grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 12)], spacing: 12) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.context) {
                        VStack(alignment: .center, spacing: 6) {
                            artwork(entry, size: 108)
                            Text(entry.title).font(.headline).lineLimit(2)
                            Text(subtitle(entry)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 178, alignment: .top)
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.context) {
                        VStack(spacing: 6) {
                            artwork(entry, size: 54)
                            Text(entry.title).font(.headline)
                            Text(subtitle(entry)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func subtitle(_ entry: LibraryBrowseEntry) -> String {
        if !entry.artist.isEmpty { return entry.artist }
        return entry.count == 1 ? String(localized: "1 song") : String(localized: "\(entry.count) songs")
    }

    @ViewBuilder
    private func artwork(_ entry: LibraryBrowseEntry, size: CGFloat) -> some View {
        if entry.artwork != nil || entry.playlistCover?.isEmpty == false {
            TrackArtwork(track: entry.artwork, size: size, playlistCover: entry.playlistCover)
        } else {
            let symbol: String = switch entry.context {
            case .artist: "music.mic"
            case .album: "opticaldisc"
            case .playlist: "music.note.list"
            case .liked: "heart.fill"
            }
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
    }
}

private struct LibraryContextView: View {
    let context: LibraryContext
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    var onMoveToTrash: ((LibraryTrack) -> Void)? = nil
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @EnvironmentObject private var catalog: CatalogPresentationModel
    @EnvironmentObject private var downloads: OfflineDownloads
    @Environment(\.downtifyPalette) private var palette
    @State private var confirmingDownload = false
    @State private var downloadMessage: LocalizedStringKey?
    @State private var playlistSheet: PlaylistEditingSheet?
    @State private var playlistNameDraft = ""
    @State private var selectedTrackIDs: Set<String> = []

    private var playlist: LibraryPlaylist? {
        guard case .playlist(let name) = context else { return nil }
        return collections.playlist(named: name)
    }

    private var title: String {
        switch context {
        case .album(let id): library.catalog.albumsByID[id]?.title ?? String(localized: "Album")
        case .artist(let id): library.catalog.artistsByID[id]?.title ?? String(localized: "Artist")
        case .playlist: playlist?.title ?? String(localized: "Playlist")
        case .liked: String(localized: "Liked songs")
        }
    }

    var body: some View {
        let tracks = library.catalog.tracks(in: context, likedIDs: collections.likedIDs ?? [], playlist: playlist)
        ScrollView {
            VStack(alignment: .center, spacing: DowntifyStyle.Space.regular) {
                if let playlist, playlist.mine == false, let owner = playlist.owner, !owner.isEmpty {
                    Text("By \(owner)").foregroundStyle(.secondary)
                }
                if case .album(let id) = context, let album = library.catalog.albumsByID[id], !album.artist.isEmpty {
                    if let artistID = tracks.first?.artistID, library.catalog.artistsByID[artistID] != nil {
                        NavigationLink(album.artist, value: LibraryContext.artist(artistID))
                    } else {
                        Text(album.artist).foregroundStyle(.secondary)
                    }
                }
                if let cover = tracks.first(where: \.hasCover), playlist?.cover?.isEmpty != false {
                    TrackArtwork(track: cover, size: 160)
                } else if let cover = playlist?.cover, !cover.isEmpty {
                    TrackArtwork(track: tracks.first(where: \.hasCover), size: 160, playlistCover: cover)
                }
                actions(tracks)
                if let downloadMessage { Text(downloadMessage).font(.subheadline).foregroundStyle(.secondary) }
                PlaylistMutationFeedbackRow()
                status(tracks)
                if case .artist(let id) = context {
                    let albums = library.catalog.albums(for: id)
                    if catalog.externalCatalogAvailable, let artist = library.catalog.artistsByID[id] {
                        NavigationLink {
                            ArtistCatalogAlbumsView(artist: artist.title, library: library,
                                                    serverDownloads: serverDownloads, catalog: catalog)
                        } label: {
                            Label("Find more albums", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                    if !albums.isEmpty {
                        Text("Albums").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        LibraryEntryList(entries: albums, grid: false)
                    }
                }
                if !tracks.isEmpty {
                    Text("Songs").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LibraryTrackList(tracks: tracks, context: context, playback: playback,
                                     onMoveToTrash: onMoveToTrash)
                } else if let error = collections.actionError {
                    Text(error).foregroundStyle(.secondary)
                    Button("Dismiss") { collections.clearError() }
                }
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .downtifyScrollEndClearance()
        .refreshable {
            async let music: Void = library.refresh()
            async let lists: Void = collections.refresh()
            _ = await (music, lists)
        }
        .navigationTitle(title)
        .background(palette.background.ignoresSafeArea())
        .toolbar {
            if canEditTracks || canRenamePlaylist {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canRenamePlaylist {
                            Button("Rename Playlist", systemImage: "pencil") {
                                playlistNameDraft = playlist?.name ?? ""
                                playlistSheet = .rename
                            }
                        }
                        if canEditTracks {
                            Button("Add Tracks", systemImage: "plus") {
                                selectedTrackIDs = []
                                playlistSheet = .addTracks
                            }
                            Button("Remove Track Occurrence", systemImage: "minus.circle") {
                                playlistSheet = .removeOccurrence
                            }
                            Button("Reorder Tracks", systemImage: "arrow.up.arrow.down") {
                                playlistSheet = .reorder
                            }
                        }
                    } label: {
                        Image(systemName: "pencil.and.list")
                    }
                    .accessibilityLabel("Edit playlist")
                }
            }
        }
        .sheet(item: $playlistSheet) { sheet in
            if let playlist {
                switch sheet {
                case .rename:
                    NavigationStack {
                        Form {
                            TextField("Playlist name", text: $playlistNameDraft)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .accessibilityLabel("Playlist name")
                            PlaylistMutationFeedbackRow()
                        }
                        .navigationTitle("Rename Playlist")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { playlistSheet = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") {
                                    let name = playlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    Task {
                                        await collections.renamePlaylist(name: playlist.name, to: name)
                                        if collections.playlistMutationError == nil {
                                            playlistSheet = nil
                                        }
                                    }
                                }
                                .disabled(playlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                          playlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == playlist.name ||
                                          collections.mutationBusy)
                            }
                        }
                    }
                case .addTracks:
                    PlaylistTrackSelectionSheet(
                        tracks: LibraryTrackOrdering.sorted(library.tracks),
                        selectedTrackIDs: $selectedTrackIDs,
                        isBusy: collections.mutationBusy
                    ) { allowDuplicates in
                        let ids = LibraryTrackOrdering.sorted(library.tracks)
                            .filter { selectedTrackIDs.contains($0.id) }
                            .map(\.id)
                        Task {
                            await collections.addTracks(ids, to: playlist.name, allowDuplicates: allowDuplicates)
                            if collections.playlistMutationError == nil {
                                playlistSheet = nil
                            }
                        }
                    }
                case .removeOccurrence:
                    PlaylistOccurrenceRemovalSheet(
                        playlist: playlist,
                        catalog: library.catalog,
                        isBusy: collections.mutationBusy
                    ) { occurrence in
                        let rank = playlist.trackIDs.prefix(occurrence.position)
                            .filter { $0 == occurrence.trackID }.count
                        Task {
                            await collections.removePlaylistOccurrence(
                                trackID: occurrence.trackID, occurrence: rank, from: playlist.name
                            )
                        }
                    } onRemoveAll: { trackID in
                        Task { await collections.removeTracks([trackID], from: playlist.name) }
                    }
                case .reorder:
                    PlaylistReorderSheet(playlist: playlist, catalog: library.catalog,
                                         isBusy: collections.mutationBusy) { orderedIDs in
                        Task {
                            await collections.reorderPlaylist(playlist.name, trackIDs: orderedIDs)
                            if collections.playlistMutationError == nil {
                                playlistSheet = nil
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Download these songs for offline playback?", isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("Download songs") {
                var failures = 0
                var queued = Set<String>()
                for track in tracks where queued.insert(track.id).inserted {
                    do { try downloads.enqueue(track) } catch { failures += 1 }
                }
                downloadMessage = failures == 0 ? "Offline downloads requested." : "Some downloads could not be started."
            }
        }
    }

    private func actions(_ tracks: [LibraryTrack]) -> some View {
        HStack {
            if !tracks.isEmpty {
                Button("Play", systemImage: "play.fill") {
                    collections.record(context)
                    playback.setShuffle(false)
                    playback.replaceQueue(tracks)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    collections.record(context)
                    playback.replaceQueue(tracks, startingAt: Int.random(in: tracks.indices))
                    playback.setShuffle(true)
                } label: {
                    Image(systemName: "shuffle").downtifyControlTarget()
                }
                .accessibilityLabel("Shuffle songs")
            }
            if let playlist, playlist.favorite != nil {
                let favorite = collections.effectiveFavorite(playlist)
                Button {
                    Task { await collections.toggleFavorite(playlist.name) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: favorite ? "star.fill" : "star").downtifyControlTarget()
                        if collections.hasPendingFavorite(playlist.name) {
                            Text("Queued").font(.caption)
                        }
                    }
                }
                .disabled(collections.mutationBusy)
                .accessibilityLabel(favorite ? "Remove playlist from favorites" : "Favorite playlist")
                .accessibilityValue(collections.hasPendingFavorite(playlist.name) ? "Queued" : "")
            }
            if !tracks.isEmpty {
                Menu {
                    Button("Add songs to queue", systemImage: "text.append") { playback.append(tracks) }
                    Button("Download songs", systemImage: "arrow.down.circle") { confirmingDownload = true }
                } label: {
                    Image(systemName: "ellipsis.circle").downtifyControlTarget()
                }
                .accessibilityLabel("Collection actions")
            }
        }
    }

    private var canEditTracks: Bool {
        guard collections.supportsPlaylistEditing,
              let playlist,
              playlist.manual == true,
              playlist.canEditTracks == true else { return false }
        return true
    }

    private var canRenamePlaylist: Bool {
        guard collections.supportsPlaylistEditing,
              let playlist,
              playlist.manual == true,
              playlist.mine == true else { return false }
        return true
    }

    @ViewBuilder
    private func status(_ tracks: [LibraryTrack]) -> some View {
        let collectionState: LibraryCollectionsModel.State? = switch context {
        case .playlist: collections.playlistState
        case .liked: collections.likesState
        default: nil
        }
        let hasCache = context == .liked ? collections.likedIDs != nil : playlist != nil
        if collectionState == .unavailable {
            Label(hasCache ? "Showing saved collection. Refresh failed." : "Collection unavailable.",
                  systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            Button("Retry") { Task { await collections.refresh() } }
        } else if collectionState == .loading && !hasCache {
            ProgressView("Loading collection…")
        }
        switch library.state {
        case .cachedError(let message), .storageFailure(let message):
            Label(LocalizedStringKey(message), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Retry library refresh") { Task { await library.refresh() } }
        case .loading, .refreshing:
            if tracks.isEmpty { ProgressView("Loading songs…") }
        case .empty, .ready:
            if tracks.isEmpty && (collectionState == nil || collectionState == .ready || hasCache) {
                ContentUnavailableView("No songs available", systemImage: "music.note")
            }
        }
    }
}


/// Catalog browsing is scoped to this page so it does not replace the Search tab's results.
private struct ArtistCatalogAlbumsView: View {
    let artist: String
    @ObservedObject var library: LibraryPresentationModel
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    @ObservedObject var catalog: CatalogPresentationModel
    @State private var albums: [CatalogAlbum] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        List {
            if isLoading { ProgressView("Loading albums…") }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !isLoading && error == nil && albums.isEmpty {
                Text("No albums found.").foregroundStyle(.secondary)
            }
            ForEach(albums) { album in
                NavigationLink {
                    ArtistCatalogAlbumView(album: album, library: library, serverDownloads: serverDownloads, catalog: catalog)
                } label: {
                    VStack(alignment: .leading) {
                        Text(album.title)
                        Text(album.artist).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(artist)
        .task(id: catalog.session) {
            albums = []
            error = nil
            guard let session = catalog.session, catalog.externalCatalogAvailable else {
                isLoading = false
                error = String(localized: "Catalog is unavailable.")
                return
            }
            isLoading = true
            do {
                let results = try await CatalogAPI().searchAlbums(query: artist, limit: 50, session: session)
                guard !Task.isCancelled else { return }
                albums = results.filter { $0.artist.localizedCaseInsensitiveCompare(artist) == .orderedSame }
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

private enum PlaylistEditingSheet: String, Identifiable {
    case rename, addTracks, removeOccurrence, reorder
    var id: String { rawValue }
}

private struct PlaylistTrackSelectionSheet: View {
    let tracks: [LibraryTrack]
    @Binding var selectedTrackIDs: Set<String>
    let isBusy: Bool
    let onAdd: (Bool) -> Void
    @State private var allowDuplicates = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                PlaylistMutationFeedbackRow()
                Toggle("Add another copy of existing tracks", isOn: $allowDuplicates)
                ForEach(tracks) { track in
                    Button {
                        if selectedTrackIDs.contains(track.id) {
                            selectedTrackIDs.remove(track.id)
                        } else {
                            selectedTrackIDs.insert(track.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(track.title)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedTrackIDs.contains(track.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(track.title), \(track.artist)")
                    .accessibilityValue(selectedTrackIDs.contains(track.id) ? Text("Selected") : Text("Not selected"))
                }
            }
            .navigationTitle("Add Tracks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(allowDuplicates) }
                        .disabled(selectedTrackIDs.isEmpty || isBusy)
                }
            }
        }
    }
}

private struct ArtistCatalogAlbumView: View {
    let album: CatalogAlbum
    @ObservedObject var library: LibraryPresentationModel
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    @ObservedObject var catalog: CatalogPresentationModel
    @State private var songs: [CatalogSong] = []
    @State private var isLoading = true
    @State private var error: String?

    private func isInLibrary(_ song: CatalogSong) -> Bool {
        library.tracks.contains {
            $0.title.localizedCaseInsensitiveCompare(song.title) == .orderedSame &&
            $0.album.localizedCaseInsensitiveCompare(album.title) == .orderedSame &&
            ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist).localizedCaseInsensitiveCompare(album.artist) == .orderedSame
        }
    }

    private func canRequest(_ song: CatalogSong) -> Bool {
        guard catalog.externalCatalogAvailable, !isInLibrary(song), song.source != "library" else { return false }
        switch serverDownloads.actionState(for: song) {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func status(_ song: CatalogSong) -> String {
        if isInLibrary(song) || song.source == "library" { return String(localized: "In your library") }
        switch serverDownloads.actionState(for: song) {
        case .idle: return String(localized: "Add to library")
        case .submitting: return String(localized: "Requesting…")
        case .queued, .accepted: return String(localized: "Queued")
        case .partiallyAccepted: return String(localized: "Partially queued")
        case .outcomeUnknown: return String(localized: "Check queue")
        case .failed: return String(localized: "Retry")
        }
    }

    var body: some View {
        List {
            if isLoading { ProgressView("Loading album…") }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !isLoading && error == nil && songs.isEmpty { Text("No songs found.").foregroundStyle(.secondary) }
            let missing = songs.filter(canRequest)
            if !missing.isEmpty {
                Button("Add missing songs to library", systemImage: "plus.circle") {
                    Task { await serverDownloads.requestBatch(songs: missing) }
                }
            }
            ForEach(songs) { song in
                VStack(alignment: .leading) {
                    HStack {
                        Text(song.title)
                        Spacer()
                        Button(status(song)) { Task { await serverDownloads.request(song: song) } }
                            .disabled(!canRequest(song))
                    }
                    if case .failed(let message) = serverDownloads.actionState(for: song) {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !songs.isEmpty {
                Text("Songs are added after the server downloads them and the library syncs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(album.title)
        .task(id: catalog.session) {
            songs = []
            error = nil
            guard let session = catalog.session, catalog.externalCatalogAvailable else {
                isLoading = false
                error = String(localized: "Catalog is unavailable.")
                return
            }
            isLoading = true
            do {
                let id = album.deezerAlbumID ?? (album.source.lowercased() == "deezer" ? album.albumID : nil)
                if let id, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }), catalog.supportsDiscover == true {
                    songs = try await CatalogAPI().finderAlbum(id: id, session: session).tracks
                } else if let url = album.url {
                    songs = try await CatalogAPI().resolve(url: url, session: session).tracks
                } else {
                    error = String(localized: "Album details are unavailable.")
                }
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}

private struct PlaylistOccurrenceRemovalSheet: View {
    let playlist: LibraryPlaylist
    let catalog: LibraryCatalog
    let isBusy: Bool
    let onRemove: (PlaylistTrackOccurrence) -> Void
    let onRemoveAll: (String) -> Void
    @State private var removeAllTrackID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                PlaylistMutationFeedbackRow()
                ForEach(catalog.playlistOccurrences(playlist)) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.track?.title ?? String(localized: "Unavailable track"))
                            Text(row.track?.artist ?? row.occurrence.trackID)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            onRemove(row.occurrence)
                        }
                        .disabled(isBusy)
                        .accessibilityLabel(Text(row.track?.title ?? row.occurrence.trackID) + Text(", ") + Text("Remove track occurrence"))
                        .accessibilityValue(Text("Occurrence \(Int(row.occurrence.position + 1))"))
                        Button("Remove All Copies", role: .destructive) { removeAllTrackID = row.occurrence.trackID }
                            .disabled(isBusy)
                            .accessibilityLabel("Remove all copies of \(row.track?.title ?? row.occurrence.trackID)")
                    }
                }
            }
            .confirmationDialog("Remove all copies of this track?", isPresented: Binding(
                get: { removeAllTrackID != nil }, set: { if !$0 { removeAllTrackID = nil } }
            ), titleVisibility: .visible) {
                Button("Remove All Copies", role: .destructive) {
                    if let id = removeAllTrackID { onRemoveAll(id) }
                    removeAllTrackID = nil
                }
            }
            .navigationTitle("Remove Occurrence")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PlaylistReorderSheet: View {
    let playlist: LibraryPlaylist
    let catalog: LibraryCatalog
    let isBusy: Bool
    let onSave: ([String]) -> Void
    @State private var occurrences: [PlaylistTrackOccurrence] = []
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var collections: LibraryCollectionsModel

    var body: some View {
        NavigationStack {
            List {
                PlaylistMutationFeedbackRow()
                ForEach(occurrences) { occurrence in
                    VStack(alignment: .leading) {
                        Text(catalog.tracksByID[occurrence.trackID]?.title ?? String(localized: "Unavailable track"))
                        Text(catalog.tracksByID[occurrence.trackID]?.artist ?? occurrence.trackID)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text("Occurrence \(Int((occurrences.firstIndex(of: occurrence) ?? 0) + 1))"))
                }
                .onMove { source, destination in occurrences.move(fromOffsets: source, toOffset: destination) }
            }
            .navigationTitle("Reorder Tracks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let completeIDs = PlaylistTrackOccurrence.completeOrder(
                            occurrences, matching: playlist.trackIDs
                        ) else { return }
                        onSave(completeIDs)
                    }
                    .disabled(isBusy || PlaylistTrackOccurrence.completeOrder(
                        occurrences, matching: playlist.trackIDs
                    ) == nil || (collections.playlistMutationError == .conflictRequiresReview ||
                          collections.playlistMutationError == .conflictRefreshFailed))
                }
            }
            .onChange(of: collections.playlistMutationError) { _, error in
                if error == .conflictRequiresReview {
                    occurrences = PlaylistTrackOccurrence.ordered(playlist.trackIDs)
                }
            }
            .onChange(of: playlist.trackIDs, initial: true) { _, trackIDs in
                // A conflict refresh replaces the local draft with the authoritative server order.
                // The user sees the refreshed rows before another reorder can be submitted.
                occurrences = PlaylistTrackOccurrence.ordered(trackIDs)
            }
        }
    }
}

private struct PlaylistMutationFeedbackRow: View {
    @EnvironmentObject private var collections: LibraryCollectionsModel

    @ViewBuilder
    var body: some View {
        if let operation = collections.activePlaylistMutation {
            ProgressView {
                Text(progressMessage(for: operation))
            }
            .accessibilityElement(children: .combine)
            .listRowSeparator(.hidden)
        } else if let error = collections.playlistMutationError {
            VStack(alignment: .leading, spacing: 8) {
                Label(errorMessage(for: error), systemImage: error == .conflictRequiresReview
                      ? "arrow.clockwise.circle" : "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                if error == .conflictRequiresReview {
                    Text("The latest playlist order is loaded. Review the updated list before saving again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if error == .conflictRefreshFailed || error == .acceptedResponseUnreadable {
                    Button("Refresh") { Task { await collections.refreshPlaylistAfterConflict() } }
                        .font(.caption)
                } else if error == .conflictRequiresReview {
                    Button("Review Updated Order") { collections.clearPlaylistMutationError() }
                        .font(.caption)
                } else {
                    Button("Dismiss") { collections.clearPlaylistMutationError() }
                        .font(.caption)
                }
            }
            .accessibilityElement(children: .contain)
            .listRowSeparator(.hidden)
        }
    }

    private func progressMessage(for operation: LibraryCollectionsModel.PlaylistMutationOperation) -> LocalizedStringKey {
        switch operation {
        case .creating: "Creating playlist…"
        case .renaming: "Renaming playlist…"
        case .addingTracks: "Adding tracks…"
        case .removingTracks: "Removing tracks…"
        case .removingTrack: "Removing tracks…"
        case .reordering: "Updating playlist order…"
        }
    }

    private func errorMessage(for error: LibraryCollectionsModel.PlaylistMutationError) -> LocalizedStringKey {
        switch error {
        case .conflictRequiresReview:
            "This playlist changed on the server."
        case .conflictRefreshFailed:
            "Could not refresh the changed playlist. Refresh before saving again."
        case .acceptedResponseUnreadable:
            "The server accepted the change, but its response could not be read. Refresh to see the result."
        case .invalidRequest:
            "The server could not accept this change. Check the playlist and selected tracks."
        case .permissionDenied:
            "The server denied this change. Your playlist permissions may have changed."
        case .notFound:
            "The playlist or one of its tracks is no longer available. Refresh and try again."
        case .libraryIndexUnavailable:
            "The server library index is still starting. Try again shortly."
        case .httpStatus(let status):
            "The server returned error \(status). Try again."
        case .unexpected:
            "Could not update this playlist. Check the connection and try again."
        }
    }
}

private struct LibraryTrackList: View {
    let tracks: [LibraryTrack]
    let context: LibraryContext?
    let playback: PlaybackController
    var onMoveToTrash: ((LibraryTrack) -> Void)? = nil
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @EnvironmentObject private var downloads: OfflineDownloads
    @Environment(\.downtifyPalette) private var palette
    @State private var downloadMessage: LocalizedStringKey?

    var body: some View {
        let downloadByID = Dictionary(downloads.currentDownloads.map { ($0.track.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        if let error = collections.actionError {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            Button("Dismiss") { collections.clearError() }
        }
        if let downloadMessage { Text(downloadMessage).font(.subheadline).foregroundStyle(.secondary) }
        LazyVStack(spacing: 0) {
            ForEach(tracks.indices, id: \.self) { index in
                let track = tracks[index]
                let liked = collections.effectiveLike(track.id)
                HStack(spacing: 0) {
                    Button {
                        if let context { collections.record(context) }
                        playback.replaceQueue(tracks, startingAt: index)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(track.accessibleMetadata))
                    .accessibilityValue(spokenDuration(track.duration))
                    .accessibilityHint("Play this song and replace the current queue")
                    Menu {
                        if collections.likedIDs != nil {
                            Button(liked ? "Unlike song" : "Like song", systemImage: liked ? "heart.slash" : "heart") {
                                Task { await collections.toggleLike(track) }
                            }
                            .disabled(collections.mutationBusy)
                            if collections.hasPendingLike(track.id) { Text("Queued") }
                        }
                        Button("Add to queue", systemImage: "text.append") { playback.append([track]) }
                        if let onMoveToTrash {
                            Button("Move to trash", systemImage: "trash", role: .destructive) { onMoveToTrash(track) }
                        }
                        downloadAction(track, record: downloadByID[track.id])
                    } label: {
                        HStack(spacing: 0) {
                            if liked {
                                Image(systemName: "heart.fill").font(.caption).foregroundStyle(DowntifyStyle.accent)
                            }
                            if collections.hasPendingLike(track.id) {
                                Image(systemName: "clock").font(.caption).accessibilityLabel("Queued")
                            }
                            Image(systemName: "ellipsis")
                        }
                        .downtifyControlTarget()
                    }
                    .accessibilityLabel("Actions for \(track.displayTitle)")
                    .accessibilityValue(liked ? Text("Liked") : Text(""))
                }
                if index < tracks.count - 1 { Divider().padding(.leading, 80) }
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func downloadAction(_ track: LibraryTrack, record: OfflineDownload?) -> some View {
        if let record, record.state == .ready {
            Button("Remove offline copy", systemImage: "trash", role: .destructive) {
                do { try downloads.delete(record.id); downloadMessage = "Offline copy removed." }
                catch { downloadMessage = "Could not remove this offline copy." }
            }
        } else if let record, record.pending {
            Button("Cancel offline download", systemImage: "xmark.circle") { downloads.cancel(record.id) }
        } else {
            Button(record == nil ? "Download for offline playback" : "Retry offline download", systemImage: "arrow.down.circle") {
                do { try downloads.enqueue(track); downloadMessage = "Offline download requested." }
                catch { downloadMessage = "Could not start this download." }
            }
        }
    }
}
