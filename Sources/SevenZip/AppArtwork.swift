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

    /// Reuse the document artwork advertised to Finder, including its format label.
    private static let archiveIcons: [String: NSImage] = {
        var icons: [String: NSImage] = [:]
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        for type in types {
            guard let name = type["CFBundleTypeIconFile"] as? String,
                  let extensions = type["CFBundleTypeExtensions"] as? [String],
                  let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "icns"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = false
            for ext in extensions { icons[ext.lowercased()] = image }
        }
        return icons
    }()

    static func archiveIcon(for filename: String) -> NSImage? {
        archiveIcons[(filename as NSString).pathExtension.lowercased()]
    }
}
