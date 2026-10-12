import Foundation
import Darwin
import ExplorerCore

// An app-bundled supervisor, with a separately armed cleanup process. No Python,
// checkout paths, permanent LaunchAgents, or private client entitlements are needed.
private struct CommandResult {
    let code: Int32
    let output: String
    var absent: Bool { code != 0 && output.contains("Could not find service") }
}

private func save<T: Encodable>(_ value: T, at url: URL) throws {
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
}

private func command(_ arguments: [String], in directory: URL) throws -> CommandResult {
    let output = directory.appendingPathComponent("command-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw ExplorerError("Cannot save launchctl response.")
    }
    defer { try? FileManager.default.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = handle; process.standardError = handle
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    try process.run()
    let deadline = Date().addingTimeInterval(8)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        throw ExplorerError("launchctl timed out.")
    }
    let reader = try FileHandle(forReadingFrom: output)
    defer { try? reader.close() }
    return CommandResult(code: process.terminationStatus, output: String(decoding: try reader.read(upToCount: 1024 * 1024) ?? Data(), as: UTF8.self))
}

private func cleanup(_ plan: AnalysisLaunchPlan) -> CommandResult {
    guard plan.label.hasPrefix(AnalysisLaunchPlan.labelPrefix) else {
        return CommandResult(code: 1, output: "Unexpected job label; cleanup refused.")
    }
    do {
        for _ in 0..<3 {
            let current = try command(["print", plan.service], in: plan.directory)
            if current.absent { return CommandResult(code: 0, output: "Temporary launch job is absent.") }
            guard current.code == 0, plan.ownsRegistration(current.output) else {
                return CommandResult(code: 1, output: "Could not verify ownership of the launch job; it was left untouched.")
            }
            _ = try command(["bootout", plan.service], in: plan.directory)
            let after = try command(["print", plan.service], in: plan.directory)
            if after.absent { return CommandResult(code: 0, output: "Temporary launch job removed.") }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return CommandResult(code: 1, output: "Temporary launch job could not be removed.")
    } catch { return CommandResult(code: 1, output: error.localizedDescription) }
}

private struct CleanupResult: Codable { let cleaned: Bool; let message: String }

private func guardJob(_ plan: AnalysisLaunchPlan) throws {
    // Ignore hangup so cleanup survives the GUI app or supervisor exiting.
    signal(SIGHUP, SIG_IGN)
    try Data().write(to: plan.directory.appendingPathComponent("guard-armed"), options: .atomic)
    let request = plan.directory.appendingPathComponent("stop")
    let ready = plan.directory.appendingPathComponent("cleanup-ready")
    let supervisorPID = getppid()
    let deadline = plan.deadline.addingTimeInterval(20)
    while Date() < deadline {
        // A stop during bootstrap must not let cleanup finish before registration.
        let supervisorGone = kill(supervisorPID, 0) != 0 && errno == ESRCH
        if supervisorGone || (FileManager.default.fileExists(atPath: request.path) && FileManager.default.fileExists(atPath: ready.path)) { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let result = cleanup(plan)
    try save(CleanupResult(cleaned: result.code == 0, message: result.output), at: plan.directory.appendingPathComponent("cleanup.json"))
}

private func child(_ executable: URL, arguments: [String], output: URL) throws -> (Process, FileHandle) {
    guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw ExplorerError("Cannot create helper output.")
    }
    let handle = try FileHandle(forWritingTo: output)
    let process = Process(); process.executableURL = executable; process.arguments = arguments
    process.standardOutput = handle; process.standardError = handle
    do { try process.run() } catch { try? handle.close(); throw error }
    return (process, handle)
}

private func stop(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(1)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
}

private func supervise(_ directory: URL, seconds: TimeInterval) throws {
    let plan = AnalysisLaunchPlan(directory: directory, userID: getuid(), seconds: seconds)
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let config = directory.appendingPathComponent("plan.json")
    guard !manager.fileExists(atPath: config.path) else { throw ExplorerError("Use a new launch session directory.") }
    try save(plan, at: config)
    try plan.candidateData(original: Data(contentsOf: URL(fileURLWithPath: "/System/Library/LaunchAgents/com.apple.mediaanalysisd.plist")))
        .write(to: plan.candidate, options: .atomic)
    var status = AnalysisLaunchStatus()
    let statusURL = directory.appendingPathComponent("status.json")
    try save(status, at: statusURL)
    var guardProcess: Process?
    var logProcess: Process?
    var awakeProcess: Process?
    var handles: [FileHandle] = []
    var evidence = AnalysisLaunchEvidence()
    var logOffset: UInt64 = 0
    var pending = Data()
    let logURL = directory.appendingPathComponent("events.ndjson")
    var discardedLine = false
    var completionSeenAt: Date?
    func readEvents() throws {
        guard manager.fileExists(atPath: logURL.path) else { return }
        let reader = try FileHandle(forReadingFrom: logURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: logOffset)
        // Bound each read and retained evidence; stop log collection at 32 MiB.
        let bytes = try reader.read(upToCount: 1024 * 1024) ?? Data()
        logOffset += UInt64(bytes.count)
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if !discardedLine { evidence.consume(line: line, daemonPIDs: status.daemonPIDs) }
            discardedLine = false
        }
        if pending.count > 256 * 1024 { pending.removeAll(); discardedLine = true }
        if logOffset >= 32 * 1024 * 1024 {
            stop(logProcess)
            status.monitoringIssue = "The log observation limit was reached; completion may be unavailable."
        }
    }
    do {
        let supervisor = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let guardChild = try child(supervisor, arguments: ["--guard", config.path], output: directory.appendingPathComponent("guard.log"))
        guardProcess = guardChild.0; handles.append(guardChild.1)
        let armed = directory.appendingPathComponent("guard-armed")
        let armDeadline = Date().addingTimeInterval(5)
        while !manager.fileExists(atPath: armed.path), guardChild.0.isRunning, Date() < armDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard manager.fileExists(atPath: armed.path), guardChild.0.isRunning else {
            throw ExplorerError("The independent cleanup helper could not be armed.")
        }
        guard !manager.fileExists(atPath: directory.appendingPathComponent("stop").path) else {
            throw ExplorerError("The launch was stopped before registration.")
        }
        // log's own timeout prevents an orphaned stream if this supervisor crashes.
        do {
            let stream = try child(URL(fileURLWithPath: "/usr/bin/log"), arguments: ["stream", "--style", "ndjson", "--level", "info",
                "--timeout", "\(Int(seconds + 20))s", "--predicate", "process == \"mediaanalysisd\""], output: logURL)
            logProcess = stream.0; handles.append(stream.1)
        } catch { status.monitoringIssue = "Daemon logs unavailable: " + error.localizedDescription }
        // Keep the system awake only for this supervisor's lifetime (and at most the deadline).
        if let awake = try? child(URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-i", "-w", "\(getpid())", "-t", "\(Int(seconds + 20))"], output: directory.appendingPathComponent("awake.log")) {
            awakeProcess = awake.0; handles.append(awake.1)
        }
        let bootstrap = try command(["bootstrap", plan.domain, plan.candidate.path], in: directory)
        try Data(bootstrap.output.utf8).write(to: directory.appendingPathComponent("bootstrap.txt"))
        guard bootstrap.code == 0 else { throw ExplorerError("mediaanalysisd could not be launched (\(bootstrap.code)): \(bootstrap.output)") }
        status.phase = "Requested"
        status.message = "Launch accepted. Waiting for library analysis…"
        try save(status, at: statusURL)
        while Date() < plan.deadline && !manager.fileExists(atPath: directory.appendingPathComponent("stop").path) {
            guard guardChild.0.isRunning else { throw ExplorerError("The cleanup helper exited; the launch session was stopped.") }
            let job = try command(["print", plan.service], in: directory)
            if job.code == 0 {
                guard plan.ownsRegistration(job.output) else { throw ExplorerError("The launch job no longer matches this session.") }
                for line in job.output.split(separator: "\n") {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("pid = "), let pid = Int(text.dropFirst(6)), !status.daemonPIDs.contains(pid) {
                        status.daemonPIDs.append(pid)
                    }
                }
                try Data(job.output.utf8).write(to: directory.appendingPathComponent("last-job.txt"), options: .atomic)
            } else if !job.absent { throw ExplorerError("Launch status unavailable: " + job.output) }
            try readEvents()
            status.processingObserved = evidence.processingObserved
            status.completedSuccessfully = evidence.completedSuccessfully
            if let logProcess, !logProcess.isRunning, status.monitoringIssue == nil {
                status.monitoringIssue = "Daemon log observation ended; completion may be unavailable."
            }
            if evidence.completionObserved && completionSeenAt == nil { completionSeenAt = Date() }
            // The scheduler's per-task completion record can follow the marking event.
            if evidence.completedSuccessfully || completionSeenAt.map({ Date().timeIntervalSince($0) >= 3 }) == true {
                status.phase = status.completedSuccessfully ? "Completed" : "Task ended"
                status.message = status.completedSuccessfully ? "Library analysis task completed successfully." : "The library task ended; successful processing was not verified."
                break
            }
            if job.absent {
                status.phase = "Ended"
                status.message = "The daemon's launch job ended; processing completion was not verified."
                break
            }
            status.phase = evidence.processingObserved ? "Processing" : status.daemonPIDs.isEmpty ? "Requested" : "Running"
            status.message = evidence.processingObserved ? "The daemon is processing eligible library media…" : status.daemonPIDs.isEmpty ? "Launch accepted. Waiting for the daemon…" : "mediaanalysisd is running. Waiting for eligible library work…"
            try save(status, at: statusURL)
            Thread.sleep(forTimeInterval: 1)
        }
        if !evidence.completionObserved && !["Ended", "Task ended"].contains(status.phase) {
            let cancelled = manager.fileExists(atPath: directory.appendingPathComponent("stop").path)
            status.phase = cancelled ? "Stopped" : "Time limit"
            status.message = cancelled ? "Library analysis launch stopped." : "The observation time limit was reached; processing completion was not verified."
        }
    } catch {
        status.phase = "Failed"; status.message = error.localizedDescription
    }
    // Ask the independent guard to remove only the job with our exact label/path.
    try? Data().write(to: directory.appendingPathComponent("cleanup-ready"), options: .atomic)
    try? Data().write(to: directory.appendingPathComponent("stop"), options: .atomic)
    status.finished = false
    let terminalPhase = status.phase
    status.phase = "Cleaning up"
    try? save(status, at: statusURL)
    let cleanupURL = directory.appendingPathComponent("cleanup.json")
    let cleanupDeadline = Date().addingTimeInterval(35)
    while guardProcess?.isRunning == true, !manager.fileExists(atPath: cleanupURL.path), Date() < cleanupDeadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    let cleanupResult: CleanupResult
    if let bytes = try? Data(contentsOf: cleanupURL), let result = try? JSONDecoder().decode(CleanupResult.self, from: bytes) {
        cleanupResult = result
    } else {
        let result = cleanup(plan)
        cleanupResult = CleanupResult(cleaned: result.code == 0, message: result.output)
        try? save(cleanupResult, at: cleanupURL)
    }
    stop(logProcess); stop(awakeProcess)
    for handle in handles { try? handle.close() }
    status.cleaned = cleanupResult.cleaned
    status.finished = true
    status.phase = cleanupResult.cleaned ? terminalPhase : "Cleanup failed"
    if !cleanupResult.cleaned { status.message += " " + cleanupResult.message }
    try save(status, at: statusURL)
}

let arguments = CommandLine.arguments
do {
    if arguments.count == 3, arguments[1] == "--guard" {
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let plan = try JSONDecoder().decode(AnalysisLaunchPlan.self, from: data)
        guard plan.userID == getuid(), plan.label.hasPrefix(AnalysisLaunchPlan.labelPrefix) else { throw ExplorerError("Invalid cleanup plan.") }
        try guardJob(plan)
    } else if (arguments.count == 3 || arguments.count == 5), arguments[1] == "--run" {
        let seconds = arguments.count == 5 && arguments[3] == "--seconds" ? Double(arguments[4]) ?? 3600 : 3600
        guard seconds.isFinite, (15...3600).contains(seconds) else { throw ExplorerError("Invalid observation duration.") }
        try supervise(URL(fileURLWithPath: arguments[2]).standardizedFileURL, seconds: seconds)
    } else { throw ExplorerError("Usage: MediaAnalysisLauncher --run <new-session-directory> [--seconds 15…3600]") }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
