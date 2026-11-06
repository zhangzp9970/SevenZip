import Foundation

/// Exercises language changes without writing any system or app preferences.
@main
struct LocalizationSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: LocalizationSmoke <localization resources directory>\n", stderr)
            exit(2)
        }
        let cases: [([String], String)] = [
            (["zh-Hant-TW"], "zh-Hant"),
            (["zh-HK"], "zh-Hant"),
            (["zh-Hans-SG"], "zh-Hans"),
            (["en-GB"], "en"),
            (["it-IT", "de-DE"], "de"),
            (["ru-RU"], "en"),
            (["ja-JP"], "ja"),
            (["fr-CA"], "fr"),
            (["es-MX"], "es")
        ]
        for (input, expected) in cases {
            precondition(Localization.resolve(input) == expected, "Language resolution failed: \(input)")
        }
        var preferred = ["en-US"]
        let resolver = Localization(
            resourceRoot: URL(fileURLWithPath: CommandLine.arguments[1]),
            preferences: { preferred }
        )
        precondition(resolver.text("打开") == "Open", "English bundle did not load")
        for (language, expected) in [
            ("zh-Hans", "打开"), ("zh-Hant", "打開"), ("ja", "開く"),
            ("de", "Öffnen"), ("fr", "Ouvrir"), ("es", "Abrir")
        ] {
            preferred = [language]
            let oldRevision = resolver.revision
            resolver.refresh()
            precondition(resolver.text("打开") == expected, "Bundle failed: \(language)")
            precondition(resolver.revision == oldRevision + 1, "Revision did not change")
            precondition(resolver.locale.identifier == language, "Locale did not change")
        }
        print("PASS: language resolution, seven language bundles, live refresh, revision and locale changes")
    }
}
