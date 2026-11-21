import Foundation

/// An artist page opened from Now Playing. Either ID may be missing; the page then shows what it can.
struct NowPlayingArtistTarget: Hashable, Sendable {
    let name: String
    /// Server library artist ID (`LibraryTrack.artistID`).
    var libraryArtistID: String?
    /// Deezer artist ID usable with the Finder endpoints. Always decimal digits when present.
    var providerArtistID: String?

    init(name: String, libraryArtistID: String? = nil, providerArtistID: String? = nil) {
        self.name = name
        self.libraryArtistID = libraryArtistID.flatMap { $0.isEmpty ? nil : $0 }
        self.providerArtistID = providerArtistID.flatMap(CatalogNameMatch.decimalID)
    }
}

/// An album page opened from Now Playing.
struct NowPlayingAlbumTarget: Hashable, Sendable {
    let title: String
    let artist: String
    var libraryAlbumID: String?
    var providerAlbumID: String?
    var providerArtistID: String?

    init(title: String, artist: String, libraryAlbumID: String? = nil,
         providerAlbumID: String? = nil, providerArtistID: String? = nil) {
        self.title = title
        self.artist = artist
        self.libraryAlbumID = libraryAlbumID.flatMap { $0.isEmpty ? nil : $0 }
        self.providerAlbumID = providerAlbumID.flatMap(CatalogNameMatch.decimalID)
        self.providerArtistID = providerArtistID.flatMap(CatalogNameMatch.decimalID)
    }
}

enum NowPlayingRoute: Hashable, Sendable {
    case artist(NowPlayingArtistTarget)
    case album(NowPlayingAlbumTarget)
}

/// Name comparison shared by Now Playing navigation. Library and provider metadata differ
/// in case, accents and spacing, so exact string equality would miss most matches.
enum CatalogNameMatch {
    static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func decimalID(_ value: String) -> String? {
        !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) ? value : nil
    }

    static func providerArtistID(_ artist: CatalogArtist) -> String? {
        (artist.deezerID ?? (artist.source.lowercased() == "deezer" ? artist.artistID : nil)).flatMap(decimalID)
    }

    static func providerAlbumID(_ album: CatalogAlbum) -> String? {
        (album.deezerAlbumID ?? (album.source.lowercased() == "deezer" ? album.albumID : nil)).flatMap(decimalID)
    }

    /// Exact (normalized) name match with a usable provider ID. Several matches pick the most
    /// followed artist, then the first in server order.
    static func bestArtist(named name: String, in artists: [CatalogArtist]) -> CatalogArtist? {
        let key = normalize(name)
        guard !key.isEmpty else { return nil }
        let candidates = artists.filter { normalize($0.name) == key && providerArtistID($0) != nil }
        guard var best = candidates.first else { return nil }
        for candidate in candidates.dropFirst() where (candidate.fans ?? 0) > (best.fans ?? 0) {
            best = candidate
        }
        return best
    }

    /// Exact (normalized) title and artist match with a usable provider ID; the first in server order wins.
    static func bestAlbum(title: String, artist: String, in albums: [CatalogAlbum]) -> CatalogAlbum? {
        let titleKey = normalize(title)
        let artistKey = normalize(artist)
        guard !titleKey.isEmpty else { return nil }
        return albums.first {
            normalize($0.title) == titleKey && normalize($0.artist) == artistKey && providerAlbumID($0) != nil
        }
    }
}

enum NowPlayingNavigationResolver {
    /// Every distinct artist credited on the item, primary first.
    static func artistTargets(for item: PlaybackItem, catalog: LibraryCatalog) -> [NowPlayingArtistTarget] {
        var targets: [NowPlayingArtistTarget] = []
        var seen = Set<String>()
        func add(_ target: NowPlayingArtistTarget) {
            let key = CatalogNameMatch.normalize(target.name)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            targets.append(target)
        }
        switch item {
        case .library(let track):
            if let entry = catalog.artistsByID[track.artistID], !entry.title.isEmpty {
                add(NowPlayingArtistTarget(name: entry.title, libraryArtistID: track.artistID))
            } else {
                let name = LibraryCatalog.artistName(track)
                add(NowPlayingArtistTarget(name: name, libraryArtistID: uniqueLibraryArtistID(named: name, in: catalog)))
            }
            for name in [track.artist] + track.artists {
                add(NowPlayingArtistTarget(name: name, libraryArtistID: uniqueLibraryArtistID(named: name, in: catalog)))
            }
        case .catalog(let song):
            add(NowPlayingArtistTarget(name: song.artist,
                                       libraryArtistID: uniqueLibraryArtistID(named: song.artist, in: catalog),
                                       providerArtistID: song.deezerArtistID))
            for name in song.artists {
                add(NowPlayingArtistTarget(name: name, libraryArtistID: uniqueLibraryArtistID(named: name, in: catalog)))
            }
        }
        return targets
    }

