import SwiftUI
import AppKit

@MainActor
final class VolumeStore: ObservableObject {
    @Published var volume: Volume?
    @Published var status: String = "Open a DICOM folder to begin (⌘O)"
    @Published var loading = false

    // Display state
    @Published var windowCenter: Float = 0.55
    @Published var windowWidth: Float = 0.7
    @Published var renderMode: RenderMode = .mip

    // Clipping plane
    @Published var clipEnabled = false
    @Published var clipAxis: Int = 2          // 0=X 1=Y 2=Z
    @Published var clipPosition: Float = 0.5  // 0..1 along axis
    @Published var clipFlip = false

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a DICOM series folder"
        panel.message = "Select the folder that contains the .dcm slices (the IMGDATA/<date>/<series> folder on a CBCT disk works directly)."
        if panel.runModal() == .OK, let url = panel.urls.first {
            loadFolder(url)
        }
    }

    func loadFolder(_ url: URL) {
        loading = true
        status = "Scanning \(url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            do {
                let v = try DICOMSeriesLoader.load(folder: url) { msg in
                    Task { @MainActor in self.status = msg }
                }
                await MainActor.run {
                    self.volume = v
                    self.loading = false
                    self.status = "Loaded \(v.depth) slices • \(v.width)×\(v.height) • \(String(format: "%.2f", v.spacing.x))×\(String(format: "%.2f", v.spacing.y))×\(String(format: "%.2f", v.spacing.z)) mm"
                }
            } catch {
                await MainActor.run {
                    self.loading = false
                    self.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

enum RenderMode: Int, Hashable {
    case mip = 0
    case composite = 1
}
