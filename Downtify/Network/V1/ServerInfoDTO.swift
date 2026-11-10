enum MobileAPIV1 {
    static let serverInfoPath = "/api/server/info"
    static let maximumAPIVersion = 1

    struct ServerInfoDTO: Decodable {
        struct Capabilities: Decodable {
            struct Transcoding: Decodable {
                let available: Bool?
                let formats: [String]?
                let bitrates: [Int]?
            }

            let signedURLs: Bool?
            let passwordSignIn: Bool?
            let podcasts: Bool?
            let discover: Bool?
            let lyrics: Bool?
            let transcoding: Transcoding?

            enum CodingKeys: String, CodingKey {
                case signedURLs = "signed_urls"
                case passwordSignIn = "password_sign_in"
                case podcasts, discover, lyrics
                case transcoding
            }
        }

        let product: String
        let apiVersion: Int
        let serverID: String
        let name: String?
        let libraryOnly: Bool?
        let capabilities: Capabilities?

        var supportsPasswordSignIn: Bool {
            capabilities?.passwordSignIn == true
        }

        var supportsPodcasts: Bool { capabilities?.podcasts == true }
        var supportsDiscover: Bool { capabilities?.discover == true }
        var supportsLyrics: Bool { capabilities?.lyrics == true }
        var isLibraryOnly: Bool { libraryOnly == true }

        var isCompatible: Bool {
            product == "Downtify" && apiVersion <= MobileAPIV1.maximumAPIVersion
        }

        enum CodingKeys: String, CodingKey {
            case product, name, capabilities
            case libraryOnly = "library_only"
            case apiVersion = "api_version"
            case serverID = "server_id"
        }
    }
}
