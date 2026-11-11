import Foundation

struct PlaylistCreateRequestDTO: Encodable {
    let name: String
}

struct PlaylistRenameRequestDTO: Encodable {
    let name: String
    let newName: String

    enum CodingKeys: String, CodingKey {
        case name
        case newName = "new_name"
    }
}

struct PlaylistTrackEditsRequestDTO: Encodable {
    struct RemovalEntry: Encodable {
        let trackID: String
        let occurrence: Int

        enum CodingKeys: String, CodingKey {
            case trackID = "track_id"
            case occurrence
        }
    }

    let name: String
    let add: [String]?
    let remove: [String]?
    let removeEntries: [RemovalEntry]?
    let allowDuplicates: Bool?

    enum CodingKeys: String, CodingKey {
        case name, add, remove
        case removeEntries = "remove_entries"
        case allowDuplicates = "allow_duplicates"
    }
}

struct PlaylistOrderRequestDTO: Encodable {
    let name: String
    let trackIDs: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case trackIDs = "track_ids"
    }
}
