import AppKit
import SwiftUI
import Combine

@main
@MainActor
final class Application: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model = AppModel()
    private var window: NSWindow!
    private var chrome: WindowChrome?
    private var terminationWait: AnyCancellable?
    private var pendingURLs: [URL] = []
    private var languageObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = Application()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppArtwork.applicationIcon
        Localization.shared.refresh()
        installMenu()
        languageObserver = NotificationCenter.default.addObserver(forName: .sevenZipLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installMenu() }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SevenZip"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SevenZipMainWindow")
        let splitController = NSSplitViewController()
        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin
        splitController.splitView.autosaveName = "SevenZipSidebar"
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SidebarView(model: model)))
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 320
        sidebar.preferredThicknessFraction = 0.2
        let content = NSSplitViewItem(viewController: NSHostingController(rootView: ContentView(model: model)))
        content.minimumThickness = 560
        splitController.addSplitViewItem(sidebar)
        splitController.addSplitViewItem(content)
        window.contentViewController = splitController
        chrome = WindowChrome(window: window, splitView: splitController.splitView, model: model)
        showWindow()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if !pendingURLs.isEmpty { model.receive(pendingURLs); pendingURLs = [] }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if window == nil { pendingURLs.append(contentsOf: urls) }
        else { showWindow(); model.receive(urls) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isBusy {
            let alert = NSAlert()
            alert.messageText = L10n.tr("任务仍在进行")
            alert.informativeText = L10n.tr("退出会取消当前压缩或解压任务。")
            alert.addButton(withTitle: L10n.tr("继续任务")); alert.addButton(withTitle: L10n.tr("取消任务并退出"))
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            model.cancel()
            // Let the in-process library finish cancellation and clean its temporary output.
            terminationWait = model.$isBusy.filter { !$0 }.prefix(1).sink { _ in
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return urls }
        let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }
    @objc(compressFiles:userData:error:)
    func compressFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(pasteboard)
        guard !urls.isEmpty else { error.pointee = L10n.tr("请选择要压缩的文件或文件夹。") as NSString; return }
        guard !model.isBusy else { error.pointee = L10n.tr("SevenZip 正在执行任务，请稍后再试。") as NSString; return }
        showWindow(); model.beginCompression(urls)
    }
    @objc(extractFiles:userData:error:)
    func extractFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(pasteboard)
        guard !urls.isEmpty else { error.pointee = L10n.tr("请选择要解压的压缩包。") as NSString; return }
        guard !model.isBusy else { error.pointee = L10n.tr("SevenZip 正在执行任务，请稍后再试。") as NSString; return }
        showWindow(); model.extractFromService(urls)
    }
    @objc private func openArchive() { showWindow(); model.chooseArchive() }
    @objc private func compress() { showWindow(); model.beginCompression() }
    @objc private func extract() { showWindow(); model.beginExtraction() }
    @objc private func testArchive() { model.testArchive() }
    @objc private func goHome() { showWindow(); model.home() }
    @objc private func find() { chrome?.beginSearch() }
    @objc private func goBack() { model.goBack() }
    @objc private func goForward() { model.goForward() }
    @objc private func goUp() { model.goUp() }
    @objc private func toggleSidebar() { chrome?.toggleSidebar() }
    @objc private func addFiles() { model.beginAddingFiles() }
    @objc private func deleteItems() { model.deleteSelectedArchiveItems() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openArchive), #selector(compress), #selector(goHome): return !model.isBusy
        case #selector(testArchive): return !model.isBusy && model.archiveURL != nil
        case #selector(find): return !model.isBusy && !model.isHome
        case #selector(goBack): return model.canGoBack
        case #selector(goForward): return model.canGoForward
        case #selector(goUp): return model.canGoUp
        case #selector(addFiles): return model.canModifyArchive
        case #selector(deleteItems): return model.canDeleteArchiveItems && !(window?.firstResponder is NSTextView)
        case #selector(extract):
            return !model.isBusy && (model.archiveURL != nil || model.selectedFileURLs.contains {
                AppModel.archiveExtensions.contains($0.pathExtension.lowercased())
            })
        default: return true
        }
    }

    private func installMenu() {
        let main = NSMenu()
        NSApp.mainMenu = main
        let appItem = main.addItem(withTitle: "SevenZip", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "SevenZip"); appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.tr("关于 SevenZip"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesItem = appMenu.addItem(withTitle: L10n.tr("服务"), action: nil, keyEquivalent: "")
        let services = NSMenu(title: L10n.tr("服务")); servicesItem.submenu = services; NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("隐藏 SevenZip"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.tr("退出 SevenZip"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = main.addItem(withTitle: L10n.tr("文件"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.tr("文件")); fileItem.submenu = fileMenu
        add(fileMenu, L10n.tr("打开压缩包…"), #selector(openArchive), "o", symbol: "folder")
        add(fileMenu, L10n.tr("创建压缩包…"), #selector(compress), "n", symbol: "archivebox")
        add(fileMenu, L10n.tr("解压…"), #selector(extract), "e", symbol: "square.and.arrow.up")
        add(fileMenu, L10n.tr("测试归档"), #selector(testArchive), "t", symbol: "checkmark.circle")
        fileMenu.addItem(.separator())
        add(fileMenu, L10n.tr("添加文件…"), #selector(addFiles), "", symbol: "plus")
        add(fileMenu, L10n.tr("从归档中删除…"), #selector(deleteItems), "\u{8}", symbol: "trash")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.tr("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = main.addItem(withTitle: L10n.tr("编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.tr("编辑")); editItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.tr("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.tr("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.tr("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.tr("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.tr("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        add(editMenu, L10n.tr("搜索当前目录"), #selector(find), "f", symbol: "magnifyingglass")
        let goItem = main.addItem(withTitle: L10n.tr("前往"), action: nil, keyEquivalent: "")
        let goMenu = NSMenu(title: L10n.tr("前往")); goItem.submenu = goMenu
        add(goMenu, L10n.tr("后退"), #selector(goBack), "[", symbol: "chevron.left")
        add(goMenu, L10n.tr("前进"), #selector(goForward), "]", symbol: "chevron.right")
        add(goMenu, L10n.tr("上一级"), #selector(goUp), "\u{F700}", symbol: "arrow.up")
        let windowItem = main.addItem(withTitle: L10n.tr("窗口"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L10n.tr("窗口")); windowItem.submenu = windowMenu; NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: L10n.tr("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add(windowMenu, L10n.tr("开始"), #selector(goHome), "1")
        add(windowMenu, L10n.tr("显示或隐藏侧栏"), #selector(toggleSidebar), "", symbol: "sidebar.left")
    }
    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector, _ shortcut: String, symbol: String? = nil) {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: shortcut)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
    }
}
