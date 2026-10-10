import SwiftUI
import AppKit

@main struct MediaAnalysisExplorerApp: App {
    @NSApplicationDelegateAdaptor(ExplorerAppDelegate.self) private var appDelegate
    @StateObject private var model = ExplorerModel()
    var body: some Scene {
        WindowGroup("MediaAnalysis Explorer") {
            ExplorerView(model: model).frame(minWidth: 1050, minHeight: 700)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    model.startIfNeeded()
                }
        }
        .defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
