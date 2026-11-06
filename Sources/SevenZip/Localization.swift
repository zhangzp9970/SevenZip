import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let sevenZipLanguageDidChange = Notification.Name("SevenZipLanguageDidChange")
}

/// Resolves the user's language preferences without changing system settings.
/// SwiftUI observes revision; AppKit listens for sevenZipLanguageDidChange.
final class Localization: ObservableObject {
    static let shared = Localization()
    static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "de", "fr", "es"]
    @Published private(set) var revision = 0
    @Published private(set) var locale: Locale
    private(set) var language: String
    private var bundle: Bundle?
    private let englishBundle: Bundle?
    private let resourceRoot: URL?
    private let languagePreferences: () -> [String]
    private var observers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?

    init(resourceRoot: URL? = Bundle.main.resourceURL, preferences: (() -> [String])? = nil) {
        self.resourceRoot = resourceRoot
        languagePreferences = preferences ?? Self.preferredLanguages
        let language = Self.resolve(languagePreferences())
        self.language = language
        locale = Locale(identifier: language)
        bundle = Self.bundle(for: language, root: resourceRoot)
        englishBundle = Self.bundle(for: "en", root: resourceRoot)
        let center = NotificationCenter.default
        for name in [NSLocale.currentLocaleDidChangeNotification, UserDefaults.didChangeNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleLanguagePreferencesChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
    }

    static func resolve(_ preferences: [String]) -> String {
        for preference in preferences {
            let parts = preference.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hant") || (!parts.contains("hans") && parts.contains(where: { ["tw", "hk", "mo"].contains($0) })) {
                    return "zh-Hant"
                }
                return "zh-Hans"
            }
            if ["en", "ja", "de", "fr", "es"].contains(base) { return base }
        }
        return "en"
    }

    func refresh() {
        let selected = Self.resolve(languagePreferences())
        guard selected != language else { return }
        language = selected
        bundle = Self.bundle(for: selected, root: resourceRoot)
        locale = Locale(identifier: selected)
        revision &+= 1
        NotificationCenter.default.post(name: .sevenZipLanguageDidChange, object: self)
    }

    private static func preferredLanguages() -> [String] {
        // Refresh the global preferences cache so a running app sees a language
        // change the next time it becomes active. Respect per-app language overrides.
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if let identifier = Bundle.main.bundleIdentifier {
            CFPreferencesAppSynchronize(identifier as CFString)
        }
        if let identifier = Bundle.main.bundleIdentifier,
           let languages = UserDefaults.standard.persistentDomain(forName: identifier)?["AppleLanguages"] as? [String] {
            return languages
        }
        if let languages = CFPreferencesCopyValue("AppleLanguages" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            return languages
        }
        return Locale.preferredLanguages
    }

    func text(_ key: String) -> String {
        let fallback = englishBundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        return bundle?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback
    }

    private static func bundle(for language: String, root: URL?) -> Bundle? {
        guard let root else { return nil }
        for directory in [root, root.appendingPathComponent("Localizations", isDirectory: true)] {
            if let bundle = Bundle(url: directory.appendingPathComponent(language + ".lproj", isDirectory: true)) { return bundle }
        }
        return nil
    }
}

enum L10n {
    static func tr(_ key: String) -> String { Localization.shared.text(key) }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: Localization.shared.locale, arguments: arguments)
    }
    static func message(_ key: String, _ arguments: CVarArg...) -> LocalizedMessage {
        LocalizedMessage(key: key, arguments: arguments)
    }
}

/// Keeps already displayed task status translatable when the system language changes.
struct LocalizedMessage {
    let key: String
    let arguments: [CVarArg]
    var text: String {
        guard !key.isEmpty else { return "" }
        return String(format: L10n.tr(key), locale: Localization.shared.locale, arguments: arguments)
    }
}
