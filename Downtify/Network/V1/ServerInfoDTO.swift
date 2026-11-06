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
            let transcoding: Transcoding?

            enum CodingKeys: String, CodingKey {
                case signedURLs = "signed_urls"
                case passwordSignIn = "password_sign_in"
                case transcoding
            }
        }

        let product: String
        let apiVersion: Int
        let serverID: String
        let name: String?
        let capabilities: Capabilities?

        var supportsPasswordSignIn: Bool {
            capabilities?.passwordSignIn == true
        }

        var isCompatible: Bool {
            product == "Downtify" && apiVersion <= MobileAPIV1.maximumAPIVersion
        }

        enum CodingKeys: String, CodingKey {
            case product, name, capabilities
            case apiVersion = "api_version"
            case serverID = "server_id"
        }
    }
}
