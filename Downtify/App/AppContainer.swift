import Foundation

/// Storage and transport choices for one launch. Release always resolves to the live configuration.
@MainActor
private struct AppEnvironment {
    let defaults: UserDefaults
    let transport: any HTTPDataLoading
    let sessionStore: any DeviceSessionStoring
    let databaseURL: URL?
    let offlineDirectory: URL?
    let preloadDirectory: URL?
    let outboxRoot: URL?
    let streamResolver: (any PlaybackStreamResolving)?

    static func resolve() -> AppEnvironment {
        #if DEBUG
        if let harness = DebugHarness.current {
            try? harness.resetDirectories()
            let defaults = harness.makeDefaults()
            NetworkOperationCoordinator.shared = NetworkOperationCoordinator(
                limit: NetworkOperationCoordinator.savedLimit(in: defaults), defaults: defaults)
            return AppEnvironment(
                defaults: defaults, transport: harness.makeTransport(), sessionStore: harness.makeSessionStore(),
                databaseURL: harness.databaseURL,
                offlineDirectory: harness.cachesDirectory.appending(path: "Offline", directoryHint: .isDirectory),
                preloadDirectory: harness.cachesDirectory.appending(path: "PlaybackPreload", directoryHint: .isDirectory),
                outboxRoot: harness.cachesDirectory.appending(path: "PlaybackListens", directoryHint: .isDirectory),
                streamResolver: harness.makeStreamResolver())
        }
        #endif
        return AppEnvironment(
            defaults: .standard, transport: ConnectionHTTPTransport(), sessionStore: KeychainSessionStore(),
            databaseURL: nil, offlineDirectory: nil, preloadDirectory: nil, outboxRoot: nil, streamResolver: nil
        )
    }
}

@MainActor
struct AppContainer {
    let displayName: String
    let defaults: UserDefaults
    let connectionService: ConnectionService
    let sessionPresentation: SessionPresentationCoordinator
    let serverDiscovery = BonjourServerDiscovery()
    let library: LibraryRepository
    let librarySync: LibrarySyncCoordinator
    let collections: LibraryCollectionsModel
    let libraryPresentation: LibraryPresentationModel
    let catalogPresentation: CatalogPresentationModel
    let playback: PlaybackController
    let artwork: ArtworkLoader
    let offlineDownloads: OfflineDownloads
    let serverDownloadQueue: ServerDownloadQueue
    let serverDownloads: ServerDownloadPresentationModel
    let dataReset: AppDataReset
    let storageSettings: StorageSettingsModel
    let reachability: ServerReachabilityModel
    #if DEBUG
    let harness: DebugHarness?
    #endif

