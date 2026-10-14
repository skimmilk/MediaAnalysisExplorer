import AppKit
import Photos
import PhotosUI
import SwiftUI

/// Retains the system controller while the analysis viewer is open, preserving
/// its browsing position. Only public picker APIs are used; media is not imported.
@MainActor final class PhotoLibraryBrowser: NSObject, ObservableObject, PHPickerViewControllerDelegate {
    var onSelection: ((String?) -> Void)?
    private(set) lazy var picker: PHPickerViewController = {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.selection = .continuous
        configuration.disabledCapabilities = [.selectionActions]
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        return picker
    }()

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let result = results.first else { return }
        // Deselect so the same asset can be opened again after navigating back.
        if let identifier = result.assetIdentifier { picker.deselectAssets(withIdentifiers: [identifier]) }
        onSelection?(result.assetIdentifier)
    }
}

struct PhotoLibraryPicker: NSViewControllerRepresentable {
    let browser: PhotoLibraryBrowser
    let onSelection: (String?) -> Void

    func makeNSViewController(context: Context) -> PHPickerViewController {
        browser.onSelection = onSelection
        return browser.picker
    }
    func updateNSViewController(_ controller: PHPickerViewController, context: Context) {
        browser.onSelection = onSelection
    }
}
