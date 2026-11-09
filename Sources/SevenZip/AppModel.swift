import AppKit
import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers

struct BrowserItem: Identifiable, BrowserSortableItem {
    let id: String
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    let modified: Date?
    let encrypted: Bool
    let url: URL?
    var type: String {
        if isDirectory { return L10n.tr("文件夹") }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? L10n.tr("文件") : L10n.format("%@ 文件", ext)
    }
    var symbol: String {
        if isDirectory { return "folder.fill" }
        if AppModel.archiveExtensions.contains((name as NSString).pathExtension.lowercased()) { return "doc.zipper" }
        return "doc"
    }
    var sizeText: String {
        guard !isDirectory, let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }
}

enum AppSheet: Identifiable {
    case compress([URL]), extract([URL], [String]?), password(URL)
    var id: String {
        switch self {
        case .compress: return "compress"
        case .extract: return "extract"
        case .password: return "password"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let archiveExtensions: Set<String> = ["7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "tbz", "lzma", "xz", "txz", "zst", "cab", "iso", "dmg", "wim", "arj", "lzh", "001"]
    @Published var folderURL: URL?
    @Published var archiveURL: URL?
    @Published var archivePath = ""
    @Published var archiveEntries: [ArchiveEntry] = []
    @Published var folderItems: [BrowserItem] = []
    @Published var selection = Set<String>()
    @Published var search = ""
    @Published var sortOrder = [BrowserSortComparator<BrowserItem>(.name)]
    @Published var recentURLs: [URL] = []
    @Published var sheet: AppSheet?
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var jobTitle = L10n.message("")
    @Published var jobProgress: Double?
    @Published var jobLog = ""
    @Published var status = L10n.message("准备就绪")
    @Published var revealURL: URL? { didSet { resultIsBackup = false } }
    @Published var resultIsBackup = false
    @Published var showLog = false
    private var archivePassword: String?
    private enum Location: Equatable {
        case home, folder(URL), archive(URL, String)
    }
    private var history = BrowserHistory<Location>(initial: .home)
    private var knownPasswords: [URL: String] = [:]
    private var passwordRequest: (archive: URL, action: (String) -> Void)?
    private var cancellation = ArchiveCancellation()
    private let engine: ArchiveEngine
    private let preferences: UserDefaults
    private let documentOpener: ((URL) async throws -> String)?

    init(engine: ArchiveEngine? = nil, preferences: UserDefaults = .standard,
         documentOpener: ((URL) async throws -> String)? = nil) {
        self.engine = engine ?? ArchiveEngine(libraryURL:
            Bundle.main.privateFrameworksURL!.appendingPathComponent("libSevenZip.dylib"))
        self.preferences = preferences
        self.documentOpener = documentOpener
        recentURLs = (preferences.stringArray(forKey: "recentArchives") ?? [])
            .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isHome: Bool { folderURL == nil && archiveURL == nil }
    var title: String {
        if archiveURL != nil, !archivePath.isEmpty { return String(archivePath.split(separator: "/").last ?? "") }
        if let archiveURL { return archiveURL.lastPathComponent }
        guard let folderURL else { return "SevenZip" }
        let path = folderURL.standardizedFileURL.path
        let cloudPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path
        if path == cloudPath { return L10n.tr("iCloud 云盘") }
        if path == "/", let name = (try? folderURL.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName {
            return name
        }
        return FileManager.default.displayName(atPath: path)
    }
    var navigationSubtitle: String {
        guard let archiveURL, !archivePath.isEmpty else { return "" }
        let parent = archivePath.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? archiveURL.lastPathComponent : archiveURL.lastPathComponent + " / " + parent
    }
    var canGoBack: Bool { !isBusy && history.backIndex != nil }
    var canGoForward: Bool { !isBusy && history.forwardIndex != nil }
    var canGoUp: Bool {
        !isBusy && (archiveURL != nil || folderURL.map { $0.standardizedFileURL.path != "/" } == true)
    }
    var canModifyArchive: Bool {
        guard !isBusy, let url = archiveURL, ["7z", "zip"].contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
            && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
    var canDeleteArchiveItems: Bool { canModifyArchive && !selectedItems.isEmpty }

    var selectedItems: [BrowserItem] { items.filter { selection.contains($0.id) } }
    var selectedFileURLs: [URL] { selectedItems.compactMap(\.url) }
    var items: [BrowserItem] {
        let result: [BrowserItem]
        if archiveURL != nil {
            let prefix = archivePath.isEmpty ? "" : archivePath + "/"
            var children: [String: BrowserItem] = [:]
            for entry in archiveEntries where entry.path.hasPrefix(prefix) {
                let tail = String(entry.path.dropFirst(prefix.count))
                let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
                guard let first = parts.first else { continue }
                let name = String(first)
                let id = prefix + name
                let directory = parts.count > 1 || entry.isDirectory
                if children[id] == nil || parts.count == 1 {
                    children[id] = BrowserItem(id: id, name: name, isDirectory: directory,
                        size: directory ? nil : entry.size, modified: entry.modified,
                        encrypted: entry.encrypted, url: nil)
                }
            }
            result = Array(children.values)
        } else { result = folderItems }
        let filtered = result.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return BrowserItemOrdering.sorted(filtered, using: sortOrder)
    }
    var totalSizeText: String {
        let size = archiveEntries.reduce(UInt64(0)) { sum, item in
            let (new, overflow) = sum.addingReportingOverflow(item.size ?? 0)
            return overflow ? UInt64.max : new
        }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }

    func home() { navigate(to: .home) }
    func browse(_ url: URL) { navigate(to: .folder(url.standardizedFileURL)) }
    func goBack() {
        guard canGoBack, let index = history.backIndex else { return }
        navigate(to: history.locations[index], restoring: index)
    }
    func goForward() {
        guard canGoForward, let index = history.forwardIndex else { return }
        navigate(to: history.locations[index], restoring: index)
    }
    private func navigate(to location: Location, restoring index: Int? = nil) {
        guard !isBusy else { return }
        switch location {
        case .home:
            folderURL = nil; archiveURL = nil; archivePath = ""; selection = []; search = ""; archiveEntries = []
            archivePassword = nil
            status = L10n.message("准备就绪")
        case .folder(let url):
            do {
                let children = try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])
                let loadedItems = children.map {
                    let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    return BrowserItem(id: $0.path, name: $0.lastPathComponent,
                        isDirectory: values?.isDirectory ?? false,
                        size: values?.fileSize.map { UInt64(max(0, $0)) },
                        modified: values?.contentModificationDate, encrypted: false, url: $0)
                }
                folderItems = loadedItems
                folderURL = url; archiveURL = nil; archivePath = ""; archiveEntries = []; selection = []; search = ""
                archivePassword = nil
                status = L10n.message("%d 个项目", folderItems.count)
            } catch { errorMessage = error.localizedDescription; return }
        case .archive(let url, let path):
            if archiveURL == url {
                guard archiveDirectoryExists(path) else { errorMessage = L10n.tr("归档中的此文件夹已不存在。"); return }
                archivePath = path; selection = []; search = ""
            } else {
                loadArchive(url, password: knownPasswords[url], path: path, restoring: index)
                return
            }
        }
        history.commit(location, restoring: index)
        objectWillChange.send()
    }
    private func archiveDirectoryExists(_ path: String) -> Bool {
        path.isEmpty || archiveEntries.contains { ($0.path == path && $0.isDirectory) || $0.path.hasPrefix(path + "/") }
    }
    func goUp() {
        guard canGoUp else { return }
        if let url = archiveURL {
            if archivePath.isEmpty { browse(url.deletingLastPathComponent()) }
            else { navigate(to: .archive(url, archivePath.split(separator: "/").dropLast().joined(separator: "/"))) }
        } else if let url = folderURL { browse(url.deletingLastPathComponent()) }
    }
    func activate(_ ids: Set<String>) {
        guard !isBusy, let item = items.first(where: { ids.contains($0.id) }) else { return }
        if let url = item.url {
            if item.isDirectory { browse(url) }
            else if Self.archiveExtensions.contains(url.pathExtension.lowercased()) { openArchive(url) }
            else { openDocument(url) }
        } else if let url = archiveURL {
            if item.isDirectory { navigate(to: .archive(url, item.id)) }
            else { previewArchiveDocument(item.id) }
        }
    }
    func chooseArchive() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("打开压缩包"); panel.prompt = L10n.tr("打开"); panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openArchive(url) }
    }
    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isBusy else { errorMessage = L10n.tr("当前任务还在进行，请完成或取消后再打开文件。"); return }
        if urls.count == 1 {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &directory), directory.boolValue {
                browse(urls[0]); return
            }
            if Self.archiveExtensions.contains(urls[0].pathExtension.lowercased()) {
                openArchive(urls[0]); return
            }
        }
        beginCompression(urls)
    }
    func openArchive(_ url: URL, password: String? = nil) {
        let url = url.standardizedFileURL
        loadArchive(url, password: password ?? knownPasswords[url], path: "")
    }
    private func loadArchive(_ url: URL, password: String?, path: String,
                             restoring index: Int? = nil, refreshing: Bool = false) {
        guard beginJob(L10n.message("正在打开 %@", url.lastPathComponent)) else { return }
        let engine = engine, cancellation = cancellation
        Task { [self] in
            do {
                let listing = try await engine.list(archive: url, password: password, cancellation: cancellation, onEvent: eventHandler())
                var resolvedPath = path
                if !resolvedPath.isEmpty && !listing.entries.contains(where: { ($0.path == resolvedPath && $0.isDirectory) || $0.path.hasPrefix(resolvedPath + "/") }) {
                    if refreshing {
                        while !resolvedPath.isEmpty && !listing.entries.contains(where: { ($0.path == resolvedPath && $0.isDirectory) || $0.path.hasPrefix(resolvedPath + "/") }) {
                            resolvedPath = resolvedPath.split(separator: "/").dropLast().joined(separator: "/")
                        }
                    } else { throw ArchiveError.invalidInput(L10n.tr("归档中的此文件夹已不存在。")) }
                }
                archiveURL = url; folderURL = nil; archivePath = resolvedPath; archiveEntries = listing.entries
                archivePassword = password
                if let password { knownPasswords[url] = password }
                selection = []; search = ""; remember(url)
                if refreshing { history.replaceCurrent(.archive(url, resolvedPath)) }
                else { history.commit(.archive(url, resolvedPath), restoring: index) }
                finishJob(listing.result, success: L10n.message("已打开 · %d 个项目", listing.entries.count))
            } catch {
                isBusy = false
                if isPasswordError(error) {
                    requestPassword(for: url) { [weak self] password in
                        self?.loadArchive(url, password: password, path: path, restoring: index, refreshing: refreshing)
                    }
                } else { fail(error) }
            }
        }
    }
    private func isPasswordError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("password") || error.localizedDescription.contains("密码")
    }
    private func requestPassword(for archive: URL, action: @escaping (String) -> Void) {
        passwordRequest = (archive, action)
        status = L10n.message("此归档需要密码")
        sheet = .password(archive)
    }
    func submitPassword(_ password: String, for archive: URL) {
        sheet = nil
        let request = passwordRequest
        passwordRequest = nil
        if let request, request.archive == archive { request.action(password) }
        else { openArchive(archive, password: password) }
    }
    func cancelPasswordRequest() { passwordRequest = nil }
    private func openDocument(_ url: URL) {
        Task { [self] in
            do { _ = try await launchDocument(url) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    /// Wait for Launch Services to complete its request, rather than treating
    /// the legacy Boolean "request accepted" result as a successful open.
    private func launchDocument(_ url: URL) async throws -> String {
        if let documentOpener { return try await documentOpener(url) }
        let mode = TemporaryDocument.openingMode(for: url)
        guard mode != .blockedExecutable else {
            throw ArchiveError.invalidInput(L10n.tr("此项目可能是可执行程序，请先手动解压后再打开。"))
        }
        let workspace = NSWorkspace.shared
        let editor: URL?
        if mode == .textEditor {
            if let associated = workspace.urlForApplication(toOpen: url),
               let info = Bundle(url: associated)?.infoDictionary,
               TemporaryDocument.isTextEditor(applicationInfo: info, for: url) {
                editor = associated
            } else {
                editor = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            }
        } else { editor = nil }
        let configuration = NSWorkspace.OpenConfiguration()
        // Present failures in SevenZip instead of leaving an unrelated system
        // error/open dialog behind while our operation appears complete.
        configuration.promptsUserIfNeeded = false
        let unavailable = ArchiveError.invalidInput(L10n.format("无法使用默认应用打开 %@。", url.lastPathComponent))
        guard mode != .textEditor || editor != nil else { throw unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let completed: @Sendable (NSRunningApplication?, Error?) -> Void = { application, error in
                if let error { continuation.resume(throwing: error) }
                else if let application {
                    let identifier = application.bundleIdentifier ?? application.localizedName ?? String(application.processIdentifier)
                    continuation.resume(returning: identifier)
                } else { continuation.resume(throwing: unavailable) }
            }
            if let editor {
                workspace.open([url], withApplicationAt: editor, configuration: configuration, completionHandler: completed)
            } else {
                workspace.open(url, configuration: configuration, completionHandler: completed)
            }
        }
    }
    private func previewArchiveDocument(_ path: String, password: String? = nil) {
        guard !isBusy, let archive = archiveURL,
              archiveEntries.contains(where: { $0.path == path && !$0.isDirectory }) else { return }
        guard TemporaryDocument.isSafeArchivePath(path) else {
            errorMessage = L10n.tr("归档中的文件路径不安全，无法打开。"); return
        }
        let effectivePassword = password ?? archivePassword
        if effectivePassword == nil && archiveEntries.contains(where: { $0.path == path && $0.encrypted }) {
            requestPassword(for: archive) { [weak self] password in self?.previewArchiveDocument(path, password: password) }
            return
        }
        guard beginJob(L10n.message("正在打开 %@", (path as NSString).lastPathComponent)) else { return }
        let engine = engine, cancellation = cancellation
        Task { [self] in
            var temporary: TemporaryDocument?
            do {
                let document = try TemporaryDocument.prepare(path: path)
                temporary = document
                let result = try await engine.extract(archive: archive, destination: document.directory,
                    entries: [path], password: effectivePassword, cancellation: cancellation, onEvent: eventHandler())
                guard !cancellation.isCancelled else { throw ArchiveError.cancelled }
                guard result.warnings.isEmpty else { throw ArchiveError.operationFailed(exitCode: result.exitCode, output: result.output) }
                try document.validateExtractedFile()
                if Self.archiveExtensions.contains(document.file.pathExtension.lowercased()) {
                    // Keep nested archives in this browser. Launch Services can route
                    // the file back to SevenZip before this extraction job has ended.
                    temporary = nil // Retain the private copy for navigation and password retries.
                    if let effectivePassword { knownPasswords[archive] = effectivePassword }
                    revealURL = document.file
                    finishJob(result, success: L10n.message("已打开临时副本 · %@", document.file.lastPathComponent))
                    openArchive(document.file)
                    return
                }
                let application = try await launchDocument(document.file)
                jobLog += "Opened with \(application): \(document.file.path)\n"
                temporary = nil // External applications now own the lifetime of this temporary copy.
                if let effectivePassword { archivePassword = effectivePassword; knownPasswords[archive] = effectivePassword }
                revealURL = document.file
                finishJob(result, success: L10n.message("已打开临时副本 · %@", document.file.lastPathComponent))
            } catch {
                temporary?.discardFailedExtraction()
                isBusy = false
                if isPasswordError(error) && !cancellation.isCancelled {
                    requestPassword(for: archive) { [weak self] password in self?.previewArchiveDocument(path, password: password) }
                } else { fail(error) }
            }
        }
    }

    func beginAddingFiles() {
        guard canModifyArchive else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.tr("添加文件到归档")
        panel.prompt = L10n.tr("添加")
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let prefix = archivePath.isEmpty ? "" : archivePath + "/"
        var overlapping: [String] = []
        for url in panel.urls {
            let path = prefix + url.lastPathComponent
            let exact = archiveEntries.first { $0.path == path }
            let hasChildren = archiveEntries.contains { $0.path.hasPrefix(path + "/") }
            guard exact != nil || hasChildren else { continue }
            let incomingDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let existingDirectory = exact?.isDirectory == true || hasChildren
            guard incomingDirectory == existingDirectory else {
                errorMessage = L10n.format("%@ 与归档中现有项目的类型不同，请先重命名。", url.lastPathComponent)
                return
            }
            overlapping.append(url.lastPathComponent)
        }
        if !overlapping.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("替换归档中的同名文件？")
            alert.informativeText = overlapping.joined(separator: "\n") + "\n\n" + L10n.tr("文件夹会合并，同名文件会被替换。原归档会保留一份备份。")
            alert.addButton(withTitle: L10n.tr("取消"))
            alert.addButton(withTitle: L10n.tr("添加并替换"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        updateArchive(adding: panel.urls, removing: [])
    }

    func deleteSelectedArchiveItems() {
        guard canDeleteArchiveItems, let archive = archiveURL else { return }
        let paths = selectedItems.map(\.id).sorted()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("从归档中删除 %d 个项目？", paths.count)
        alert.informativeText = archive.lastPathComponent + "\n\n" + paths.joined(separator: "\n")
            + "\n\n" + L10n.tr("所选文件夹及其内容都会删除。原归档会保留一份备份。")
        alert.addButton(withTitle: L10n.tr("取消"))
        alert.addButton(withTitle: L10n.tr("删除"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        updateArchive(adding: [], removing: paths)
    }

    private func updateArchive(adding inputs: [URL], removing paths: [String], password: String? = nil) {
        guard canModifyArchive, let archive = archiveURL else { return }
        let effectivePassword = password ?? archivePassword
        if effectivePassword == nil && archiveEntries.contains(where: \.encrypted) {
            requestPassword(for: archive) { [weak self] password in self?.updateArchive(adding: inputs, removing: paths, password: password) }
            return
        }
        guard beginJob(L10n.message("正在更新 %@", archive.lastPathComponent)) else { return }
        let engine = engine, cancellation = cancellation, directory = archivePath
        Task { [self] in
            do {
                let result = try await engine.update(archive: archive, adding: inputs, inDirectory: directory,
                    removing: paths, password: effectivePassword, cancellation: cancellation, onEvent: eventHandler())
                if let effectivePassword { archivePassword = effectivePassword; knownPasswords[archive] = effectivePassword }
                revealURL = result.backupURL ?? archive
                resultIsBackup = result.backupURL != nil
                selection = []
                // The update is already committed. A failed refresh must not invite
                // the user to retry the destructive operation believing it failed.
                do {
                    let listing = try await engine.list(archive: archive, password: effectivePassword)
                    archiveEntries = listing.entries
                    while !archiveDirectoryExists(archivePath) {
                        archivePath = archivePath.split(separator: "/").dropLast().joined(separator: "/")
                    }
                    history.replaceCurrent(.archive(archive, archivePath))
                    finishJob(result, success: result.backupURL.map { L10n.message("归档已更新；原文件备份：%@", $0.path) } ?? L10n.message("归档已更新"))
                } catch {
                    finishJob(result, success: L10n.message("归档已更新"))
                    errorMessage = L10n.format("归档已更新，但无法刷新列表：%@", error.localizedDescription)
                }
            } catch {
                isBusy = false
                if isPasswordError(error) && !cancellation.isCancelled {
                    requestPassword(for: archive) { [weak self] password in self?.updateArchive(adding: inputs, removing: paths, password: password) }
                } else { fail(error) }
            }
        }
    }
    func beginCompression(_ urls: [URL] = []) {
        guard !isBusy else { return }
        var inputs = urls.isEmpty ? selectedFileURLs : urls
        if inputs.isEmpty {
            let panel = NSOpenPanel()
            panel.title = L10n.tr("选择要压缩的文件或文件夹"); panel.prompt = L10n.tr("选择")
            panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }
            inputs = panel.urls
        }
        sheet = .compress(inputs)
    }
    func createArchive(inputs: [URL], output: URL, format: ArchiveFormat, level: Int, password: String?) {
        sheet = nil
        guard beginJob(L10n.message("正在压缩 %d 个项目", inputs.count)) else { return }
        let engine = engine, cancellation = cancellation
        Task { [self] in
            do {
                let result = try await engine.create(inputs: inputs, archive: output, format: format,
                    compressionLevel: level, password: password, cancellation: cancellation, onEvent: eventHandler())
                remember(output); revealURL = output
                finishJob(result, success: L10n.message("压缩完成 · %@", output.lastPathComponent))
                if result.warnings.isEmpty { openArchive(output, password: password) }
            } catch { fail(error) }
        }
    }
    func beginExtraction(selectedOnly: Bool = false) {
        guard !isBusy else { return }
        if let archiveURL {
            sheet = .extract([archiveURL], selectedOnly && !selection.isEmpty ? Array(selection).sorted() : nil)
        } else {
            let urls = selectedFileURLs.filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
            if !urls.isEmpty { sheet = .extract(urls, nil) }
        }
    }
    func extractFromService(_ urls: [URL]) {
        guard !isBusy else { errorMessage = L10n.tr("请等待当前任务完成后，再解压所选文件。"); return }
        guard !urls.isEmpty else { return }
        sheet = .extract(urls, nil)
    }
    func extract(archives: [URL], destination: URL, subfolder: Bool, entries: [String]?, password: String?) {
        sheet = nil
        guard beginJob(L10n.message("正在解压")) else { return }
        let engine = engine, cancellation = cancellation
        let effectivePassword = password ?? (archives.count == 1 && archives.first == archiveURL ? archivePassword : nil)
        Task { [self] in
            do {
                var warnings: [String] = []
                var lastDestination = destination
                for (index, archive) in archives.enumerated() {
                    jobTitle = archives.count > 1
                        ? L10n.message("正在解压 %@（%d/%d）", archive.lastPathComponent, index + 1, archives.count)
                        : L10n.message("正在解压 %@", archive.lastPathComponent)
                    jobProgress = nil
                    let target = subfolder || archives.count > 1 ? Self.availableFolder(in: destination, name: Self.archiveStem(archive)) : destination
                    let result = try await engine.extract(archive: archive, destination: target,
                        entries: entries, password: effectivePassword, cancellation: cancellation, onEvent: eventHandler())
                    warnings += result.warnings; lastDestination = target
                }
                isBusy = false; jobProgress = 1
                status = warnings.isEmpty ? L10n.message("解压完成") : L10n.message("解压完成，但存在警告；请查看任务日志")
                showLog = !warnings.isEmpty
                revealURL = archives.count == 1 ? lastDestination : destination
            } catch { fail(error) }
        }
    }
    func testArchive() {
        guard let archiveURL, beginJob(L10n.message("正在测试 %@", archiveURL.lastPathComponent)) else { return }
        let engine = engine, cancellation = cancellation, password = archivePassword
        Task { [self] in
            do {
                let result = try await engine.test(archive: archiveURL, password: password, cancellation: cancellation, onEvent: eventHandler())
                finishJob(result, success: L10n.message("测试通过 · 归档数据完整"))
            } catch { fail(error) }
        }
    }
    func refresh() {
        if let archiveURL { loadArchive(archiveURL, password: archivePassword, path: archivePath, refreshing: true) }
        else if let folderURL { browse(folderURL) }
    }
    func cancel() { cancellation.cancel(); status = L10n.message("正在取消…") }
    func reveal() {
        if let url = revealURL ?? archiveURL ?? folderURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    private func beginJob(_ title: LocalizedMessage) -> Bool {
        guard !isBusy else { return false }
        cancellation = ArchiveCancellation(); isBusy = true; jobTitle = title
        jobProgress = nil; jobLog = ""; showLog = false; status = title
        return true
    }
    private func eventHandler() -> @Sendable (ArchiveEvent) -> Void {
        let jobCancellation = cancellation
        return { [weak self] event in
            Task { @MainActor in
                guard let self, self.cancellation === jobCancellation else { return }
                switch event {
                case .log(let text):
                    self.jobLog += text
                    if self.jobLog.count > 100_000 { self.jobLog = String(self.jobLog.suffix(80_000)) }
                case .progress(let progress): self.jobProgress = progress
                }
            }
        }
    }
    private func finishJob(_ result: ArchiveOperationResult, success: LocalizedMessage) {
        isBusy = false; jobProgress = 1
        status = result.warnings.isEmpty ? success : L10n.message("操作完成，但存在警告；请查看任务日志")
        if !result.warnings.isEmpty { showLog = true }
    }
    private func fail(_ error: Error) {
        isBusy = false
        if error is CancellationError || error.localizedDescription.localizedCaseInsensitiveContains("cancel") || error.localizedDescription.contains("取消") {
            status = L10n.message("任务已取消"); return
        }
        status = L10n.message("操作未完成"); errorMessage = error.localizedDescription
    }
    private func remember(_ url: URL) {
        recentURLs.removeAll { $0 == url }; recentURLs.insert(url, at: 0)
        recentURLs = Array(recentURLs.prefix(12))
        preferences.set(recentURLs.map(\.path), forKey: "recentArchives")
    }
    static func archiveStem(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name.isEmpty ? L10n.tr("解压文件") : name
    }
    static func availableFolder(in parent: URL, name: String) -> URL {
        var target = parent.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("\(name) \(index)", isDirectory: true); index += 1
        }
        return target
    }
}
