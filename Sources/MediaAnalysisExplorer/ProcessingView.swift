import SwiftUI
import Charts
import ExplorerCore

private enum HistoryMetric: String, CaseIterable, Identifiable {
    case assets = "Photo items", reported = "Reported analyses", sessions = "Sessions", changes = "Result changes"
    var id: String { rawValue }
    var key: KeyPath<ProcessingBucket, Int?> {
        switch self { case .assets: \.assets; case .reported: \.reported; case .sessions: \.sessions; case .changes: \.changes }
    }
}

struct ProcessingView: View {
    @ObservedObject var model: ExplorerModel
    @ObservedObject private var launcher: AnalysisLauncher
    @State private var metric: HistoryMetric = .assets
    @State private var selectedDate: Date?
    private var history: ProcessingHistory? { model.processingHistory }
    init(model: ExplorerModel) {
        self.model = model
        launcher = model.analysisLauncher
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    AnalysisLaunchControls(launcher: model.analysisLauncher)
                    if model.processingRange == .custom {
                        HStack {
                            DatePicker("From", selection: $model.processingStart, in: ...Date(), displayedComponents: .date)
                            DatePicker("Through", selection: $model.processingEnd, in: ...Date(), displayedComponents: .date)
                            Spacer()
                        }.datePickerStyle(.field).controlSize(.small).frame(maxWidth: 520)
                    }
                    if let failure = model.processingHistoryFailure {
                        HStack { Label("History could not be updated", systemImage: "exclamationmark.triangle"); InfoButton(title: "History read error", text: failure) }.font(.caption).foregroundStyle(.orange)
                    }
                    if let history {
                        summary(history)
                        if geometry.size.width >= 870 {
                            HStack(alignment: .top, spacing: 12) {
                                trend(history).frame(maxWidth: .infinity)
                                mix(history).frame(width: min(320, geometry.size.width * 0.3))
                            }
                            HStack(alignment: .top, spacing: 12) {
                                recent(history).frame(maxWidth: .infinity)
                                tasks(history).frame(width: min(320, geometry.size.width * 0.3))
                            }
                        } else {
                            trend(history); recent(history)
                            HStack(alignment: .top, spacing: 12) { mix(history); tasks(history) }
                        }
                        liveStatus
                        health(history)
                    } else if model.busy.contains("processingHistory") {
                        ProgressView("Reading processing history…").frame(maxWidth: .infinity, minHeight: 400)
                    } else {
                        ContentUnavailableView("Processing history unavailable", systemImage: "chart.bar.xaxis")
                        liveStatus
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: launcher.isRunning) {
            if model.dashboard == nil { model.refreshDashboard() }
            if model.processingHistory == nil && !model.busy.contains("processingHistory") { model.refreshProcessingHistory() }
            let active = launcher.isRunning
            let monitor = ProcessingChangeMonitor(databases: model.daemonDatabases)
            var ticks = 0
            while !Task.isCancelled {
                if active {
                    await model.pollProcessingChanges(monitor)
                    if ticks % 4 == 0 { model.refreshProcessingProcesses() }
                    if ticks > 0 && ticks % 60 == 0 { model.refreshDashboard() }
                }
                do { try await Task.sleep(for: .milliseconds(active ? 250 : 15_000)) } catch { break }
                guard !Task.isCancelled else { break }
                ticks += 1
                if !active {
                    model.refreshDashboard()
                    if ticks % 4 == 0 { model.refreshProcessingHistory() }
                }
            }
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Text("Processing").font(.title2.bold())
            InfoButton(title: "Processing history", text: "Recent media analysis, background sessions, and saved results.")
            Spacer()
            Picker("History range", selection: $model.processingRange) {
                ForEach(ProcessingRange.allCases) { range in Text(range.rawValue).tag(range) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 335)
            if model.busy.contains("processingHistory") { ProgressView().controlSize(.small) }
        }
    }
    private func summary(_ history: ProcessingHistory) -> some View {
        HStack(spacing: 10) {
            metricCard("Photo items", history.total(\.assets), detail: "Latest analysis date")
            metricCard("Reported analyses", history.total(\.reported), detail: history.reportingSessions.map { "\($0.formatted()) / \((history.total(\.sessions) ?? 0).formatted()) sessions report counts" } ?? "Counts unavailable")
            metricCard("Daemon sessions", history.total(\.sessions), detail: "Dated task sessions")
            metricCard("Result changes", history.total(\.changes), detail: "Retained Photos history")
        }
    }
    private func metricCard(_ title: String, _ value: Int?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary) }
            Text(value?.formatted() ?? "—").font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.subheadline.weight(.semibold)); Spacer() }
            content()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func trend(_ history: ProcessingHistory) -> some View {
        panel("Activity over time") {
            HStack {
                Picker("Metric", selection: $metric) { ForEach(HistoryMetric.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().controlSize(.small).frame(maxWidth: 190)
                Spacer()
                Text(history.granularity + " · " + dateRange(history)).font(.caption2).foregroundStyle(.secondary)
            }
            if history.total(metric.key) != nil {
                Chart {
                    ForEach(history.buckets) { bucket in
                        RectangleMark(xStart: .value("Start", bucket.start), xEnd: .value("End", bucket.end),
                                      yStart: .value("Baseline", 0), yEnd: .value(metric.rawValue, bucket[keyPath: metric.key] ?? 0))
                            .foregroundStyle(Color.teal.gradient).opacity(selectedBucket(history)?.id == bucket.id ? 1 : 0.8)
                    }
                    if let selected = selectedBucket(history) { RuleMark(x: .value("Selected", selected.start)).foregroundStyle(.orange) }
                }.chartXScale(domain: history.start...history.end)
                    .chartYScale(domain: 0...max(1, history.buckets.compactMap { $0[keyPath: metric.key] }.max() ?? 1))
                    .chartYAxis { AxisMarks(position: .leading) }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .frame(height: 132)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let point): if let frame = proxy.plotFrame { selectedDate = proxy.value(atX: point.x - geometry[frame].minX) }
                                    case .ended: selectedDate = nil
                                    }
                                }
                                .onTapGesture { point in
                                    if let frame = proxy.plotFrame {
                                        selectedDate = proxy.value(atX: point.x - geometry[frame].minX)
                                        if let bucket = selectedBucket(history) { model.focusProcessingPeriod(start: bucket.start, end: bucket.end); selectedDate = nil }
                                    }
                                }
                        }
                    }
            } else { ContentUnavailableView("This metric is unavailable", systemImage: "chart.bar").frame(height: 132) }
            HStack {
                if let selected = selectedBucket(history) {
                    Text(selected.start.formatted(date: .abbreviated, time: .omitted))
                    Spacer(); Text((selected[keyPath: metric.key]?.formatted() ?? "—") + " " + metric.rawValue.lowercased()).monospacedDigit()
                } else {
                    Text("\(history.buckets.count) \(history.granularity.lowercased()) periods")
                    Spacer(); Text(history.total(metric.key).map { "\($0.formatted()) total" } ?? "Unavailable")
                }
            }.font(.caption2).foregroundStyle(.secondary).frame(height: 16)
        }
    }
    private func selectedBucket(_ history: ProcessingHistory) -> ProcessingBucket? {
        guard let selectedDate else { return nil }; return history.buckets.first { selectedDate >= $0.start && selectedDate < $0.end }
    }
    private func dateRange(_ history: ProcessingHistory) -> String {
        history.start.formatted(.dateTime.month(.abbreviated).day()) + "–" + history.end.addingTimeInterval(-1).formatted(.dateTime.month(.abbreviated).day().year())
    }
    private func mix(_ history: ProcessingHistory) -> some View {
        panel("Analysis mix") {
            if history.families.isEmpty {
                Text(history.total(\.changes) == nil ? "Result history unavailable" : "No result changes in this period").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 170)
            } else {
                Chart(Array(history.families.prefix(7))) { row in
                    BarMark(x: .value("Changes", Int(row["n"]) ?? 0), y: .value("Result", VisualMetadata.title("Z" + row["entity"].uppercased())))
                        .foregroundStyle(.indigo.gradient)
                }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }.frame(height: 170)
            }
            Text("\(history.families.count) result families").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func recent(_ history: ProcessingHistory) -> some View {
        panel("Recently analyzed items") {
            if history.recentAssets.isEmpty { Text(history.total(\.assets) == nil ? "Photo analysis dates unavailable" : "No dated photo items in this period").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 131) }
            else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(history.recentAssets) { asset in
                            RecentlyAnalyzedRow(asset: asset, arrivedAt: model.recentAnalysisArrivals[asset.identifier]) { model.openProcessedAsset(asset) }
                            Divider()
                        }
                    }
                }.frame(height: 131)
            }
        }
    }
    private func tasks(_ history: ProcessingHistory) -> some View {
        panel("Task activity") {
            if history.tasks.isEmpty { Text(history.total(\.sessions) == nil ? "Task history unavailable" : "No dated sessions in this period").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 131) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(history.tasks) { task in
                            HStack(alignment: .top) {
                                Text("Task \(task.task)").font(.caption.weight(.medium))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(task.sessions.formatted()) sessions").font(.caption.monospacedDigit())
                                    Text(task.reported.map { "\($0.formatted()) reported analyses" } ?? "Count unavailable").font(.caption2).foregroundStyle(.secondary)
                                    if task.nonzeroExits > 0 { Text("\(task.nonzeroExits) nonzero exits").font(.caption2).foregroundStyle(.orange) }
                                }
                            }
                            Divider()
                        }
                    }
                }.frame(height: 131)
            }
        }
    }
    private var liveStatus: some View {
        HStack(spacing: 10) {
            Label("Now", systemImage: "waveform.path.ecg").font(.caption.weight(.semibold))
            InfoButton(title: "Current daemon sample", text: "Current CPU usage and memory for the media analysis processes. CPU usage can exceed 100% when several cores are active.")
            if let dashboard = model.dashboard {
                if dashboard.processIssue != nil { Text("Process sample unavailable").font(.caption).foregroundStyle(.secondary) }
                else if dashboard.processes.isEmpty { Text("No related daemon running").font(.caption).foregroundStyle(.secondary) }
                ForEach(dashboard.processes) { process in
                    HStack(spacing: 4) {
                        Circle().fill(process.cpuPercent > 1 ? Color.green : Color.secondary).frame(width: 5, height: 5)
                        Text(process.name).font(.caption2)
                        Text(String(format: "%.1f%%", process.cpuPercent)).font(.caption2.monospacedDigit()).foregroundStyle(.teal)
                        Text(bytes(process.rssKiB * 1024)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }.help("PID \(process.pid) · running \(process.elapsed)")
                }
                Spacer()
                Text(dashboard.updated.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            } else { Text("Sample unavailable").font(.caption).foregroundStyle(.secondary); Spacer() }
        }.padding(10).background(.quaternary.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private func health(_ history: ProcessingHistory) -> some View {
        HStack(spacing: 10) {
            if let earliest = history.earliestRetained { Text("Retained dates from " + earliest.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary) }
            if let count = history.undatedAssets, count > 0 { Text("\(count.formatted()) undated photo items").font(.caption2).foregroundStyle(.secondary) }
            if let count = history.undatedSessions, count > 0 { Text("\(count.formatted()) undated sessions").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            if !history.issues.isEmpty {
                Label("Partial history", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                InfoButton(title: "History availability", text: history.issues.joined(separator: "\n\n"))
            }
            if let dashboard = model.dashboard {
                ForEach(dashboard.sources) { source in
                    Circle().fill(source.report == nil ? Color.orange : Color.teal).frame(width: 5, height: 5)
                        .help(source.database.name + ": " + (source.issue ?? "Readable") + "\n" + source.database.source.analysisPath)
                }
            }
        }
    }
}

private struct RecentlyAnalyzedRow: View {
    let asset: ProcessedAsset
    let arrivedAt: Date?
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlight = false
    @State private var justNow = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: asset.name.map { ["mp4", "mov", "m4v"].contains(($0 as NSString).pathExtension.lowercased()) } == true ? "film" : "photo").foregroundStyle(.teal)
                Text(asset.name ?? asset.identifier).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(justNow ? "Just Now" : asset.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption2.monospacedDigit()).foregroundStyle(justNow ? Color.teal : Color.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 6).padding(.horizontal, 6).contentShape(Rectangle())
                .background(Color.teal.opacity(highlight ? 0.22 : 0), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help(asset.identifier)
            .task(id: arrivedAt ?? asset.date) {
                let displaySince = arrivedAt ?? asset.date
                let age = Date().timeIntervalSince(displaySince)
                justNow = age >= 0 && age < 30
                highlight = arrivedAt != nil && age >= 0 && age < 1.5
                guard justNow else { return }
                do {
                    if highlight {
                        try await Task.sleep(for: .seconds(max(0, 1.5 - age)))
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 2.5)) { highlight = false }
                    }
                    try await Task.sleep(for: .seconds(max(0, 30 - Date().timeIntervalSince(displaySince))))
                    justNow = false
                } catch { /* A newer analysis or removal cancels this row's timer. */ }
            }
    }
}
