import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct Smoke {
    static func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw CheckFailure(description: message) }
    }

    static func rejects(_ label: String, kind: String = "operation", _ body: () async throws -> Void) async throws {
        do {
            try await body()
            throw CheckFailure(description: "\(label): unexpectedly succeeded")
        } catch let error as ArchiveError {
            switch (kind, error) {
            case ("operation", .operationFailed), ("invalid", .invalidInput), ("cancelled", .cancelled): break
            default: throw CheckFailure(description: "\(label): unexpected error \(error)")
            }
        }
    }

    static func main() async {
        // An overall watchdog makes missing-password/cancellation regressions fail
        // clearly instead of leaving a command-line check waiting forever.
        let watchdog = DispatchWorkItem {
            report("FAIL: checks exceeded 90 seconds")
            exit(124)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try await run()
            report("ALL CHECKS PASSED")
        } catch {
            report("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CheckFailure(description: "Usage: Smoke /absolute/path/to/libSevenZip.dylib")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SevenZip-checks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if ProcessInfo.processInfo.environment["SEVENZIP_KEEP_CHECK_FILES"] == "1" {
                report("Retained test files: \(root.path)")
            } else { try? fm.removeItem(at: root) }
        }
        let engine = ArchiveEngine(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source.appendingPathComponent("中文 文件夹/nested"), withIntermediateDirectories: true)
        let samples: [String: Data] = [
            "中文 文件夹/你好 world.txt": Data("Hello 中文 \0\n".utf8),
            "中文 文件夹/nested/bytes.bin": Data((0..<1024).map { UInt8($0 % 256) }),
            "-leading dash.txt": Data("dash input\n".utf8),
            "空 格.txt": Data("space unicode\n".utf8),
            "@selected.txt": Data("literal at-sign filename\n".utf8)
        ]
        for (name, data) in samples { try data.write(to: source.appendingPathComponent(name)) }
        let inputs = ["中文 文件夹", "-leading dash.txt", "空 格.txt", "@selected.txt"].map { source.appendingPathComponent($0) }
        for format in ArchiveFormat.allCases {
            for password: String? in [nil, "Correct password 123"] {
                let label = format.rawValue + (password == nil ? "-plain" : "-encrypted")
                let archive = root.appendingPathComponent(label + "." + format.rawValue)
                let result = try await engine.create(inputs: inputs, archive: archive, format: format, password: password)
                try require(result.exitCode == 0, "\(label): creation warned")
                let listing = try await engine.list(archive: archive, password: password)
                try require(Set(listing.entries.filter { !$0.isDirectory }.map(\.path)) == Set(samples.keys), "\(label): wrong listing")
                try require(listing.entries.contains { $0.path == "中文 文件夹" && $0.isDirectory }, "\(label): folder not identified")
                _ = try await engine.test(archive: archive, password: password)
                let out = root.appendingPathComponent(label + "-out")
                _ = try await engine.extract(archive: archive, destination: out, password: password)
                for (name, data) in samples {
                    try require(Data(contentsOf: out.appendingPathComponent(name)) == data, "\(label): byte mismatch \(name)")
                }
                let selected = root.appendingPathComponent(label + "-selected")
                _ = try await engine.extract(archive: archive, destination: selected, entries: ["中文 文件夹"], password: password)
                for (name, data) in samples where name.hasPrefix("中文 文件夹/") {
                    try require(Data(contentsOf: selected.appendingPathComponent(name)) == data, "\(label): selected folder mismatch")
                }
                try require(!fm.fileExists(atPath: selected.appendingPathComponent("空 格.txt").path), "\(label): extracted unselected file")
                if password != nil {
                    for bad: String? in [nil, "wrong"] {
                        let start = Date()
                        try await rejects("\(label): bad/missing password test") {
                            _ = try await engine.test(archive: archive, password: bad)
                        }
                        try await rejects("\(label): bad/missing password extraction") {
                            _ = try await engine.extract(archive: archive, destination: root.appendingPathComponent(UUID().uuidString), password: bad)
                        }
                        try require(Date().timeIntervalSince(start) < 10, "\(label): password error was not prompt")
                    }
                }
                report("PASS \(label): create/list/test/byte-exact extract/selected folder/Unicode-space-dash/passwords")
            }
        }

        let existing = root.appendingPathComponent("existing.zip")
        let sentinel = Data("existing file must survive".utf8)
        try sentinel.write(to: existing)
        try await rejects("creation must not overwrite", kind: "invalid") {
            _ = try await engine.create(inputs: inputs, archive: existing, format: .zip)
        }
        try require(Data(contentsOf: existing) == sentinel, "creation changed existing output")
        let preserve = root.appendingPathComponent("preserve")
        try fm.createDirectory(at: preserve, withIntermediateDirectories: true)
        try sentinel.write(to: preserve.appendingPathComponent("空 格.txt"))
        _ = try await engine.extract(archive: root.appendingPathComponent("zip-plain.zip"), destination: preserve)
        try require(Data(contentsOf: preserve.appendingPathComponent("空 格.txt")) == sentinel, "extraction overwrote existing file")
        let renamed = try fm.contentsOfDirectory(at: preserve, includingPropertiesForKeys: [.isRegularFileKey]).filter { $0.lastPathComponent.hasPrefix("空 格_") }
        try require(renamed.count == 1, "extraction did not rename duplicate")
        try require(Data(contentsOf: renamed[0]) == samples["空 格.txt"], "renamed file content mismatch")
        report("PASS existing archive and extracted file are preserved")

        for password in ["中文密码", String(repeating: "x", count: 100)] {
            do {
                _ = try await engine.create(inputs: inputs, archive: root.appendingPathComponent(UUID().uuidString + ".zip"), format: .zip, password: password)
                throw CheckFailure(description: "invalid ZIP password accepted")
            } catch ArchiveError.invalidInput(let message) {
                try require(message.contains("ASCII") && message.contains("99"), "ZIP password has no useful explanation")
            }
        }
        report("PASS ZIP non-ASCII and overlong passwords have actionable validation")

        let preCancelled = ArchiveCancellation()
        preCancelled.cancel()
        try await rejects("pre-cancellation", kind: "cancelled") {
            _ = try await engine.list(archive: root.appendingPathComponent("zip-plain.zip"), cancellation: preCancelled)
        }
        // Incompressible input lets us cancel from a progress callback while the
        // dynamic library is still processing actual archive data.
        var random = Data(count: 16 * 1024 * 1024)
        random.withUnsafeMutableBytes { buffer in
            var state: UInt64 = 0x12abcdef34567890
            let words = buffer.bindMemory(to: UInt64.self)
            for i in words.indices {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                words[i] = state
            }
        }
        let big = root.appendingPathComponent("cancel-source.bin")
        try random.write(to: big)
        let running = ArchiveCancellation()
        let cancelledOutput = root.appendingPathComponent("cancelled.7z")
        let start = Date()
        try await rejects("running cancellation", kind: "cancelled") {
            _ = try await engine.create(inputs: [big], archive: cancelledOutput, format: .sevenZip,
                                        cancellation: running, onEvent: { event in
                if case .progress(let fraction) = event, fraction > 0 && fraction < 1 { running.cancel() }
            })
        }
        try require(Date().timeIntervalSince(start) < 10, "running cancellation took too long")
        try require(!fm.fileExists(atPath: cancelledOutput.path), "cancelled creation published archive")
        report("PASS cancellation before start and during native dynamic-library execution")

        for format in ArchiveFormat.allCases {
            let selected = root.appendingPathComponent("at-sign-" + format.rawValue)
            _ = try await engine.extract(archive: root.appendingPathComponent(format.rawValue + "-plain." + format.rawValue), destination: selected, entries: ["@selected.txt"])
            try require(Data(contentsOf: selected.appendingPathComponent("@selected.txt")) == samples["@selected.txt"], "literal @ selection failed")
            try require(fm.contentsOfDirectory(atPath: selected.path) == ["@selected.txt"], "literal @ selection extracted other files")
        }
        report("PASS selecting a literal @ filename")
        let nestedDestination = root.appendingPathComponent("new/deep/output", isDirectory: true)
        _ = try await engine.extract(archive: root.appendingPathComponent("zip-plain.zip"), destination: nestedDestination, entries: ["@selected.txt"])
        try require(Data(contentsOf: nestedDestination.appendingPathComponent("@selected.txt")) == samples["@selected.txt"], "multilevel destination extraction failed")
        report("PASS extraction creates a multilevel destination")
        try await checkUpdates(engine: engine, root: root, samples: samples, big: big)
        let loadedLibraries = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
        try require(loadedLibraries.contains { $0.hasSuffix("libSevenZip.dylib") }, "native library was not loaded into this process")
        report("PASS libSevenZip.dylib is loaded in process")
    }
    static func checkUpdates(engine: ArchiveEngine, root: URL, samples: [String: Data], big: URL) async throws {
        let fm = FileManager.default
        let additions = root.appendingPathComponent("update-inputs")
        try fm.createDirectory(at: additions.appendingPathComponent("追加目录/empty"), withIntermediateDirectories: true)
        let addedBytes = Data("new Unicode document\n".utf8)
        let replacedBytes = Data("replacement content\n".utf8)
        try addedBytes.write(to: additions.appendingPathComponent("追加目录/新 文档.txt"))
        try addedBytes.write(to: additions.appendingPathComponent("文档.docx"))
        try replacedBytes.write(to: additions.appendingPathComponent("@selected.txt"))
        for format in ArchiveFormat.allCases {
            for password: String? in [nil, "Correct password 123"] {
                let label = format.rawValue + (password == nil ? "-plain" : "-encrypted")
                let archive = root.appendingPathComponent("edit-" + label + "." + format.rawValue)
                try fm.copyItem(at: root.appendingPathComponent(label + "." + format.rawValue), to: archive)
                try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: archive.path)
                let original = try Data(contentsOf: archive)
                let beforeListing = try await engine.list(archive: archive, password: password)
                let first = try await engine.update(archive: archive,
                    adding: [additions.appendingPathComponent("追加目录"), additions.appendingPathComponent("@selected.txt")], password: password)
                try require(first.exitCode == 0 && first.warnings.isEmpty, "\(label): update failed")
                guard let backup = first.backupURL else { throw CheckFailure(description: "\(label): no recoverable backup") }
                try require(Data(contentsOf: backup) == original, "\(label): original backup is not byte-exact")
                try require(backup.path.contains("/.sevenzip-backups/"), "\(label): backup path is not isolated")
                let mode = try fm.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
                try require(mode?.intValue == 0o640, "\(label): original permissions lost")
                let afterListing = try await engine.list(archive: archive, password: password)
                for entry in beforeListing.entries where entry.path != "@selected.txt" {
                    guard let retained = afterListing.entries.first(where: { $0.path == entry.path }) else {
                        throw CheckFailure(description: "\(label): unchanged entry was lost: \(entry.path)")
                    }
                    // Solid 7z blocks may be recompressed when another member is
                    // replaced, so packed size is not stable per-entry metadata.
                    try require(retained.size == entry.size && retained.modified == entry.modified &&
                        retained.isDirectory == entry.isDirectory && retained.encrypted == entry.encrypted,
                        "\(label): unchanged metadata was lost for \(entry.path)")
                }
                try require(afterListing.entries.filter { $0.path == "@selected.txt" }.count == 1, "\(label): replacement duplicated item")
                try require(afterListing.entries.contains { $0.path == "追加目录/empty" && $0.isDirectory }, "\(label): empty added directory missing")
                let out = root.appendingPathComponent("edited-out-" + label)
                _ = try await engine.extract(archive: archive, destination: out, password: password)
                for (path, bytes) in samples where path != "@selected.txt" {
                    try require(Data(contentsOf: out.appendingPathComponent(path)) == bytes, "\(label): unchanged content altered")
                }
                try require(Data(contentsOf: out.appendingPathComponent("@selected.txt")) == replacedBytes, "\(label): replacement content mismatch")
                try require(Data(contentsOf: out.appendingPathComponent("追加目录/新 文档.txt")) == addedBytes, "\(label): added content mismatch")
                let beforeNested = try Data(contentsOf: archive)
                let nested = try await engine.update(archive: archive, adding: [additions.appendingPathComponent("文档.docx")], inDirectory: "中文 文件夹", password: password)
                try require(nested.backupURL != nil && Data(contentsOf: nested.backupURL!) == beforeNested, "\(label): nested update backup mismatch")
                let removed = try await engine.update(archive: archive, removing: ["中文 文件夹/nested", "追加目录"], password: password)
                try require(removed.backupURL != nil, "\(label): delete has no backup")
                let listing = try await engine.list(archive: archive, password: password)
                try require(!listing.entries.contains { $0.path == "追加目录" || $0.path.hasPrefix("追加目录/") || $0.path == "中文 文件夹/nested" || $0.path.hasPrefix("中文 文件夹/nested/") }, "\(label): recursive deletion missed children")
                try require(listing.entries.contains { $0.path == "中文 文件夹/文档.docx" }, "\(label): adding into current directory failed")
                _ = try await engine.test(archive: archive, password: password)
                if password != nil {
                    for bad: String? in [nil, "incorrect"] {
                        let previous = try Data(contentsOf: archive)
                        try await rejects("\(label): update without correct password") {
                            _ = try await engine.update(archive: archive, adding: [additions.appendingPathComponent("文档.docx")], password: bad)
                        }
                        try require(Data(contentsOf: archive) == previous, "\(label): password failure changed original")
                    }
                    try require(listing.entries.filter { !$0.isDirectory }.allSatisfy(\.encrypted), "\(label): updating silently removed encryption")
                }
                let previous = try Data(contentsOf: archive)
                let cancel = ArchiveCancellation()
                try await rejects("\(label): cancel updating", kind: "cancelled") {
                    _ = try await engine.update(archive: archive, adding: [big], password: password, cancellation: cancel, onEvent: { event in
                        if case .progress(let fraction) = event, fraction > 0 && fraction < 1 { cancel.cancel() }
                    })
                }
                try require(Data(contentsOf: archive) == previous, "\(label): cancelled update changed original")
                let allEntries = try await engine.list(archive: archive, password: password).entries.map(\.path)
                _ = try await engine.update(archive: archive, removing: allEntries, password: password)
                let empty = try await engine.list(archive: archive, password: password)
                try require(empty.entries.isEmpty, "\(label): removing all entries did not create empty archive")
                _ = try await engine.test(archive: archive, password: password)
                report("PASS \(label): add/replace/nested-add/recursive-delete/empty/update-password/cancel/permissions/exact backup")
            }
        }
        let archive = root.appendingPathComponent("zip-plain.zip")
        let original = try Data(contentsOf: archive)
        for path in ["../escape", "/absolute", "folder//item", "C:/item", "folder\\item"] {
            try await rejects("unsafe update path", kind: "invalid") {
                _ = try await engine.update(archive: archive, adding: [additions.appendingPathComponent("文档.docx")], inDirectory: path)
            }
            try await rejects("unsafe deletion path", kind: "invalid") {
                _ = try await engine.update(archive: archive, removing: [path])
            }
        }
        try await rejects("self inclusion", kind: "invalid") { _ = try await engine.update(archive: archive, adding: [archive]) }
        try await rejects("empty update", kind: "invalid") { _ = try await engine.update(archive: archive) }
        let alias = root.appendingPathComponent("alias.zip")
        try fm.createSymbolicLink(at: alias, withDestinationURL: archive)
        try await rejects("symlink archive", kind: "invalid") { _ = try await engine.update(archive: alias, removing: ["@selected.txt"]) }
        let unsupported = root.appendingPathComponent("read-only.rar")
        try fm.copyItem(at: archive, to: unsupported)
        try await rejects("unsupported update format", kind: "invalid") { _ = try await engine.update(archive: unsupported, removing: ["@selected.txt"]) }
        try require(Data(contentsOf: archive) == original, "validation failure changed original")
        let disguised = root.appendingPathComponent("mismatched.7z")
        try fm.copyItem(at: archive, to: disguised)
        try await rejects("format mismatch") { _ = try await engine.update(archive: disguised, removing: ["@selected.txt"]) }
        try require(Data(contentsOf: disguised) == original, "format mismatch changed original")
        report("PASS update rejects unsafe paths, self inclusion, symbolic links, unsupported/mismatched formats and empty changes")

        let changed = root.appendingPathComponent("externally-changed.zip")
        try fm.copyItem(at: archive, to: changed)
        let externalBytes = Data("changed by another writer".utf8)
        let once = OneShot()
        try await rejects("concurrent archive modification", kind: "invalid") {
            _ = try await engine.update(archive: changed, adding: [big], onEvent: { event in
                if case .progress = event, once.claim() { try? externalBytes.write(to: changed, options: .atomic) }
            })
        }
        try require(Data(contentsOf: changed) == externalBytes, "update overwrote an external edit")
        report("PASS concurrent external edit is preserved instead of replaced")
    }

}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}
