import SwiftUI

/// Pages opened from the profile drawer, the Search page's Browse tiles and Home shortcuts in the drawer layout.
enum ProfileRoute: Hashable {
    case downloads, podcasts, settings, pendingActions, trash, about
    case discover(String)
}

struct LibraryHomeView: View {
    static let discoverSectionKey = "catalog.discover.section"

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
    @EnvironmentObject private var offlineDownloads: OfflineDownloads
    @EnvironmentObject private var storageModel: StorageSettingsModel
    @EnvironmentObject private var reachability: ServerReachabilityModel
    @Environment(\.openURL) private var openURL
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("library.sort") private var sort = LibrarySort.recentlyAdded
    @AppStorage("library.descending") private var descending = true
    @AppStorage("library.grid") private var grid = true
    @AppStorage("library.redesign.grid") private var redesignGrid = false
    @AppStorage("downtify.language") private var language = "system"
    @AppStorage("debug.networkOverlay.enabled") private var networkOverlayEnabled = false
    @AppStorage(NetworkOperationCoordinator.limitDefaultsKey) private var networkOperationLimit = NetworkOperationCoordinator.defaultLimit
    @State private var category = Category.albums
    @State private var searchText = ""
    @State private var showingSignOutConfirmation = false
    @State private var signOutError: LocalizedStringKey?
    @State private var tab = Tab.home
    @State private var trashTrack: LibraryTrack?
    @State private var showingSettings = false
    @State private var showingDrawer = false
    @State private var showingCreatePlaylist = false
    @State private var newPlaylistName = ""
    // Drawer layout: one navigation stack per tab, so drawer pages push onto the tab in front.
    @State private var homePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var libraryFilter: LibraryFilter?
    @State private var showingLibrarySearch = false
    @FocusState private var librarySearchFocused: Bool

