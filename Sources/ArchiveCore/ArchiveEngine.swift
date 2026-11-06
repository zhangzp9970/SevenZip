import Foundation
import Darwin
import SevenZipBridge

public enum ArchiveFormat: String, CaseIterable, Sendable {
    case sevenZip = "7z"
    case zip = "zip"
}

public struct ArchiveEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let size: UInt64?
    public let packedSize: UInt64?
    public let modified: Date?
    public let isDirectory: Bool
    public let encrypted: Bool
    public var id: String { path }
}

public struct ArchiveOperationResult: Sendable {
    /// Native C ABI status, retained under this name for source compatibility.
    public let exitCode: Int32
    public let output: String
    public let warnings: [String]
    /// A successful in-place update retains the preceding archive at this URL.
    public var backupURL: URL? = nil
}

public struct ArchiveListing: Sendable {
    public let entries: [ArchiveEntry]
    public let result: ArchiveOperationResult
}

public enum ArchiveEvent: Sendable {
    case log(String)
    case progress(Double)
}

public enum ArchiveError: LocalizedError, Sendable {
    case invalidInput(String)
    case engineUnavailable(String)
    case operationFailed(exitCode: Int32, output: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): return message
        case .engineUnavailable(let detail): return "Unable to load the 7-Zip dynamic library: \(detail)"
        case .operationFailed(let code, let output): return "7-Zip operation failed (status \(code)).\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .cancelled: return "Operation cancelled."
        }
    }
}

/// Cancellation is cooperative through the C ABI callbacks, including stream I/O.
public final class ArchiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
    fileprivate func check() throws {
        if isCancelled { throw ArchiveError.cancelled }
    }
}

/// Owns function pointers to the in-process C++ 7-Zip implementation.
/// Handles remain loaded for the process lifetime so codec registration and worker
/// thread-local objects cannot outlive a dynamic-library mapping.
private final class NativeLibrary: @unchecked Sendable {
    typealias List = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<SZBCallbacks>?) -> Int32
    typealias Create = @convention(c) (UnsafePointer<CChar>?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?, Int, UnsafePointer<SZBCallbacks>?) -> Int32
    typealias Extract = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, Int, UnsafePointer<CChar>?, UnsafePointer<SZBCallbacks>?) -> Int32
    typealias Update = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?, Int, UnsafePointer<UnsafePointer<CChar>?>?, Int, UnsafePointer<SZBCallbacks>?) -> Int32
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?
    let handle: UnsafeMutableRawPointer
    let list: List
    let create: Create
    let extract: Extract
    let test: List
    let update: Update
    let version: Version
    private static let lock = NSLock()
    private static var loaded: [String: NativeLibrary] = [:]

    static func load(_ url: URL) throws -> NativeLibrary {
        lock.lock(); defer { lock.unlock() }
        if let result = loaded[url.path] { return result }
        let result = try NativeLibrary(url)
        loaded[url.path] = result
        return result
    }
    private init(_ url: URL) throws {
        guard url.isFileURL, let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? url.path
            throw ArchiveError.engineUnavailable(detail)
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw ArchiveError.engineUnavailable("Missing C ABI symbol: \(name)")
            }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            self.list = try symbol("szb_list", List.self)
            self.create = try symbol("szb_create", Create.self)
            self.extract = try symbol("szb_extract", Extract.self)
            self.test = try symbol("szb_test", List.self)
            self.update = try symbol("szb_update", Update.self)
            self.version = try symbol("szb_version", Version.self)
        } catch { dlclose(handle); throw error }
        self.handle = handle
    }
}

