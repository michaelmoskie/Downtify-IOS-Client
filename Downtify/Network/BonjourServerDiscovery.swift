import Foundation
import Network
import dnssd

struct DiscoveredServer: Equatable {
    let serviceName: String
    let serverID: String?
    let name: String
    let address: ServerAddress

    init?(serviceName: String, host: String, resolvedPort: Int, text: [String: String]) {
        let apiVersion = text["api"].flatMap(Int.init) ?? 0
        let port = text["port"].flatMap(Int.init) ?? resolvedPort
        guard apiVersion <= MobileAPIV1.maximumAPIVersion, (1...65535).contains(port) else { return nil }

        var url = URLComponents()
        url.scheme = text["scheme"] == "https" ? "https" : "http"
        url.host = host.hasSuffix(".") ? String(host.dropLast()) : host
        url.port = port
        let path = (text["path"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = path.isEmpty ? "" : "/\(path)"
        guard let value = url.string, let address = try? ServerAddress(value) else { return nil }

        self.serviceName = serviceName
        serverID = text["id"].flatMap { $0.isEmpty ? nil : $0 }
        name = text["name"].flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
        self.address = address
    }
}

@MainActor
final class BonjourServerDiscovery: NSObject, NetServiceDelegate {
    static let serviceType = "_downtify._tcp"

    enum Status: Equatable {
        case searching
        case ready
        case localNetworkUnavailable
        case waiting
        case failed
    }

    struct Snapshot: Equatable {
        let status: Status
        let servers: [DiscoveredServer]
    }

    private struct ServiceKey: Hashable {
        let name: String
        let type: String
        let domain: String
    }

    private struct Resolution {
        let service: NetService
        let text: [String: String]
        var server: DiscoveredServer?

        func stop() {
            service.delegate = nil
            service.stop()
            service.remove(from: .main, forMode: .common)
        }
    }

    private var browser: NWBrowser?
    private var resolutions: [ServiceKey: Resolution] = [:]
    private var continuation: AsyncStream<Snapshot>.Continuation?
    private var status = Status.searching
    private var generation = 0

    /// Start after the user chooses to discover servers. Cancelling the consumer stops the browse.
    func snapshots() -> AsyncStream<Snapshot> {
        stop()
        let generation = self.generation
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.stop()
            }
        }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.update(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.resolve(results)
            }
        }
        self.browser = browser
        publish()
        browser.start(queue: .main)
        return stream
    }

    func stop() {
        generation += 1
        browser?.cancel()
        browser = nil
        resolutions.values.forEach { $0.stop() }
        resolutions.removeAll()
        continuation?.finish()
        continuation = nil
        status = .searching
    }

    private func update(_ state: NWBrowser.State) {
        switch state {
        case .setup: status = .searching
        case .ready: status = .ready
        case .waiting(.dns(let code)) where code == kDNSServiceErr_PolicyDenied:
            status = .localNetworkUnavailable
        case .waiting: status = .waiting
        case .failed(.dns(let code)) where code == kDNSServiceErr_PolicyDenied:
            status = .localNetworkUnavailable
        case .failed: status = .failed
        case .cancelled: return
        @unknown default: status = .failed
        }
        publish()
        if case .failed = state { stop() }
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        var advertisements: [ServiceKey: [String: String]] = [:]
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let key = ServiceKey(name: name, type: type, domain: domain)
            if case .bonjour(let text) = result.metadata {
                advertisements[key] = text.dictionary
            } else if advertisements[key] == nil {
                advertisements[key] = [:]
            }
        }

        for key in Array(resolutions.keys) where resolutions[key]?.text != advertisements[key] {
            resolutions.removeValue(forKey: key)?.stop()
        }
        for (key, text) in advertisements where resolutions[key] == nil {
            let type = key.type.hasSuffix(".") ? key.type : key.type + "."
            let service = NetService(domain: key.domain, type: type, name: key.name)
            resolutions[key] = Resolution(service: service, text: text)
            service.delegate = self
            service.schedule(in: .main, forMode: .common)
            service.resolve(withTimeout: 5)
        }
        publish()
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let identifier = ObjectIdentifier(sender)
        guard let host = sender.hostName else { return }
        let port = sender.port
        // Resolvers are scheduled on the main run loop.
        MainActor.assumeIsolated { resolved(identifier, host: host, port: port) }
    }

    private func resolved(_ identifier: ObjectIdentifier, host: String, port: Int) {
        guard let key = resolutions.first(where: { ObjectIdentifier($0.value.service) == identifier })?.key,
              var resolution = resolutions[key] else { return }
        resolution.server = DiscoveredServer(serviceName: key.name, host: host,
                                             resolvedPort: port, text: resolution.text)
        resolution.stop()
        resolutions[key] = resolution
        publish()
    }

    private func publish() {
        let servers = resolutions.values.compactMap(\.server).sorted {
            if $0.name.caseInsensitiveCompare($1.name) == .orderedSame {
                return $0.address.baseURL.absoluteString < $1.address.baseURL.absoluteString
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        continuation?.yield(Snapshot(status: status, servers: servers))
    }
}