    init(displayName: String = "Downtify") {
        self.displayName = displayName
        let environment = AppEnvironment.resolve()
        defaults = environment.defaults
        let connection = ConnectionService(transport: environment.transport, store: environment.sessionStore)
        connectionService = connection
        let artworkLoader = ArtworkLoader(connection: connection, transport: environment.transport)
        artwork = artworkLoader
        sessionPresentation = SessionPresentationCoordinator(connectionService: connection, serverDiscovery: serverDiscovery) {
            try await connection.sessionUpdates()
        }
        let api = LibraryAPIClient(transport: environment.transport)
        let database = environment.databaseURL.map { LibraryDatabase(fileURL: $0) } ?? LibraryDatabase()
        let repository = LibraryRepository(database: database, feed: api) {
            try await connection.restoreSession()
        }
        library = repository
        let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?> = { try await connection.sessionUpdates() }
        // Same transport as the library so harness fixture and staging guards also cover likes and playlists.
        let collections = LibraryCollectionsModel(api: LibraryCollectionsAPI(transport: environment.transport,
                                                                            preservesTransportErrors: true),
                                                  database: database, sessionUpdates: sessionUpdates, verifySession: { session in
            (try? await connection.verifySession(expected: session)) == .active
        }, defaults: environment.defaults)
        self.collections = collections
        let presentation = LibraryPresentationModel(repository: repository, sessionUpdates: sessionUpdates,
                                                    defaults: environment.defaults)
        libraryPresentation = presentation
        let catalogPresentation = CatalogPresentationModel(api: CatalogAPI(transport: environment.transport),
                                                           sessionUpdates: sessionUpdates)
        self.catalogPresentation = catalogPresentation
        catalogPresentation.start()
        let playbackCache = PlaybackCache()
        let preloadCache = environment.preloadDirectory.map { PlaybackPreloadCache(directory: $0) } ?? PlaybackPreloadCache()
        let verifyPlaybackSession: (DeviceSession) async -> Void = {
            _ = try? await connection.verifySession(expected: $0)
        }
        if let offlineDirectory = environment.offlineDirectory {
            offlineDownloads = OfflineDownloads(directory: offlineDirectory)
        } else {
            offlineDownloads = .live
        }
        offlineDownloads.verifySession = verifyPlaybackSession
        artworkLoader.savedCovers = offlineDownloads
        let serverDownloadQueue = ServerDownloadQueue(verifySession: verifyPlaybackSession)
        self.serverDownloadQueue = serverDownloadQueue
        let serverDownloads = ServerDownloadPresentationModel(queue: serverDownloadQueue, sessionUpdates: sessionUpdates)
        self.serverDownloads = serverDownloads
        serverDownloads.start()
        let listenOutbox = environment.outboxRoot.map { PlaybackListenOutbox(root: $0) } ?? .applicationSupport()
        let controller = PlaybackController(
            engine: AVPlaybackEngine(),
            resolver: environment.streamResolver
                ?? PlaybackStreamResolver(cache: playbackCache, offline: offlineDownloads, preloadCache: preloadCache),
            audioSession: SystemPlaybackAudioSession(),
            remote: SystemPlaybackRemoteControls(artworkProvider: AppNowPlayingArtworkProvider(artwork: artworkLoader)),
            store: PlaybackStateStore(defaults: environment.defaults), networkMonitor: SystemPlaybackNetworkMonitor(),
            cache: playbackCache, preloadCache: preloadCache,
            reporting: PlaybackReporting(outbox: listenOutbox, defaults: environment.defaults,
                                         verifySession: verifyPlaybackSession),
            verifySession: verifyPlaybackSession
        )
        controller.lyricsTransport = environment.transport
        playback = controller
        Task { @MainActor in
            for await state in catalogPresentation.$policyState.values {
                guard state == .ready, let only = catalogPresentation.isLibraryOnly else { continue }
                controller.applyLibraryOnlyPolicy(only, tracks: presentation.tracks)
            }
        }
        librarySync = LibrarySyncCoordinator(
            repository: repository, events: LibraryWebSocket(api: api),
            sessionUpdates: sessionUpdates,
            verifySession: { try await connection.verifySession(expected: $0) },
            didUpdate: { await presentation.syncDidUpdate(for: $0) },
            didFail: { presentation.syncDidFail(for: $0, message: $1) },
            didChangeCollections: { await collections.refresh(for: $0) },
            didChangeMusicPolicy: { [weak catalogPresentation] session in
                await catalogPresentation?.refreshPolicy(for: session)
                guard catalogPresentation?.policyState == .ready,
                      let only = catalogPresentation?.isLibraryOnly else { return }
                controller.applyLibraryOnlyPolicy(only, tracks: presentation.tracks)
            },
            didChangeDownloadQueue: { [weak serverDownloads] session in
                guard serverDownloads?.session == session else { return }
                await serverDownloads?.queueDidChange()
            }
        )
        dataReset = AppDataReset(
            sync: LibrarySyncReset(coordinator: librarySync, presentation: presentation),
            playback: controller, offline: offlineDownloads,
            preloadCache: preloadCache, blockCache: playbackCache, artwork: artwork,
            database: database, pendingActions: collections,
            listenOutbox: listenOutbox, savedQueues: PlaybackStateStore(defaults: environment.defaults),
            networkFailures: NetworkOperationCoordinator.shared
        )
        storageSettings = StorageSettingsModel(reset: dataReset)
        let transport = environment.transport
        reachability = ServerReachabilityModel(sessionUpdates: sessionUpdates) { session in
            await NetworkOperationContext.$priority.withValue(.userFacing) {
                (try? await LibraryAPIClient(transport: transport).verifiedAddress(for: session)) != nil
            }
        }
        #if DEBUG
        harness = DebugHarness.current
        if let harness {
            Task { @MainActor in await Self.harnessSignIn(connection, harness) }
        }
        #endif
    }

    #if DEBUG
    /// Harness-only: signs in without UI. Fixture credentials are test values for the in-process fixture server.
    private static func harnessSignIn(_ connection: ConnectionService, _ harness: DebugHarness) async {
        let server: String
        let username: String
        let password: String
        switch harness.configuration.mode {
        case .fixture:
            server = "https://fixture.test"
            username = "fixture"
            password = "fixture-password"
        case .staging:
            guard let target = harness.configuration.staging else { return }
            server = target.server
            username = target.username
            password = target.password
        }
        do {
            let target = try await connection.probe(server)
            _ = try await connection.signIn(username: username, password: password, at: target, deviceName: "Harness")
        } catch {
            // The state probe reports signed-out; nothing else to do here.
        }
    }
    #endif
}
