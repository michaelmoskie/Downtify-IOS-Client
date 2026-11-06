struct LibraryTrack: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let file: String
    let title: String
    let artist: String
    let artists: [String]
    let album: String
    let albumArtist: String
    let albumID: String
    let artistID: String
    let trackNumber: Int
    let year: String
    let duration: Double
    let codec: String
    let bitrate: Int
    let sampleRate: Int
    let channels: Int
    let size: Int64
    let added: Int64
    let hasCover: Bool
    let isExplicit: Bool
    let playlists: [String]
}

struct LibraryScope: Equatable, Sendable {
    let serverID: String
    let account: String

    init(serverID: String, username: String?, deviceID: String) {
        self.serverID = serverID
        if let username, !username.isEmpty {
            account = "user:\(username.lowercased())"
        } else {
            account = "device:\(deviceID)"
        }
    }
}

struct LibrarySnapshot: Equatable, Sendable {
    let cursor: Int64?
    let tracks: [LibraryTrack]
}
