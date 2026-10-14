import AppKit
import Combine
import ExplorerCore
import UniformTypeIdentifiers
import Darwin

struct LocalMediaRun: Identifiable {
    enum State: String { case preparing = "Preparing", running = "Analyzing", complete = "Complete", partial = "Some analyses unavailable", cancelled = "Stopped", failed = "Unavailable" }
    let id: UUID
    let name: String
    var url: URL?
    var preview: MediaPreview?
    var video = false
    var state = State.preparing
    var reports: [LocalAnalysisReport] = []
    var presentation = LocalAnalysisPresentation.empty
    var error: String?
    var previewError: String?
    var families: [LocalAnalysisFamily] { reports.flatMap(\.families) }
    var timeline: RegionTimeline { presentation.regionTimeline }
    var active: Bool { state == .preparing || state == .running }
}

/// A session owns its copies. No source file is written, imported or retained
/// through a Photos asset. Temporary copies disappear when the app exits.
private final class AnalysisWorkspace: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaAnalysisExplorer-" + UUID().uuidString, isDirectory: true)
    func clear() { try? FileManager.default.removeItem(at: root) }
    deinit { clear() }
    // Preparation is serialized behind the previous run's completion, so
    // pruning cannot delete a copy still being used by an earlier helper.
    func prune(except id: UUID?) {
        for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if child.lastPathComponent != id?.uuidString { try? FileManager.default.removeItem(at: child) }
        }
    }
    func prepare(_ source: URL, id: UUID, budget: WorkBudget) throws -> (URL, MediaPreview?, String?, Bool) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL else { throw ExplorerError("Choose a local image or video file.") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024 else {
            throw ExplorerError("Choose one image or video file up to 256 MB.")
        }
        let type = values.contentType ?? UTType(filenameExtension: source.pathExtension)
        let video = type?.conforms(to: .movie) == true
        guard video || type?.conforms(to: .image) == true else { throw ExplorerError("This file type is unsupported. Choose an image or video.") }
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: directory) } }
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ExplorerError("Could not create a private media copy.") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total = 0
        while true {
            try budget.check()
            let block = try input.read(upToCount: 1024 * 1024) ?? Data()
            if block.isEmpty { break }
            total += block.count
            guard total <= 256 * 1024 * 1024 else { throw ExplorerError("File grew beyond the 256 MB limit.") }
            try output.write(contentsOf: block)
        }
        try output.synchronize()
        try budget.check()
        // A preview failure must not prevent the actual analysis of a valid file.
        do {
            let preview = try PreviewReader.read(destination, budget: budget)
            finished = true; return (destination, preview, nil, video)
        } catch {
            try budget.check(); finished = true
            return (destination, nil, error.localizedDescription, video)
        }
    }
}

