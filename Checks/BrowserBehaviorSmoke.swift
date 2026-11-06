import Foundation

@main
struct BrowserBehaviorSmoke {
    static func main() throws {
        var history = BrowserHistory(initial: "home")
        precondition(history.backIndex == nil && history.forwardIndex == nil)
        history.commit("folder")
        history.commit("archive.zip")
        history.commit("archive.zip/documents")
        history.commit("archive.zip/documents") // Refreshing does not grow history.
        precondition(history.locations.count == 4)
        history.commit(history.locations[history.backIndex!], restoring: history.backIndex!)
        precondition(history.locations[history.index] == "archive.zip" && history.forwardIndex == 3)
        history.commit(history.locations[history.backIndex!], restoring: history.backIndex!)
        precondition(history.locations[history.index] == "folder")
        let failedDestination = history.forwardIndex!
        // A failed load never commits a destination.
        precondition(history.index == 1 && failedDestination == 2)
        history.commit("new-folder")
        precondition(history.locations == ["home", "folder", "new-folder"] && history.forwardIndex == nil)
        history.replaceCurrent("refreshed-folder")
        precondition(history.locations.count == 3 && history.locations[history.index] == "refreshed-folder")

        for bad in ["", "/absolute.txt", "../escape.txt", "a/../escape.txt", "a//b", "a/./b", "C:/escape", "a\\b", "a\0b"] {
            precondition(!TemporaryDocument.isSafeArchivePath(bad), bad)
        }
        precondition(TemporaryDocument.isSafeArchivePath("文稿/报告.docx"))
        let first = try TemporaryDocument.prepare(path: "文稿/报告.docx")
        let second = try TemporaryDocument.prepare(path: "文稿/报告.docx")
        defer { first.discardFailedExtraction(); second.discardFailedExtraction() }
        precondition(first.directory != second.directory)
        let mode = try FileManager.default.attributesOfItem(atPath: first.directory.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o700)
        try FileManager.default.createDirectory(at: first.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("document".utf8).write(to: first.file)
        try first.validateExtractedFile()
        precondition(TemporaryDocument.openingMode(for: first.file) == .defaultApplication)
        let scripts: [(String, String)] = [
            ("Preview.py", "print('Preview only')\n"),
            ("Preview.sh", "#!/bin/sh\necho 'Preview only'\n"),
            ("Preview.PY", "MZ = 'a variable, not a binary signature'\n"),
            ("Preview.command", "#!/bin/zsh\necho 'Preview only'\n"),
            ("Preview.js", "console.log('Preview only');\n"),
            ("Preview", "#!/usr/bin/env python3\nprint('Preview only')\n")
        ]
        for (name, contents) in scripts {
            let file = first.directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            precondition(TemporaryDocument.openingMode(for: file) == .textEditor, name)
        }
        for ext in ["app", "exe", "scpt", "scptd", "jar", "workflow"] {
            precondition(TemporaryDocument.openingMode(for: first.directory.appendingPathComponent("Program." + ext)) == .blockedExecutable)
        }
        let disguisedBinary = first.directory.appendingPathComponent("Program.py")
        for signature: [UInt8] in [[0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0x7f, 0x45, 0x4c, 0x46], [0x4d, 0x5a, 0x90, 0]] {
            try Data(signature).write(to: disguisedBinary)
            precondition(TemporaryDocument.openingMode(for: disguisedBinary) == .blockedExecutable)
        }
        let source = first.directory.appendingPathComponent("Preview.py")
        let editor: [String: Any] = ["CFBundleDocumentTypes": [["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.text"]]]]
        let legacyEditor: [String: Any] = ["CFBundleDocumentTypes": [["CFBundleTypeRole": "Editor", "CFBundleTypeExtensions": ["PY"]]]]
        let runner: [String: Any] = ["CFBundleDocumentTypes": [["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.python-script"]]]]
        let unrelatedEditor: [String: Any] = ["CFBundleDocumentTypes": [["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.directory"]]]]
        precondition(TemporaryDocument.isTextEditor(applicationInfo: editor, for: source))
        precondition(TemporaryDocument.isTextEditor(applicationInfo: legacyEditor, for: source))
        precondition(!TemporaryDocument.isTextEditor(applicationInfo: runner, for: source))
        precondition(!TemporaryDocument.isTextEditor(applicationInfo: unrelatedEditor, for: source))
        for identifier in ["com.apple.Terminal", "com.googlecode.iterm2", "org.python.PythonLauncher"] {
            var info = editor
            info["CFBundleIdentifier"] = identifier
            precondition(!TemporaryDocument.isTextEditor(applicationInfo: info, for: source))
        }
        try FileManager.default.removeItem(at: first.file)
        try FileManager.default.createSymbolicLink(at: first.file, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        do { try first.validateExtractedFile(); preconditionFailure("Preview followed a symbolic link") }
        catch { }
        print("PASS: navigation history, private staging, safe paths, symlink rejection, script editor routing and binary rejection")
    }
}
