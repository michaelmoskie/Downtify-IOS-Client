import CryptoKit
import Foundation

enum PlaybackItem: Sendable, Equatable {
    case library(LibraryTrack)
    case catalog(CatalogSong)

    var libraryTrack: LibraryTrack? {
        if case .library(let track) = self { return track }
        return nil
    }

    var catalogSong: CatalogSong? {
        if case .catalog(let song) = self { return song }
        return nil
    }

    enum MediaID: Hashable, Sendable {
        case library(String)
        case catalog(CatalogResultID)
    }

    var mediaID: MediaID {
        switch self {
        case .library(let track): .library(track.id)
        case .catalog(let song): .catalog(song.id)
        }
    }

    var title: String { libraryTrack?.title ?? catalogSong?.title ?? "" }
    var artist: String { libraryTrack?.artist ?? catalogSong?.artist ?? "" }
    var artists: [String] { libraryTrack?.artists ?? catalogSong?.artists ?? [] }
    var album: String { libraryTrack?.album ?? catalogSong?.albumName ?? "" }
    var duration: Double? {
        switch self {
        case .library(let track): track.duration > 0 ? track.duration : nil
        case .catalog(let song): song.duration
        }
    }
    var artworkURL: String? { catalogSong?.coverURL }

    static func resolving(_ song: CatalogSong, in scopedTracks: [LibraryTrack]) -> PlaybackItem {
        if let track = song.libraryTrack(in: scopedTracks) { return .library(track) }
        return .catalog(song)
    }
}

struct PlaybackQueueEntry: Equatable, Identifiable, Sendable {
    let id: UUID
    let item: PlaybackItem

    // Retained for existing library-only callers while catalog playback migrates to item.
    var track: LibraryTrack {
        guard let track = item.libraryTrack else {
            preconditionFailure("Catalog queue entries do not have a library track")
        }
        return track
    }

    init(id: UUID = UUID(), track: LibraryTrack) {
        self.id = id
        self.item = .library(track)
    }

    init(id: UUID = UUID(), item: PlaybackItem) {
        self.id = id
        self.item = item
    }
}

enum PlaybackRepeat: String, Codable, Sendable {
    case off, all, one
}

struct PlaybackQueue {
    private(set) var entries: [PlaybackQueueEntry] = []
    private(set) var shuffledIDs: [UUID]?
    private(set) var currentID: UUID?
    var repeatMode: PlaybackRepeat = .off

    var current: PlaybackQueueEntry? { entries.first { $0.id == currentID } }

    var order: [PlaybackQueueEntry] {
        guard let shuffledIDs else { return entries }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return shuffledIDs.compactMap { byID[$0] }
    }

    var currentIndex: Int? {
        guard let currentID else { return nil }
        if let shuffledIDs { return shuffledIDs.firstIndex(of: currentID) }
        return entries.firstIndex { $0.id == currentID }
    }

    mutating func replace(_ tracks: [LibraryTrack], startingAt index: Int) {
        replace(tracks.map(PlaybackItem.library), startingAt: index)
    }

    mutating func replace(_ items: [PlaybackItem], startingAt index: Int) {
        entries = items.map { PlaybackQueueEntry(item: $0) }
        currentID = entries.indices.contains(index) ? entries[index].id : entries.first?.id
        if shuffledIDs != nil { shuffle() }
    }

    mutating func append(_ tracks: [LibraryTrack]) {
        append(tracks.map(PlaybackItem.library))
    }

    mutating func append(_ items: [PlaybackItem]) {
        let added = items.map { PlaybackQueueEntry(item: $0) }
        entries.append(contentsOf: added)
        shuffledIDs?.append(contentsOf: added.map(\.id))
        if currentID == nil { currentID = order.first?.id }
    }

