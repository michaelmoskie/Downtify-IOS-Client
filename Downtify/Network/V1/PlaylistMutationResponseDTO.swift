import Foundation

struct PlaylistMutationResponseDTO: Decodable, Equatable, Sendable {
    let name: String
    let manual: Bool
    let count: Int
    let trackIDs: [String]
    let previous: String?
    let added: Int?
    let removed: Int?
    let already: [String]?

    enum CodingKeys: String, CodingKey {
        case name, manual, count, previous, added, removed, already
        case trackIDs = "track_ids"
    }
}
