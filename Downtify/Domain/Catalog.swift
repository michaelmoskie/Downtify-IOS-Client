import Foundation

/// A JSON value retained from a catalog response so a result can be sent back
/// to the server without losing provider-specific fields.
enum CatalogJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CatalogJSONValue])
    case object([String: CatalogJSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([CatalogJSONValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: CatalogJSONValue].self) { self = .object(object) }
        else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported catalog JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    var objectValue: [String: CatalogJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var stringsValue: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }
}

struct CatalogResultID: Hashable, Sendable, CustomStringConvertible {
    let source: String
    let value: String

    var description: String { "\(source):\(value)" }
}

struct CatalogLibraryArtist: Codable, Equatable, Sendable {
    let name: String
    let tracks: Int
    let liked: Int
}

struct CatalogLibraryAlbum: Codable, Equatable, Sendable {
    let artist: String
    let title: String
}

/// A provider or local-catalog song. It is deliberately not a `LibraryTrack`:
/// provider IDs cannot be used with `/api/v1/tracks/{id}`.
struct CatalogSong: Codable, Equatable, Identifiable, Sendable {
    let source: String
    let songID: String?
    let youtubeID: String?
    let deezerArtistID: String?
    let deezerAlbumID: String?
    let title: String
    let artist: String
    let artists: [String]
    let albumName: String
    let duration: Double?
    let url: String
    let previewURL: String?
    let coverURL: String?
    let file: String?
    let trackNumber: Int?
    let albumTrackTotal: Int?
    let rawPayload: CatalogJSONValue

    var id: CatalogResultID {
        let value = songID ?? youtubeID ?? (url.isEmpty ? "\(title)\u{1F}\(artist)\u{1F}\(duration ?? 0)" : url)
        return CatalogResultID(source: source, value: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CatalogCodingKey.self)
        var payload: [String: CatalogJSONValue] = [:]
        for key in container.allKeys {
            payload[key.stringValue] = try container.decode(CatalogJSONValue.self, forKey: key)
        }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = payload[key]?.stringValue, !value.isEmpty { return value }
            }
            return nil
        }
        func integer(_ keys: String...) -> Int? {
            for key in keys {
                if let number = payload[key]?.doubleValue, number.isFinite { return Int(number) }
            }
            return nil
        }

        guard let source = string("source"), let title = string("name", "title") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Catalog song requires source and a title"))
        }
        let artist = string("artist") ?? ""
        let decodedArtists = payload["artists"]?.stringsValue ?? []
        self.source = source
        songID = string("song_id", "songId")
        youtubeID = string("youtube_id", "video_id")
        deezerArtistID = string("deezer_artist_id")
        deezerAlbumID = string("deezer_album_id")
        self.title = title
        self.artist = artist.isEmpty ? decodedArtists.first ?? "" : artist
        artists = decodedArtists.isEmpty && !artist.isEmpty ? [artist] : decodedArtists
        albumName = string("album_name", "album") ?? ""
        duration = payload["duration"]?.doubleValue
        url = string("url") ?? ""
        previewURL = string("preview_url")
        coverURL = string("cover_url")
        file = string("file")
        trackNumber = integer("track_number")
        albumTrackTotal = integer("album_track_total")
        rawPayload = .object(payload)
    }

    func encode(to encoder: Encoder) throws {
        guard let payload = rawPayload.objectValue else {
            throw EncodingError.invalidValue(rawPayload, .init(codingPath: encoder.codingPath,
                                                               debugDescription: "Catalog song payload must be an object"))
        }
        var container = encoder.container(keyedBy: CatalogCodingKey.self)
        for (key, value) in payload {
            try container.encode(value, forKey: CatalogCodingKey(stringValue: key))
        }
    }

    /// Library-only search rows identify a file path, not a synced track ID.
    /// Callers must pass the current account-scoped library snapshot.
    func libraryTrack(in scopedTracks: [LibraryTrack]) -> LibraryTrack? {
        guard source == "library", let file else { return nil }
        let matches = scopedTracks.filter { $0.file == file }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct CatalogAlbum: Codable, Equatable, Identifiable, Sendable {
    let source: String
    let albumID: String
    let title: String
    let artist: String
    let artistID: String?
    let deezerAlbumID: String?
    let spotifyID: String?
    let coverURL: String?
    let url: String?
    let releaseType: String?
    let releaseDate: String?
    let year: String?
    let trackCount: Int?
    let rawPayload: CatalogJSONValue

    var id: CatalogResultID { CatalogResultID(source: source, value: albumID) }

    init(from decoder: Decoder) throws {
        let payload = try CatalogPayload(from: decoder).value
        let value = payload.objectValue ?? [:]
        let deezerAlbumID = value["deezer_album_id"]?.stringValue
        let spotifyID = value["spotify_id"]?.stringValue
        let source = value["source"]?.stringValue ?? (deezerAlbumID != nil ? "deezer" : spotifyID != nil ? "spotify" : nil)
        guard let source,
              let albumID = value["album_id"]?.stringValue ?? deezerAlbumID ?? spotifyID ?? value["id"]?.stringValue,
              let title = value["name"]?.stringValue ?? value["title"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Catalog album requires source, ID, and title"))
        }
        self.source = source
        self.albumID = albumID
        self.title = title
        artist = value["artist"]?.stringValue ?? ""
        artistID = value["artist_id"]?.stringValue ?? value["deezer_artist_id"]?.stringValue
        self.deezerAlbumID = deezerAlbumID
        self.spotifyID = spotifyID
        coverURL = value["cover_url"]?.stringValue
        url = value["url"]?.stringValue
        releaseType = value["release_type"]?.stringValue
        releaseDate = value["release_date"]?.stringValue
        year = value["year"]?.stringValue
        trackCount = value["track_count"].flatMap { $0.doubleValue.map { Int($0) } }
        rawPayload = payload
    }

    func encode(to encoder: Encoder) throws { try CatalogPayload.encode(rawPayload, to: encoder) }
}

struct CatalogArtist: Codable, Equatable, Identifiable, Sendable {
    let source: String
    let artistID: String
    let name: String
    let deezerID: String?
    let coverURL: String?
    let url: String?
    let fans: Int?
    let albumCount: Int?
    let rawPayload: CatalogJSONValue

    var id: CatalogResultID { CatalogResultID(source: source, value: artistID) }

    init(from decoder: Decoder) throws {
        let payload = try CatalogPayload(from: decoder).value
        let value = payload.objectValue ?? [:]
        let deezerID = value["deezer_id"]?.stringValue
        let source = value["source"]?.stringValue ?? (deezerID != nil ? "deezer" : nil)
        guard let source,
              let artistID = value["artist_id"]?.stringValue ?? deezerID ?? value["id"]?.stringValue,
              let name = value["name"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Catalog artist requires source, ID, and name"))
        }
        self.source = source
        self.artistID = artistID
        self.name = name
        self.deezerID = deezerID
        coverURL = value["cover_url"]?.stringValue ?? value["picture_url"]?.stringValue
        url = value["url"]?.stringValue
        fans = value["fans"].flatMap { $0.doubleValue.map { Int($0) } }
        albumCount = value["album_count"].flatMap { $0.doubleValue.map { Int($0) } }
        rawPayload = payload
    }

    func encode(to encoder: Encoder) throws { try CatalogPayload.encode(rawPayload, to: encoder) }
}

struct CatalogPlaylist: Codable, Equatable, Identifiable, Sendable {
    let source: String
    let playlistID: String
    let name: String
    let deezerPlaylistID: String?
    let spotifyID: String?
    let owner: String?
    let coverURL: String?
    let url: String?
    let rawPayload: CatalogJSONValue
    var id: CatalogResultID { CatalogResultID(source: source, value: playlistID) }

    init(from decoder: Decoder) throws {
        let payload = try CatalogPayload(from: decoder).value
        let value = payload.objectValue ?? [:]
        let deezerPlaylistID = value["deezer_playlist_id"]?.stringValue
        let spotifyID = value["spotify_id"]?.stringValue
        let source = value["source"]?.stringValue ?? (deezerPlaylistID != nil ? "deezer" : spotifyID != nil ? "spotify" : nil)
        guard let source,
              let playlistID = value["playlist_id"]?.stringValue ?? deezerPlaylistID ?? spotifyID ?? value["id"]?.stringValue,
              let name = value["name"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Catalog playlist requires source, ID, and name"))
        }
        self.source = source
        self.playlistID = playlistID
        self.name = name
        self.deezerPlaylistID = deezerPlaylistID
        self.spotifyID = spotifyID
        owner = value["owner"]?.stringValue
        coverURL = value["cover_url"]?.stringValue
        url = value["url"]?.stringValue
        rawPayload = payload
    }

    func encode(to encoder: Encoder) throws { try CatalogPayload.encode(rawPayload, to: encoder) }
}

struct CatalogSearchResults: Codable, Equatable, Sendable {
    let tracks: [CatalogSong]
    let albums: [CatalogAlbum]
    let artists: [CatalogArtist]

    init(tracks: [CatalogSong] = [], albums: [CatalogAlbum] = [], artists: [CatalogArtist] = []) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CatalogCodingKey.self)
        tracks = try container.decodeIfPresent([CatalogSong].self, forKey: .init(stringValue: "songs")) ??
            container.decodeIfPresent([CatalogSong].self, forKey: .init(stringValue: "tracks")) ?? []
        albums = try container.decodeIfPresent([CatalogAlbum].self, forKey: .init(stringValue: "albums")) ?? []
        artists = try container.decodeIfPresent([CatalogArtist].self, forKey: .init(stringValue: "artists")) ?? []
    }
}