/// One bounded subprocess per pass isolates private framework failures from the
/// UI. Termination, deadline and app shutdown all use the same cancellation path.
final class LocalAnalysisWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    func cancel() {
        lock.lock(); stopped = true; let child = process; lock.unlock()
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
    func run(executable: URL, input: URL, pass: LocalAnalysisPass, progress: @escaping @Sendable (Double) -> Void) throws -> LocalAnalysisReport {
        let child = Process(), pipe = Pipe()
        child.executableURL = executable
        child.arguments = [input.path, pass.kind, String(pass.mask), String(pass.seconds)]
        child.standardOutput = pipe
        // Private framework diagnostics are not the structured result channel.
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if stopped { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(pass.seconds + 5))
        timer.setEventHandler { [weak self] in self?.cancel() }
        timer.resume()
        defer {
            timer.cancel(); try? pipe.fileHandleForReading.close()
            lock.lock(); process = nil; let running = child.isRunning; lock.unlock()
            if running { child.terminate(); if child.isRunning { kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
        }
        var buffer = Data(), total = 0, result: AnalysisValue?
        while let bytes = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !bytes.isEmpty {
            total += bytes.count
            guard total <= 32 * 1024 * 1024 else { throw ExplorerError("Worker output exceeded its limit.") }
            buffer.append(bytes)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                // Ignore bounded framework log lines; accept only our event schema.
                guard let event = try? LocalAnalysisReport.decodeEvent(Data(line)) else { continue }
                if event["event"].text == "progress", let fraction = event["fraction"].double {
                    progress(max(0, min(1, fraction)))
                } else if event["event"].text == "result", !event["report"].object.isEmpty { result = event["report"] }
            }
            guard buffer.count <= 16 * 1024 * 1024 else { throw ExplorerError("Worker event exceeded its limit.") }
        }
        child.waitUntilExit()
        lock.lock(); let wasStopped = stopped; lock.unlock()
        if wasStopped { throw ExplorerError("Analysis stopped or reached its time limit. Completed passes are retained.") }
        guard let result else { throw ExplorerError("Analysis helper exited without a result (exit \(child.terminationStatus)). Completed passes are retained.") }
        return LocalAnalysisReport(pass: pass, raw: result)
    }
}

@MainActor final class LocalAnalysisProgress: ObservableObject {
    @Published var fraction: Double = 0
    @Published var phase = ""
    @Published var name = ""
    @Published var running = false
}

@MainActor final class LocalAnalysisModel: ObservableObject {
    @Published private(set) var current: LocalMediaRun?
    @Published private(set) var activeID: UUID?
    let progress = LocalAnalysisProgress()
    @Published var dropError: String?
    private var task: Task<Void, Never>?
    private var worker: LocalAnalysisWorker?
    private var preparationBudget: WorkBudget?
    private let workspace = AnalysisWorkspace()
    private let executableOverride: URL?
    private var quitObservation: AnyCancellable?
    private var dropGeneration = UUID()
    init(executable: URL? = nil) {
        executableOverride = executable
        quitObservation = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }
    private func update(_ id: UUID, _ change: (inout LocalMediaRun) -> Void) {
        guard var run = current, run.id == id else { return }
        change(&run); current = run
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.prompt = "Analyze"
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.start(url) }
        }
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.count == 1, let provider = providers.first else {
            dropError = "Drop one file at a time. A new file stops the current analysis."; return false
        }
        let generation = UUID(); dropGeneration = generation
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, error in
            let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, dropGeneration == generation else { return }
                if let url { start(url) }
                else { dropError = message ?? "The dropped item did not provide a local file URL." }
            }
        }
        return true
    }
    func cancel() {
        task?.cancel(); preparationBudget?.cancel(); worker?.cancel()
        if let id = activeID { update(id) { $0.state = .cancelled } }
        activeID = nil; progress.running = false; progress.phase = "Stopped"
    }
    func shutdown() { cancel(); workspace.clear() }
    func retry() { if let url = current?.url { start(url) } else { choose() } }
    func start(_ source: URL) {
        dropGeneration = UUID()
        let previous = task
        cancel()
        let id = UUID()
        current = LocalMediaRun(id: id, name: source.lastPathComponent)
        activeID = id; progress.fraction = 0; progress.phase = "Preparing media"; progress.name = source.lastPathComponent; progress.running = true; dropError = nil
        let workspace = workspace, budget = WorkBudget(seconds: 30)
        preparationBudget = budget
        task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else {
                workspace.prune(except: nil)
                return
            }
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        do {
                            let result = try workspace.prepare(source, id: id, budget: budget)
                            workspace.prune(except: id)
                            return result
                        } catch {
                            workspace.prune(except: nil)
                            throw error
                        }
                    }.value
                } onCancel: { budget.cancel() }
                try Task.checkCancellation()
                update(id) { $0.url = prepared.0; $0.preview = prepared.1; $0.previewError = prepared.2; $0.video = prepared.3; $0.state = .running }
                let passes = LocalAnalysisPass.passes(video: prepared.3)
                let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MediaAnalysisWorker")
                let adjacent = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("MediaAnalysisWorker")
                let executable = executableOverride ?? (FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : adjacent)
                guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ExplorerError("The media analysis helper is missing. Rebuild using build-app.sh.") }
                for (index, pass) in passes.enumerated() {
                    try Task.checkCancellation()
                    progress.phase = pass.title; progress.fraction = Double(index) / Double(passes.count)
                    let worker = LocalAnalysisWorker(); self.worker = worker
                    let observer = self
                    let report = try await withTaskCancellationHandler {
                        try await Task.detached(priority: .userInitiated) { [observer] in
                            try worker.run(executable: executable, input: prepared.0, pass: pass) { value in
                                Task { @MainActor [weak observer] in
                                    guard let observer, observer.activeID == id, observer.progress.phase == pass.title else { return }
                                    observer.progress.fraction = max(observer.progress.fraction, (Double(index) + min(value, 0.99)) / Double(passes.count))
                                }
                            }
                        }.value
                    } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard activeID == id, let current else { return }
                    let reports = current.reports + [report]
                    let presentation = await Task.detached(priority: .userInitiated) {
                        LocalAnalysisPresentation(reports: reports)
                    }.value
                    try Task.checkCancellation()
                    update(id) { $0.reports = reports; $0.presentation = presentation }
                    // Incompatible interfaces/input rejection cannot become
                    // useful by repeatedly starting another pass.
                    if report.raw["unavailableReason"].text != nil { break }
                }
                guard activeID == id else { return }
                update(id) { run in run.state = run.reports.allSatisfy(\.succeeded) ? .complete : .partial }
                progress.fraction = 1; progress.phase = "Complete"; progress.running = false; activeID = nil; worker = nil
            } catch {
                guard activeID == id else { return }
                update(id) { $0.state = .failed; $0.error = error.localizedDescription }
                progress.phase = "Unavailable"; progress.running = false; activeID = nil; worker = nil
            }
        }
    }
}