    /// Filter chips of the redesigned Your Library page; no chip selected shows everything.
    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case playlists = "Playlists", albums = "Albums", artists = "Artists", songs = "Songs", downloaded = "Downloaded"
        var id: Self { self }
    }

    private var usesDrawer: Bool { palette.theme?.navigationStyle == "drawer" }
    private var isAdmin: Bool { server.role?.lowercased() == "admin" }
    private var displayName: String { server.username.flatMap { $0.isEmpty ? nil : $0 } ?? server.name }

    private var currentGrid: Bool { palette.redesign("library") ? redesignGrid : grid }
    private func toggleGrid() {
        if palette.redesign("library") { redesignGrid.toggle() } else { grid.toggle() }
    }

    private enum Tab { case home, library, search, discover, downloads, podcasts, adminTrash, more }
    private enum Category: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists"
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
        Group {
            if usesDrawer { drawerShell } else { standardTabs }
        }
        .onAppear { if palette.redesign("library") { category = .all } }
        .onChange(of: palette.theme?.componentStyles?["library"]) { _, style in
            if style == "redesign" { category = .all }
            else if category == .all { category = .albums }
        }
        .onChange(of: palette.theme?.navigationStyle) { _, style in
            showingDrawer = false
            if style == "drawer", ![Tab.home, .search, .library].contains(tab) { tab = .home }
        }
        .task(id: catalogPresentation.session) { configureAutoplay() }
        .onChange(of: networkOperationLimit) { _, value in
            Task { await NetworkOperationCoordinator.shared.setLimit(value) }
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
            if networkOverlayEnabled && tab != .more && !showingDrawer {
                NetworkDebugOverlayContainer(playback: playback)
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
                SettingsView(appearance: $appearance, language: $language, networkOperationLimit: $networkOperationLimit, playback: playback)
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

    // MARK: Drawer layout

    /// Home, Search and Your Library in the system tab bar; everything else is in the profile drawer.
    private var drawerShell: some View {
        ZStack {
            TabView(selection: $tab) {
                tabStack(path: $homePath, showsServerBanner: true) {
                    pageHeader(palette.redesign("home") ? greeting : "Home") {
                        headerIcon("arrow.down.circle", label: "Downloads", badge: activeDeviceDownloads) { open(.downloads) }
                        headerIcon("gearshape", label: "Settings") { open(.settings) }
                    }
                    // The yellow banner already says the server is down.
                    if !reachability.isUnreachable { syncStatus }
                    if palette.redesign("home") { redesignHomeContent } else { homeContent }
                }
                .tabItem { Label("Home", systemImage: "house.fill").accessibilityIdentifier("tab.home") }
                .tag(Tab.home)
                tabStack(path: $searchPath) {
                    pageHeader("Search", font: .title.bold()) { EmptyView() }
                    CatalogSearchContainer(catalog: catalogPresentation, library: library, playback: playback,
                                           serverDownloads: serverDownloads,
                                           libraryState: { catalogLibraryState(for: $0) },
                                           onAddToDevice: { addCatalogSongToDevice($0) },
                                           deviceState: { catalogDeviceState(for: $0) },
                                           onBrowse: { open(drawerRoute(forBrowseTile: $0)) },
                                           loadSuggestions: loadSearchSuggestions,
                                           browse: AnyView(browseGrid))
                }
                .tabItem { Label("Search", systemImage: "magnifyingglass").accessibilityIdentifier("tab.search") }
                .tag(Tab.search)
                tabStack(path: $libraryPath) {
                    if palette.redesign("library") {
                        redesignLibraryContent
                    } else {
                        pageHeader("Your Library") { EmptyView() }
                        libraryContent
                    }
                }
                .tabItem { Label("Your Library", systemImage: "books.vertical.fill").accessibilityIdentifier("tab.library") }
                .tag(Tab.library)
            }
            .tint(Color.primary)

            SideDrawer(isPresented: $showingDrawer) { drawerContent }
                .allowsHitTesting(showingDrawer)
        }
    }

    private func drawerRoute(forBrowseTile title: String) -> ProfileRoute {
        switch title {
        case "Downloads": .downloads
        case "Podcasts": .podcasts
        default: .discover(title)
        }
    }

    private func tabStack<Content: View>(path: Binding<NavigationPath>, showsServerBanner: Bool = false,
                                         @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path) {
            rootPage(content: content)
                .serverConnectionBanner(isEnabled: showsServerBanner)
                .navigationDestination(for: LibraryContext.self) { context in
                    LibraryContextView(context: context, library: library, playback: playback,
                                       serverDownloads: serverDownloads,
                                       onMoveToTrash: isAdmin ? { trashTrack = $0 } : nil)
                }
                .navigationDestination(for: ProfileRoute.self) { destination($0) }
        }
        .tint(palette.accent)
        .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
    }

    /// Root pages draw their own header (avatar and title), so the navigation bar is hidden there.
    private func rootPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DowntifyStyle.Space.large) {
                content()
            }
            .padding(.horizontal, DowntifyStyle.Space.regular)
            .padding(.top, DowntifyStyle.Space.small)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .downtifyScrollEndClearance()
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await refresh() }
        .background(palette.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            // Solid strip under the status bar so scrolled content never runs behind the clock.
            Color.clear
                .frame(height: 0)
                .background(palette.background.ignoresSafeArea(edges: .top))
                .allowsHitTesting(false)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func open(_ route: ProfileRoute) {
        showingDrawer = false
        if case .discover(let section) = route {
            UserDefaults.standard.set(section, forKey: Self.discoverSectionKey)
        }
        switch tab {
        case .search: searchPath.append(route)
        case .library: libraryPath.append(route)
        default: homePath.append(route)
        }
    }

    @ViewBuilder
    private func destination(_ route: ProfileRoute) -> some View {
        switch route {
        case .downloads:
            DownloadsView(connection: connection, queue: serverDownloadQueue, serverDownloads: serverDownloads,
                          playback: playback, membership: library.membership)
        case .podcasts:
            PodcastsView(connection: connection, playback: playback, embedsNavigationStack: false)
        case .settings:
            SettingsView(appearance: $appearance, language: $language, networkOperationLimit: $networkOperationLimit,
                         playback: playback, showsDoneButton: false,
                         account: SettingsAccount(name: displayName, server: server.name, role: server.role,
                                                  signOut: { showingSignOutConfirmation = true }),
                         storage: storageModel)
                .scrollContentBackground(.hidden)
                .background(palette.background.ignoresSafeArea())
                .downtifyScrollEndClearance()
        case .pendingActions:
            pendingActionsPage
        case .trash:
            AdminTrashView(connection: connection, role: server.role,
                           pairingID: "\(server.serverID):\(server.deviceID):\(server.username ?? ""):\(server.role ?? "")")
        case .about:
            AboutView(version: versionText, showsDoneButton: false)
        case .discover:
            ScrollView {
                discoveryContent
                    .padding(DowntifyStyle.Space.regular)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            .downtifyScrollEndClearance()
            .scrollDismissesKeyboard(.interactively)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var avatarButton: some View {
        Button { showingDrawer = true } label: {
            ProfileAvatar(name: displayName, size: 34)
                .frame(width: DowntifyStyle.minimumControlSize, height: DowntifyStyle.minimumControlSize, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open navigation menu")
        .accessibilityHint("Opens your profile, downloads and settings")
        .accessibilityIdentifier("profile.avatar")
    }

    private func pageHeader<Trailing: View>(_ title: LocalizedStringKey, font: Font = .title2.bold(),
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            avatarButton
            Text(title)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
        .font(.title3)
    }

    private func headerIcon(_ systemImage: String, label: LocalizedStringKey, badge: Int = 0,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Circle().fill(palette.brand).frame(width: 9, height: 9).offset(x: 3, y: -2)
                    }
                }
                .downtifyControlTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(badge > 0 ? String(localized: "\(badge) in progress") : "")
    }

    private var activeDeviceDownloads: Int { offlineDownloads.currentDownloads.filter(\.pending).count }

    private var drawerContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ProfileAvatar(name: displayName, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: displayName).font(.title3.bold()).lineLimit(1)
                        Label { Text(verbatim: server.name) } icon: { Image(systemName: "server.rack") }
                            .font(.subheadline)
                            .foregroundStyle(DowntifyStyle.secondaryText)
                            .lineLimit(1)
                        if isAdmin {
                            Text("Administrator").font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
                        }
                    }
                }
                .padding(.vertical, DowntifyStyle.Space.large)
                .accessibilityElement(children: .combine)
                Divider()
                VStack(spacing: 0) {
                    DrawerRow(title: "Downloads", systemImage: "arrow.down.circle", badge: activeDeviceDownloads) { open(.downloads) }
                        .accessibilityIdentifier("drawer.downloads")
                    DrawerRow(title: "Discover", systemImage: "sparkles") { open(.discover("For You")) }
                    DrawerRow(title: "Podcasts", systemImage: "mic") { open(.podcasts) }
                    if !collections.pendingActions.isEmpty || collections.actionError != nil {
                        DrawerRow(title: "Pending Actions", systemImage: "clock.arrow.circlepath",
                                  badge: collections.pendingActions.count) { open(.pendingActions) }
                    }
                    if isAdmin {
                        DrawerRow(title: "Trash", systemImage: "trash") { open(.trash) }
                    }
                }
                .padding(.vertical, DowntifyStyle.Space.small)
                Divider()
                VStack(spacing: 0) {
                    DrawerRow(title: "Settings", systemImage: "gearshape") { open(.settings) }
                        .accessibilityIdentifier("drawer.settings")
                    DrawerRow(title: "Refresh library", systemImage: "arrow.clockwise") {
                        showingDrawer = false
                        Task { await refresh() }
                    }
                    DrawerRow(title: "About Downtify", systemImage: "info.circle") { open(.about) }
                }
                .padding(.vertical, DowntifyStyle.Space.small)
                Divider()
                DrawerRow(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    showingDrawer = false
                    showingSignOutConfirmation = true
                }
                .padding(.vertical, DowntifyStyle.Space.small)
                Text("Version \(versionText)")
                    .font(.caption)
                    .foregroundStyle(DowntifyStyle.secondaryText)
                    .padding(.top, DowntifyStyle.Space.regular)
            }
            .padding(.horizontal, 20)
        }
    }

    private var pendingActionsPage: some View {
        Form {
            Section {
                if let error = collections.actionError {
                    Text(error).foregroundStyle(DowntifyStyle.error)
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
                            Text(action.failure ?? String(localized: "Action failed")).foregroundStyle(DowntifyStyle.error)
                        }
                        if action.status != .queued {
                            Button("Dismiss") { Task { await collections.dismissAction(action.id) } }
                        }
                    }
                }
            } footer: {
                Text("Likes and favorites made while the server is unreachable are sent when it is back.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Pending Actions")
        .downtifyScrollEndClearance()
    }

    // MARK: Tab layout

    private var standardTabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                browsePage(title: "Home") { homeContent }
                    .serverConnectionBanner()
            }
            .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
            .tabItem { Label("Home", systemImage: "house") }.tag(Tab.home)

            NavigationStack {
                browsePage(title: "Library") { libraryContent }
                    .searchable(text: $searchText, prompt: "Filter your library")
            }
            .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
            .tabItem { Label("Library", systemImage: "books.vertical").accessibilityIdentifier("tab.library") }.tag(Tab.library)

            NavigationStack {
                browsePage(title: "Search") { searchContent }
            }
            .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
            .tabItem { Label("Search", systemImage: "magnifyingglass").accessibilityIdentifier("tab.search") }.tag(Tab.search)

            NavigationStack {
                browsePage(title: "Discover") { discoveryContent }
            }
            .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
            .tabItem { Label("Discover", systemImage: "sparkles").accessibilityIdentifier("tab.discover") }.tag(Tab.discover)

            NavigationStack {
                DownloadsView(connection: connection, queue: serverDownloadQueue, serverDownloads: serverDownloads,
                              playback: playback, membership: library.membership)
            }
                .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(Tab.downloads)

            PodcastsView(connection: connection, playback: playback)
                .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
                .tabItem { Label("Podcasts", systemImage: "mic") }.tag(Tab.podcasts)

            if server.role?.lowercased() == "admin" {
                NavigationStack {
                    AdminTrashView(connection: connection, role: server.role,
                                   pairingID: "\(server.serverID):\(server.deviceID):\(server.username ?? ""):\(server.role ?? "")")
                }
                .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
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
                    StorageSection(model: storageModel)
                    Section("About") {
                        NavigationLink("About Downtify") { AboutView(version: versionText) }
                        LabeledContent("Version", value: versionText)
                    }
                }
                .navigationTitle("More")
                .downtifyScrollEndClearance()
            }
            .playbackDock(playback: playback, library: library, serverDownloads: serverDownloads)
            .tabItem { Label("More", systemImage: "ellipsis").accessibilityIdentifier("tab.more") }.tag(Tab.more)
        }
    }

    /// Autoplay continues with up to ten songs similar to the last one, resolved to library copies where they exist.
    private func configureAutoplay() {
        let catalog = catalogPresentation
        let library = library
        playback.autoplayProvider = { [weak catalog, weak library] seed in
            guard let catalog, let library,
                  let songs = try? await catalog.similarSongs(artist: seed.leadArtist, track: seed.title) else { return [] }
            let tracks = library.tracks
            let libraryOnly = catalog.isLibraryOnly == true
            return Array(songs.map { PlaybackItem.resolving($0, in: tracks) }
                .filter { !libraryOnly || $0.libraryTrack != nil }
                .prefix(10))
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
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
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        .refreshable { await refresh() }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(palette.redesign("home") && tab == .home ? greeting : title)
        .navigationBarTitleDisplayMode(palette.theme?.headerStyle == "profile" ? .inline : .automatic)
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
        let artists = Array(library.catalog.artistsByID.values
            .sorted { $0.count == $1.count ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.count > $1.count }
            .prefix(12))
        ForEach(palette.theme?.resolvedHomeSections ?? DowntifyTheme.standardHomeSections, id: \.self) { section in
            switch section {
            case "recent":
                if !jump.isEmpty {
                    if palette.theme?.recentStyle == "tiles" && !dynamicTypeSize.isAccessibilitySize {
                        LibraryEntryList(entries: Array(jump.prefix(8)), grid: true, compactTiles: true)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Jump back in")
                        if jump.count > 8 { shelf("Jump back in", entries: Array(jump.dropFirst(8))) }
                    } else { shelf("Jump back in", entries: jump) }
                }
            case "new": if !newest.isEmpty { shelf("Recently added", entries: newest) }
            case "favorites": if !favorites.isEmpty { shelf("Favorite playlists", entries: favorites) }
            case "discover": discoverCard
            case "artists": if artists.count > 1 { shelf("Your artists", entries: artists) }
            case "downloaded": downloadedCard
            default: EmptyView()
            }
        }
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
        let carousel = palette.theme?.shelfLayout == "carousel" && !dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: carousel ? .leading : .center, spacing: 8) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: entries, grid: !dynamicTypeSize.isAccessibilitySize && palette.theme?.shelfLayout != "list",
                             carousel: carousel)
        }
    }

    private var homeCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: palette.cardCornerRadius(default: 10), style: .continuous)
    }

    /// Opens Discover's personalised suggestions. The artwork uses the theme's For You color, as the Search tile does.
    private var discoverCard: some View {
        let hex = palette.theme?.browseColors?["For You"].flatMap { UInt32($0, radix: 16) } ?? 0x203562
        let tile = DowntifyStyle.adaptive(light: hex, dark: hex)
        return Button {
            UserDefaults.standard.set("For You", forKey: "catalog.discover.section")
            tab = .discover
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(LinearGradient(colors: [tile, tile.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: min(palette.cardCornerRadius(default: 10), 8), style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Made for you").font(.caption.weight(.semibold)).foregroundStyle(DowntifyStyle.secondaryText)
                    Text("Discover something new").font(.headline)
                    Text("Suggestions, charts and similar songs").font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DowntifyStyle.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(palette.cardPadding(default: 10))
            .background(palette.surface, in: homeCardShape)
            .contentShape(homeCardShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Discover")
        .accessibilityIdentifier("home.discover")
    }

    /// Songs saved on this device, with a button that plays them in order. Tapping the card opens Downloads.
    @ViewBuilder
    private var downloadedCard: some View {
        let ready = offlineDownloads.currentDownloads.filter { $0.state == .ready }
        if !ready.isEmpty {
            HStack(spacing: 14) {
                Button { tab = .downloads } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                            .foregroundStyle(palette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloaded to this device").font(.headline)
                            Text(ready.count == 1 ? String(localized: "1 song") : String(localized: "\(ready.count) songs"))
                                .font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens Downloads")
                Button {
                    playback.setShuffle(false)
                    playback.replaceQueue(ready.map(\.track))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(palette.onBrand)
                        .frame(width: 48, height: 48)
                        .background(palette.brand, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play downloaded songs")
                .accessibilityIdentifier("home.playDownloaded")
            }
            .padding(palette.cardPadding(default: 12))
            .background(palette.surface, in: homeCardShape)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.downloaded")
        }
    }

    // MARK: Redesigned Home

    @ViewBuilder
    private var redesignHomeContent: some View {
        let newest = library.latestAlbums
        let recents = collections.recents.compactMap(entry)
        let fallback = (likedEntry.count > 0 ? [likedEntry] : []) + newest
        let quick = Array((recents.isEmpty ? fallback : recents).prefix(8))
        let favorites = LibrarySort.alphabetical.ordered(
            (collections.playlists ?? []).filter { $0.favorite == true && $0.liked != true }.map(playlistEntry),
            descending: false
        )
        let artists = Array(library.catalog.artistsByID.values
            .sorted { $0.count == $1.count ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.count > $1.count }
            .prefix(12))
        ForEach(palette.theme?.resolvedHomeSections ?? DowntifyTheme.standardHomeSections, id: \.self) { section in
            switch section {
            case "recent":
                if !quick.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(quick) { entry in
                            NavigationLink(value: entry.context) { QuickAccessTile(entry: entry) }
                                .buttonStyle(.plain)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Jump back in")
                }
                if recents.count > 8 { redesignShelf("Jump back in", entries: Array(recents.dropFirst(8))) }
            case "new": if !newest.isEmpty { redesignShelf("Recently added", entries: newest) }
            case "favorites": if !favorites.isEmpty { redesignShelf("Favorite playlists", entries: favorites) }
            case "discover": redesignDiscoverCard
            case "artists": if artists.count > 1 { redesignShelf("Your artists", entries: artists) }
            case "downloaded": offlineCard
            default: EmptyView()
            }
        }
        if quick.isEmpty && newest.isEmpty && favorites.isEmpty {
            if library.tracks.isEmpty { emptyTracks }
            else {
                DowntifyUnavailableView(title: "Nothing to jump back into yet", symbol: "clock",
                                        message: Text("Play an album, playlist, or artist to see it here."))
            }
        }
    }

    /// Horizontal shelf of cards; artists get round images.
    private func redesignShelf(_ title: LocalizedStringKey, entries: [LibraryBrowseEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DowntifySectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.context) { ShelfCard(entry: entry) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DowntifyStyle.Space.regular)
            }
            .padding(.horizontal, -DowntifyStyle.Space.regular)
        }
    }

    /// Opens Discover's personalised suggestions from Home.
    private var redesignDiscoverCard: some View {
        Button { open(.discover("For You")) } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.39), Color(red: 0.55, green: 0.4, blue: 0.67)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Made for you").font(.caption.weight(.semibold)).foregroundStyle(DowntifyStyle.secondaryText)
                    Text("Discover something new").font(.headline)
                    Text("Suggestions, charts and similar songs").font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DowntifyStyle.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Discover")
        .accessibilityIdentifier("home.discover")
    }

    /// Songs saved on this device with a play button; tapping the card opens Downloads.
    @ViewBuilder
    private var offlineCard: some View {
        let ready = offlineDownloads.currentDownloads.filter { $0.state == .ready }
        if !ready.isEmpty {
            HStack(spacing: 14) {
                Button { open(.downloads) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                            .foregroundStyle(palette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloaded to this device").font(.headline)
                            Text(ready.count == 1 ? String(localized: "1 song") : String(localized: "\(ready.count) songs"))
                                .font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens Downloads")
                DowntifyPlayButton(size: 44) {
                    playback.setShuffle(false)
                    playback.replaceQueue(ready.map(\.track))
                }
                .accessibilityLabel("Play downloaded songs")
                .accessibilityIdentifier("home.playDownloaded")
            }
            .padding(12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.downloaded")
        }
    }

    // MARK: Redesigned Your Library

    @ViewBuilder
    private var redesignLibraryContent: some View {
        pageHeader("Your Library") {
            headerIcon("magnifyingglass", label: "Filter your library") {
                showingLibrarySearch.toggle()
                librarySearchFocused = showingLibrarySearch
                if !showingLibrarySearch { searchText = "" }
            }
            if collections.supportsPlaylistEditing {
                headerIcon("plus", label: "Create Playlist") { showingCreatePlaylist = true }
                    .disabled(collections.mutationBusy)
            }
        }
        if showingLibrarySearch || !searchText.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DowntifyStyle.secondaryText)
                TextField("Filter your library", text: $searchText)
                    .focused($librarySearchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(DowntifyStyle.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(palette.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if libraryFilter != nil {
                    Button { libraryFilter = nil } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .frame(width: 34, height: 34)
                            .background(palette.elevated, in: Circle())
                            .frame(minWidth: DowntifyStyle.minimumControlSize, minHeight: DowntifyStyle.minimumControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show everything")
                }
                ForEach(LibraryFilter.allCases) { filter in
                    DowntifyChip(title: LocalizedStringKey(filter.rawValue), isSelected: libraryFilter == filter) {
                        libraryFilter = libraryFilter == filter ? nil : filter
                    }
                }
            }
            .padding(.horizontal, DowntifyStyle.Space.regular)
        }
        .padding(.horizontal, -DowntifyStyle.Space.regular)
        .padding(.top, -DowntifyStyle.Space.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library category")
        syncStatus
        if libraryFilter != .playlists && libraryFilter != .downloaded {
            HStack {
                sortMenu
                Spacer()
                if libraryFilter != .songs && !dynamicTypeSize.isAccessibilitySize {
                    Button { toggleGrid() } label: {
                        Image(systemName: currentGrid ? "list.bullet" : "square.grid.2x2").downtifyControlTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(currentGrid ? String(localized: "Show as list") : String(localized: "Show as grid"))
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, -DowntifyStyle.Space.regular)
        }
        switch libraryFilter {
        case nil:
            redesignAllLibraryContent
        case .songs:
            let tracks = library.songs(sort: sort, descending: descending, query: query)
            if library.tracks.isEmpty { emptyTracks }
            else if tracks.isEmpty { ContentUnavailableView.search(text: searchText) }
            else { LibraryTrackList(tracks: tracks, context: nil, playback: playback,
                                    onMoveToTrash: isAdmin ? { trashTrack = $0 } : nil) }
        case .albums:
            browseGroups(Array(library.catalog.albumsByID.values), emptyTitle: "No albums")
        case .artists:
            browseGroups(Array(library.catalog.artistsByID.values), emptyTitle: "No artists")
        case .playlists:
            playlistContent
        case .downloaded:
            downloadedContent
        }
    }

    /// Liked Songs and pinned playlists first, then every playlist, album and artist.
    @ViewBuilder
    private var redesignAllLibraryContent: some View {
        let lists = (collections.playlists ?? []).filter { $0.liked != true }
        let favoriteIDs = Set(lists.filter { $0.favorite == true }.map(\.id))
        let liked = collections.likedIDs == nil ? [] : matching([likedEntry])
        let pinned = liked + matching(lists.filter { favoriteIDs.contains($0.id) }.map(playlistEntry))
        let playlists = matching(lists.filter { !favoriteIDs.contains($0.id) }.map(playlistEntry))
        let rest = sort.ordered(matching(Array(library.catalog.albumsByID.values) + Array(library.catalog.artistsByID.values)),
                                descending: descending)
        let all = pinned + playlists + rest
        if library.tracks.isEmpty && all.isEmpty { emptyTracks }
        else if all.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: searchText) }
        else {
            LibraryEntryList(entries: all, grid: currentGrid && !dynamicTypeSize.isAccessibilitySize,
                             pinnedIDs: Set(pinned.map(\.id)))
        }
    }

    @ViewBuilder
    private var downloadedContent: some View {
        let ready = offlineDownloads.currentDownloads.filter { $0.state == .ready }.map(\.track)
        let tracks = query.isEmpty ? ready : LibraryTrackOrdering.matching(ready, query: query)
        Button { open(.downloads) } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage downloads").font(.headline)
                    Text("Device storage and server requests").font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(DowntifyStyle.secondaryText)
            }
            .padding(12)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if tracks.isEmpty {
            DowntifyUnavailableView(title: "Nothing downloaded yet", symbol: "arrow.down.circle",
                                    message: Text("Use the download button on an album or playlist to listen offline."))
        } else {
            LibraryTrackList(tracks: tracks, context: nil, playback: playback,
                             onMoveToTrash: isAdmin ? { trashTrack = $0 } : nil)
        }
    }

    // MARK: Redesigned Search

    private func browseTileColor(_ key: String, fallback: Color) -> Color {
        guard let hex = palette.theme?.browseColors?[key].flatMap({ UInt32($0, radix: 16) }) else { return fallback }
        return DowntifyStyle.adaptive(light: hex, dark: hex)
    }

    private var browseGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse all").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                browseTile("For You", symbol: "sparkles",
                           color: browseTileColor("For You", fallback: Color(red: 0.12, green: 0.2, blue: 0.39)), id: "foryou") {
                    open(.discover("For You"))
                }
                browseTile("Charts", symbol: "chart.line.uptrend.xyaxis",
                           color: browseTileColor("Charts", fallback: Color(red: 0.88, green: 0.2, blue: 0)), id: "charts") {
                    open(.discover("Charts"))
                }
                browseTile("Finder", symbol: "sparkle.magnifyingglass",
                           color: browseTileColor("Finder", fallback: Color(red: 0.15, green: 0.52, blue: 0.42)), id: "finder") {
                    open(.discover("Finder"))
                }
                browseTile("Similar", symbol: "waveform.path",
                           color: browseTileColor("Similar", fallback: Color(red: 0.55, green: 0.4, blue: 0.67)), id: "similar") {
                    open(.discover("Similar"))
                }
                if collections.likedIDs != nil {
                    browseTile("Liked songs", symbol: "heart.fill", color: Color(red: 0.27, green: 0.04, blue: 0.96), id: "liked") {
                        searchPath.append(LibraryContext.liked)
                    }
                }
                browseTile("Podcasts", symbol: "mic.fill",
                           color: browseTileColor("Podcasts", fallback: Color(red: 0, green: 0.39, blue: 0.31)), id: "podcasts") {
                    open(.podcasts)
                }
                browseTile("Downloads", symbol: "arrow.down.circle.fill",
                           color: browseTileColor("Downloads", fallback: Color(red: 0.73, green: 0.36, blue: 0.03)), id: "downloads") {
                    open(.downloads)
                }
                browseTile("Recently added", symbol: "clock.fill", color: Color(red: 0.91, green: 0.07, blue: 0.36), id: "recent") {
                    libraryFilter = .albums
                    sort = .recentlyAdded
                    descending = true
                    tab = .library
                }
            }
        }
    }

    private func browseTile(_ title: LocalizedStringKey, symbol: String, color: Color, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { BrowseTile(title: title, symbol: symbol, color: color) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("browse.\(id)")
    }

    @ViewBuilder
    private var libraryContent: some View {
        if palette.redesign("library") {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Category.allCases) { option in
                        Button { category = option } label: {
                            Text(LocalizedStringKey(option.rawValue))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .foregroundStyle(category == option ? palette.onBrand : Color.primary)
                                .background(category == option ? palette.brand : palette.elevated, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == option ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else {
        ViewThatFits(in: .horizontal) {
            Picker("Library category", selection: $category) {
                ForEach(Category.allCases.filter { $0 != .all }) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            Picker("Library category", selection: $category) {
                ForEach(Category.allCases.filter { $0 != .all }) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
        }
        }
        HStack {
            if category != .playlists { sortMenu }
            Spacer()
            if category != .songs && !dynamicTypeSize.isAccessibilitySize {
                Button { toggleGrid() } label: {
                    Image(systemName: currentGrid ? "list.bullet" : "square.grid.2x2").downtifyControlTarget()
                }
                .accessibilityLabel(currentGrid ? String(localized: "Show as list") : String(localized: "Show as grid"))
            }
        }
        switch category {
        case .all:
            allLibraryContent
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
    private var allLibraryContent: some View {
        let lists = (collections.playlists ?? []).filter { $0.liked != true }
        let pinned = (collections.likedIDs == nil ? [] : [likedEntry])
            + lists.filter { $0.favorite == true }.map(playlistEntry)
        let others = lists.filter { $0.favorite != true }.map(playlistEntry)
        let albums = Array(library.catalog.albumsByID.values)
        let artists = Array(library.catalog.artistsByID.values)
        let entries = matching(pinned) + matching(others)
            + sort.ordered(matching(albums + artists), descending: descending)
        if entries.isEmpty && library.tracks.isEmpty { emptyTracks }
        else if entries.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: searchText) }
        else { LibraryEntryList(entries: entries, grid: currentGrid && !dynamicTypeSize.isAccessibilitySize) }
    }

    @ViewBuilder
    private var searchContent: some View {
        CatalogSearchContainer(catalog: catalogPresentation, library: library, playback: playback,
                               serverDownloads: serverDownloads,
                               libraryState: { catalogLibraryState(for: $0) },
                               onAddToDevice: { addCatalogSongToDevice($0) },
                               deviceState: { catalogDeviceState(for: $0) },
                               onBrowse: { destination in
                                   switch destination {
                                   case "Downloads": tab = .downloads
                                   case "Podcasts": tab = .podcasts
                                   default:
                                       UserDefaults.standard.set(destination, forKey: "catalog.discover.section")
                                       tab = .discover
                                   }
                               },
                               loadSuggestions: loadSearchSuggestions)
    }

    /// Charts and Discover collections feed the suggestion shelves under Search's Browse grid.
    private func loadSearchSuggestions() {
        let catalog = catalogPresentation
        switch catalog.chartsState {
        case .idle, .unavailable, .failed: catalog.loadCharts()
        default: break
        }
        guard catalog.supportsDiscover == true else { return }
        switch catalog.discoverArtistsState {
        case .idle, .unavailable, .failed:
            catalog.loadDiscover(library: discoveryLibraryArtists,
                                 albums: Array(library.catalog.albumsByID.values).map { CatalogLibraryAlbum(artist: $0.artist, title: $0.title) },
                                 playlistNames: (collections.playlists ?? []).filter { $0.liked != true }.map(\.name),
                                 playlistIDs: (collections.playlists ?? []).filter { $0.liked != true }.map(\.id),
                                 shown: [])
        default: break
        }
    }

    private func libraryTrack(forCatalogSong song: CatalogSong) -> LibraryTrack? {
        library.membership.track(for: song)
            ?? serverDownloads.completedFilename(forActionKey: song.id.description)
                .flatMap(library.membership.track(forServerFilename:))
    }

    private func catalogLibraryState(for song: CatalogSong) -> ServerDownloadActionState {
        .catalogRow(server: serverDownloads.actionState(for: song),
                     inLibrary: library.membership.containsSong(song) || libraryTrack(forCatalogSong: song) != nil)
    }

    private func catalogDeviceState(for song: CatalogSong) -> DeviceSaveState {
        let track = libraryTrack(forCatalogSong: song)
        let record = track.flatMap { track in offlineDownloads.currentDownloads.first { $0.track.id == track.id } }
        return DeviceSaveState(track: track, record: record)
    }

    private func addCatalogSongToDevice(_ song: CatalogSong) {
        guard let track = libraryTrack(forCatalogSong: song) else { return }
        let failed = offlineDownloads.currentDownloads.first {
            $0.track.id == track.id && { if case .failed = $0.state { return true } else { return false } }($0)
        }
        if let failed { _ = try? offlineDownloads.retry(failed.id) } else { _ = try? offlineDownloads.enqueue(track) }
    }

    private var discoveryContent: some View {
        CatalogDiscoverContainer(
            catalog: catalogPresentation,
            serverDownloads: serverDownloads,
            libraryTracks: library.tracks,
            membership: library.membership,
            libraryArtists: discoveryLibraryArtists,
            libraryAlbums: Array(library.catalog.albumsByID.values).map {
                CatalogLibraryAlbum(artist: $0.artist, title: $0.title)
            },
            playlistNames: (collections.playlists ?? []).filter { $0.liked != true }.map(\.name),
            playlistIDs: (collections.playlists ?? []).filter { $0.liked != true }.map(\.id),
            onPlay: { song in playCatalogSong(song) },
            libraryState: { catalogLibraryState(for: $0) },
            onAddToDevice: { addCatalogSongToDevice($0) },
            deviceState: { catalogDeviceState(for: $0) },
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
            if palette.redesign("library") {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
                    .foregroundStyle(Color.primary)
                    .padding(.vertical, 10)
            } else {
                Label(sort.label, systemImage: "arrow.up.arrow.down").padding(.vertical, 10)
            }
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
                             grid: currentGrid && !dynamicTypeSize.isAccessibilitySize)
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
            if palette.redesign("library") {
                Button { showingCreatePlaylist = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(palette.elevated, in: RoundedRectangle(cornerRadius: 4))
                        Text("Create Playlist").font(.body.weight(.semibold))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(collections.mutationBusy)
                .accessibilityHint("Create a new manual playlist")
            } else {
                Button("Create Playlist", systemImage: "plus") {
                    showingCreatePlaylist = true
                }
                .disabled(collections.mutationBusy)
                .accessibilityHint("Create a new manual playlist")
            }
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
        let useGrid = currentGrid && !dynamicTypeSize.isAccessibilitySize
        let sectionFont: Font = palette.redesign("library") ? .title3.bold() : .headline
        if !pinned.isEmpty { LibraryEntryList(entries: pinned, grid: useGrid, pinnedIDs: favoriteIDs.union([""])) }
        if !shared.isEmpty {
            Text("Shared with me").font(sectionFont).accessibilityAddTraits(.isHeader)
            LibraryEntryList(entries: shared, grid: useGrid)
        }
        if !others.isEmpty {
            Text("Public playlists").font(sectionFont).accessibilityAddTraits(.isHeader)
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
            ProgressView("Loading playlists and likes…").frame(maxWidth: .infinity)
        } else if state == .unavailable {
            Label(title, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Retry") { Task { await collections.refresh() } }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if library.state == .refreshing { ProgressView("Refreshing library…").frame(maxWidth: .infinity) }
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

struct NetworkDebugOverlayContainer: View {
    @ObservedObject var playback: PlaybackController
    @AppStorage("debug.networkOverlay.corner") private var corner = "topTrailing"
    @AppStorage("debug.networkOverlay.size") private var size = "medium"

    private var alignment: Alignment {
        switch corner {
        case "topLeading": .topLeading
        case "centerLeading": .leading
        case "centerTrailing": .trailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: .topTrailing
        }
    }

    var body: some View {
        NetworkDebugOverlay(playback: playback, size: size, corner: $corner, selectedSize: $size)
            .padding(.horizontal, 8)
            .padding(.top, corner.hasPrefix("top") ? 54 : 0)
            .padding(.bottom, corner.hasPrefix("bottom") ? 72 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

struct NetworkDebugOverlay: View {
    @ObservedObject var playback: PlaybackController
    let size: String
    @Binding var corner: String
    @Binding var selectedSize: String
    @EnvironmentObject private var downloads: OfflineDownloads
    @AppStorage("debug.networkOverlay.enabled") private var overlayEnabled = false
    @State private var audioDeliveryRate: Double?
    @State private var preload = PlaybackPreloadCache.Snapshot()
    @State private var network = NetworkOperationSnapshot(active: 0, maximum: NetworkOperationCoordinator.defaultLimit, queued: 0,
                                                          foregroundActive: 0, backgroundActive: 0,
                                                          foregroundQueued: 0, backgroundQueued: 0,
                                                          recentFailures: [])

    private var width: CGFloat { size == "small" ? 205 : size == "large" ? 315 : 255 }
    private var fontSize: CGFloat { size == "small" ? 9 : size == "large" ? 12 : 10 }

    var body: some View {
        let activeTransfers = downloads.currentDownloads.filter { $0.state == .transferring }.count
        let pausedTransfers = downloads.currentDownloads.filter { $0.state == .paused }.count
        let currentReadiness = preload.currentReady ? "ready" : "not ready"
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("NETWORK DEBUG").fontWeight(.bold)
                Spacer(minLength: 4)
                Menu {
                    Section("Position") {
                        positionButton("Top left", value: "topLeading")
                        positionButton("Top right", value: "topTrailing")
                        positionButton("Center left", value: "centerLeading")
                        positionButton("Center right", value: "centerTrailing")
                        positionButton("Bottom left", value: "bottomLeading")
                        positionButton("Bottom right", value: "bottomTrailing")
                    }
                    Section("Size") {
                        sizeButton("Small", value: "small")
                        sizeButton("Medium", value: "medium")
                        sizeButton("Large", value: "large")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Move or resize debug overlay")
                Button { overlayEnabled = false } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close debug overlay")
            }
            Text("NET  \(network.active)/\(network.maximum)  ·  wait \(network.queued)")
            Text("FG \(network.foregroundActive) (+\(network.foregroundQueued))  BG \(network.backgroundActive) (+\(network.backgroundQueued))")
            Text("QUEUE  \(playback.queue.upcomingCount) upcoming")
            Text("CACHE  \(preload.readyCount)/\(preload.windowCount) ready  ·  current \(currentReadiness)")
            if preload.activeCount > 0 {
                Text("PRELOAD  \(preload.activeCount) active  ·  \(megabytes(preload.downloadedBytes))/\(megabytes(preload.downloadingBytes)) MB")
            }
            Text("CACHE SIZE  \(megabytes(preload.storedBytes))/\(megabytes(preload.capacityBytes)) MB")
            Text("DOWNLOADS  \(activeTransfers) active / \(pausedTransfers) paused")
            Text("PLAY  \(playbackStatus)")
            if let audioDeliveryRate {
                Text("AUDIO  \(audioDeliveryRate * 8 / 1_000_000, specifier: "%.2f") Mbps effective")
            }
            if !network.recentFailures.isEmpty {
                Divider().overlay(.secondary.opacity(0.25))
                Text("RECENT FAILURES · SAVED").foregroundStyle(.red)
                ForEach(Array(network.recentFailures.suffix(size == "small" ? 1 : 3).reversed()), id: \.self) { failure in
                    Text(failure).foregroundStyle(.primary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: width, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5))
        .task {
            while !Task.isCancelled {
                network = await NetworkOperationCoordinator.shared.snapshot()
                audioDeliveryRate = await PlaybackThroughput.shared.latestRate()
                preload = await playback.preloadSnapshot()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func positionButton(_ title: String, value: String) -> some View {
        Button { corner = value } label: {
            if corner == value { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func sizeButton(_ title: String, value: String) -> some View {
        Button { selectedSize = value } label: {
            if selectedSize == value { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func megabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000) }

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
    @Environment(\.downtifyPalette) private var palette
    @EnvironmentObject private var downloads: OfflineDownloads
    @EnvironmentObject private var collections: LibraryCollectionsModel
    let entries: [LibraryBrowseEntry]
    let grid: Bool
    var carousel = false
    var compactTiles = false
    /// Entries marked with a pin in the redesigned list (Liked Songs and favorite playlists).
    var pinnedIDs: Set<String> = []

    var body: some View {
        if palette.redesign("library") && !compactTiles && !carousel {
            redesignBody
        } else {
            standardBody
        }
    }

    /// Spotify-style grid (cover over title and kind) or rows with a 60 pt cover and "kind · owner".
    @ViewBuilder
    private var redesignBody: some View {
        if grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 18) {
                ForEach(entries, id: \.context) { entry in
                    NavigationLink(value: entry.context) {
                        VStack(alignment: entry.isArtist ? .center : .leading, spacing: 6) {
                            LibraryEntryArtwork(entry: entry, size: 104)
                            Text(entry.title).font(.footnote.weight(.semibold)).lineLimit(2)
                            Text(entry.kindSubtitle).font(.caption).foregroundStyle(DowntifyStyle.secondaryText).lineLimit(1)
                        }
                        .multilineTextAlignment(entry.isArtist ? .center : .leading)
                        .frame(maxWidth: .infinity, alignment: entry.isArtist ? .center : .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            let onDevice = Set(downloads.currentDownloads.filter { $0.state == .ready }.map(\.track.id))
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(entries, id: \.context) { entry in
                    NavigationLink(value: entry.context) {
                        LibraryListRow(entry: entry, isPinned: pinnedIDs.contains(entry.id),
                                       isOnDevice: entry.count > 0 && isFullyOnDevice(entry, onDevice: onDevice))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Playlists and Liked Songs whose every song is saved on this device show the download mark.
    private func isFullyOnDevice(_ entry: LibraryBrowseEntry, onDevice: Set<String>) -> Bool {
        guard !onDevice.isEmpty else { return false }
        switch entry.context {
        case .playlist(let name):
            guard let ids = collections.playlist(named: name)?.trackIDs, !ids.isEmpty else { return false }
            return ids.allSatisfy(onDevice.contains)
        case .liked:
            guard let ids = collections.likedIDs, !ids.isEmpty else { return false }
            return ids.allSatisfy(onDevice.contains)
        case .album, .artist:
            return false
        }
    }

    @ViewBuilder
    private var standardBody: some View {
        if compactTiles {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.context) {
                        HStack(spacing: 8) {
                            artwork(entry, size: 52)
                            Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if carousel {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.context) {
                            VStack(alignment: .leading, spacing: 6) {
                                artwork(entry, size: 142)
                                Text(entry.title).font(.headline).lineLimit(2)
                                Text(subtitle(entry)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(width: 142, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else if grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: palette.theme.map { CGFloat($0.albumGridMinimum) } ?? 142), spacing: 12)], spacing: 12) {
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
    @EnvironmentObject private var artworkLoader: ArtworkLoader
    @Environment(\.downtifyPalette) private var palette
    @State private var artworkTint: Color?
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

    @State private var showsBarTitle = false

    private var isAlbum: Bool { if case .album = context { true } else { false } }
    private var isArtist: Bool { if case .artist = context { true } else { false } }

    var body: some View {
        let tracks = library.catalog.tracks(in: context, likedIDs: collections.likedIDs ?? [], playlist: playlist)
        Group {
            if palette.redesign("collection") { redesignPage(tracks) } else { standardPage(tracks) }
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
        .confirmationDialog("Add these songs to this device for offline playback?", isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("Add to Device") {
                var failures = 0
                var queued = Set<String>()
                for track in tracks where queued.insert(track.id).inserted {
                    do { try downloads.enqueue(track) } catch { failures += 1 }
                }
                downloadMessage = failures == 0 ? "Adding songs to this device." : "Some downloads could not be started."
            }
        }
    }

    private func standardPage(_ tracks: [LibraryTrack]) -> some View {
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
                        playlistEditButtons
                    } label: {
                        Image(systemName: "pencil.and.list")
                    }
                    .accessibilityLabel("Edit playlist")
                }
            }
        }
    }

    @ViewBuilder
    private var playlistEditButtons: some View {
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
    }

    /// Cover-tinted header, large artwork, byline and a "kind · year · songs · length" line; the bar title fades in
    /// once the header scrolls away.
    private func redesignPage(_ tracks: [LibraryTrack]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DowntifyStyle.Space.regular) {
                header(tracks)
                redesignActions(tracks)
                if let downloadMessage { Text(downloadMessage).font(.subheadline).foregroundStyle(.secondary) }
                PlaylistMutationFeedbackRow()
                status(tracks)
                if !tracks.isEmpty {
                    if isArtist {
                        Text("Popular").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    }
                    LibraryTrackList(tracks: tracks, context: context, playback: playback,
                                     onMoveToTrash: onMoveToTrash, showsArtwork: !isAlbum)
                } else if let error = collections.actionError {
                    Text(error).foregroundStyle(.secondary)
                    Button("Dismiss") { collections.clearError() }
                }
                if case .artist(let id) = context {
                    let albums = library.catalog.albums(for: id)
                    if !albums.isEmpty {
                        Text("Albums").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            .padding(.top, DowntifyStyle.Space.small)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(albums) { album in
                                    NavigationLink(value: album.context) { ShelfCard(entry: album, size: 140) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, DowntifyStyle.Space.regular)
                        }
                        .padding(.horizontal, -DowntifyStyle.Space.regular)
                    }
                    if catalog.externalCatalogAvailable, let artist = library.catalog.artistsByID[id] {
                        NavigationLink {
                            ArtistCatalogAlbumsView(artist: artist.title, library: library,
                                                    serverDownloads: serverDownloads, catalog: catalog)
                        } label: {
                            Label("Find more albums", systemImage: "plus.circle")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 36)
                                .overlay(Capsule().strokeBorder(DowntifyStyle.secondaryText, lineWidth: 1))
                                .frame(minHeight: DowntifyStyle.minimumControlSize)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: "collection")
        .onPreferenceChange(CollectionHeaderBottomKey.self) { bottom in
            let shows = bottom < 40
            if shows != showsBarTitle { withAnimation(.easeInOut(duration: 0.2)) { showsBarTitle = shows } }
        }
        .downtifyScrollEndClearance()
        .refreshable {
            async let music: Void = library.refresh()
            async let lists: Void = collections.refresh()
            _ = await (music, lists)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [(artworkTint ?? palette.elevated).opacity(0.95), palette.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 440)
                .ignoresSafeArea(edges: .top)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(showsBarTitle ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(artworkTint ?? palette.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: title).font(.headline).lineLimit(1).opacity(showsBarTitle ? 1 : 0)
                    .accessibilityHidden(!showsBarTitle)
            }
        }
        .artworkTint(for: tracks.first(where: \.hasCover), into: $artworkTint)
    }

    @ViewBuilder
    private func header(_ tracks: [LibraryTrack]) -> some View {
        let size: CGFloat = isArtist ? 200 : 232
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if case .liked = context {
                    LikedSongsArtwork(size: size)
                } else if let cover = playlist?.cover, !cover.isEmpty {
                    TrackArtwork(track: tracks.first(where: \.hasCover), size: size, playlistCover: cover)
                } else if let cover = tracks.first(where: \.hasCover) {
                    TrackArtwork(track: cover, size: size)
                        .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(Rectangle()))
                } else {
                    Image(systemName: isArtist ? "music.mic" : "music.note.list")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(DowntifyStyle.secondaryText)
                        .frame(width: size, height: size)
                        .background(palette.elevated, in: isArtist ? AnyShape(Circle()) : AnyShape(Rectangle()))
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            .frame(maxWidth: .infinity)
            .padding(.top, DowntifyStyle.Space.small)
            .padding(.bottom, DowntifyStyle.Space.small)
            .accessibilityHidden(true)

            Text(verbatim: title)
                .font(isArtist ? .largeTitle.bold() : .title.bold())
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: CollectionHeaderBottomKey.self,
                                           value: proxy.frame(in: .named("collection")).maxY)
                })
            byline(tracks)
            Text(verbatim: metadata(tracks))
                .font(.subheadline)
                .foregroundStyle(DowntifyStyle.secondaryText)
        }
    }

    @ViewBuilder
    private func byline(_ tracks: [LibraryTrack]) -> some View {
        if case .album(let id) = context, let album = library.catalog.albumsByID[id], !album.artist.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(DowntifyStyle.secondaryText)
                if let artistID = tracks.first?.artistID, library.catalog.artistsByID[artistID] != nil {
                    NavigationLink(value: LibraryContext.artist(artistID)) {
                        Text(verbatim: album.artist).font(.subheadline.weight(.bold)).foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(verbatim: album.artist).font(.subheadline.weight(.bold))
                }
            }
        } else if let playlist, playlist.mine == false, let owner = playlist.owner, !owner.isEmpty {
            Text("By \(owner)").font(.subheadline.weight(.bold))
        }
    }

    private func metadata(_ tracks: [LibraryTrack]) -> String {
        let kind: String = switch context {
        case .album: String(localized: "Album")
        case .artist: String(localized: "Artist")
        case .playlist, .liked: String(localized: "Playlist")
        }
        var parts = [kind]
        if isAlbum, let year = tracks.first(where: { !$0.year.isEmpty })?.year { parts.append(String(year.prefix(4))) }
        if !tracks.isEmpty {
            parts.append(tracks.count == 1 ? String(localized: "1 song") : String(localized: "\(tracks.count) songs"))
            let minutes = Int(tracks.reduce(0) { $0 + max(0, $1.duration) } / 60)
            if minutes > 0 {
                parts.append(minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min")
                                           : String(localized: "\(minutes) min"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Pin, download and "…" on the left; shuffle and the large play button on the right.
    private func redesignActions(_ tracks: [LibraryTrack]) -> some View {
        let onDevice = Set(downloads.currentDownloads.filter { $0.state == .ready }.map(\.track.id))
        let allOnDevice = !tracks.isEmpty && tracks.allSatisfy { onDevice.contains($0.id) }
        return HStack(spacing: 18) {
            if let playlist, playlist.favorite != nil {
                let favorite = collections.effectiveFavorite(playlist)
                Button {
                    Task { await collections.toggleFavorite(playlist.name) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: favorite ? "pin.circle.fill" : "pin.circle")
                            .font(.title)
                            .foregroundStyle(favorite ? palette.accent : DowntifyStyle.secondaryText)
                        if collections.hasPendingFavorite(playlist.name) {
                            Text("Queued").font(.caption)
                        }
                    }
                    .downtifyControlTarget()
                }
                .buttonStyle(.plain)
                .disabled(collections.mutationBusy)
                .accessibilityLabel(favorite ? String(localized: "Remove playlist from favorites") : String(localized: "Favorite playlist"))
                .accessibilityValue(collections.hasPendingFavorite(playlist.name) ? String(localized: "Queued") : "")
            }
            if !tracks.isEmpty {
                Button { if !allOnDevice { confirmingDownload = true } } label: {
                    Image(systemName: allOnDevice ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.title)
                        .foregroundStyle(allOnDevice ? palette.accent : DowntifyStyle.secondaryText)
                        .downtifyControlTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(allOnDevice ? String(localized: "Downloaded to this device") : String(localized: "Add Songs to Device"))
                Menu {
                    Button("Add songs to queue", systemImage: "text.append") { playback.append(tracks) }
                    Button(String(localized: "Add Songs to Device"), systemImage: "arrow.down.to.line.circle") { confirmingDownload = true }
                    if canRenamePlaylist || canEditTracks {
                        Section("Edit playlist") { playlistEditButtons }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(DowntifyStyle.secondaryText)
                        .downtifyControlTarget()
                }
                .accessibilityLabel("Collection actions")
            }
            Spacer(minLength: 0)
            if !tracks.isEmpty {
                Button {
                    collections.record(context)
                    playback.replaceQueue(tracks, startingAt: Int.random(in: tracks.indices))
                    playback.setShuffle(true)
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(DowntifyStyle.secondaryText)
                        .downtifyControlTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle songs")
                NowPlayingReader { nowPlaying in
                    let isCurrent = tracks.contains(where: nowPlaying.isCurrent)
                    DowntifyPlayButton(isPlaying: isCurrent && nowPlaying.isPlaying) {
                        if isCurrent {
                            playback.togglePlayback()
                        } else {
                            collections.record(context)
                            playback.setShuffle(false)
                            playback.replaceQueue(tracks)
                        }
                    }
                    .accessibilityIdentifier("collection.play")
                }
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
                .accessibilityLabel(favorite ? String(localized: "Remove playlist from favorites") : String(localized: "Favorite playlist"))
                .accessibilityValue(collections.hasPendingFavorite(playlist.name) ? String(localized: "Queued") : "")
            }
            if !tracks.isEmpty {
                Menu {
                    Button("Add songs to queue", systemImage: "text.append") { playback.append(tracks) }
                    Button(String(localized: "Add Songs to Device"), systemImage: "arrow.down.to.line.circle") { confirmingDownload = true }
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
            Label(hasCache ? String(localized: "Showing saved collection. Refresh failed.") : String(localized: "Collection unavailable."),
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
        .downtifyScrollEndClearance()
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

private struct CollectionHeaderBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
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
    @Environment(\.downtifyPalette) private var palette
    let album: CatalogAlbum
    @ObservedObject var library: LibraryPresentationModel
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    @ObservedObject var catalog: CatalogPresentationModel
    @State private var songs: [CatalogSong] = []
    @State private var isLoading = true
    @State private var error: String?

    private func isInLibrary(_ song: CatalogSong) -> Bool {
        library.membership.containsSong(song)
    }

    private func canRequest(_ song: CatalogSong) -> Bool {
        guard catalog.externalCatalogAvailable, !isInLibrary(song), song.source != "library" else { return false }
        switch serverDownloads.actionState(for: song) {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func status(_ song: CatalogSong) -> String {
        if isInLibrary(song) || song.source == "library" { return String(localized: "In Library") }
        return MediaActionPresentation.library(serverDownloads.actionState(for: song), itemTitle: song.title).title
    }

    var body: some View {
        List {
            if isLoading { ProgressView("Loading album…") }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !isLoading && error == nil && songs.isEmpty { Text("No songs found.").foregroundStyle(.secondary) }
            let missing = songs.filter(canRequest)
            if !missing.isEmpty {
                Button(String(localized: "Add Missing Songs to Library"), systemImage: "plus.circle") {
                    Task { await serverDownloads.requestBatch(songs: missing) }
                }
            }
            ForEach(songs) { song in
                VStack(alignment: .leading) {
                    HStack {
                        NowPlayingReader { nowPlaying in
                            let isCurrent = nowPlaying.isCurrent(song)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if isCurrent { NowPlayingBadge(isPlaying: nowPlaying.isPlaying) }
                                Text(song.title)
                                    .foregroundStyle(isCurrent ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.primary))
                            }
                            .accessibilityElement(children: .combine)
                            .downtifyCurrentRowAccessibility(isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying)
                        }
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
                Text("Songs appear in your Library after the server adds them and the library syncs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(album.title)
        .downtifyScrollEndClearance()
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

/// Adds one library song to a playlist the listener can edit. Shared by Now Playing and song row menus.
struct AddToPlaylistSheet: View {
    let track: LibraryTrack
    /// Called with the playlist title after the server confirms the song is in the playlist.
    let onAdded: (String) -> Void
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.downtifyPalette) private var palette
    @State private var addingTo: String?
    @State private var duplicate: LibraryPlaylist?

    private var playlists: [LibraryPlaylist] {
        EditablePlaylists.sorted(collections.playlists, supportsEditing: collections.supportsPlaylistEditing)
    }

    private var duplicateTitle: String { duplicate?.title ?? "" }

    var body: some View {
        NavigationStack {
            List {
                PlaylistMutationFeedbackRow()
                if playlists.isEmpty {
                    DowntifyUnavailableView(title: "No playlists you can edit", symbol: "music.note.list")
                        .listRowBackground(palette.surface)
                }
                ForEach(playlists) { playlist in
                    let contains = playlist.trackIDs.contains(track.id)
                    Button { choose(playlist) } label: {
                        HStack {
                            Label { Text(verbatim: playlist.title) } icon: {
                                Image(systemName: playlist.favorite == true ? "star.fill" : "music.note.list")
                            }
                            Spacer()
                            if addingTo == playlist.name {
                                ProgressView()
                            } else if contains {
                                Image(systemName: "checkmark").foregroundStyle(DowntifyStyle.secondaryText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .downtifyControlTarget()
                    .disabled(collections.mutationBusy)
                    .accessibilityValue(contains ? String(localized: "Already in this playlist") : "")
                    .accessibilityIdentifier("addToPlaylist.\(playlist.name)")
                    .listRowBackground(palette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
            .toolbarBackground(palette.background, for: .navigationBar)
            .navigationTitle("Choose Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog(String(localized: "Already in \(duplicateTitle)"),
                                isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }),
                                titleVisibility: .visible, presenting: duplicate) { playlist in
                Button("Add Again") { add(to: playlist, allowDuplicates: true) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This song is already in the playlist. Add another copy?")
            }
        }
        .onAppear { collections.clearPlaylistMutationError() }
    }

    private func choose(_ playlist: LibraryPlaylist) {
        if playlist.trackIDs.contains(track.id) {
            duplicate = playlist
        } else {
            add(to: playlist, allowDuplicates: false)
        }
    }

    private func add(to playlist: LibraryPlaylist, allowDuplicates: Bool) {
        let before = playlist.trackIDs.filter { $0 == track.id }.count
        addingTo = playlist.name
        Task {
            await collections.addTracks([track.id], to: playlist.name, allowDuplicates: allowDuplicates)
            addingTo = nil
            // Confirm only when the refreshed playlist really holds another copy of the song.
            let after = collections.playlist(named: playlist.name)?.trackIDs.filter { $0 == track.id }.count ?? before
            if collections.playlistMutationError == nil, after > before {
                onAdded(collections.playlist(named: playlist.name)?.title ?? playlist.title)
                dismiss()
            }
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

struct PlaylistMutationFeedbackRow: View {
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
    /// Album pages in the redesigned layout leave artwork off each row, as every song shares the album cover.
    var showsArtwork = true
    @EnvironmentObject private var collections: LibraryCollectionsModel
    @EnvironmentObject private var downloads: OfflineDownloads
    @Environment(\.downtifyPalette) private var palette
    @State private var downloadMessage: LocalizedStringKey?
    @State private var playlistTrack: LibraryTrack?

    private var redesign: Bool { palette.redesign("library") || palette.redesign("collection") }

    private var canAddToPlaylists: Bool {
        !EditablePlaylists.sorted(collections.playlists, supportsEditing: collections.supportsPlaylistEditing).isEmpty
    }

    /// Shows inline feedback and announces it for VoiceOver.
    private func announceQueueChange(_ message: LocalizedStringKey, _ spoken: String) {
        downloadMessage = message
        AccessibilityNotification.Announcement(spoken).post()
    }

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
                    NowPlayingReader { nowPlaying in
                        let isCurrent = nowPlaying.isCurrent(track)
                        Button {
                            if let context { collections.record(context) }
                            playback.replaceQueue(tracks, startingAt: index)
                        } label: {
                            TrackRow(track: track, isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying,
                                     showsArtwork: showsArtwork,
                                     isOnDevice: redesign && downloadByID[track.id]?.state == .ready)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(track.accessibleMetadata))
                        .downtifyCurrentRowAccessibility(isCurrent: isCurrent, isPlaying: nowPlaying.isPlaying,
                                                         value: spokenDuration(track.duration))
                        .accessibilityHint("Play this song and replace the current queue")
                        .accessibilityIdentifier("library.trackRow.\(track.id)")
                    }
                    Menu {
                        if collections.likedIDs != nil {
                            Button(liked ? String(localized: "Unlike song") : String(localized: "Like song"), systemImage: liked ? "heart.slash" : "heart") {
                                Task { await collections.toggleLike(track) }
                            }
                            .disabled(collections.mutationBusy)
                            if collections.hasPendingLike(track.id) { Text("Queued") }
                        }
                        Button("Play next", systemImage: "text.insert") {
                            playback.playNext([track])
                            announceQueueChange("Added to play next", String(localized: "Added to play next"))
                        }
                        .accessibilityIdentifier("library.menu.playNext.\(track.id)")
                        Button("Add to queue", systemImage: "text.append") {
                            playback.append([track])
                            announceQueueChange("Added to queue", String(localized: "Added to queue"))
                        }
                        .accessibilityIdentifier("library.menu.addToQueue.\(track.id)")
                        if canAddToPlaylists {
                            Button("Add to Playlist", systemImage: "text.badge.plus") { playlistTrack = track }
                                .disabled(collections.mutationBusy)
                        }
                        if let onMoveToTrash {
                            Button("Move to trash", systemImage: "trash", role: .destructive) { onMoveToTrash(track) }
                        }
                        downloadAction(track, record: downloadByID[track.id])
                    } label: {
                        HStack(spacing: redesign ? 6 : 0) {
                            if liked {
                                Image(systemName: "heart.fill").font(redesign ? .footnote : .caption).foregroundStyle(palette.accent)
                            }
                            if collections.hasPendingLike(track.id) {
                                Image(systemName: "clock").font(.caption).accessibilityLabel("Queued")
                            }
                            if redesign {
                                Image(systemName: "ellipsis").foregroundStyle(DowntifyStyle.secondaryText)
                            } else {
                                Image(systemName: "ellipsis")
                            }
                        }
                        .downtifyControlTarget()
                    }
                    .accessibilityLabel("Actions for \(track.displayTitle)")
                    .accessibilityIdentifier("library.menu.\(track.id)")
                    .accessibilityValue(liked ? Text("Liked") : Text(""))
                }
                if index < tracks.count - 1 && !redesign { Divider().padding(.leading, 80) }
            }
        }
        .background(redesign ? AnyShapeStyle(Color.clear) : AnyShapeStyle(palette.surface), in: RoundedRectangle(cornerRadius: 20))
        .sheet(item: $playlistTrack) { track in
            AddToPlaylistSheet(track: track) { title in
                downloadMessage = "Added to \(title)"
                AccessibilityNotification.Announcement(String(localized: "Added to \(title)")).post()
            }
            .presentationDragIndicator(.visible)
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func downloadAction(_ track: LibraryTrack, record: OfflineDownload?) -> some View {
        let state = DeviceSaveState(track: track, record: record)
        MediaActionButton(presentation: .device(state, itemTitle: track.title), style: .label) {
            do {
                if case .failed = state, let record {
                    _ = try downloads.retry(record.id)
                } else {
                    _ = try downloads.enqueue(track)
                }
                downloadMessage = "Adding to this device."
            } catch { downloadMessage = "Could not add this song to the device." }
        }
        switch state {
        case .pending, .transferring:
            if let record {
                Button(String(localized: "Cancel Adding to Device"), systemImage: "xmark.circle") { downloads.cancel(record.id) }
            }
        case .saved:
            if let record {
                Button(String(localized: "Remove from Device"), systemImage: "trash", role: .destructive) {
                    do { try downloads.delete(record.id); downloadMessage = "Removed from this device." }
                    catch { downloadMessage = "Could not remove this song from the device." }
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Observes the server queue only for the Search tab so Add to Library rows refresh
/// without re-rendering the whole library root on every queue poll.
private struct CatalogSearchContainer: View {
    @ObservedObject var catalog: CatalogPresentationModel
    @ObservedObject var library: LibraryPresentationModel
    let playback: PlaybackController
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    let libraryState: (CatalogSong) -> ServerDownloadActionState
    let onAddToDevice: (CatalogSong) -> Void
    let deviceState: (CatalogSong) -> DeviceSaveState
    let onBrowse: (String) -> Void
    let loadSuggestions: () -> Void
    /// The drawer layout's own Browse grid, shown instead of the built-in shortcuts.
    var browse: AnyView? = nil

    var body: some View {
        CatalogSearchView(catalog: catalog, library: library, playback: playback,
                          onDownloadAlbum: { url, tracks in Task { await serverDownloads.requestAlbum(url: url, expected: tracks) } },
                          albumDownloadState: { album, count in
                              .catalogRow(server: serverDownloads.actionState(forAlbumURL: album.url ?? ""),
                                          inLibrary: library.membership.isAlbumFullyInLibrary(
                                              title: album.title, artist: album.artist, trackCount: count))
                          },
                          onDownload: { song in Task { await serverDownloads.request(song: song) } },
                          downloadState: libraryState,
                          onAddToDevice: onAddToDevice,
                          deviceState: deviceState, onBrowse: onBrowse, loadSuggestions: loadSuggestions,
                          browse: browse)
    }
}

/// Same scoping for the Discover tab.
private struct CatalogDiscoverContainer: View {
    @ObservedObject var catalog: CatalogPresentationModel
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    let libraryTracks: [LibraryTrack]
    let membership: LibraryMembership
    let libraryArtists: [CatalogLibraryArtist]
    let libraryAlbums: [CatalogLibraryAlbum]
    let playlistNames: [String]
    let playlistIDs: [String]
    let onPlay: (CatalogSong) -> Void
    let libraryState: (CatalogSong) -> ServerDownloadActionState
    let onAddToDevice: (CatalogSong) -> Void
    let deviceState: (CatalogSong) -> DeviceSaveState
    let onOpenURL: (URL) -> Void

    var body: some View {
        CatalogDiscoverView(
            catalog: catalog,
            libraryTracks: libraryTracks,
            libraryArtists: libraryArtists,
            libraryAlbums: libraryAlbums,
            playlistNames: playlistNames,
            playlistIDs: playlistIDs,
            shownArtists: [],
            onPlay: onPlay,
            onDownload: { song in Task { await serverDownloads.request(song: song) } },
            onDownloadAlbum: { url, tracks in Task { await serverDownloads.requestAlbum(url: url, expected: tracks) } },
            downloadState: libraryState,
            onAddToDevice: onAddToDevice,
            deviceState: deviceState,
            albumDownloadState: { album, count in
                .catalogRow(server: serverDownloads.actionState(forAlbumURL: album.url ?? ""),
                            inLibrary: membership.isAlbumFullyInLibrary(
                                title: album.title, artist: album.artist, trackCount: count))
            },
            onOpenURL: onOpenURL,
            membership: membership
        )
    }
}
