import SwiftUI
import AVFoundation
import UIKit

@MainActor
struct FoundationView: View {
    let name: String
    var recoverableError: String? = nil
    var retryAction: (() -> Void)? = nil
    let connection: ConnectionService
    let discovery: BonjourServerDiscovery
    let deviceName: String
    @StateObject private var model: ConnectionFlowModel

    init(name: String, recoverableError: String? = nil, retryAction: (() -> Void)? = nil,
         connection: ConnectionService, discovery: BonjourServerDiscovery,
         deviceName: String = "iPhone") {
        self.name = name
        self.recoverableError = recoverableError
        self.retryAction = retryAction
        self.connection = connection
        self.discovery = discovery
        self.deviceName = deviceName
        _model = StateObject(wrappedValue: ConnectionFlowModel(connection: connection, discovery: discovery, deviceName: deviceName))
    }

    @Environment(\.downtifyPalette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @State private var showingScanner = false

    private var contentWidth: CGFloat {
        horizontalSizeClass == .regular ? 560 : 440
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .center, spacing: DowntifyStyle.Space.section) {
                    brand
                    welcome
                    setupCard
                }
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DowntifyStyle.Space.large)
                .padding(.vertical, DowntifyStyle.Space.section)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .background(palette.background.ignoresSafeArea())
        }
        .tint(DowntifyStyle.accent)
    }

    private var brand: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DowntifyStyle.onAccent)
                .frame(width: 48, height: 48)
                .background(DowntifyStyle.accent.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityHidden(true)

            Text(name)
                .font(.headline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var welcome: some View {
        VStack(alignment: .center, spacing: DowntifyStyle.Space.small) {
            Text("Your music,\nyour server.")
                .font(.largeTitle.weight(.bold))
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text("Connect to your Downtify server to explore and play your library.")
                .font(.body)
                .foregroundStyle(DowntifyStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
    }

    private var setupCard: some View {
        DowntifyCard {
            VStack(alignment: .center, spacing: DowntifyStyle.Space.regular) {
                Label("Server setup", systemImage: "server.rack")
                    .font(.headline)

                if let recoverableError {
                    Text(recoverableError)
                        .font(.body)
                        .foregroundStyle(DowntifyStyle.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") {
                        retryAction?()
                    }
                }

                TextField("https://music.example.com", text: $model.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Server address")
                Button { model.probeAddress() } label: {
                    if model.isWorking { ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Connecting to server") }
                    else { Text("Connect to server").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent).foregroundStyle(DowntifyStyle.onAccent).disabled(model.isWorking || model.address.isEmpty)

                Button { model.startDiscovery() } label: {
                    Label(model.isDiscovering ? "Searching local network…" : "Find servers on this network", systemImage: "dot.radiowaves.left.and.right")
                }.disabled(model.isWorking)
                Button { showingScanner = true } label: {
                    Label("Scan pairing QR code", systemImage: "qrcode.viewfinder")
                }.disabled(model.isWorking)
                .sheet(isPresented: $showingScanner) {
                    PairingCodeScanner { value in
                        showingScanner = false
                        model.acceptPairingPayload(value)
                    }
                    .presentationDetents([.medium, .large])
                }
                ForEach(model.servers, id: \.address.baseURL.absoluteString) { server in
                    Button { model.probe(server) } label: {
                        VStack(alignment: .leading) { Text(server.name).fontWeight(.medium); Text(server.address.baseURL.absoluteString).font(.caption).foregroundStyle(DowntifyStyle.secondaryText) }
                    }
                }
                if let message = model.discoveryMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                        if model.needsPermissionRecovery {
                            Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(DowntifyStyle.error).fixedSize(horizontal: false, vertical: true) }

                if let target = model.target {
                    Divider()
                    Label(target.name, systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(DowntifyStyle.accent)
                    Text(target.address).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                    if target.supportsPasswordSignIn {
                        Text("Sign in with password").font(.subheadline.weight(.semibold))
                        TextField("Username", text: $model.username).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $model.password).textFieldStyle(.roundedBorder)
                        Button(model.cooldownSeconds > 0 ? "Wait \(model.cooldownSeconds)s" : "Sign in") { model.signIn() }.buttonStyle(.borderedProminent).foregroundStyle(DowntifyStyle.onAccent).disabled(model.isWorking || model.cooldownSeconds > 0 || model.username.isEmpty || model.password.isEmpty)
                    }
                    Text("Pairing code").font(.subheadline.weight(.semibold))
                    TextField("Enter code", text: $model.pairingCode).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Button(model.cooldownSeconds > 0 ? "Wait \(model.cooldownSeconds)s" : "Pair device") { model.pair() }.buttonStyle(.borderedProminent).foregroundStyle(DowntifyStyle.onAccent).disabled(model.isWorking || model.cooldownSeconds > 0 || model.pairingCode.isEmpty)
                    if model.cooldownSeconds > 0 {
                        Text("Sign-in is paused for this server. Try again in \(model.cooldownSeconds) seconds.")
                            .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                    }
                    if target.usesInsecureHTTP {
                        Label("This server uses unencrypted HTTP", systemImage: "lock.slash.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(DowntifyStyle.error)
                        Text("Your password, pairing code, and access token could be read by others on the network.")
                            .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                        Toggle("I understand and want to continue", isOn: $model.consentToInsecureHTTP)
                            .font(.caption)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private final class ConnectionFlowModel: ObservableObject {
    struct ServerPresentation {
        let name: String
        let address: String
        let supportsPasswordSignIn: Bool
        let usesInsecureHTTP: Bool
    }
    @Published var address = ""
    @Published var username = ""
    @Published var password = ""
    @Published var pairingCode = ""
    @Published var target: ServerPresentation?
    @Published var error: String?
    @Published var servers: [DiscoveredServer] = []
    @Published var isDiscovering = false
    @Published var isWorking = false
    @Published var consentToInsecureHTTP = false
    @Published var discoveryMessage: String?
    @Published var cooldownSeconds = 0
    @Published var needsPermissionRecovery = false
    private let connection: ConnectionService
    private let discovery: BonjourServerDiscovery
    private let deviceName: String
    private var connectionTarget: ConnectionTarget?
    private var scannedPayload: PairingPayload?
    private var discoveryTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    init(connection: ConnectionService, discovery: BonjourServerDiscovery, deviceName: String) {
        self.connection = connection; self.discovery = discovery; self.deviceName = deviceName
    }
    func startDiscovery() {
        discoveryTask?.cancel(); isDiscovering = true; discoveryMessage = nil
        needsPermissionRecovery = false
        discoveryTask = Task {
            for await snapshot in discovery.snapshots() {
                servers = snapshot.servers
                switch snapshot.status {
                case .searching: break
                case .ready: discoveryMessage = servers.isEmpty ? "No Downtify servers found yet." : nil
                case .localNetworkUnavailable:
                    discoveryMessage = "Local network access is off. Enable it in Settings to find nearby servers."
                    needsPermissionRecovery = true
                case .waiting: discoveryMessage = "Waiting for the local network…"
                case .failed: discoveryMessage = "Server discovery failed. Enter an address above instead."
                }
            }
            isDiscovering = false
        }
    }
    func acceptPairingPayload(_ value: String) {
        do {
            let payload = try PairingPayload(value)
            scannedPayload = payload
            address = payload.address.baseURL.absoluteString
            pairingCode = payload.code
            consentToInsecureHTTP = false
            error = nil
            let connection = self.connection
            run { try await connection.probe(payload.address.baseURL.absoluteString) }
        } catch { self.error = Self.message(error) }
    }
    func probeAddress() { scannedPayload = nil; consentToInsecureHTTP = false; let connection = self.connection, address = self.address; run { try await connection.probe(address) } }
    func probe(_ server: DiscoveredServer) { scannedPayload = nil; consentToInsecureHTTP = false; let connection = self.connection; run { try await connection.probe(server) } }
    private func run(_ action: @escaping () async throws -> ConnectionTarget) {
        isWorking = true; error = nil; target = nil; connectionTarget = nil; consentToInsecureHTTP = false
        Task { do {
            let probed = try await action()
            connectionTarget = probed
            target = ServerPresentation(name: probed.info.name ?? "Downtify server",
                                        address: probed.address.baseURL.absoluteString,
                                        supportsPasswordSignIn: probed.info.supportsPasswordSignIn,
                                        usesInsecureHTTP: probed.address.usesInsecureHTTP)
            address = probed.address.baseURL.absoluteString
        }
            catch { self.error = Self.message(error) }
            isWorking = false }
    }
    func signIn() { guard let target = connectionTarget else { return }; let username = self.username, password = self.password, deviceName = self.deviceName, connection = self.connection, consent = consentToInsecureHTTP; authenticate { try await connection.signIn(username: username, password: password, at: target, deviceName: deviceName, consentingTo: consent ? target.address : nil) } }
    func pair() {
        guard let target = connectionTarget else { return }
        let code = pairingCode, deviceName = self.deviceName, connection = self.connection
        let consent = consentToInsecureHTTP, payload = scannedPayload
        authenticate {
            if let payload {
                return try await connection.pair(payload, deviceName: deviceName,
                    consentingTo: consent ? target.address : nil)
            }
            return try await connection.pair(code: code, at: target, deviceName: deviceName,
                consentingTo: consent ? target.address : nil)
        }
    }
    private func authenticate(_ action: @escaping () async throws -> DeviceSession) {
        guard cooldownSeconds == 0 else { return }
        isWorking = true; error = nil
        Task { do { _ = try await action(); password = ""; pairingCode = "" }
            catch {
                self.error = Self.message(error)
                if case ConnectionError.rateLimited(let delay) = error { beginCooldown(seconds: delay) }
            }; isWorking = false }
    }
    private func beginCooldown(seconds: TimeInterval) {
        cooldownTask?.cancel()
        let cooldown = AuthenticationCooldown(seconds: seconds)
        func update() {
            cooldownSeconds = cooldown.remainingSeconds(at: Date())
        }
        update()
        cooldownTask = Task {
            while !Task.isCancelled && cooldown.remainingSeconds(at: Date()) > 0 {
                try? await Task.sleep(for: .seconds(1))
                update()
            }
            cooldownSeconds = 0
        }
    }
    private static func message(_ error: Error) -> String {
        switch error {
        case ConnectionError.invalidPairingPayload: return "That pairing code is invalid. Check it and try again."
        case ConnectionError.differentServer: return "The server identity changed. Verify the address and try again."
        case ConnectionError.wrongCode: return "That pairing code was not accepted. Check it and try again."
        case ConnectionError.wrongCredentials: return "The username or password is incorrect."
        case ConnectionError.passwordSignInUnavailable: return "This server does not support password sign-in. Use a pairing code instead."
        case ConnectionError.rateLimited(let delay): return "Too many attempts. Wait about \(Int(delay.rounded(.up))) seconds and try again."
        case APIError.invalidAddress: return "Enter a valid server address, such as https://music.example.com."
        case APIError.insecureTransportConsentRequired: return "Confirm the unencrypted HTTP connection before signing in."
        case APIError.transportFailure: return "Could not reach this server. Check the address and network connection."
        default: return "Could not connect. Check the server address and try again."
        }
    }
}

@MainActor
private struct PairingCodeScanner: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraDenied = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            Group {
                if cameraDenied {
                    ContentUnavailableView("Camera access is off", systemImage: "camera.fill",
                        description: Text("Allow camera access in Settings to scan a pairing code."))
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                        .buttonStyle(.borderedProminent)
                } else {
                    CameraQRReader(onCode: onCode, onDenied: { cameraDenied = true }, onError: { scanError = $0 })
                        .overlay(alignment: .bottom) {
                            Text(scanError ?? "Point your camera at the server’s pairing QR code.")
                                .font(.callout).padding().frame(maxWidth: .infinity)
                                .background(.ultraThinMaterial)
                        }
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

private struct CameraQRReader: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onDenied: () -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> QRReaderController {
        let controller = QRReaderController()
        controller.onCode = onCode; controller.onDenied = onDenied; controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: QRReaderController, context: Context) {}
    static func dismantleUIViewController(_ controller: QRReaderController, coordinator: ()) {
        controller.stop()
    }
}

private final class QRReaderController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onDenied: (() -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.downtify.qr-camera-session")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.configure() : self?.onDenied?() }
            }
        default: onDenied?()
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            onError?("Camera is unavailable on this device."); return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { onError?("Could not start the camera scanner."); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer
        sessionQueue.async { [session] in session.startRunning() }
    }
    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        delivered = true
        guard (try? PairingPayload(value)) != nil else {
            onError?("This QR code is not a Downtify pairing code."); delivered = false; return
        }
        session.stopRunning(); onCode?(value)
    }
}

struct AuthenticationCooldown {
    private let deadline: Date

    init(seconds: TimeInterval, now: Date = Date()) {
        deadline = now.addingTimeInterval(max(0, seconds))
    }

    func remainingSeconds(at now: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
}

struct FoundationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            FoundationView(name: "Downtify", connection: ConnectionService(), discovery: BonjourServerDiscovery())
                .preferredColorScheme(.light)
                .previewDisplayName("Light")
            FoundationView(name: "Downtify", connection: ConnectionService(), discovery: BonjourServerDiscovery())
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark")
        }
    }
}
