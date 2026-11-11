import Foundation

enum LibraryContext: Codable, Hashable, Sendable {
    case album(String)
    case artist(String)
    case playlist(String)
    case liked
}

/// One playlist occurrence. Playlist IDs may repeat, so `trackID` alone is not a row identity.
struct PlaylistTrackOccurrence: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let trackID: String
        let position: Int
    }

    let trackID: String
    /// Zero-based position in the complete server-provided playlist order.
    let position: Int

    var id: ID { ID(trackID: trackID, position: position) }

    static func ordered(_ trackIDs: [String]) -> [Self] {
        trackIDs.enumerated().map { position, trackID in
            Self(trackID: trackID, position: position)
        }
    }

    /// Returns a complete reordered ID sequence only when every original occurrence is present.
    /// The multiset check protects repeated IDs as well as tracks missing from the local catalog.
    static func completeOrder(_ occurrences: [Self], matching trackIDs: [String]) -> [String]? {
        guard occurrences.count == trackIDs.count else { return nil }
        let expectedCounts = Dictionary(trackIDs.map { ($0, 1) }, uniquingKeysWith: +)
        let proposedCounts = Dictionary(occurrences.map { ($0.trackID, 1) }, uniquingKeysWith: +)
        guard expectedCounts == proposedCounts else { return nil }
        return occurrences.map(\.trackID)
    }
}

/// A playlist row retains the server occurrence even when its track is not in the local catalog.
struct LibraryPlaylistTrackOccurrence: Identifiable, Equatable {
    let occurrence: PlaylistTrackOccurrence
    let track: LibraryTrack?

    var id: PlaylistTrackOccurrence.ID { occurrence.id }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyAdded, alphabetical, artist

    var id: Self { self }
    var descendingByDefault: Bool { self == .recentlyAdded }

    var label: String {
        switch self {
        case .recentlyAdded: String(localized: "Recently added")
        case .alphabetical: String(localized: "Alphabetical")
        case .artist: String(localized: "Artist")
        }
    }

    func ordered(_ entries: [LibraryBrowseEntry], descending: Bool) -> [LibraryBrowseEntry] {
        entries.sorted {
            if self == .recentlyAdded, $0.added != $1.added {
                return descending ? $0.added > $1.added : $0.added < $1.added
            }
            let primary = self == .artist ? $0.artist.localizedStandardCompare($1.artist) : .orderedSame
            let title = $0.title.localizedStandardCompare($1.title)
            let result = primary == .orderedSame ? title : primary
            if result == .orderedSame { return $0.id < $1.id }
            return descending ? result == .orderedDescending : result == .orderedAscending
        }
    }

    func orderedTracks(_ tracks: [LibraryTrack], descending: Bool) -> [LibraryTrack] {
        ordered(tracks.map {
            LibraryBrowseEntry(id: $0.id, context: .liked, title: $0.title,
                               artist: LibraryCatalog.artistName($0), added: $0.added, count: 1, artwork: $0)
        }, descending: descending).compactMap(\.artwork)
    }
}

struct LibraryBrowseEntry: Identifiable, Equatable {
    let id: String
    let context: LibraryContext
    let title: String
    let artist: String
    let added: Int64
    let count: Int
    let artwork: LibraryTrack?
    var playlistCover: String? = nil
}

struct LibraryCatalog {
    let tracksByID: [String: LibraryTrack]
    let albumsByID: [String: LibraryBrowseEntry]
    let artistsByID: [String: LibraryBrowseEntry]
    private let albumTracks: [String: [LibraryTrack]]
    private let artistTracks: [String: [LibraryTrack]]
    private let albumsByArtist: [String: [LibraryBrowseEntry]]

    init(_ tracks: [LibraryTrack]) {
        tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let albumGroups = Dictionary(grouping: tracks.filter { !$0.albumID.isEmpty }, by: \.albumID).mapValues {
            $0.sorted {
                let lhs = $0.trackNumber > 0 ? $0.trackNumber : Int.max
                let rhs = $1.trackNumber > 0 ? $1.trackNumber : Int.max
                if lhs != rhs { return lhs < rhs }
                let title = $0.title.localizedStandardCompare($1.title)
                return title == .orderedSame ? $0.id < $1.id : title == .orderedAscending
            }
        }
        albumTracks = albumGroups
        artistTracks = Dictionary(grouping: tracks.filter { !$0.artistID.isEmpty }, by: \.artistID)
        let albums: [String: LibraryBrowseEntry] = albumGroups.compactMapValues { group in
            guard let first = group.first else { return nil }
            return Self.entry(group, id: first.albumID, context: .album(first.albumID),
                              title: first.album, artist: Self.artistName(first))
        }
        albumsByID = albums
        artistsByID = artistTracks.compactMapValues { group in
            guard let first = group.first else { return nil }
            let artist = Self.artistName(first)
            return Self.entry(group, id: first.artistID, context: .artist(first.artistID), title: artist, artist: artist)
        }
        albumsByArtist = Dictionary(grouping: Array(albums.values)) {
            albumGroups[$0.id]?.first?.artistID ?? ""
        }
    }

    func tracks(in context: LibraryContext, likedIDs: [String], playlist: LibraryPlaylist?) -> [LibraryTrack] {
        switch context {
        case .album(let id): albumTracks[id] ?? []
        case .artist(let id): LibraryTrackOrdering.sorted(artistTracks[id] ?? [])
        case .playlist: (playlist?.trackIDs ?? []).compactMap { tracksByID[$0] }
        case .liked: likedIDs.compactMap { tracksByID[$0] }
        }
    }

    /// Resolves playlist occurrences without dropping IDs absent from this catalog snapshot.
    func playlistOccurrences(_ playlist: LibraryPlaylist?) -> [LibraryPlaylistTrackOccurrence] {
        PlaylistTrackOccurrence.ordered(playlist?.trackIDs ?? []).map { occurrence in
            LibraryPlaylistTrackOccurrence(occurrence: occurrence, track: tracksByID[occurrence.trackID])
        }
    }

    func albums(for artistID: String) -> [LibraryBrowseEntry] {
        LibrarySort.recentlyAdded.ordered(albumsByArtist[artistID] ?? [], descending: true)
    }

    static func artistName(_ track: LibraryTrack) -> String {
        track.albumArtist.isEmpty ? track.artist : track.albumArtist
    }

    private static func entry(_ group: [LibraryTrack], id: String, context: LibraryContext,
                              title: String, artist: String) -> LibraryBrowseEntry {
        LibraryBrowseEntry(id: id, context: context, title: title, artist: artist,
                           added: group.map(\.added).max() ?? 0, count: group.count,
                           artwork: group.first(where: \.hasCover))
    }
}
