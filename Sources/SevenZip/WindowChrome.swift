import AppKit
import Combine

/// Native window controls and toolbar adopt the system's current appearance,
/// including Liquid Glass on macOS 26 and later.
@MainActor
final class WindowChrome: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    private let model: AppModel
    private weak var window: NSWindow?
    private let splitView: NSSplitView
    private var subscription: AnyCancellable?
    private var languageObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private let toolbar = NSToolbar(identifier: "SevenZip.MainToolbar")
    private var searchItem: NSSearchToolbarItem?
    private var isChangingSearch = false
    private weak var pendingSearchDismissal: NSSearchToolbarItem?
    private var navigationItem: NSToolbarItemGroup?
    private let commands: [(String, String, String)] = [
        ("sidebarToggle", "显示或隐藏侧栏", "sidebar.left"),
        ("open", "打开", "folder"), ("compress", "压缩", "archivebox"),
        ("extract", "解压", "square.and.arrow.up"), ("test", "测试", "checkmark.circle"),
        ("refresh", "刷新", "arrow.clockwise"),
        ("add", "添加文件…", "plus"), ("delete", "从归档中删除…", "trash")
    ]

    init(window: NSWindow, splitView: NSSplitView, model: AppModel) {
        self.window = window
        self.splitView = splitView
        self.model = model
        super.init()
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .sevenZipLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.trackSearchDismissal(event)
            return event
        }
        refresh()
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("sidebarToggle"), NSToolbarItem.Identifier("sidebarSeparator"),
         NSToolbarItem.Identifier("navigation"),
         .flexibleSpace, NSToolbarItem.Identifier("open"), NSToolbarItem.Identifier("compress"),
         NSToolbarItem.Identifier("extract"), .space, NSToolbarItem.Identifier("add"),
         NSToolbarItem.Identifier("delete"), .space, NSToolbarItem.Identifier("test"),
         NSToolbarItem.Identifier("refresh"), .space, NSToolbarItem.Identifier("search")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [NSToolbarItem.Identifier("searchField")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier.rawValue == "sidebarSeparator" {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
        }
        if identifier.rawValue == "navigation" {
            let images = ["chevron.left", "chevron.right"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let item = NSToolbarItemGroup(itemIdentifier: identifier, images: images,
                selectionMode: .momentary, labels: [L10n.tr("后退"), L10n.tr("前进")],
                target: self, action: #selector(navigate(_:)))
            item.label = L10n.tr("导航")
            item.isNavigational = true
            item.isBordered = true
            item.controlRepresentation = .expanded
            item.visibilityPriority = .high
            item.autovalidates = false
            item.subitems.forEach { $0.autovalidates = false }
            navigationItem = item
            return item
        }
        if identifier.rawValue == "search" {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L10n.tr("搜索当前目录")
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: item.label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            item.image?.isTemplate = true
            item.isBordered = true
            item.target = self
            item.action = #selector(activateSearch(_:))
            item.autovalidates = false
            item.visibilityPriority = .high
            return item
        }
        if identifier.rawValue == "searchField" {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.preferredWidthForSearchField = 240
            item.resignsFirstResponderWithCancel = true
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.placeholderString = L10n.tr("搜索当前目录")
            item.searchField.stringValue = model.search
            item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            item.label = L10n.tr("搜索当前目录")
            item.autovalidates = false
            item.visibilityPriority = .high
            searchItem = item
            return item
        }
        guard let command = commands.first(where: { $0.0 == identifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = L10n.tr(command.1)
        item.toolTip = L10n.tr(command.1)
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        item.image = NSImage(systemSymbolName: command.2, accessibilityDescription: item.label)?
            .withSymbolConfiguration(configuration)
        item.image?.isTemplate = true
        // Standard toolbar buttons give AppKit control of sizing and glass grouping.
        item.isBordered = true
        item.target = self
        item.action = #selector(performCommand(_:))
        item.autovalidates = false
        if ["test", "refresh"].contains(identifier.rawValue) { item.visibilityPriority = .low }
        if identifier.rawValue == "sidebarToggle" { item.visibilityPriority = .high }
        return item
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { model.goBack() }
        else if sender.selectedIndex == 1 { model.goForward() }
    }

    func toggleSidebar() {
        (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil)
    }

    @objc private func performCommand(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier.rawValue {
        case "sidebarToggle": toggleSidebar()
        case "open": model.chooseArchive()
        case "compress": model.beginCompression()
        case "extract": model.beginExtraction()
        case "test": model.testArchive()
        case "refresh": model.refresh()
        case "add": model.beginAddingFiles()
        case "delete": model.deleteSelectedArchiveItems()
        default: break
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchItem?.searchField else { return }
        model.search = field.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isChangingSearch, let item = searchItem,
              notification.object as? NSSearchField === item.searchField else { return }
        // A mouse click may still be targeting another toolbar control. Let its
        // mouse-up finish before changing the toolbar layout.
        if pendingSearchDismissal === item { return }
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, let item, self.searchItem === item,
                  item.searchField.currentEditor() == nil else { return }
            self.endSearch()
        }
    }

    private func trackSearchDismissal(_ event: NSEvent) {
        pendingSearchDismissal = nil
        guard let window, event.window === window, let item = searchItem else { return }
        let field = item.searchField
        let point = field.convert(event.locationInWindow, from: nil)
        guard !field.bounds.contains(point) else { return }
        // Blank SwiftUI content does not necessarily take first responder.
        pendingSearchDismissal = item
        // Native controls and menus can consume mouse-up in a tracking loop.
        // The default run-loop mode resumes after that original interaction,
        // so collapsing cannot move a toolbar button before it is activated.
        RunLoop.main.perform(inModes: [.default]) { [weak self, weak item] in
            MainActor.assumeIsolated {
                guard let self, let item, self.searchItem === item,
                      self.pendingSearchDismissal === item else { return }
                self.endSearch()
            }
        }
    }

    @objc private func activateSearch(_ sender: NSToolbarItem) { beginSearch() }

    func beginSearch() {
        guard !model.isHome && !model.isBusy && !isChangingSearch else { return }
        if let item = searchItem {
            item.beginSearchInteraction()
            return
        }
        guard let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == "search" }) else { return }
        isChangingSearch = true
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("searchField"), at: index)
        isChangingSearch = false
        refresh()
        // The inserted field must be attached to the window before requesting
        // first responder. Both mouse activation and Command-F use this path.
        guard let item = searchItem else { return }
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, let item, self.searchItem === item,
                  !self.model.isHome && !self.model.isBusy else { return }
            item.beginSearchInteraction()
        }
    }

    private func endSearch() {
        guard !isChangingSearch, let item = searchItem,
              let index = toolbar.items.firstIndex(where: { $0 === item }) else { return }
        isChangingSearch = true
        item.endSearchInteraction()
        // The model remains the query's only source of truth while collapsed.
        pendingSearchDismissal = nil
        searchItem = nil
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("search"), at: index)
        isChangingSearch = false
        refresh()
    }

    private func refresh() {
        for item in toolbar.items {
            if let command = commands.first(where: { $0.0 == item.itemIdentifier.rawValue }) {
                item.label = L10n.tr(command.1)
                item.toolTip = item.label
            }
            switch item.itemIdentifier.rawValue {
            case "add": item.isEnabled = model.canModifyArchive
            case "delete": item.isEnabled = model.canDeleteArchiveItems
            case "extract":
                item.isEnabled = !model.isBusy && (model.archiveURL != nil || model.selectedFileURLs.contains {
                    AppModel.archiveExtensions.contains($0.pathExtension.lowercased())
                })
            case "test": item.isEnabled = !model.isBusy && model.archiveURL != nil
            case "refresh": item.isEnabled = !model.isBusy && !model.isHome
            case "search", "searchField":
                item.isEnabled = !model.isBusy && !model.isHome
                item.label = L10n.tr("搜索当前目录")
                item.toolTip = model.search.isEmpty ? item.label : item.label + " · " + model.search
            case "open", "compress": item.isEnabled = !model.isBusy
            default: break
            }
        }
        navigationItem?.label = L10n.tr("导航")
        for (index, key) in ["后退", "前进"].enumerated() {
            guard let group = navigationItem, group.subitems.indices.contains(index) else { continue }
            let item = group.subitems[index]
            item.label = L10n.tr(key)
            item.toolTip = item.label
            item.isEnabled = index == 0 ? model.canGoBack : model.canGoForward
        }
        searchItem?.searchField.placeholderString = L10n.tr("搜索当前目录")
        searchItem?.label = L10n.tr("搜索当前目录")
        searchItem?.searchField.isEnabled = !model.isHome && !model.isBusy
        if searchItem?.searchField.stringValue != model.search {
            searchItem?.searchField.stringValue = model.search
        }
        if model.isHome || model.isBusy { endSearch() }
        window?.title = model.isHome ? L10n.tr("开始") : model.title
        window?.subtitle = model.navigationSubtitle
    }
}
