import AppKit
import UniformTypeIdentifiers

@MainActor
enum AppArtwork {
    /// Load the declared resource directly so Home and the running Dock icon
    /// always use the same artwork as the current application bundle.
    static let applicationIcon: NSImage = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        let baseName = (name as NSString).deletingPathExtension
        if let url = Bundle.main.url(forResource: baseName, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }()

    /// Finder's actual folder artwork, including the system's blue gradient.
    static let folderIcon: NSImage = {
        let image = NSWorkspace.shared.icon(for: .folder).copy() as! NSImage
        image.isTemplate = false
        return image
    }()
}