    static func albumTarget(for item: PlaybackItem, catalog: LibraryCatalog) -> NowPlayingAlbumTarget? {
        switch item {
        case .library(let track):
            guard !track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let artist = LibraryCatalog.artistName(track)
            let id = catalog.albumsByID[track.albumID] != nil
                ? track.albumID : uniqueLibraryAlbumID(title: track.album, artist: artist, in: catalog)
            return NowPlayingAlbumTarget(title: track.album, artist: artist, libraryAlbumID: id)
        case .catalog(let song):
            guard !song.albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return NowPlayingAlbumTarget(title: song.albumName, artist: song.artist,
                                         libraryAlbumID: uniqueLibraryAlbumID(title: song.albumName, artist: song.artist, in: catalog),
                                         providerAlbumID: song.deezerAlbumID, providerArtistID: song.deezerArtistID)
        }
    }

    /// The artist page link from an album page.
    static func artistTarget(forAlbum target: NowPlayingAlbumTarget, catalog: LibraryCatalog) -> NowPlayingArtistTarget? {
        guard !CatalogNameMatch.normalize(target.artist).isEmpty else { return nil }
        let libraryID = target.libraryAlbumID
            .flatMap { catalog.tracks(in: .album($0), likedIDs: [], playlist: nil).first?.artistID }
            .flatMap { catalog.artistsByID[$0] != nil ? $0 : nil }
        return NowPlayingArtistTarget(name: target.artist,
                                      libraryArtistID: libraryID ?? uniqueLibraryArtistID(named: target.artist, in: catalog),
                                      providerArtistID: target.providerArtistID)
    }

    /// The one library track with the song's title by the same artist, if exactly one exists.
    static func libraryTrack(matching song: CatalogSong, in tracks: [LibraryTrack]) -> LibraryTrack? {
        if let track = song.libraryTrack(in: tracks) { return track }
        let title = CatalogNameMatch.normalize(song.title)
        let artist = CatalogNameMatch.normalize(song.artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let matches = tracks.filter {
            CatalogNameMatch.normalize($0.title) == title &&
            (CatalogNameMatch.normalize($0.artist) == artist || CatalogNameMatch.normalize($0.albumArtist) == artist)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func uniqueLibraryArtistID(named name: String, in catalog: LibraryCatalog) -> String? {
        let key = CatalogNameMatch.normalize(name)
        guard !key.isEmpty else { return nil }
        let matches = catalog.artistsByID.values.filter { CatalogNameMatch.normalize($0.title) == key }
        return matches.count == 1 ? matches[0].id : nil
    }

    static func uniqueLibraryAlbumID(title: String, artist: String, in catalog: LibraryCatalog) -> String? {
        let titleKey = CatalogNameMatch.normalize(title)
        let artistKey = CatalogNameMatch.normalize(artist)
        guard !titleKey.isEmpty else { return nil }
        let matches = catalog.albumsByID.values.filter {
            CatalogNameMatch.normalize($0.title) == titleKey && CatalogNameMatch.normalize($0.artist) == artistKey
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}

/// One row of an album page that combines the provider tracklist with the library's tracks.
enum AlbumPageRow: Identifiable, Equatable {
    case owned(LibraryTrack, catalog: CatalogSong?)
    case catalogOnly(CatalogSong)
    case libraryOnly(LibraryTrack)

    var id: String {
        switch self {
        case .owned(let track, _), .libraryOnly(let track): return "lib:\(track.id)"
        case .catalogOnly(let song): return "cat:\(song.id)"
        }
    }

    var libraryTrack: LibraryTrack? {
        switch self {
        case .owned(let track, _), .libraryOnly(let track): track
        case .catalogOnly: nil
        }
    }

    var catalogSong: CatalogSong? {
        switch self {
        case .owned(_, let song): song
        case .catalogOnly(let song): song
        case .libraryOnly: nil
        }
    }
}

enum AlbumTrackMerge {
    /// Provider order first; library tracks the provider list lacks follow in their given order.
    static func rows(catalogTracks: [CatalogSong], libraryTracks: [LibraryTrack]) -> [AlbumPageRow] {
        var unused = libraryTracks
        var rows: [AlbumPageRow] = []
        for song in catalogTracks {
            let key = CatalogNameMatch.normalize(song.title)
            let candidates = unused.indices.filter { CatalogNameMatch.normalize(unused[$0].title) == key }
            let index = candidates.first { index in
                guard let number = song.trackNumber, number > 0 else { return false }
                return unused[index].trackNumber == number
            } ?? candidates.first
            if let index {
                rows.append(.owned(unused.remove(at: index), catalog: song))
            } else {
                rows.append(.catalogOnly(song))
            }
        }
        return rows + unused.map(AlbumPageRow.libraryOnly)
    }

    static func playbackItems(_ rows: [AlbumPageRow], includeCatalog: Bool) -> [PlaybackItem] {
        rows.compactMap { row in
            switch row {
            case .owned(let track, _), .libraryOnly(let track): .library(track)
            case .catalogOnly(let song): includeCatalog ? .catalog(song) : nil
            }
        }
    }
}

enum ArtistAlbumMerge {
    /// Provider albums the library does not already list for this artist.
    static func catalogOnly(providerAlbums: [CatalogAlbum], libraryAlbums: [LibraryBrowseEntry]) -> [CatalogAlbum] {
        let owned = Set(libraryAlbums.map { CatalogNameMatch.normalize($0.title) })
        return providerAlbums.filter { !owned.contains(CatalogNameMatch.normalize($0.title)) }
    }
}