    mutating func applyLibraryOnlyPolicy(_ libraryOnly: Bool, tracks: [LibraryTrack]) {
        guard libraryOnly else { return }
        let oldOrder = order
        let oldCurrentIndex = currentIndex
        var retainedIDs = Set<UUID>()
        entries = entries.compactMap { entry in
            let item: PlaybackItem
            switch entry.item {
            case .library:
                item = entry.item
            case .catalog(let song) where song.source == "library":
                guard let track = song.libraryTrack(in: tracks) else { return nil }
                item = .library(track)
            case .catalog:
                return nil
            }
            retainedIDs.insert(entry.id)
            return PlaybackQueueEntry(id: entry.id, item: item)
        }
        shuffledIDs = shuffledIDs.map { $0.filter(retainedIDs.contains) }

        if let currentID, retainedIDs.contains(currentID) { return }
        guard let oldCurrentIndex else {
            currentID = order.first?.id
            return
        }
        let following = oldOrder.dropFirst(oldCurrentIndex + 1).first { retainedIDs.contains($0.id) }
        let preceding = oldOrder.prefix(oldCurrentIndex).last { retainedIDs.contains($0.id) }
        currentID = following?.id ?? preceding?.id
    }

    mutating func remove(_ id: UUID) {
        let oldIndex = currentIndex
        entries.removeAll { $0.id == id }
        shuffledIDs?.removeAll { $0 == id }
        if id == currentID {
            let ordered = order
            currentID = oldIndex.flatMap { ordered.indices.contains($0) ? ordered[$0].id : ordered.last?.id }
        }
    }

    mutating func move(_ id: UUID, to index: Int) {
        if var shuffledIDs {
            guard shuffledIDs.indices.contains(index), let from = shuffledIDs.firstIndex(of: id) else { return }
            let moved = shuffledIDs.remove(at: from)
            shuffledIDs.insert(moved, at: index)
            self.shuffledIDs = shuffledIDs
        } else {
            guard entries.indices.contains(index), let from = entries.firstIndex(where: { $0.id == id }) else { return }
            let moved = entries.remove(at: from)
            entries.insert(moved, at: index)
        }
    }

    mutating func select(_ id: UUID) {
        if entries.contains(where: { $0.id == id }) { currentID = id }
    }

    mutating func setShuffle(_ enabled: Bool) {
        if enabled {
            if shuffledIDs == nil { shuffle() }
        } else {
            shuffledIDs = nil
        }
    }

    var preloadItems: [PlaybackItem] {
        guard let currentIndex else { return [] }
        let ordered = order
        let current = ordered[currentIndex].item
        guard repeatMode != .one else { return [current] }

        var items = [current]
        var seen = Set([current.mediaID])
        let upcoming = ordered.dropFirst(currentIndex + 1)
        let wrapped = repeatMode == .all ? ordered.prefix(currentIndex) : ordered.prefix(0)
        for entry in upcoming + wrapped {
            guard seen.insert(entry.item.mediaID).inserted else { continue }
            items.append(entry.item)
            if items.count == 6 { break }
        }
        return items
    }

    func next(automatic: Bool) -> UUID? {
        guard let currentIndex, let currentID else { return nil }
        if automatic && repeatMode == .one { return currentID }
        if currentIndex + 1 < entries.count { return id(at: currentIndex + 1) }
        return repeatMode == .all ? id(at: 0) : nil
    }

    func previous() -> UUID? {
        guard let currentIndex else { return nil }
        if currentIndex > 0 { return id(at: currentIndex - 1) }
        return repeatMode == .all ? id(at: entries.count - 1) : nil
    }

    private func id(at index: Int) -> UUID { shuffledIDs?[index] ?? entries[index].id }

    private mutating func shuffle() {
        let rest = entries.map(\.id).filter { $0 != currentID }.shuffled()
        shuffledIDs = currentID.map { [$0] + rest } ?? rest
    }

    func saved(position: TimeInterval, listen: PlaybackListenProgress? = nil) -> SavedPlaybackQueue {
        SavedPlaybackQueue(
            entries: entries.map { entry in
                switch entry.item {
                case .library(let track): .init(id: entry.id, trackID: track.id)
                case .catalog(let song): .init(id: entry.id, catalogSong: song)
                }
            },
            shuffledIDs: shuffledIDs, currentID: currentID, position: position, repeatMode: repeatMode, listen: listen
        )
    }

