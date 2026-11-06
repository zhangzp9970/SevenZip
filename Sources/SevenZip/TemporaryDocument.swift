import Foundation
import UniformTypeIdentifiers

/// A successful document is kept in the system temporary directory so another
/// application can continue to read or edit it after SevenZip closes.
struct TemporaryDocument {
    let directory: URL
    let file: URL

    static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            && !(parts.first?.contains(":") ?? true)
    }

    static func prepare(path: String) throws -> TemporaryDocument {
        guard isSafeArchivePath(path) else { throw CocoaError(.fileReadInvalidFileName) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SevenZip-Preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return TemporaryDocument(directory: root, file: root.appendingPathComponent(path))
    }

    /// Validate every component again after extraction before handing it to an
    /// external application. The extraction bridge independently rejects links.
    func validateExtractedFile() throws {
        let fm = FileManager.default
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().path == file.path,
              file.path.hasPrefix(directory.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        _ = try fm.attributesOfItem(atPath: file.path)
    }

    enum OpeningMode { case defaultApplication, textEditor, blockedExecutable }

    /// Source scripts are documents even when their archive entry has executable
    /// permissions. They must be sent explicitly to an editor, never a runner.
    static func openingMode(for url: URL) -> OpeningMode {
        let ext = url.pathExtension.lowercased()
        let prefix: [UInt8]
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            prefix = Array((try? handle.read(upToCount: 256)) ?? Data())
        } else { prefix = [] }
        // Mach-O (including universal binaries), ELF, PE/DOS and Java bytecode
        // remain executables even if given a source-code filename.
        let binarySignatures: Set<[UInt8]> = [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
            [0x7f, 0x45, 0x4c, 0x46]
        ]
        if binarySignatures.contains(Array(prefix.prefix(4)))
            || (prefix.starts(with: [0x4d, 0x5a]) && prefix.contains(0)) { return .blockedExecutable }
        let executableExtensions: Set<String> = ["app", "scpt", "workflow", "jar", "terminal", "action", "scptd", "exe", "com", "class"]
        if executableExtensions.contains(ext) { return .blockedExecutable }
        let sourceExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh", "py", "pyw", "rb", "pl", "pm", "js", "mjs", "cjs", "ts", "jsx", "tsx", "ps1", "bat", "cmd", "command", "tool", "applescript", "lua", "r", "php", "swift"]
        let declaredType = UTType(filenameExtension: ext)
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if sourceExtensions.contains(ext) || prefix.starts(with: [0x23, 0x21])
            || declaredType?.conforms(to: .script) == true || contentType?.conforms(to: .script) == true {
            return .textEditor
        }
        if declaredType?.conforms(to: .executable) == true || contentType?.conforms(to: .executable) == true
            || (ext.isEmpty && FileManager.default.isExecutableFile(atPath: url.path)) { return .blockedExecutable }
        return .defaultApplication
    }

    /// Inspect the chosen application's declared document role. Launch Services
    /// may associate .command or .py with Terminal/Python Launcher (role Shell),
    /// while an Editor association such as VS Code should be respected.
    static func isTextEditor(applicationInfo: [String: Any], for url: URL) -> Bool {
        let identifier = (applicationInfo["CFBundleIdentifier"] as? String)?.lowercased() ?? ""
        let runners: Set<String> = ["com.apple.terminal", "com.googlecode.iterm2", "org.python.pythonlauncher"]
        guard !runners.contains(identifier), let documents = applicationInfo["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        return documents.contains { declaration in
            guard (declaration["CFBundleTypeRole"] as? String)?.lowercased() == "editor" else { return false }
            let extensions = (declaration["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() }
            if extensions.contains(ext) || extensions.contains("*") { return true }
            return (declaration["LSItemContentTypes"] as? [String] ?? []).contains { identifier in
                guard let acceptedType = UTType(identifier) else { return false }
                return type?.conforms(to: acceptedType) == true || UTType.plainText.conforms(to: acceptedType)
            }
        }
    }

    /// Call only for operations that failed before any external application was
    /// launched. Successfully opened files belong to the system temp lifecycle.
    func discardFailedExtraction() { try? FileManager.default.removeItem(at: directory) }
}
