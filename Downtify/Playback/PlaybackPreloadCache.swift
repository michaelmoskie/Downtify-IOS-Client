import Foundation

actor PlaybackPreloadCache {
    struct Key: Hashable, Sendable {
        let scope: LibraryScope
        let media: PlaybackItem.MediaID
        let quality: PlaybackQuality

        init(session: DeviceSession, item: PlaybackItem, quality: PlaybackQuality) {
            self.init(scope: LibraryScope(serverID: session.serverID, username: session.username, deviceID: session.deviceID),
                      media: item.mediaID, quality: quality)
        }

        init(scope: LibraryScope, media: PlaybackItem.MediaID, quality: PlaybackQuality) {
            self.scope = scope
            self.media = media
            switch media {
            case .library: self.quality = quality
            case .catalog: self.quality = .original
            }
        }
    }

    private struct Entry {
        let key: Key
        let length: Int64
        let contentType: String
        let fileExtension: String
        let quality: PlaybackQuality
        let availableQualities: [PlaybackQuality]
        var readers = 0
        var retired = false
    }

    private final class Lease: Sendable {
        let cache: PlaybackPreloadCache
        let url: URL

        init(cache: PlaybackPreloadCache, url: URL) {
            self.cache = cache
            self.url = url
        }

        deinit {
            Task { [cache, url] in await cache.release(url) }
        }
    }

    private let directory: URL
    private var opened = false
    private var entries: [URL: Entry] = [:]
    private var pending: [Key: Int64] = [:]
    private var byteLimit: Int64
    private var occupied: Int64 {
        entries.values.reduce(0) { $0 + $1.length } + pending.values.reduce(0, +)
    }

    init(directory: URL = URL.cachesDirectory.appending(path: "PlaybackPreload", directoryHint: .isDirectory),
         byteLimit: Int = PlaybackBuffering().byteLimit) {
        self.directory = directory
        self.byteLimit = Int64(max(0, byteLimit))
    }

    func retain(_ window: [Key], byteLimit: Int) {
        if !opened && FileManager.default.fileExists(atPath: directory.path) {
            try? openDirectory()
        }
        self.byteLimit = Int64(max(0, byteLimit))
        let ranks = Dictionary(uniqueKeysWithValues: window.enumerated().map { ($1, $0) })
        for (url, entry) in entries where !window.contains(where: {
            $0.scope == entry.key.scope && $0.media == entry.key.media
        }) {
            retire(url)
        }

        // Drop unneeded qualities and the farthest songs first when the budget shrinks.
        let farthestFirst = entries.keys.sorted {
            (entries[$0].flatMap { ranks[$0.key] } ?? Int.max) >
                (entries[$1].flatMap { ranks[$0.key] } ?? Int.max)
        }
        for url in farthestFirst where occupied > self.byteLimit {
            retire(url)
        }
    }

    func contains(_ key: Key) -> Bool {
        url(for: key, allowAlternateQuality: false) != nil
    }

    func store(_ stream: PlaybackStream, for key: Key) async throws {
        guard stream.fileURL == nil, stream.length > 0, stream.length <= byteLimit,
              !contains(key), pending[key] == nil else { return }
        try Task.checkCancellation()
        try openDirectory()

        // Keep the old quality available until there is a replacement or we need its space.
        if stream.length > byteLimit - occupied {
            for (url, entry) in entries where entry.key.scope == key.scope && entry.key.media == key.media &&
                entry.key != key && entry.readers == 0 {
                retire(url)
            }
        }
        guard stream.length <= byteLimit - occupied else { return }
        let partial = directory.appending(path: UUID().uuidString).appendingPathExtension("partial")
        let complete = partial.deletingPathExtension().appendingPathExtension(stream.fileExtension)
        pending[key] = stream.length
        defer {
            pending.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: partial)
        }

        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < stream.length {
            try Task.checkCancellation()
            let end = offset + min(PlaybackCache.blockSize, stream.length - offset)
            let bytes = try await stream.read(offset...(end - 1))
            try Task.checkCancellation()
            guard bytes.count == end - offset else { throw PlaybackFailure.invalidStream }
            try handle.write(contentsOf: bytes)
            offset = end
        }
        try handle.close()
        try Task.checkCancellation()
        guard occupied <= byteLimit else { return }
        try FileManager.default.moveItem(at: partial, to: complete)
        for (url, entry) in entries where entry.key.scope == key.scope && entry.key.media == key.media {
            retire(url)
        }
        entries[complete] = Entry(key: key, length: stream.length, contentType: stream.contentType,
                                  fileExtension: stream.fileExtension, quality: stream.quality,
                                  availableQualities: stream.availableQualities)
    }

    func stream(for key: Key, allowAlternateQuality: Bool = false) -> PlaybackStream? {
        guard let url = url(for: key, allowAlternateQuality: allowAlternateQuality),
              let entry = entries[url] else { return nil }
        entries[url]?.readers += 1
        let lease = Lease(cache: self, url: url)
        return PlaybackStream(contentType: entry.contentType, fileExtension: entry.fileExtension,
                              length: entry.length, quality: entry.quality,
                              availableQualities: entry.availableQualities, fileURL: url) { range in
            guard range.lowerBound >= 0, range.upperBound < entry.length else { throw PlaybackFailure.invalidStream }
            let handle = try FileHandle(forReadingFrom: lease.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let length = Int(range.upperBound - range.lowerBound + 1)
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw PlaybackFailure.invalidStream
            }
            return data
        }
    }

    private func url(for key: Key, allowAlternateQuality: Bool) -> URL? {
        var alternate: URL?
        for (url, entry) in entries where !entry.retired && entry.key.scope == key.scope &&
            entry.key.media == key.media && (entry.key == key || allowAlternateQuality) {
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == entry.length else {
                retire(url)
                continue
            }
            if entry.key == key { return url }
            alternate = url
        }
        return alternate
    }

    private func retire(_ url: URL) {
        entries[url]?.retired = true
        removeIfReleased(url)
    }

    private func release(_ url: URL) {
        entries[url]?.readers -= 1
        removeIfReleased(url)
    }

    private func removeIfReleased(_ url: URL) {
        guard let entry = entries[url], entry.retired, entry.readers == 0 else { return }
        do {
            try FileManager.default.removeItem(at: url)
            entries.removeValue(forKey: url)
        } catch CocoaError.fileNoSuchFile {
            entries.removeValue(forKey: url)
        } catch {
            // Count files that could not be deleted against the budget and retry on the next reconciliation.
        }
    }

    private func openDirectory() throws {
        guard !opened || !FileManager.default.fileExists(atPath: directory.path) else { return }
        if !opened && FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        opened = true
    }
}