/// This object stays alive until the synchronous native call and all its callbacks
/// finish. Callback strings/entry structures are copied before returning to C++.
private final class NativeCall: @unchecked Sendable {
    let cancellation: ArchiveCancellation
    let onEvent: @Sendable (ArchiveEvent) -> Void
    private let lock = NSLock()
    private var entries: [ArchiveEntry] = []
    private var output = ""
    private var warnings: [String] = []
    init(cancellation: ArchiveCancellation, onEvent: @escaping @Sendable (ArchiveEvent) -> Void) {
        self.cancellation = cancellation; self.onEvent = onEvent
    }
    func message(_ text: String, severity: Int32) {
        lock.lock()
        output += text + "\n"
        if output.utf8.count > 100_000 { output = String(output.suffix(80_000)) }
        if severity == 1 { warnings.append(text) }
        lock.unlock()
        onEvent(.log(text + "\n"))
    }
    func entry(_ value: SZBEntry) {
        guard let path = value.path else { return }
        let flags = value.flags
        let item = ArchiveEntry(path: String(cString: path),
            size: flags & UInt32(SZB_ENTRY_HAS_SIZE) != 0 ? value.size : nil,
            packedSize: flags & UInt32(SZB_ENTRY_HAS_PACKED_SIZE) != 0 ? value.packed_size : nil,
            modified: flags & UInt32(SZB_ENTRY_HAS_MODIFIED) != 0 ? Date(timeIntervalSince1970: Double(value.modified_seconds)) : nil,
            isDirectory: flags & UInt32(SZB_ENTRY_DIRECTORY) != 0,
            encrypted: flags & UInt32(SZB_ENTRY_ENCRYPTED) != 0)
        lock.lock(); entries.append(item); lock.unlock()
    }
    func finish(_ code: Int32) throws -> ArchiveListing {
        try cancellation.check()
        lock.lock(); defer { lock.unlock() }
        if code == SZB_CANCELLED { throw ArchiveError.cancelled }
        guard code == SZB_OK || code == SZB_WARNING else {
            throw ArchiveError.operationFailed(exitCode: code, output: output)
        }
        let warningMessages = code == SZB_WARNING && warnings.isEmpty ? [output] : warnings
        return ArchiveListing(entries: entries, result: ArchiveOperationResult(exitCode: code, output: output, warnings: warningMessages))
    }
    func invoke(_ body: (UnsafePointer<SZBCallbacks>) -> Int32) throws -> ArchiveListing {
        try cancellation.check()
        var callbacks = SZBCallbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.progress = { context, completed, total in
            guard let context, total > 0 else { return }
            let call = Unmanaged<NativeCall>.fromOpaque(context).takeUnretainedValue()
            call.onEvent(.progress(min(1, Double(completed) / Double(total))))
        }
        callbacks.is_cancelled = { context in
            guard let context else { return 1 }
            return Unmanaged<NativeCall>.fromOpaque(context).takeUnretainedValue().cancellation.isCancelled ? 1 : 0
        }
        callbacks.message = { context, severity, text in
            guard let context, let text else { return }
            Unmanaged<NativeCall>.fromOpaque(context).takeUnretainedValue().message(String(cString: text), severity: severity)
        }
        callbacks.entry = { context, value in
            guard let context, let value else { return }
            Unmanaged<NativeCall>.fromOpaque(context).takeUnretainedValue().entry(value.pointee)
        }
        let result = try finish(withUnsafePointer(to: &callbacks, body))
        onEvent(.progress(1))
        return result
    }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    if let value, !value.isEmpty { return try value.withCString(body) }
    return try body(nil)
}

/// Owns one contiguous allocation for each UTF-8 path for the duration of a call.
private func withCStringArray<T>(_ values: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) throws -> T) throws -> T {
    var strings: [UnsafeMutablePointer<CChar>] = []
    defer { strings.forEach { free($0) } }
    for value in values {
        guard let copy = strdup(value) else { throw ArchiveError.invalidInput("Not enough memory to prepare archive paths.") }
        strings.append(copy)
    }
    let pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
    return try pointers.withUnsafeBufferPointer { try body($0.baseAddress, $0.count) }
}

/// All archive operations call libSevenZip's C ABI directly in this process.
/// Callbacks execute off the main actor. No executable, shell, pipe or CLI text
/// parser is used. Native calls are serialized; 7-Zip may use its own workers.
public final class ArchiveEngine: @unchecked Sendable {
    public let libraryURL: URL
    public init(libraryURL: URL) { self.libraryURL = libraryURL }
    private static let worker = DispatchQueue(label: "org.sevenzip.archive-engine", qos: .userInitiated)

