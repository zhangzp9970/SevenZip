import Foundation
import XCTest
@testable import ArchiveCore

final class ArchiveEngineTests: XCTestCase {
    private var workspace: URL!
    private var engine: ArchiveEngine!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("SevenZipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        let candidates = [ProcessInfo.processInfo.environment["SEVENZIP_LIBRARY"],
                          repository.appendingPathComponent(".build/native/libSevenZip.dylib").path,
                          repository.appendingPathComponent("dist/SevenZip.app/Contents/Frameworks/libSevenZip.dylib").path].compactMap { $0 }
        guard let library = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Build libSevenZip.dylib or set SEVENZIP_LIBRARY before running integration tests.")
        }
        engine = ArchiveEngine(libraryURL: URL(fileURLWithPath: library))
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
    }

    @discardableResult
    private func write(_ path: String, _ content: String) throws -> URL {
        let url = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func assertFailure(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await action()
            XCTFail("Expected operation to fail", file: file, line: line)
        } catch { }
    }

    func testZipAndSevenZipRoundTripsAcrossDifferentParents() async throws {
        let first = try write("parent one/-空格 文件.txt", "Unicode 内容\n")
        let second = try write("parent two/@literal[1]*?.txt", "literal wildcards\n")
        for format in ArchiveFormat.allCases {
            let archive = workspace.appendingPathComponent("-压缩 文件.\(format.rawValue)")
            let created = try await engine.create(inputs: [first, second], archive: archive, format: format)
            XCTAssertEqual(created.exitCode, 0)
            let listing = try await engine.list(archive: archive)
            XCTAssertEqual(Set(listing.entries.map(\.path)), Set([first.lastPathComponent, second.lastPathComponent]))
            XCTAssertEqual(listing.entries.first(where: { $0.path == first.lastPathComponent })?.size, UInt64(Data("Unicode 内容\n".utf8).count))
            _ = try await engine.test(archive: archive)
            let destination = workspace.appendingPathComponent("提取 \(format.rawValue)")
            _ = try await engine.extract(archive: archive, destination: destination)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(first.lastPathComponent)), try Data(contentsOf: first))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(second.lastPathComponent)), try Data(contentsOf: second))
        }
    }

    func testSelectedFolderIncludesDescendantsAndExcludesOtherFiles() async throws {
        _ = try write("source/文件夹/deep/child.txt", "nested")
        _ = try write("source/文件夹/top.txt", "top")
        let unrelated = try write("elsewhere/unrelated.txt", "leave out")
        let directory = workspace.appendingPathComponent("source/文件夹")
        let archive = workspace.appendingPathComponent("selection.7z")
        _ = try await engine.create(inputs: [directory, unrelated], archive: archive, format: .sevenZip)
        let listing = try await engine.list(archive: archive)
        XCTAssertTrue(listing.entries.contains(where: { $0.path == "文件夹" && $0.isDirectory }))
        let destination = workspace.appendingPathComponent("selected")
        _ = try await engine.extract(archive: archive, destination: destination, entries: ["文件夹"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("文件夹/deep/child.txt"), encoding: .utf8), "nested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("unrelated.txt").path))
        await assertFailure { _ = try await self.engine.extract(archive: archive, destination: destination, entries: []) }
    }

    func testSelectedWildcardNameIsLiteral() async throws {
        let literal = try write("literal*.txt", "selected")
        let other = try write("literalOTHER.txt", "excluded")
        let archive = workspace.appendingPathComponent("literal.zip")
        _ = try await engine.create(inputs: [literal, other], archive: archive, format: .zip)
        let destination = workspace.appendingPathComponent("literal-output")
        _ = try await engine.extract(archive: archive, destination: destination, entries: [literal.lastPathComponent])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(literal.lastPathComponent), encoding: .utf8), "selected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(other.lastPathComponent).path))
    }

    func testEncryptedArchivesAcceptCorrectPasswordAndRejectWrongOrMissingPassword() async throws {
        let source = try write("secret.txt", "password-protected content")
        for format in ArchiveFormat.allCases {
            let password = format == .sevenZip ? "密码 with spaces -flag" : "ASCII password -flag"
            let archive = workspace.appendingPathComponent("protected.\(format.rawValue)")
            _ = try await engine.create(inputs: [source], archive: archive, format: format, password: password)
            let listing = try await engine.list(archive: archive, password: password)
            XCTAssertEqual(listing.entries.count, 1)
            XCTAssertTrue(listing.entries[0].encrypted)
            _ = try await engine.test(archive: archive, password: password)
            let start = Date()
            await assertFailure { _ = try await self.engine.test(archive: archive, password: "wrong") }
            await assertFailure { _ = try await self.engine.test(archive: archive) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 15, "Password errors must not wait for stdin")
            let destination = workspace.appendingPathComponent("decrypted-\(format.rawValue)")
            _ = try await engine.extract(archive: archive, destination: destination, password: password)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)), try Data(contentsOf: source))
        }
    }

    func testCreationValidatesPasswordBeforeInvokingEngine() async throws {
        let source = try write("password-validation.txt", "content")
        let archive = workspace.appendingPathComponent("rejected.zip")
        let invalidPasswords = ["中文密码", "line\nbreak", String(repeating: "a", count: 100)]
        for password in invalidPasswords {
            do {
                _ = try await engine.create(inputs: [source], archive: archive, format: .zip, password: password)
                XCTFail("Expected unsupported ZIP password to fail")
            } catch ArchiveError.invalidInput(let message) {
                XCTAssertTrue(message.contains("99"))
                XCTAssertTrue(message.contains("7z"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        }
        for format in ArchiveFormat.allCases {
            do {
                _ = try await engine.create(inputs: [source], archive: archive, format: format, password: "before\u{0000}after")
                XCTFail("Expected NUL password to fail")
            } catch ArchiveError.invalidInput(let message) {
                XCTAssertTrue(message.contains("NUL"))
            }
        }
        let maximum = String(repeating: "a", count: 99)
        _ = try await engine.create(inputs: [source], archive: archive, format: .zip, password: maximum)
        _ = try await engine.test(archive: archive, password: maximum)
    }

    func testCreationRejectsDuplicateNamesAndExistingArchive() async throws {
        let first = try write("a/same.txt", "one")
        let second = try write("b/same.txt", "two")
        let archive = workspace.appendingPathComponent("never-overwrite.zip")
        await assertFailure { _ = try await self.engine.create(inputs: [first, second], archive: archive, format: .zip) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        let original = Data("existing file".utf8)
        try original.write(to: archive)
        await assertFailure { _ = try await self.engine.create(inputs: [first], archive: archive, format: .zip) }
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testInvalidArchivePropagatesExitCodeAndOutput() async throws {
        let invalid = try write("broken.zip", "this is not a ZIP archive")
        do {
            _ = try await engine.test(archive: invalid)
            XCTFail("Invalid archive was accepted")
        } catch ArchiveError.operationFailed(let code, let output) {
            XCTAssertNotEqual(code, 0)
            XCTAssertFalse(output.isEmpty)
        }
    }

    func testCancellationBeforeAndDuringNativeCallDoesNotPublishArchive() async throws {
        let source = try write("cancel.txt", String(repeating: "cancel me\n", count: 100_000))
        let before = ArchiveCancellation()
        before.cancel()
        let first = workspace.appendingPathComponent("cancelled-before.7z")
        do {
            _ = try await engine.create(inputs: [source], archive: first, format: .sevenZip, cancellation: before)
            XCTFail("Expected cancellation")
        } catch ArchiveError.cancelled { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        let during = ArchiveCancellation()
        let second = workspace.appendingPathComponent("cancelled-during.7z")
        do {
            _ = try await engine.create(inputs: [source], archive: second, format: .sevenZip, cancellation: during) { event in
                if case .progress(let fraction) = event, fraction < 1 { during.cancel() }
            }
            XCTFail("Expected cancellation from the native progress callback")
        } catch ArchiveError.cancelled { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testStructuredNativeListingPreservesMetadata() async throws {
        let source = try write("folder/中文.txt", "test")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let archive = workspace.appendingPathComponent("metadata.7z")
        _ = try await engine.create(inputs: [source.deletingLastPathComponent()], archive: archive, format: .sevenZip, password: "secret")
        let listing = try await engine.list(archive: archive, password: "secret")
        XCTAssertEqual(Set(listing.entries.map(\.path)), Set(["folder", "folder/中文.txt"]))
        XCTAssertTrue(listing.entries.first(where: { $0.path == "folder" })!.isDirectory)
        let file = listing.entries.first(where: { $0.path == "folder/中文.txt" })!
        XCTAssertEqual(file.size, 4)
        XCTAssertTrue(file.encrypted)
        XCTAssertEqual(file.modified?.timeIntervalSince1970, date.timeIntervalSince1970)
    }
}
