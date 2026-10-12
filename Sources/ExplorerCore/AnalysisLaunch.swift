import Foundation

/// The separate-job configuration verified in research-notes/launch-agent-trigger.
/// The daemon discovers its enrolled libraries; this does not enroll arbitrary folders.
public struct AnalysisLaunchPlan: Codable, Sendable {
    public static let labelPrefix = "local.mediaanalysisd.explorer.analysis."
    public static let taskIdentifier = "com.apple.mediaanalysisd.photos.full"
    public let label: String
    public let directory: URL
    public let deadline: Date
    public let userID: UInt32
    public var domain: String { "gui/\(userID)" }
    public var service: String { domain + "/" + label }
    public var candidate: URL { directory.appendingPathComponent(label + ".plist") }

    public init(directory: URL, userID: UInt32, seconds: TimeInterval = 3600, now: Date = Date()) {
        self.directory = directory.standardizedFileURL
        self.userID = userID
        label = Self.labelPrefix + UUID().uuidString.lowercased()
        deadline = now.addingTimeInterval(min(3600, max(15, seconds)))
    }

    public func candidateData(original: Data) throws -> Data {
        guard var plist = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
              plist["Label"] as? String == "com.apple.mediaanalysisd",
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.first == "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd" else {
            throw ExplorerError("The installed mediaanalysisd launch definition is unsupported.")
        }
        // Keep the installed executable and OS-specific settings, without owning Apple's endpoints.
        plist.removeValue(forKey: "MachServices")
        plist["Label"] = label
        plist["RunAtLoad"] = true
        plist["KeepAlive"] = false
        plist["ProcessType"] = "Standard"
        plist["EnableTransactions"] = false
        plist["EnablePressuredExit"] = false
        plist["ExitTimeOut"] = 5
        plist["StandardOutPath"] = directory.appendingPathComponent("agent.stdout").path
        plist["StandardErrorPath"] = directory.appendingPathComponent("agent.stderr").path
        plist["LaunchEvents"] = ["com.apple.bg.system.task": [Self.taskIdentifier: [
            "NonRepeatingTask": ["ScheduleAfter": 0, "TrySchedulingBefore": 60],
            "RequiresUserInactivity": false, "RequiresExternalPower": false,
            "RequiresBuddyComplete": true, "RequiresNetworkConnectivity": false,
            "GroupName": label, "GroupConcurrencyLimit": 1, "Priority": "Utility",
            "ResourceIntensive": true, "Resources": 5, "ExpectedDuration": 3600,
            "RequiresProtectionClass": "C", "PowerNap": true, "PrimaryDomain": "Media"
        ]]]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public func ownsRegistration(_ output: String) -> Bool {
        label.hasPrefix(Self.labelPrefix) && output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "path = " + candidate.path
        }
    }
}

public struct AnalysisLaunchStatus: Codable, Sendable {
    public var phase: String = "Preparing"
    public var message: String = "Preparing library analysis…"
    public var daemonPIDs: [Int] = []
    public var processingObserved = false
    public var completedSuccessfully = false
    public var finished = false
    public var cleaned = false
    public var monitoringIssue: String?
    public init() {}
}

/// Accept only the launched daemon's events. Registration alone is never completion.
public struct AnalysisLaunchEvidence: Sendable {
    private var running: [Int: Set<String>] = [:]
    private var completed: [Int: Set<String>] = [:]
    private var succeeded: Set<Int> = []
    private var markedComplete: Set<Int> = []
    public private(set) var processingObserved = false
    public private(set) var completionObserved = false
    public var completedSuccessfully: Bool {
        markedComplete.contains { pid in
            succeeded.contains(pid) && !(running[pid, default: []].intersection(completed[pid, default: []])).isEmpty
        }
    }
    public init() {}
    public mutating func consume(line: Data, daemonPIDs: [Int]) {
        guard line.count <= 256 * 1024,
              let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let pid = event["processID"] as? Int, daemonPIDs.contains(pid),
              let message = event["eventMessage"] as? String else { return }
        if message.contains("Running task VCPLibraryProcessingTask"), let task = taskNumber(message) {
            running[pid, default: []].insert(task); processingObserved = true
        }
        if message.contains("[Scheduler] Completed"), let task = taskNumber(message) {
            completed[pid, default: []].insert(task)
        }
        if message.contains("Task is completed (0)") { succeeded.insert(pid) }
        if message == "Marking task <BGNonRepeatingSystemTask: \(AnalysisLaunchPlan.taskIdentifier)> complete" {
            markedComplete.insert(pid); completionObserved = true
        }
    }
    private func taskNumber(_ message: String) -> String? {
        guard let start = message.lastIndex(of: "("), let end = message[start...].firstIndex(of: ")") else { return nil }
        let value = String(message[message.index(after: start)..<end])
        return !value.isEmpty && value.allSatisfy(\.isNumber) ? value : nil
    }
}