struct CatalogCharts: Codable, Equatable, Sendable {
    let tracks: [CatalogSong]
    let albums: [CatalogAlbum]
    let artists: [CatalogArtist]
    let playlists: [CatalogPlaylist]
}

struct URLResolution: Codable, Equatable, Sendable {
    let kind: String
    let name: String
    let subtitle: String
    let coverURL: String?
    let year: String?
    let tracks: [CatalogSong]
    let albums: [CatalogAlbum]

    enum CodingKeys: String, CodingKey {
        case kind, name, subtitle, year, tracks, albums
        case coverURL = "cover_url"
    }
}

struct CatalogFinderArtist: Decodable, Equatable, Sendable {
    let artist: CatalogArtist
    let bio: String
    let social: [String: String]
    let related: [CatalogArtist]
    let topSongs: [CatalogSong]

    enum CodingKeys: String, CodingKey {
        case bio, social, related
        case artistID = "artist_id"
        case name, coverURL = "cover_url", fans, albumCount = "album_count", url, source
        case topSongs = "top_songs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try CatalogPayload(from: decoder).value
        artist = try payload.decode(CatalogArtist.self)
        bio = try container.decodeIfPresent(String.self, forKey: .bio) ?? ""
        social = try container.decodeIfPresent([String: String].self, forKey: .social) ?? [:]
        related = try container.decodeIfPresent([CatalogArtist].self, forKey: .related) ?? []
        topSongs = try container.decodeIfPresent([CatalogSong].self, forKey: .topSongs) ?? []
    }
}