    public func list(archive: URL, password: String? = nil,
                     cancellation: ArchiveCancellation = .init(),
                     onEvent: @escaping @Sendable (ArchiveEvent) -> Void = { _ in }) async throws -> ArchiveListing {
        try await perform(cancellation: cancellation) {
            try self.requireFile(archive); try self.validatePassword(password)
            let library = try NativeLibrary.load(self.libraryURL)
            let call = NativeCall(cancellation: cancellation, onEvent: onEvent)
            return try archive.path.withCString { path in
                try withOptionalCString(password) { password in try call.invoke { library.list(path, password, $0) } }
            }
        }
    }

    public func create(inputs: [URL], archive: URL, format: ArchiveFormat,
                       compressionLevel: Int = 5, password: String? = nil,
                       cancellation: ArchiveCancellation = .init(),
                       onEvent: @escaping @Sendable (ArchiveEvent) -> Void = { _ in }) async throws -> ArchiveOperationResult {
        try await perform(cancellation: cancellation) {
            let fm = FileManager.default
            guard !inputs.isEmpty else { throw ArchiveError.invalidInput("Select files or folders to compress.") }
            guard archive.isFileURL else { throw ArchiveError.invalidInput("The archive destination must be a local file.") }
            guard (0...9).contains(compressionLevel) else { throw ArchiveError.invalidInput("The compression level must be between 0 and 9.") }
            try self.validatePassword(password, creating: format)
            guard !self.exists(archive) else { throw ArchiveError.invalidInput("The archive already exists. Choose a different name.") }
            let parent = archive.deletingLastPathComponent()
            let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey])
            guard parentValues.isDirectory == true else { throw ArchiveError.invalidInput("The destination folder does not exist.") }
            let library = try NativeLibrary.load(self.libraryURL)
            // Enumerate before creating the temporary output; compressing the output's
            // parent directory must not recursively include the archive being written.
            let records = try self.inputRecords(inputs, cancellation: cancellation)
            let temporary = parent.appendingPathComponent(".sevenzip-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temporary) }
            let output = temporary.appendingPathComponent("archive.\(format.rawValue)")
            let call = NativeCall(cancellation: cancellation, onEvent: onEvent)
            let result = try withCStringArray(records.map(\.source)) { sources, count in
                try withCStringArray(records.map(\.path)) { paths, _ in
                    try output.path.withCString { outputPath in
                        try withOptionalCString(password) { password in
                            try call.invoke { library.create(outputPath, format == .zip ? Int32(SZB_FORMAT_ZIP) : Int32(SZB_FORMAT_7Z), Int32(compressionLevel), password, sources, paths, count, $0) }.result
                        }
                    }
                }
            }
            try cancellation.check()
            // On the same volume, publish atomically with exclusive destination
            // semantics. A file created by another app during compression is retained.
            let renamed = output.withUnsafeFileSystemRepresentation { source in
                archive.withUnsafeFileSystemRepresentation { destination in
                    renamex_np(source!, destination!, UInt32(RENAME_EXCL))
                }
            }
            if renamed != 0 {
                if errno == EEXIST { throw ArchiveError.invalidInput("The archive already exists. It was not overwritten.") }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return result
        }
    }

