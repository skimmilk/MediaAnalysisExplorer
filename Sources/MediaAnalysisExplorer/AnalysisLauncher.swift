import AppKit
import ExplorerCore
import SwiftUI

@MainActor final class AnalysisLauncher: ObservableObject {
    @Published var status: AnalysisLaunchStatus?
    @Published private(set) var directory: URL?
    var isRunning: Bool { status.map { !$0.finished } ?? false }
    private var process: Process?
    private var output: FileHandle?
    private var observer: Task<Void, Never>?
    private let preferences: UserDefaults
    private static let sessionKey = "analysisLaunchSession"

    init(recoverSession: Bool = true, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if recoverSession, let path = preferences.string(forKey: Self.sessionKey) {
            let url = URL(fileURLWithPath: path)
            if let bytes = try? Data(contentsOf: url.appendingPathComponent("status.json")),
               let saved = try? JSONDecoder().decode(AnalysisLaunchStatus.self, from: bytes) {
                status = saved; directory = url
                if !saved.finished { observe(url) }
            }
        }
    }

    func launch() {
        guard !isRunning else { return }
        var initial = AnalysisLaunchStatus()
        status = initial
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MediaAnalysisLauncher")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw ExplorerError("The bundled launch helper is missing. Use a complete MediaAnalysis Explorer.app build.")
            }
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let url = support.appendingPathComponent("MediaAnalysis Explorer/Analysis Runs/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let log = url.appendingPathComponent("helper.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            let child = Process(); child.executableURL = helper; child.arguments = ["--run", url.path]
            child.currentDirectoryURL = url
            child.standardOutput = handle; child.standardError = handle
            do { try child.run() } catch { try? handle.close(); throw error }
            process = child; output = handle; directory = url
            preferences.set(url.path, forKey: Self.sessionKey)
            observe(url)
        } catch {
            initial.phase = "Failed"; initial.message = error.localizedDescription; initial.finished = true
            status = initial
        }
    }

    func stop() {
        guard isRunning, let directory else { return }
        do {
            try Data().write(to: directory.appendingPathComponent("stop"), options: .atomic)
            status?.phase = "Stopping"
            status?.message = "Stopping the library analysis launch…"
        } catch {
            status?.message = "Could not request a stop: " + error.localizedDescription
        }
    }

    func showDetails() { if let directory { NSWorkspace.shared.open(directory) } }

    private func observe(_ url: URL) {
        observer?.cancel()
        observer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let statusURL = url.appendingPathComponent("status.json")
                if let bytes = try? Data(contentsOf: statusURL), bytes.count <= 64 * 1024,
                   let saved = try? JSONDecoder().decode(AnalysisLaunchStatus.self, from: bytes) {
                    self.status = saved
                }
                if self.status?.finished == true {
                    try? self.output?.close(); self.output = nil; self.process = nil
                    break
                }
                if self.process?.isRunning == false {
                    // A supervisor failure still has an independently armed guard.
                    try? Data().write(to: url.appendingPathComponent("stop"), options: .atomic)
                }
                if let bytes = try? Data(contentsOf: url.appendingPathComponent("cleanup.json")),
                   let cleanup = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   self.process == nil || self.process?.isRunning == false {
                    var ended = self.status ?? AnalysisLaunchStatus()
                    ended.finished = true; ended.cleaned = cleanup["cleaned"] as? Bool == true
                    ended.phase = ended.cleaned ? "Interrupted" : "Cleanup failed"
                    ended.message = "The launch helper ended. " + (cleanup["message"] as? String ?? "Completion was not verified.")
                    self.status = ended
                    try? self.output?.close(); self.output = nil; self.process = nil
                    break
                }
                if self.process?.isRunning == false, !FileManager.default.fileExists(atPath: url.appendingPathComponent("guard-armed").path) {
                    var failed = AnalysisLaunchStatus()
                    failed.phase = "Failed"; failed.finished = true
                    failed.message = "The launch helper could not prepare the session. See launch details."
                    self.status = failed
                    try? self.output?.close(); self.output = nil; self.process = nil
                    break
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
}

struct AnalysisLaunchControls: View {
    @ObservedObject var launcher: AnalysisLauncher
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Launch mediaanalysisd", systemImage: "play.fill") { launcher.launch() }
                    .disabled(launcher.isRunning)
                    .accessibilityIdentifier("launchMediaAnalysis")
                if launcher.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop", systemImage: "stop.fill") { launcher.stop() }
                        .disabled(launcher.status?.phase == "Stopping" || launcher.status?.phase == "Cleaning up")
                }
                if let status = launcher.status {
                    Text(status.phase).font(.caption.weight(.medium))
                        .foregroundStyle(status.phase == "Failed" || status.phase == "Cleanup failed" ? Color.orange : Color.secondary)
                    if !status.daemonPIDs.isEmpty { Text("PID " + status.daemonPIDs.map(String.init).joined(separator: ", ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Spacer()
                if launcher.directory != nil { Button("Launch details", systemImage: "folder") { launcher.showDetails() }.controlSize(.small) }
            }
            Text(launcher.status?.message ?? "Request image and movie analysis across the daemon’s registered Photos libraries, including System and Syndication.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let issue = launcher.status?.monitoringIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            Text("Eligible work only; macOS decides availability. Runs until the task ends, Stop, or one hour. Continues if this app closes.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(11).background(.quaternary.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
