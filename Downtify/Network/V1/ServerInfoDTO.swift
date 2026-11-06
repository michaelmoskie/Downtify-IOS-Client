enum MobileAPIV1 {
    static let serverInfoPath = "/api/server/info"
    static let maximumAPIVersion = 1

    struct ServerInfoDTO: Decodable {
        struct Capabilities: Decodable {
            let passwordSignIn: Bool?

            enum CodingKeys: String, CodingKey {
                case passwordSignIn = "password_sign_in"
            }
        }

        let product: String
        let apiVersion: Int
        let serverID: String
        let capabilities: Capabilities?

        var supportsPasswordSignIn: Bool {
            capabilities?.passwordSignIn == true
        }

        var isCompatible: Bool {
            product == "Downtify" && apiVersion <= MobileAPIV1.maximumAPIVersion
        }

        enum CodingKeys: String, CodingKey {
            case product, capabilities
            case apiVersion = "api_version"
            case serverID = "server_id"
        }
    }
}
