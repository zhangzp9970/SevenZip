import AppKit
import ArchiveCore
import Foundation

private struct ArchiveCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct ArchiveBrowserSmoke {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ArchiveCheckFailure(description: message) }
    }

    static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func main() async {
        let watchdog = DispatchWorkItem {
            FileHandle.standardError.write(Data("FAIL: archive checks exceeded 90 seconds\n".utf8))
            exit(124)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try require(CommandLine.arguments.count == 3, "Usage: ArchiveBrowserSmoke library fixtures")
            let engine = ArchiveEngine(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
            try await checkCompoundArchives(engine: engine, root: root)
            try await checkBrowser(engine: engine, root: root)
            report("ALL COMPOUND ARCHIVE CHECKS PASSED")
        } catch {
            report("FAIL: \(error)")
            exit(1)
        }
    }

    static func expectFailure(_ label: String, _ action: () async throws -> Void) async throws {
        do {
            try await action()
            throw ArchiveCheckFailure(description: "\(label) unexpectedly succeeded")
        } catch is ArchiveError { }
    }

    static func checkCompoundArchives(engine: ArchiveEngine, root: URL) async throws {
        let files: Set<String> = ["Read Me.txt", "Docs/notes.txt", "Docs/script.py"]
        let cases = ["bundle.tar.gz", "bundle.tgz", "UpperCase.TAR.GZ", "bundle.tar.bz2", "bundle.tbz",
                     "bundle.tbz2", "bundle.tar.xz", "bundle.txz", "bundle.tar.lzma", "unsafe-name.tar.gz"]
        for name in cases {
            let archive = root.appendingPathComponent(name)
            let listing = try await engine.list(archive: archive)
            try require(Set(listing.entries.filter { !$0.isDirectory }.map(\.path)) == files,
                        "\(name) did not list TAR members directly")
            try require(listing.result.warnings.isEmpty, "\(name) returned unexpected listing warnings")
            let tested = try await engine.test(archive: archive)
            try require(tested.warnings.isEmpty, "\(name) integrity test warned")
            let output = root.appendingPathComponent("full-" + name, isDirectory: true)
            let extracted = try await engine.extract(archive: archive, destination: output)
            try require(extracted.warnings.isEmpty, "\(name) full extraction warned")
            for path in files {
                try require(Data(contentsOf: output.appendingPathComponent(path))
                            == Data(contentsOf: root.appendingPathComponent("expected/" + path)),
                            "\(name) changed bytes for \(path)")
            }
            let selected = root.appendingPathComponent("selected-" + name, isDirectory: true)
            _ = try await engine.extract(archive: archive, destination: selected, entries: ["Docs"])
            try require(FileManager.default.fileExists(atPath: selected.appendingPathComponent("Docs/notes.txt").path),
                        "\(name) did not extract the selected TAR directory")
            try require(!FileManager.default.fileExists(atPath: selected.appendingPathComponent("Read Me.txt").path),
                        "\(name) extracted an unselected file")
        }
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.tar").path),
                    "The gzip original filename escaped private staging")
        let plain = root.appendingPathComponent("plain.txt.gz")
        let plainList = try await engine.list(archive: plain)
        try require(plainList.entries.count == 1 && !plainList.entries[0].isDirectory,
                    "Plain gzip must remain a single document")
        let plainOutput = root.appendingPathComponent("plain-output", isDirectory: true)
        _ = try await engine.extract(archive: plain, destination: plainOutput)
        try require(Data(contentsOf: plainOutput.appendingPathComponent(plainList.entries[0].path))
                    == Data("Plain gzip document.\n".utf8), "Plain gzip data changed")
        let empty = try await engine.list(archive: root.appendingPathComponent("empty.tar.gz"))
        try require(empty.entries.isEmpty, "Empty compressed TAR should open as an empty archive")
        let disguised = try await engine.list(archive: root.appendingPathComponent("zip-disguised.tar.gz"))
        try require(Set(disguised.entries.map(\.path)) == ["inner.tar", "inner.zip", "bundle.tar.gz"],
                    "A ZIP container must not be flattened by its filename")
        for name in ["corrupt.tar.gz", "truncated.tar.gz", "not-a-tar.tar.gz"] {
            try await expectFailure(name) { _ = try await engine.list(archive: root.appendingPathComponent(name)) }
        }
        try await expectFailure("TAR path traversal") {
            _ = try await engine.extract(archive: root.appendingPathComponent("unsafe-path.tar.gz"),
                                         destination: root.appendingPathComponent("unsafe-output", isDirectory: true))
        }
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path),
                    "TAR path traversal escaped extraction root")
        let cancelled = ArchiveCancellation()
        cancelled.cancel()
        do {
            _ = try await engine.list(archive: root.appendingPathComponent("bundle.tar.gz"), cancellation: cancelled)
            throw ArchiveCheckFailure(description: "Cancelled compressed TAR open unexpectedly succeeded")
        } catch ArchiveError.cancelled { }
        let duringDecode = ArchiveCancellation()
        do {
            _ = try await engine.list(archive: root.appendingPathComponent("bundle.tar.gz"), cancellation: duringDecode,
                                      onEvent: { event in
                if case .progress(let value) = event, value > 0 { duringDecode.cancel() }
            })
            throw ArchiveCheckFailure(description: "Cancellation during compressed TAR decoding was ignored")
        } catch ArchiveError.cancelled { }
        try require(duringDecode.isCancelled, "Compressed TAR decoding did not report progress")
        report("PASS: compressed TAR listing/test/full and selected extraction, aliases, byte integrity, plain gzip, empty TAR, corruption, cancellation and path safety")
    }

    static func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.isBusy {
            try require(Date() < deadline, "AppModel remained busy while opening an archive")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func checkBrowser(engine: ArchiveEngine, root: URL) async throws {
        let suite = "org.sevenzip.archive-checks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var documentOpens: [URL] = []
        var privateCopies = Set<URL>()
        defer {
            for directory in privateCopies { try? FileManager.default.removeItem(at: directory) }
        }
        func keepTrack(_ file: URL?) {
            guard let file else { return }
            for parent in file.pathComponents.indices.reversed() {
                let path = NSString.path(withComponents: Array(file.pathComponents.prefix(parent + 1)))
                if URL(fileURLWithPath: path).lastPathComponent.hasPrefix("SevenZip-Preview-") {
                    privateCopies.insert(URL(fileURLWithPath: path, isDirectory: true))
                    return
                }
            }
        }
        let model = AppModel(engine: engine, preferences: preferences) { url in
            documentOpens.append(url)
            return "SevenZip.TestDocumentViewer"
        }
        let compound = root.appendingPathComponent("bundle.tar.gz")
        model.openArchive(compound)
        try await waitUntilIdle(model)
        try require(model.errorMessage == nil && model.archiveURL == compound,
                    "Compressed TAR identity/open mismatch: expected \(compound), got \(String(describing: model.archiveURL)); error: \(model.errorMessage ?? "none")")
        try require(Set(model.items.map(\.name)) == ["Read Me.txt", "Docs"],
                    "Compressed TAR browser still shows an intermediate TAR item")
        model.activate(["Docs"])
        try require(model.archivePath == "Docs", "Cannot browse folders inside compressed TAR")
        model.activate(["Docs/script.py"])
        try await waitUntilIdle(model)
        keepTrack(model.revealURL)
        try require(model.errorMessage == nil && documentOpens.count == 1,
                    "Ordinary document preview inside compressed TAR did not complete")
        try require(Data(contentsOf: documentOpens[0]) == Data(contentsOf: root.appendingPathComponent("expected/Docs/script.py")),
                    "Document preview extracted incorrect contents")
        model.refresh()
        try await waitUntilIdle(model)
        try require(model.archivePath == "Docs" && model.errorMessage == nil,
                    "Refresh lost the current compressed TAR directory")
        model.goUp()
        try require(model.archivePath.isEmpty, "Up did not return to TAR root")
        model.testArchive()
        try await waitUntilIdle(model)
        try require(model.errorMessage == nil, "Browser integrity check failed")

        let parent = root.appendingPathComponent("container.zip")
        for (nested, expected) in [("inner.tar", Set(["Read Me.txt", "Docs"])),
                                   ("inner.zip", Set(["Nested.txt"])),
                                   ("bundle.tar.gz", Set(["Read Me.txt", "Docs"]))] {
            model.openArchive(parent)
            try await waitUntilIdle(model)
            try require(model.items.contains { $0.name == nested }, "Outer ZIP lost its nested archive")
            model.activate([nested])
            try await waitUntilIdle(model)
            keepTrack(model.archiveURL)
            try require(model.errorMessage == nil && model.archiveURL?.lastPathComponent == nested,
                        "Nested \(nested) open hit the busy-task gate")
            try require(Set(model.items.map(\.name)) == expected, "Nested \(nested) contents did not appear")
            try require(documentOpens.count == 1, "Nested archive was sent to an external application")
            model.goBack()
            try await waitUntilIdle(model)
            try require(model.archiveURL == parent && model.errorMessage == nil,
                        "Back did not restore the containing archive")
            model.goForward()
            try await waitUntilIdle(model)
            try require(model.archiveURL?.lastPathComponent == nested && model.errorMessage == nil,
                        "Forward could not reopen the private nested archive")
        }
        model.openArchive(compound)
        model.cancel()
        try await waitUntilIdle(model)
        try require(model.errorMessage == nil, "Cancelled open incorrectly displayed an error")
        model.openArchive(compound)
        try await waitUntilIdle(model)
        try require(model.errorMessage == nil && model.archiveURL == compound,
                    "Cancelled open left the next operation blocked")
        try require(preferences.stringArray(forKey: "recentArchives")?.contains(compound.path) == true,
                    "Recent archives lost the original compressed file")
        report("PASS: direct compressed TAR browsing, document preview, refresh, nested TAR/ZIP handoff without external launch, back/forward and cancellation recovery")
    }
}
