import SwiftUI

struct DownloadsView: View {
    let connection: ConnectionService
    let queue: ServerDownloadQueue
    @ObservedObject var serverDownloads: ServerDownloadPresentationModel
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject private var downloads: OfflineDownloads
    @EnvironmentObject private var catalog: CatalogPresentationModel
    @Environment(\.downtifyPalette) private var palette
    @State private var session: DeviceSession?
    @State private var link = ""
    @State private var submittingLink = false
    @State private var catalogQuery = ""
    @State private var selectedCatalogSongs: Set<CatalogResultID> = []
    @State private var localError: LocalizedStringKey?
    @State private var requestMessage: LocalizedStringKey?

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: DowntifyStyle.Space.large) {
                localSection
                serverSection
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Downloads")
        .toolbarBackground(palette.background, for: .navigationBar)
        .task { serverDownloads.start(); await load() }
        .refreshable { await refreshQueue() }
        .alert("Download request", isPresented: Binding(get: { requestMessage != nil }, set: { if !$0 { requestMessage = nil } })) {
            Button("OK", role: .cancel) { requestMessage = nil }
        } message: { if let requestMessage { Text(requestMessage) } }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("On this device", systemImage: "iphone.gen3")
                .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Offline files use device storage and can play without a server connection.")
                .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DowntifyStyle.error).accessibilityAddTraits(.isStaticText)
            }
            let items = downloads.currentDownloads
            if items.isEmpty {
                ContentUnavailableView("No offline downloads", systemImage: "arrow.down.to.line",
                                       description: Text("Choose Download for offline playback from a song’s actions."))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                ForEach(items) { item in localRow(item) }
            }
            HStack {
                Label("Saved", systemImage: "internaldrive")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: downloads.storedBytes, countStyle: .file))
                    .monospacedDigit()
            }.font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func localRow(_ item: OfflineDownload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.track.displayTitle).font(.headline).lineLimit(2)
                    Text(item.track.displayArtist).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                    Text(localStatus(item)).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                }
                Spacer(minLength: 8)
                Menu {
                    if item.state == .ready {
                        Button("Play offline", systemImage: "play.fill") {
                            playback.replaceQueue([item.track], startingAt: 0)
                        }
                        Button("Delete offline file", systemImage: "trash", role: .destructive) {
                            do { try downloads.delete(item.id); localError = nil }
                            catch { localError = "Could not delete the offline file. Check available storage and try again." }
                        }
                    } else if item.pending {
                        Button("Cancel download", systemImage: "xmark.circle") { downloads.cancel(item.id) }
                    } else {
                        Button("Retry download", systemImage: "arrow.clockwise") {
                            do { _ = try downloads.retry(item.id); localError = nil }
                            catch { localError = "Could not retry this download. Reconnect and try again." }
                        }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            do { try downloads.delete(item.id); localError = nil }
                            catch { localError = "Could not remove this download." }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Actions for \(item.track.displayTitle)")
            }
            if item.state == .transferring, let expected = item.expectedBytes, expected > 0 {
                ProgressView(value: Double(item.receivedBytes), total: Double(expected))
                    .accessibilityLabel("Download progress for \(item.track.displayTitle)")
                    .accessibilityValue("\(Int(Double(item.receivedBytes) / Double(expected) * 100)) percent")
            } else if item.state == .preparing {
                ProgressView().accessibilityLabel("Preparing \(item.track.displayTitle)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Server queue", systemImage: "server.rack")
                .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("These jobs run on the server. Completed items become available through library sync; they are not saved on this device.")
                .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
            catalogDownloadActions
            if let queueStatus = serverDownloads.queueStatus {
                Text("Queue \(queueStatus.paused ? "paused" : queueStatus.state) · \(queueStatus.active) active")
                    .font(.subheadline).accessibilityLabel("Server queue \(queueStatus.state), \(queueStatus.active) active jobs")
            }
            if let queueError = serverDownloads.queueError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(queueError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DowntifyStyle.error)
                    Button("Retry server queue", systemImage: "arrow.clockwise") { Task { await refreshQueue() } }
                }.font(.footnote)
            } else if serverDownloads.jobs.isEmpty && !serverDownloads.isRefreshing {
                ContentUnavailableView("Server queue is empty", systemImage: "tray",
                                       description: Text("Add a supported link to request a server download."))
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            if serverDownloads.isRefreshing { ProgressView("Loading server queue…") }
            ForEach(serverDownloads.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.song.title ?? job.filename ?? "Server download")
                        .font(.headline).lineLimit(2)
                    if let artist = job.song.artist, !artist.isEmpty {
                        Text(artist).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                    }
                    HStack {
                        Text(job.status.capitalized)
                        if let position = job.position { Text("· Position \(position)") }
                        Spacer()
                        if let progress = job.progress, progress.isFinite {
                            Text("\(Int(max(0, min(100, progress))))%")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                    if let progress = job.progress, progress.isFinite, progress > 0, progress < 100 {
                        ProgressView(value: max(0, min(100, progress)), total: 100)
                            .accessibilityLabel("Server job progress")
                            .accessibilityValue("\(Int(max(0, min(100, progress)))) percent")
                    }
                    if let message = job.message, !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
                    }
                }.padding(.vertical, 6)
            }
            HStack(spacing: 8) {
                TextField("https://…", text: $link)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Link for server download")
                Button("Request", systemImage: "arrow.down.to.line") { Task { await submitLink() } }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || serverDownloads.isRefreshing || submittingLink)
                    .frame(minHeight: 44)
            }
            .padding(.top, 4)
            Text("Server queue controls are managed by the server. This paired device can view jobs and submit links.")
                .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var catalogDownloadActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find music to download to the server")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("Song or album", text: $catalogQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Search catalog for server downloads")
                Button("Search", systemImage: "magnifyingglass") {
                    selectedCatalogSongs.removeAll()
                    catalog.search(catalogQuery)
                }
                .disabled(catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalog.isLibraryOnly != false)
                .frame(minHeight: 44)
            }
            if catalog.isLibraryOnly == true {
                Text("Server downloads are unavailable in library-only mode.")
                    .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
            } else {
                let songs = catalogSongs
                if !songs.isEmpty {
                    ForEach(songs) { song in
                        HStack(spacing: 8) {
                            Button {
                                if selectedCatalogSongs.contains(song.id) { selectedCatalogSongs.remove(song.id) }
                                else { selectedCatalogSongs.insert(song.id) }
                            } label: {
                                Image(systemName: selectedCatalogSongs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                            }
                            .accessibilityLabel(selectedCatalogSongs.contains(song.id) ? "Deselect \(song.title)" : "Select \(song.title)")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text(song.artists.joined(separator: ", ")).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                            }
                            Spacer(minLength: 4)
                            Button(songActionTitle(for: song), systemImage: "arrow.down.to.line") {
                                Task { await serverDownloads.request(song: song) }
                            }
                            .disabled(catalog.isLibraryOnly != false || !canRequest(serverDownloads.actionState(for: song)))
                            .accessibilityLabel("Download \(song.title) to server")
                        }
                        .padding(.vertical, 3)
                        if case .failed(let message) = serverDownloads.actionState(for: song) {
                            Text(message).font(.caption).foregroundStyle(DowntifyStyle.error)
                        }
                    }
                    if selectedCatalogSongs.count > 1 {
                        Button("Download selected (\(selectedCatalogSongs.count))", systemImage: "arrow.down.to.line.compact") {
                            let selected = songs.filter { selectedCatalogSongs.contains($0.id) }
                            Task { await serverDownloads.requestBatch(songs: selected) }
                        }
                        .disabled(catalog.isLibraryOnly != false || !songs.filter { selectedCatalogSongs.contains($0.id) }
                            .allSatisfy { canRequest(serverDownloads.actionState(for: $0)) })
                    }
                }
                ForEach(catalogAlbums) { album in
                    if let url = album.url, isSupportedAlbumURL(url) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text(album.artist).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                            }
                            Spacer()
                            Button(albumActionTitle(for: url), systemImage: "arrow.down.to.line") {
                                Task { await serverDownloads.requestAlbum(url: url) }
                            }
                            .disabled(catalog.isLibraryOnly != false || !canRequest(serverDownloads.actionState(forAlbumURL: url)))
                            .accessibilityLabel("Download album \(album.title) to server")
                        }
                        if case .failed(let message) = serverDownloads.actionState(forAlbumURL: url) {
                            Text(message).font(.caption).foregroundStyle(DowntifyStyle.error)
                        }
                    }
                }
                if songs.isEmpty, catalogAlbums.isEmpty, !catalogQuery.isEmpty {
                    switch catalog.searchSongsState {
                    case .loading: ProgressView("Searching catalog…")
                    case .failed(let message), .unavailable(let message): Text(message).font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
                    default: EmptyView()
                    }
                }
            }
            if !selectedCatalogSongs.isEmpty {
                Button("Clear selection") { selectedCatalogSongs.removeAll() }
                    .font(.caption)
            }
        }
        .padding(12)
        .background(palette.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var catalogSongs: [CatalogSong] {
        switch catalog.searchSongsState {
        case .loaded(let songs), .partial(let songs, _): songs
        default: []
        }
    }

    private var catalogAlbums: [CatalogAlbum] {
        switch catalog.searchAlbumsState {
        case .loaded(let albums), .partial(let albums, _): albums
        default: []
        }
    }

    private func canRequest(_ state: ServerDownloadActionState) -> Bool {
        switch state {
        case .idle, .failed: true
        case .submitting, .queued, .accepted, .partiallyAccepted, .outcomeUnknown: false
        }
    }

    private func songActionTitle(for song: CatalogSong) -> String {
        switch serverDownloads.actionState(for: song) {
        case .submitting: String(localized: "Requesting…")
        case .queued: String(localized: "Queued")
        case .accepted: String(localized: "Requested")
        case .partiallyAccepted: String(localized: "Partially queued")
        case .outcomeUnknown: String(localized: "Check queue")
        case .failed: String(localized: "Retry")
        case .idle: String(localized: "Download to server")
        }
    }

    private func albumActionTitle(for url: String) -> String {
        switch serverDownloads.actionState(forAlbumURL: url) {
        case .submitting: String(localized: "Requesting…")
        case .accepted: String(localized: "Finished")
        case .partiallyAccepted(let successful, let expected): String(localized: "\(successful) of \(expected) downloaded")
        case .outcomeUnknown: String(localized: "Check queue")
        case .failed: String(localized: "Retry")
        case .queued: String(localized: "Queued")
        case .idle: String(localized: "Download to server")
        }
    }

    private func isSupportedAlbumURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "music.youtube.com" else { return false }
        return components.path.range(of: #"^/browse/MPREb_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
            || components.queryItems?.contains(where: { $0.name == "list" && $0.value?.range(of: #"^OLAK5uy_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }) == true
    }

    private func localStatus(_ item: OfflineDownload) -> LocalizedStringKey {
        switch item.state {
        case .preparing: return "Preparing download"
        case .transferring:
            if let expected = item.expectedBytes, expected > 0 {
                return "Downloading · \(ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
            }
            return "Downloading"
        case .ready: return "Available offline"
        case .cancelled: return "Cancelled"
        case let .failed(reason): return "Failed · \(reason.localizedDescription)"
        }
    }

    @MainActor private func load() async {
        guard session == nil else { return }
        session = try? await connection.restoreSession()
        await refreshQueue()
    }

    @MainActor private func refreshQueue() async {
        guard await activeSession() != nil else { return }
        await serverDownloads.refreshQueue()
    }

    @MainActor private func submitLink() async {
        guard !submittingLink else { return }
        submittingLink = true
        defer { submittingLink = false }
        guard let session = await activeSession() else {
            requestMessage = "Reconnect to request a server download."
            return
        }
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            requestMessage = "Enter a complete HTTP or HTTPS link."
            return
        }
        do {
            _ = try await queue.requestTrack(link: url, session: session)
            link = ""
            await refreshQueue()
            requestMessage = "Server download requested. The item will appear after library sync."
        } catch {
            requestMessage = "Could not request this server download. Check the link and connection."
        }
    }

    @MainActor private func activeSession() async -> DeviceSession? {
        if let session { return session }
        guard let restored = try? await connection.restoreSession() else { return nil }
        session = restored
        return restored
    }
}

private enum TrashTab: String, CaseIterable, Identifiable {
    case trash = "Trash"
    case exclusions = "Expired"
    var id: Self { self }
}

/// Admin-only trash recovery surface. The server capability is checked on each pairing; the role
/// gate here is an additional client guard, while the server authorizes every request again.
struct AdminTrashView: View {
    let connection: ConnectionService
    let role: String?
    let pairingID: String
    @Environment(\.downtifyPalette) private var palette
    @State private var capability: TrashCapabilityDTO?
    @State private var items: [TrashItemDTO] = []
    @State private var totalItems = 0
    @State private var exclusions: [TrashItemDTO] = []
    @State private var tab: TrashTab = .trash
    @State private var search = ""
    @State private var loading = true
    @State private var loadingMore = false
    @State private var busyID: String?
    @State private var alert: TrashAlert?
    @State private var showingAllowConfirmation: TrashItemDTO?

    private var isAdmin: Bool { role?.lowercased() == "admin" }
    private var canManage: Bool { isAdmin && capability?.available == true }
    private var visibleItems: [TrashItemDTO] {
        (tab == .trash ? items : exclusions).filter { item in
            search.isEmpty || [item.metadata.title, item.metadata.artist, item.file].compactMap { $0 }
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if !isAdmin {
                ContentUnavailableView("Administrator access required", systemImage: "lock", description: Text("Music trash is available only to administrator accounts."))
            } else if loading && capability == nil {
                ProgressView("Checking music trash access…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Checking music trash access")
            } else if !canManage {
                ContentUnavailableView("Music trash unavailable", systemImage: "trash.slash", description: Text("This server has not enabled music trash, or this pairing cannot manage it."))
            } else {
                List {
                    Picker("Trash category", selection: $tab) {
                        ForEach(TrashTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Trash category")
                    TextField("Search music trash", text: $search)
                        .accessibilityLabel("Search music trash")
                    Section {
                        if loading && visibleItems.isEmpty {
                            ProgressView("Loading music trash…").frame(maxWidth: .infinity)
                        } else if let alert, visibleItems.isEmpty {
                            ContentUnavailableView("Could not load music trash", systemImage: "exclamationmark.triangle", description: Text(alert.message))
                            Button("Try again") { Task { await reload() } }
                        } else if visibleItems.isEmpty {
                            ContentUnavailableView(tab == .trash ? "Trash is empty" : "No expired songs", systemImage: tab == .trash ? "trash" : "checkmark.circle", description: Text(tab == .trash ? "Songs moved to trash will appear here." : "Expired songs that automatic downloads still skip appear here."))
                        } else {
                            ForEach(visibleItems) { item in itemRow(item) }
                        }
                    } header: {
                        Text(tab == .trash ? "In trash · \(totalItems)" : "Expired · \(exclusions.count)")
                    } footer: {
                        if let days = capability?.retentionDays, tab == .trash {
                            Text("Songs are retained for up to \(days) days. The server performs file moves in the background.")
                        }
                    }
                    if tab == .trash, items.count < totalItems {
                        Button { Task { await loadMore() } } label: {
                            HStack {
                                Spacer()
                                if loadingMore { ProgressView().accessibilityLabel("Loading more trash items") }
                                else { Text("Load more") }
                                Spacer()
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(loadingMore)
                    }
                }
                .refreshable { await reload() }
                .overlay(alignment: .top) {
                    if let alert, !visibleItems.isEmpty {
                        Label(alert.message, systemImage: "exclamationmark.triangle")
                            .font(.footnote).padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
        }
        .navigationTitle("Music Trash")
        .background(palette.background)
        .task(id: "\(pairingID):\(search)") {
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await reload()
        }
        .confirmationDialog("Allow downloads again?", isPresented: Binding(get: { showingAllowConfirmation != nil }, set: { if !$0 { showingAllowConfirmation = nil } }), titleVisibility: .visible) {
            Button("Allow downloads", role: .destructive) {
                if let item = showingAllowConfirmation { Task { await mutate(item, action: .allowDownload) } }
                showingAllowConfirmation = nil
            }
            Button("Cancel", role: .cancel) { showingAllowConfirmation = nil }
        } message: {
            Text("Automatic downloads will be allowed to retrieve this song again.")
        }
        .alert(item: $alert) { value in
            Alert(title: Text(value.title), message: Text(value.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder private func itemRow(_ item: TrashItemDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.metadata.title?.isEmpty == false ? item.metadata.title! : URL(fileURLWithPath: item.file).lastPathComponent)
                .font(.headline)
            HStack {
                Text([item.metadata.artist, item.metadata.codec?.uppercased(), item.state.replacingOccurrences(of: "_", with: " ")]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                Spacer()
                if let expiry = item.expiresAt, tab == .trash {
                    Text(Date(timeIntervalSince1970: expiry), style: .date).font(.caption)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if let error = item.error, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if tab == .trash {
                    Button("Restore") { Task { await mutate(item, action: .restore) } }
                        .disabled(busyID != nil)
                    if item.state == "error" {
                        Button("Try again") { Task { await mutate(item, action: .retry) } }
                            .disabled(busyID != nil)
                    }
                } else {
                    Button("Allow downloads") { showingAllowConfirmation = item }
                        .disabled(busyID != nil)
                }
                if busyID == item.id { ProgressView().accessibilityLabel("Working on \(item.metadata.title ?? "song")") }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private enum Mutation { case restore, retry, allowDownload }
    private func reload() async {
        guard isAdmin else { capability = nil; items = []; exclusions = []; loading = false; return }
        let requestedSearch = search
        loading = true
        alert = nil
        do {
            guard let session = try await connection.restoreSession(), session.role?.lowercased() == "admin" else {
                capability = nil; items = []; exclusions = []; loading = false; return
            }
            let api = TrashAPI()
            let found = try await api.capabilities(session: session)
            try Task.checkCancellation()
            guard try await connection.restoreSession() == session else {
                capability = nil; items = []; totalItems = 0; exclusions = []; loading = false; return
            }
            capability = found
            guard found.available else { items = []; totalItems = 0; exclusions = []; loading = false; return }
            async let page = api.listing(search: requestedSearch, session: session)
            async let skipped = api.exclusions(session: session)
            let (loadedPage, loadedExclusions) = try await (page, skipped)
            try Task.checkCancellation()
            guard search == requestedSearch else { return }
            guard try await connection.restoreSession() == session else {
                capability = nil; items = []; totalItems = 0; exclusions = []; loading = false; return
            }
            items = loadedPage.items
            totalItems = loadedPage.total
            exclusions = loadedExclusions
        } catch {
            if error is CancellationError { return }
            if shouldDisableTrash(for: error) { capability = nil; items = []; totalItems = 0; exclusions = [] }
            alert = TrashAlert(title: "Music trash could not be refreshed", message: message(for: error))
        }
        loading = false
    }
    private func loadMore() async {
        guard canManage, !loadingMore, let session = try? await connection.restoreSession(),
              session.role?.lowercased() == "admin" else { return }
        let requestedSearch = search
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await TrashAPI().listing(offset: items.count, search: requestedSearch, session: session)
            try Task.checkCancellation()
            guard search == requestedSearch, try await connection.restoreSession() == session else { return }
            let knownIDs = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !knownIDs.contains($0.id) })
            totalItems = page.total
        } catch {
            if error is CancellationError { return }
            if shouldDisableTrash(for: error) { capability = nil; items = []; totalItems = 0; exclusions = [] }
            alert = TrashAlert(title: "More trash items could not be loaded", message: message(for: error))
        }
    }
    private func mutate(_ item: TrashItemDTO, action: Mutation) async {
        guard canManage, let session = try? await connection.restoreSession(),
              session.role?.lowercased() == "admin" else { capability = nil; return }
        busyID = item.id
        do {
            let api = TrashAPI()
            switch action {
            case .restore: try await api.restore(ids: [item.id], session: session)
            case .retry: try await api.retry(ids: [item.id], session: session)
            case .allowDownload: try await api.allowDownload(ids: [item.id], session: session)
            }
            guard try await connection.restoreSession() == session else { busyID = nil; capability = nil; return }
            alert = TrashAlert(title: "Request submitted", message: "The server accepted the request. Refresh to check its latest status.")
            await reload()
        } catch {
            if shouldDisableTrash(for: error) { capability = nil; items = []; totalItems = 0; exclusions = [] }
            alert = TrashAlert(title: "Request could not be completed", message: message(for: error))
        }
        busyID = nil
    }
    private func shouldDisableTrash(for error: Error) -> Bool {
        if case TrashAPIError.httpStatus(403, _) = error { return true }
        if case TrashAPIError.httpStatus(404, _) = error { return true }
        if case TrashAPIError.httpStatus(503, _) = error { return true }
        if case APIError.httpStatus(403, _) = error { return true }
        if case APIError.httpStatus(404, _) = error { return true }
        if case APIError.httpStatus(503, _) = error { return true }
        if case ConnectionError.differentServer = error { return true }
        return false
    }
    private func message(for error: Error) -> LocalizedStringKey {
        if case let TrashAPIError.httpStatus(status, code) = error {
            if status == 403 { return "Administrator access changed. Music trash is now hidden." }
            if status == 404 { return "This server does not support music trash." }
            if status == 503 { return "Music trash is disabled on this server." }
            if status == 409 { return "The server could not complete this request (\(code ?? "conflict")). Nothing was changed." }
        }
        if case APIError.httpStatus(403, _) = error { return "Administrator access changed. Music trash is now hidden." }
        if case APIError.httpStatus(404, _) = error { return "This server does not support music trash." }
        if case APIError.httpStatus(503, _) = error { return "Music trash is disabled on this server." }
        if case ConnectionError.differentServer = error { return "The saved address now points to a different server. Reconnect before managing trash." }
        if case APIError.insecureTransportConsentRequired = error { return "Reconnect and acknowledge the server's insecure HTTP connection before using administrator actions." }
        return "Check your connection and try again. The server may have kept the song unchanged."
    }
}

private struct TrashAlert: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let message: LocalizedStringKey
}

struct MoveToTrashConfirmationView: View {
    let track: LibraryTrack
    let connection: ConnectionService
    let onSubmitted: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: TrashPreviewDTO?
    @State private var loading = true
    @State private var submitting = false
    @State private var errorMessage: LocalizedStringKey?
    @State private var submittedCount: Int?

    var body: some View {
        List {
            if loading {
                ProgressView("Checking files on the server…").accessibilityLabel("Checking which files will move to trash")
            } else if let errorMessage {
                ContentUnavailableView("Could not prepare trash request", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                Button("Try again") { Task { await preparePreview() } }
            } else if let preview {
                Section("Files the server will move") {
                    ForEach(preview.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.metadata.title ?? track.displayTitle).font(.headline)
                            Text([item.metadata.artist, item.metadata.codec?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(item.file).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if preview.items.isEmpty {
                        Text("The server found no files to move.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("After confirmation, the server starts the move in the background. Songs leave your library after the next successful sync and can be restored before retention expires.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let submittedCount {
                Section {
                    Label("\(submittedCount) song request(s) accepted", systemImage: "checkmark.circle")
                    Text("The files may still be moving. The library updates after sync.").font(.footnote).foregroundStyle(.secondary)
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationTitle("Move to Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(submitting) }
            if let preview, submittedCount == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move to Trash", role: .destructive) { Task { await confirm(preview) } }
                        .disabled(loading || submitting || preview.items.isEmpty)
                }
            }
        }
        .task(id: track.id) { await preparePreview() }
        .alert("Trash request failed", isPresented: Binding(get: { errorMessage != nil && !loading }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { if let errorMessage { Text(errorMessage) } }
    }

    @MainActor private func preparePreview() async {
        loading = true
        preview = nil
        errorMessage = nil
        do {
            guard let session = try await connection.restoreSession(), session.role?.lowercased() == "admin" else {
                throw APIError.httpStatus(403, retryAfter: nil)
            }
            let api = TrashAPI()
            let capability = try await api.capabilities(session: session)
            guard capability.available else { throw APIError.httpStatus(503, retryAfter: nil) }
            let (_, result) = try await api.preview(trackIDs: [track.id], session: session)
            guard try await connection.restoreSession() == session else { throw CancellationError() }
            preview = result
            if result.items.isEmpty { errorMessage = "The server found no matching files. Nothing was changed." }
        } catch {
            errorMessage = failureMessage(error)
        }
        loading = false
    }

    @MainActor private func confirm(_ preview: TrashPreviewDTO) async {
        submitting = true
        do {
            guard let session = try await connection.restoreSession(), session.role?.lowercased() == "admin" else {
                throw APIError.httpStatus(403, retryAfter: nil)
            }
            let ids = try await TrashAPI().confirm(preview.confirmation, session: session)
            guard try await connection.restoreSession() == session else { throw CancellationError() }
            submittedCount = ids.count
            await onSubmitted()
        } catch {
            errorMessage = failureMessage(error)
        }
        submitting = false
    }

    private func failureMessage(_ error: Error) -> LocalizedStringKey {
        if case let TrashAPIError.httpStatus(status, code) = error {
            if status == 403 { return "Administrator access is no longer available. Nothing was moved." }
            if status == 404 { return "This server does not support music trash. Nothing was moved." }
            if status == 503 { return "Music trash is disabled or unavailable. Nothing was moved." }
            if status == 409 { return "The server could not confirm this request (\(code ?? "conflict")). Nothing was moved." }
        }
        if case APIError.httpStatus(403, _) = error { return "Administrator access is no longer available. Nothing was moved." }
        if case APIError.httpStatus(404, _) = error { return "This server does not support music trash. Nothing was moved." }
        if case APIError.httpStatus(503, _) = error { return "Music trash is disabled or unavailable. Nothing was moved." }
        if case APIError.insecureTransportConsentRequired = error { return "Reconnect and acknowledge insecure HTTP before sending administrator requests." }
        if case ConnectionError.differentServer = error { return "The saved address now points to another server. Nothing was moved." }
        if case APIError.httpStatus(409, _) = error { return "The server could not confirm this request. Refresh the library and try again; nothing was moved." }
        return "The request could not be completed. Check the connection and try again."
    }
}
