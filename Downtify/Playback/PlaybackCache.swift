import Foundation

struct PlaybackBuffering: Codable, Equatable {
    var cacheMegabytes = 100

    var byteLimit: Int { ((min(200, max(10, cacheMegabytes)) + 5) / 10) * 10_000_000 }
}

actor PlaybackCache {
    static let blockSize: Int64 = 512 * 1024

    struct Representation: Hashable, Sendable {
        let scope: LibraryScope
        let url: URL
        let validator: String
        let length: Int64
        let mediaType: String
    }

    private struct Key: Hashable {
        let representation: Representation
        let block: Int64
    }

    private struct Entry {
        let data: Data
        var access: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var used = 0
    private var access: UInt64 = 0
    private var byteLimit: Int

    init(byteLimit: Int = PlaybackBuffering().byteLimit) {
        self.byteLimit = max(0, byteLimit)
    }

    func resize(to limit: Int) {
        byteLimit = max(0, limit)
        trim()
    }

    func read(_ range: ClosedRange<Int64>, representation: Representation,
              fetch: @Sendable (ClosedRange<Int64>) async throws -> Data) async throws -> Data {
        var bytes = Data()
        var position = range.lowerBound
        while position <= range.upperBound {
            try Task.checkCancellation()
            let start = position - position % Self.blockSize
            let end = start + min(Self.blockSize, representation.length - start) - 1
            let key = Key(representation: representation, block: start)
            let block: Data
            if let cached = entries[key]?.data {
                access += 1
                entries[key]?.access = access
                block = cached
            } else {
                block = try await fetch(start...end)
                try Task.checkCancellation()
                guard block.count == end - start + 1 else { throw PlaybackFailure.invalidStream }
                if block.count <= byteLimit {
                    access += 1
                    used += block.count - (entries[key]?.data.count ?? 0)
                    entries[key] = Entry(data: block, access: access)
                    trim()
                }
            }
            let count = min(end, range.upperBound) - position + 1
            let offset = block.startIndex + Int(position - start)
            bytes.append(contentsOf: block[offset..<(offset + Int(count))])
            position += count
        }
        return bytes
    }

    private func trim() {
        while used > byteLimit, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            entries.removeValue(forKey: oldest.key)
            used -= oldest.value.data.count
        }
    }
}
