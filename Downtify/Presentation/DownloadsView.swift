import SwiftUI

struct DownloadsView: View {
    let connection: ConnectionService
    let queue: ServerDownloadQueue
    @ObservedObject var playback: PlaybackController
    @ObservedObject var library: LibraryPresentationModel
    @EnvironmentObject private var downloads: OfflineDownloads
    @Environment(\.downtifyPalette) private var palette
    @State private var session: DeviceSession?
    @State private var jobs: [ServerDownloadQueue.Job] = []
    @State private var queueStatus: ServerDownloadQueue.Status?
    @State private var link = ""
    @State private var loadingQueue = false
    @State private var queueError: String?
    @State private var localError: String?
    @State private var requestMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DowntifyStyle.Space.large) {
                localSection
                serverSection
            }
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("Downloads")
        .toolbarBackground(palette.background, for: .navigationBar)
        .task { await load() }
        .refreshable { await refreshQueue() }
        .alert("Download request", isPresented: Binding(get: { requestMessage != nil }, set: { if !$0 { requestMessage = nil } })) {
            Button("OK", role: .cancel) { requestMessage = nil }
        } message: { Text(requestMessage ?? "") }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("On this device", systemImage: "iphone.gen3")
                .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Offline files use device storage and can play without a server connection.")
                .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DowntifyStyle.error).accessibilityAddTraits(.isStaticText)
            }
            let items = downloads.currentDownloads
            if items.isEmpty {
                ContentUnavailableView("No offline downloads", systemImage: "arrow.down.to.line",
                                       description: Text("Choose Download for offline playback from a song’s actions."))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                ForEach(items) { item in localRow(item) }
            }
            HStack {
                Label("Saved", systemImage: "internaldrive")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: downloads.storedBytes, countStyle: .file))
                    .monospacedDigit()
            }.font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func localRow(_ item: OfflineDownload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.track.displayTitle).font(.headline).lineLimit(2)
                    Text(item.track.displayArtist).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                    Text(localStatus(item)).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                }
                Spacer(minLength: 8)
                Menu {
                    if item.state == .ready {
                        Button("Play offline", systemImage: "play.fill") {
                            playback.replaceQueue([item.track], startingAt: 0)
                        }
                        Button("Delete offline file", systemImage: "trash", role: .destructive) {
                            do { try downloads.delete(item.id); localError = nil }
                            catch { localError = "Could not delete the offline file. Check available storage and try again." }
                        }
                    } else if item.pending {
                        Button("Cancel download", systemImage: "xmark.circle") { downloads.cancel(item.id) }
                    } else {
                        Button("Retry download", systemImage: "arrow.clockwise") {
                            do { _ = try downloads.retry(item.id); localError = nil }
                            catch { localError = "Could not retry this download. Reconnect and try again." }
                        }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            do { try downloads.delete(item.id); localError = nil }
                            catch { localError = "Could not remove this download." }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Actions for \(item.track.displayTitle)")
            }
            if item.state == .transferring, let expected = item.expectedBytes, expected > 0 {
                ProgressView(value: Double(item.receivedBytes), total: Double(expected))
                    .accessibilityLabel("Download progress for \(item.track.displayTitle)")
                    .accessibilityValue("\(Int(Double(item.receivedBytes) / Double(expected) * 100)) percent")
            } else if item.state == .preparing {
                ProgressView().accessibilityLabel("Preparing \(item.track.displayTitle)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Server queue", systemImage: "server.rack")
                .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("These jobs run on the server. Completed items become available through library sync; they are not saved on this device.")
                .font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
            if let queueStatus {
                Text("Queue \(queueStatus.paused ? "paused" : queueStatus.state) · \(queueStatus.active) active")
                    .font(.subheadline).accessibilityLabel("Server queue \(queueStatus.state), \(queueStatus.active) active jobs")
            }
            if let queueError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(queueError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DowntifyStyle.error)
                    Button("Retry server queue", systemImage: "arrow.clockwise") { Task { await refreshQueue() } }
                }.font(.footnote)
            } else if jobs.isEmpty && !loadingQueue {
                ContentUnavailableView("Server queue is empty", systemImage: "tray",
                                       description: Text("Add a supported link to request a server download."))
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            if loadingQueue { ProgressView("Loading server queue…") }
            ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.song.title ?? job.filename ?? "Server download")
                        .font(.headline).lineLimit(2)
                    if let artist = job.song.artist, !artist.isEmpty {
                        Text(artist).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
                    }
                    HStack {
                        Text(job.status.capitalized)
                        if let position = job.position { Text("· Position \(position)") }
                        Spacer()
                        if let progress = job.progress, progress.isFinite {
                            Text("\(Int(max(0, min(100, progress))))%")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
                    if let progress = job.progress, progress.isFinite, progress > 0, progress < 100 {
                        ProgressView(value: max(0, min(100, progress)), total: 100)
                            .accessibilityLabel("Server job progress")
                            .accessibilityValue("\(Int(max(0, min(100, progress)))) percent")
                    }
                    if let message = job.message, !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(DowntifyStyle.secondaryText)
                    }
                }.padding(.vertical, 6)
            }
            HStack(spacing: 8) {
                TextField("https://…", text: $link)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Link for server download")
                Button("Request", systemImage: "arrow.down.to.line") { Task { await submitLink() } }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loadingQueue)
                    .frame(minHeight: 44)
            }
            .padding(.top, 4)
            Text("Server queue controls are managed by the server. This paired device can view jobs and submit links.")
                .font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func localStatus(_ item: OfflineDownload) -> String {
        switch item.state {
        case .preparing: return "Preparing download"
        case .transferring:
            if let expected = item.expectedBytes, expected > 0 {
                return "Downloading · \(ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
            }
            return "Downloading"
        case .ready: return "Available offline"
        case .cancelled: return "Cancelled"
        case let .failed(reason): return "Failed · \(reason.localizedDescription)"
        }
    }

    @MainActor private func load() async {
        guard session == nil else { return }
        session = try? await connection.restoreSession()
        await refreshQueue()
    }

    @MainActor private func refreshQueue() async {
        guard let session = await activeSession() else {
            queueError = "Reconnect to view the server queue."
            return
        }
        loadingQueue = true
        defer { loadingQueue = false }
        do {
            async let fetchedJobs = queue.jobs(session: session)
            async let fetchedStatus = queue.status(session: session)
            let result = try await (fetchedJobs, fetchedStatus)
            guard self.session == session else { return }
            jobs = result.0
            queueStatus = result.1
            queueError = nil
        } catch {
            queueError = "Could not load the server queue. Check the connection and try again."
        }
    }

    @MainActor private func submitLink() async {
        guard let session = await activeSession() else {
            requestMessage = "Reconnect to request a server download."
            return
        }
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            requestMessage = "Enter a complete HTTP or HTTPS link."
            return
        }
        do {
            _ = try await queue.requestTrack(link: url, session: session)
            link = ""
            await refreshQueue()
            await library.refresh()
            requestMessage = "Server download requested. The item will appear after library sync."
        } catch {
            requestMessage = "Could not request this server download. Check the link and connection."
        }
    }

    @MainActor private func activeSession() async -> DeviceSession? {
        if let session { return session }
        guard let restored = try? await connection.restoreSession() else { return nil }
        session = restored
        return restored
    }
}