struct CatalogFinderAlbum: Codable, Equatable, Sendable {
    let album: CatalogAlbum
    let tracks: [CatalogSong]

    init(from decoder: Decoder) throws {
        let payload = try CatalogPayload(from: decoder).value
        let object = payload.objectValue ?? [:]
        album = try payload.decode(CatalogAlbum.self)
        tracks = try object["tracks"].map { try $0.decode([CatalogSong].self) } ?? []
    }
}

struct CatalogSimilarResults: Codable, Equatable, Sendable {
    let artist: String
    let track: String
    let source: String
    let tracks: [CatalogSong]
}

struct CatalogDiscoverResults: Codable, Equatable, Sendable {
    let artists: [CatalogArtist]
    let seeds: [String]
    let partial: Bool
}

struct CatalogBlockedArtist: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let blockedAt: String

    var id: String { name.lowercased() }

    enum CodingKeys: String, CodingKey {
        case name
        case blockedAt = "blocked_at"
    }
}

struct CatalogCollectionsResults: Codable, Equatable, Sendable {
    let source: String?
    let albums: [CatalogAlbum]
    let moreAlbums: [CatalogAlbum]
    let playlists: [CatalogPlaylist]
    let partial: Bool

    enum CodingKeys: String, CodingKey {
        case source, albums, playlists, partial
        case moreAlbums = "more_albums"
    }
}

private struct CatalogPayload: Decodable {
    let value: CatalogJSONValue

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CatalogCodingKey.self)
        var object: [String: CatalogJSONValue] = [:]
        for key in container.allKeys {
            object[key.stringValue] = try container.decode(CatalogJSONValue.self, forKey: key)
        }
        value = .object(object)
    }

    static func encode(_ value: CatalogJSONValue, to encoder: Encoder) throws {
        guard let object = value.objectValue else {
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
                                                          debugDescription: "Catalog payload must be an object"))
        }
        var container = encoder.container(keyedBy: CatalogCodingKey.self)
        for (key, value) in object {
            try container.encode(value, forKey: CatalogCodingKey(stringValue: key))
        }
    }
}

private struct CatalogCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init(intValue: Int) { stringValue = String(intValue) }
}

private extension CatalogJSONValue {
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}
