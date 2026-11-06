import CryptoKit
import Foundation

struct PlaybackQueueEntry: Equatable, Identifiable, Sendable {
    let id: UUID
    let track: LibraryTrack

    init(id: UUID = UUID(), track: LibraryTrack) {
        self.id = id
        self.track = track
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
        entries = tracks.map { PlaybackQueueEntry(track: $0) }
        currentID = entries.indices.contains(index) ? entries[index].id : entries.first?.id
        if shuffledIDs != nil { shuffle() }
    }

    mutating func append(_ tracks: [LibraryTrack]) {
        let added = tracks.map { PlaybackQueueEntry(track: $0) }
        entries.append(contentsOf: added)
        shuffledIDs?.append(contentsOf: added.map(\.id))
        if currentID == nil { currentID = order.first?.id }
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

    func saved(position: TimeInterval) -> SavedPlaybackQueue {
        SavedPlaybackQueue(
            entries: entries.map { .init(id: $0.id, trackID: $0.track.id) },
            shuffledIDs: shuffledIDs, currentID: currentID, position: position, repeatMode: repeatMode
        )
    }

    mutating func restore(_ saved: SavedPlaybackQueue, tracks: [LibraryTrack]) -> TimeInterval {
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids = Set<UUID>()
        entries = saved.entries.compactMap { entry in
            guard let track = tracksByID[entry.trackID], ids.insert(entry.id).inserted else { return nil }
            return PlaybackQueueEntry(id: entry.id, track: track)
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
        let trackID: String
    }

    let entries: [Entry]
    let shuffledIDs: [UUID]?
    let currentID: UUID?
    let position: TimeInterval
    let repeatMode: PlaybackRepeat
}

@MainActor
protocol PlaybackStateStoring {
    func load(for scope: LibraryScope) -> SavedPlaybackQueue?
    func save(_ queue: SavedPlaybackQueue, for scope: LibraryScope)
    func loadQualities() -> PlaybackQualities
    func saveQualities(_ qualities: PlaybackQualities)
}

struct PlaybackStateStore: PlaybackStateStoring {
    var defaults: UserDefaults = .standard

    func load(for scope: LibraryScope) -> SavedPlaybackQueue? { load(key(for: scope)) }
    func save(_ queue: SavedPlaybackQueue, for scope: LibraryScope) { save(queue, key: key(for: scope)) }
    func loadQualities() -> PlaybackQualities { load("playback.qualities") ?? PlaybackQualities() }
    func saveQualities(_ qualities: PlaybackQualities) { save(qualities, key: "playback.qualities") }

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
