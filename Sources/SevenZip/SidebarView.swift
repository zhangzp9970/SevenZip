import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var localization = Localization.shared
    @ViewState private var locations = SidebarView.availableLocations()

    private enum Destination: Hashable {
        case home
        case folder(URL)
        case archive(URL)
    }

    private struct Location {
        let title: String
        let symbol: String
        let url: URL
        var titleIsLocalized = false
        var systemIcon: NSImage? = nil

        var displayTitle: String { titleIsLocalized ? title : L10n.tr(title) }
    }

    // Use Finder's sidebar artwork when it is supplied by this macOS version.
    // These optional resources aren't bundled; SF Symbols remain the fallback.
    private static func sidebarIcon(_ name: String) -> NSImage? {
        let image = NSImage(contentsOfFile:
            "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns")
        image?.isTemplate = true
        return image
    }
    private static let applicationsIcon = sidebarIcon("SidebarApplicationsFolder")
    private static let musicIcon = sidebarIcon("SidebarMusicFolder")

    private var favorites: [Location] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        func userDirectory(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
            manager.urls(for: directory, in: .userDomainMask).first
                ?? home.appendingPathComponent(fallback, isDirectory: true)
        }
        return [
            Location(title: "应用程序", symbol: "square.stack.3d.up", url:
                manager.urls(for: .applicationDirectory, in: .localDomainMask).first
                    ?? URL(fileURLWithPath: "/Applications", isDirectory: true), systemIcon: Self.applicationsIcon),
            Location(title: "桌面", symbol: "menubar.dock.rectangle", url: userDirectory(.desktopDirectory, fallback: "Desktop")),
            Location(title: "文稿", symbol: "doc", url: userDirectory(.documentDirectory, fallback: "Documents")),
            Location(title: "下载", symbol: "arrow.down.circle", url: userDirectory(.downloadsDirectory, fallback: "Downloads")),
            Location(title: "图片", symbol: "photo", url: userDirectory(.picturesDirectory, fallback: "Pictures")),
            Location(title: "音乐", symbol: "music.note", url: userDirectory(.musicDirectory, fallback: "Music"), systemIcon: Self.musicIcon),
            Location(title: "影片", symbol: "film", url: userDirectory(.moviesDirectory, fallback: "Movies"))
        ]
    }

    private static func availableLocations() -> [Location] {
        let manager = FileManager.default
        var result: [Location] = []
        let cloud = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: cloud.path, isDirectory: &isDirectory), isDirectory.boolValue {
            result.append(Location(title: "iCloud 云盘", symbol: "icloud", url: cloud))
        }

        let home = manager.homeDirectoryForCurrentUser
        result.append(Location(title: home.lastPathComponent, symbol: "house", url: home, titleIsLocalized: true))

        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let rootName = (try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? manager.displayName(atPath: root.path)
        result.append(Location(title: rootName, symbol: "internaldrive", url: root, titleIsLocalized: true))

        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsBrowsableKey,
                                       .volumeIsInternalKey, .volumeIsLocalKey]
        let mounted = manager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                               options: [.skipHiddenVolumes]) ?? []
        var seen = Set(result.map { canonicalPath($0.url) })
        let volumes = mounted.compactMap { url -> Location? in
            let path = canonicalPath(url)
            // The root entry already represents the system's combined APFS volume.
            guard !path.hasPrefix("/System/Volumes/"), seen.insert(path).inserted,
                  let values = try? url.resourceValues(forKeys: keys), values.volumeIsBrowsable != false else { return nil }
            let symbol = values.volumeIsLocal == false ? "network"
                : values.volumeIsInternal == true ? "internaldrive" : "externaldrive"
            let name = values.volumeLocalizedName ?? manager.displayName(atPath: url.path)
            return Location(title: name, symbol: symbol, url: url, titleIsLocalized: true)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        result.append(contentsOf: volumes)
        return result
    }

    var body: some View {
        List(selection: navigationSelection) {
            Label(L10n.tr("开始"), systemImage: "house")
                .tag(Destination.home)

            Section(L10n.tr("个人收藏")) {
                ForEach(favorites, id: \.url) { location in
                    locationRow(location)
                }
            }

            Section(L10n.tr("位置")) {
                ForEach(locations, id: \.url) { location in
                    locationRow(location, mutedIcon: true)
                }
            }

            if !model.recentURLs.isEmpty {
                Section(L10n.tr("最近打开")) {
                    ForEach(Array(model.recentURLs.prefix(5)), id: \.path) { url in
                        Label {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        } icon: {
                            Image(systemName: "doc.zipper")
                        }
                        .tag(Destination.archive(url))
                        .help(url.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .font(.system(size: 13))
        .environment(\.locale, localization.locale)
        .disabled(model.isBusy)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            locations = Self.availableLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            locations = Self.availableLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            locations = Self.availableLocations()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            locations = Self.availableLocations()
        }
    }

    private func locationRow(_ location: Location, mutedIcon: Bool = false) -> some View {
        let isSelected = navigationSelection.wrappedValue == .folder(location.url)
        return Label {
            Text(location.displayTitle).lineLimit(1).truncationMode(.middle)
        } icon: {
            Group {
                if let image = location.systemIcon {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
                } else {
                    Image(systemName: location.symbol)
                }
            }
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor)
                : mutedIcon ? Color(nsColor: .secondaryLabelColor) : Color.accentColor)
        }
        .tag(Destination.folder(location.url))
        .help(location.url.path)
    }

    private var navigationSelection: Binding<Destination?> {
        Binding {
            if model.isHome { return .home }
            if let archive = model.archiveURL {
                return model.recentURLs.prefix(5).first { Self.canonicalPath($0) == Self.canonicalPath(archive) }
                    .map(Destination.archive)
            }
            guard let folder = model.folderURL else { return nil }
            let folderPath = Self.canonicalPath(folder)
            // Match the closest destination; iCloud and mounted disks take precedence over Home/root.
            return (favorites + locations).map { ($0, Self.canonicalPath($0.url)) }
                .sorted { $0.1.count > $1.1.count }
                .first {
                    let path = $0.1
                    return folderPath == path || folderPath.hasPrefix(path == "/" ? "/" : path + "/")
                }
                .map { .folder($0.0.url) }
        } set: { destination in
            guard !model.isBusy, let destination else { return }
            switch destination {
            case .home: model.home()
            case .folder(let url): model.browse(url)
            case .archive(let url): model.openArchive(url)
            }
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