    mutating func restore(_ saved: SavedPlaybackQueue, tracks: [LibraryTrack]) -> TimeInterval {
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set<UUID>()
        entries = saved.entries.compactMap { entry in
            guard !ids.contains(entry.id) else { return nil }
            let restored: PlaybackQueueEntry?
            if let song = entry.catalogSong {
                let item: PlaybackItem
                if song.source == "library" {
                    guard let track = song.libraryTrack(in: tracks) else { return nil }
                    item = .library(track)
                } else {
                    item = .catalog(song)
                }
                restored = PlaybackQueueEntry(id: entry.id, item: item)
            } else {
                guard let trackID = entry.trackID, let track = tracksByID[trackID] else { return nil }
                restored = PlaybackQueueEntry(id: entry.id, track: track)
            }
            if restored != nil { ids.insert(entry.id) }
            return restored
        }
        shuffledIDs = saved.shuffledIDs.map { order in
            var remaining = ids
            return order.filter { remaining.remove($0) != nil } + entries.map(\.id).filter(remaining.contains)
        }
        currentID = saved.currentID.flatMap { ids.contains($0) ? $0 : nil } ?? order.first?.id
        repeatMode = saved.repeatMode
        return currentID != nil && currentID == saved.currentID && saved.position.isFinite ? max(0, saved.position) : 0
    }
}

struct SavedPlaybackQueue: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: UUID
        let trackID: String?
        let catalogSong: CatalogSong?

        init(id: UUID, trackID: String) {
            self.id = id
            self.trackID = trackID
            catalogSong = nil
        }

        init(id: UUID, catalogSong: CatalogSong) {
            self.id = id
            trackID = nil
            self.catalogSong = catalogSong
        }

        private enum CodingKeys: String, CodingKey { case id, trackID, catalogSong }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            trackID = try container.decodeIfPresent(String.self, forKey: .trackID)
            catalogSong = try container.decodeIfPresent(CatalogSong.self, forKey: .catalogSong)
            guard trackID != nil || catalogSong != nil else {
                throw DecodingError.dataCorruptedError(forKey: .trackID, in: container,
                                                       debugDescription: "Queue entry requires a track ID or catalog song")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(trackID, forKey: .trackID)
            try container.encodeIfPresent(catalogSong, forKey: .catalogSong)
        }
    }

    let entries: [Entry]
    let shuffledIDs: [UUID]?
    let currentID: UUID?
    let position: TimeInterval
    let repeatMode: PlaybackRepeat
    let listen: PlaybackListenProgress?
}

@MainActor
protocol PlaybackStateStoring {
    func load(for scope: LibraryScope) -> SavedPlaybackQueue?
    func save(_ queue: SavedPlaybackQueue, for scope: LibraryScope)
    func loadQualities() -> PlaybackQualities
    func saveQualities(_ qualities: PlaybackQualities)
    func loadBuffering() -> PlaybackBuffering
    func saveBuffering(_ buffering: PlaybackBuffering)
    func loadNormalization() -> PlaybackNormalization
    func saveNormalization(_ normalization: PlaybackNormalization)
}

extension PlaybackStateStoring {
    func loadBuffering() -> PlaybackBuffering { PlaybackBuffering() }
    func saveBuffering(_ buffering: PlaybackBuffering) {}
    func loadNormalization() -> PlaybackNormalization { .off }
    func saveNormalization(_ normalization: PlaybackNormalization) {}
}

struct PlaybackStateStore: PlaybackStateStoring {
    var defaults: UserDefaults = .standard

    func load(for scope: LibraryScope) -> SavedPlaybackQueue? { load(key(for: scope)) }
    func save(_ queue: SavedPlaybackQueue, for scope: LibraryScope) { save(queue, key: key(for: scope)) }
    func loadQualities() -> PlaybackQualities { load("playback.qualities") ?? PlaybackQualities() }
    func saveQualities(_ qualities: PlaybackQualities) { save(qualities, key: "playback.qualities") }

    func loadBuffering() -> PlaybackBuffering { load("playback.buffering") ?? PlaybackBuffering() }
    func saveBuffering(_ buffering: PlaybackBuffering) { save(buffering, key: "playback.buffering") }
    func loadNormalization() -> PlaybackNormalization { load("playback.normalization") ?? .off }
    func saveNormalization(_ normalization: PlaybackNormalization) { save(normalization, key: "playback.normalization") }

    private func key(for scope: LibraryScope) -> String {
        let identity = Data("\(scope.serverID.utf8.count):\(scope.serverID)\(scope.account)".utf8)
        let digest = Data(SHA256.hash(data: identity)).base64EncodedString()
        return "playback.queue.\(digest)"
    }

    private func load<Value: Decodable>(_ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private func save<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