    /// Updates the existing 7z/ZIP handler directly. Unchanged entries remain in
    /// the archive; the original file is retained as a recoverable backup.
    public func update(archive: URL, adding inputs: [URL] = [], inDirectory directory: String = "",
                       removing entries: [String] = [], password: String? = nil,
                       cancellation: ArchiveCancellation = .init(),
                       onEvent: @escaping @Sendable (ArchiveEvent) -> Void = { _ in }) async throws -> ArchiveOperationResult {
        try await perform(cancellation: cancellation) {
            try self.requireFile(archive)
            guard let format = ArchiveFormat(rawValue: archive.pathExtension.lowercased()) else {
                throw ArchiveError.invalidInput("Only 7z and ZIP archives can be edited.")
            }
            guard !inputs.isEmpty || !entries.isEmpty else {
                throw ArchiveError.invalidInput("Select files to add or archive items to remove.")
            }
            try self.validatePassword(password, creating: format)
            guard directory.isEmpty || self.safeArchivePath(directory), entries.allSatisfy(self.safeArchivePath) else {
                throw ArchiveError.invalidInput("Archive item paths must be safe relative paths.")
            }
            let initial = try FileSnapshot(archive)
            guard initial.isRegular else {
                throw ArchiveError.invalidInput("The archive must be a regular file, not a symbolic link.")
            }
            let originalFD = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard originalFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(originalFD) }
            guard flock(originalFD, LOCK_EX | LOCK_NB) == 0 else {
                throw ArchiveError.invalidInput("The archive is being edited by another process.")
            }
            // Enumerate before creating recovery files. Reject any input tree
            // containing the archive, including a hard-link alias of that file.
            let records = try self.inputRecords(inputs, cancellation: cancellation)
            for record in records {
                let source = try FileSnapshot(URL(fileURLWithPath: record.source))
                guard !initial.sameIdentity(as: source) else {
                    throw ArchiveError.invalidInput("An archive cannot be added to itself.")
                }
                guard self.safeArchivePath(record.path) else {
                    throw ArchiveError.invalidInput("Input names must be safe relative archive paths.")
                }
            }
            let paths = records.map { directory.isEmpty ? $0.path : directory + "/" + $0.path }
            let fm = FileManager.default
            let backups = archive.deletingLastPathComponent().appendingPathComponent(".sevenzip-backups", isDirectory: true)
            if mkdir(backups.path, 0o700) != 0 && errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard try FileSnapshot(backups).isDirectory else {
                throw ArchiveError.invalidInput("The archive backup location is not a regular directory.")
            }
            let transaction = backups.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var published = false
            defer { if !published { try? fm.removeItem(at: transaction) } }
            // After RENAME_SWAP this same URL points to the previous original.
            let backup = transaction.appendingPathComponent(archive.lastPathComponent)
            let library = try NativeLibrary.load(self.libraryURL)
            let call = NativeCall(cancellation: cancellation, onEvent: onEvent)
            var result = try withCStringArray(records.map(\.source)) { sources, count in
                try withCStringArray(paths) { paths, _ in
                    try withCStringArray(entries) { deleted, deletedCount in
                        try archive.path.withCString { archivePath in
                            try backup.path.withCString { outputPath in
                                try withOptionalCString(password) { password in
                                    try call.invoke {
                                        library.update(archivePath, outputPath,
                                            format == .zip ? Int32(SZB_FORMAT_ZIP) : Int32(SZB_FORMAT_7Z),
                                            password, sources, paths, count, deleted, deletedCount, $0)
                                    }.result
                                }
                            }
                        }
                    }
                }
            }
            // Updating is transactional: warnings never publish a partial result.
            guard result.exitCode == SZB_OK, result.warnings.isEmpty else {
                throw ArchiveError.operationFailed(exitCode: result.exitCode, output: result.output)
            }
            let outputFD = open(backup.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard outputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(outputFD) }
            guard fchmod(outputFD, initial.permissions) == 0, fsync(outputFD) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try cancellation.check()
            guard initial == (try FileSnapshot(archive)) else {
                throw ArchiveError.invalidInput("The archive changed while it was being edited. It was not replaced.")
            }
            let exchanged = backup.withUnsafeFileSystemRepresentation { source in
                archive.withUnsafeFileSystemRepresentation { destination in
                    renamex_np(source!, destination!, UInt32(RENAME_SWAP))
                }
            }
            guard exchanged == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // No throwing/cancellation work after the commit. Always retain the
            // previous archive, including when cancellation races with commit.
            published = true
            result.backupURL = backup
            return result
        }
    }

    public func extract(archive: URL, destination: URL, entries: [String]? = nil, password: String? = nil,
                        cancellation: ArchiveCancellation = .init(),
                        onEvent: @escaping @Sendable (ArchiveEvent) -> Void = { _ in }) async throws -> ArchiveOperationResult {
        try await perform(cancellation: cancellation) {
            try self.requireFile(archive); try self.validatePassword(password)
            guard destination.isFileURL else { throw ArchiveError.invalidInput("The extraction destination must be a local folder.") }
            if let entries {
                guard !entries.isEmpty else { throw ArchiveError.invalidInput("Select at least one archive item.") }
                guard !entries.contains(where: { $0.contains("\0") }) else { throw ArchiveError.invalidInput("Archive paths cannot contain NUL characters.") }
            }
            let library = try NativeLibrary.load(self.libraryURL)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let call = NativeCall(cancellation: cancellation, onEvent: onEvent)
            return try archive.path.withCString { archivePath in
                try destination.path.withCString { destinationPath in
                    try withOptionalCString(password) { password in
                        if let entries {
                            return try withCStringArray(entries) { selected, count in
                                try call.invoke { library.extract(archivePath, destinationPath, selected, count, password, $0) }.result
                            }
                        }
                        return try call.invoke { library.extract(archivePath, destinationPath, nil, 0, password, $0) }.result
                    }
                }
            }
        }
    }

    public func test(archive: URL, password: String? = nil,
                     cancellation: ArchiveCancellation = .init(),
                     onEvent: @escaping @Sendable (ArchiveEvent) -> Void = { _ in }) async throws -> ArchiveOperationResult {
        try await perform(cancellation: cancellation) {
            try self.requireFile(archive); try self.validatePassword(password)
            let library = try NativeLibrary.load(self.libraryURL)
            let call = NativeCall(cancellation: cancellation, onEvent: onEvent)
            return try archive.path.withCString { path in
                try withOptionalCString(password) { password in try call.invoke { library.test(path, password, $0) }.result }
            }
        }
    }

    private func safeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return !parts[0].contains(":")
    }
    private struct FileSnapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init(_ url: URL) throws {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
        var isRegular: Bool { mode & S_IFMT == S_IFREG }
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var permissions: mode_t { mode & 0o7777 }
        func sameIdentity(as other: FileSnapshot) -> Bool { device == other.device && inode == other.inode }
    }

    private func validatePassword(_ password: String?, creating format: ArchiveFormat? = nil) throws {
        guard let password else { return }
        guard !password.contains("\0") else { throw ArchiveError.invalidInput("Passwords cannot contain NUL characters.") }
        if format == .zip && (!password.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) || password.utf8.count > 99) {
            throw ArchiveError.invalidInput("ZIP passwords must use printable ASCII characters, up to 99 characters. Choose 7z for a Unicode password.")
        }
    }
    private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }
    private func requireFile(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0"), exists(url) else { throw ArchiveError.invalidInput("File does not exist: \(url.path)") }
    }
    private struct InputRecord { let source: String; let path: String }
    private func inputRecords(_ inputs: [URL], cancellation: ArchiveCancellation) throws -> [InputRecord] {
        let fm = FileManager.default
        var names = Set<String>()
        var records: [InputRecord] = []
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        func append(_ url: URL, path: String) throws {
            try cancellation.check()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw ArchiveError.invalidInput("Symbolic links and special files are not supported: \(url.path)")
            }
            records.append(InputRecord(source: url.path, path: path))
        }
        for original in inputs {
            try requireFile(original)
            let input = original.standardizedFileURL
            let name = input.lastPathComponent
            guard !name.isEmpty, name != "/", names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ArchiveError.invalidInput("Selected items have duplicate names. Rename them first: \(name)")
            }
            try append(input, path: name)
            if try input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                var traversalError: Error?
                let traversalRoot = input.resolvingSymlinksInPath()
                guard let enumerator = fm.enumerator(at: traversalRoot, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
                    traversalError = error; return false
                }) else { throw ArchiveError.invalidInput("Unable to read folder: \(input.path)") }
                let prefix = traversalRoot.path.hasSuffix("/") ? traversalRoot.path : traversalRoot.path + "/"
                while let enumerated = enumerator.nextObject() as? URL {
                    let child = enumerated.standardizedFileURL
                    guard child.path.hasPrefix(prefix) else { throw ArchiveError.invalidInput("Unable to determine a relative archive path.") }
                    try append(child, path: name + "/" + child.path.dropFirst(prefix.count))
                }
                if let traversalError { throw traversalError }
            }
        }
        return records
    }
    private func perform<T: Sendable>(cancellation: ArchiveCancellation, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.worker.async {
                    do { try cancellation.check(); continuation.resume(returning: try work()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}
