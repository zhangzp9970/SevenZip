import AppKit
import ArchiveCore
import SwiftUI

private func chooseDirectory(start: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.title = L10n.tr("选择目标文件夹"); panel.prompt = L10n.tr("选择")
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = true; panel.directoryURL = start
    return panel.runModal() == .OK ? panel.url : nil
}

private struct SheetHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 21, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct DirectoryPicker: View {
    @Binding var directory: URL
    var body: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(directory.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Button(L10n.tr("选择…")) { if let chosen = chooseDirectory(start: directory) { directory = chosen } }
        }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct CompressionSheet: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: AppModel
    let inputs: [URL]
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name: String
    @ViewState private var directory: URL
    @ViewState private var useZIP = false
    @ViewState private var level = 5
    @ViewState private var password = ""
    @ViewState private var confirmation = ""

    init(model: AppModel, inputs: [URL]) {
        self.model = model; self.inputs = inputs
        _name = State(initialValue: inputs.count == 1 ? inputs[0].lastPathComponent : L10n.tr("归档"))
        _directory = State(initialValue: inputs.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser)
    }
    private var fileName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) + (useZIP ? ".zip" : ".7z") }
    private var output: URL { directory.appendingPathComponent(fileName) }
    private var validation: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.tr("请输入归档名称。") }
        if name.contains("/") || name.contains(":") || name.contains("\0") { return L10n.tr("名称不能包含 /、: 或空字符。") }
        if FileManager.default.fileExists(atPath: output.path) { return L10n.tr("此名称已存在，请换一个名称。") }
        if password.contains("\0") { return L10n.tr("密码不能包含空字符。") }
        if useZIP && (!password.unicodeScalars.allSatisfy { (32...126).contains($0.value) } || password.utf8.count > 99) {
            return L10n.tr("ZIP 密码请使用不超过 99 个英文、数字或半角符号；中文密码请选 7z。")
        }
        if password != confirmation { return L10n.tr("两次输入的密码不一致。") }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(title: L10n.tr("创建压缩包"), subtitle: L10n.format("%d 个项目 · 选择格式与保存位置", inputs.count), symbol: "archivebox")
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("所选项目")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(inputs, id: \.path) { url in
                            Label(url.lastPathComponent, systemImage: "doc").font(.system(size: 12)).help(url.path)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 66)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.tr("归档名称")).font(.system(size: 12, weight: .medium))
                HStack {
                    TextField(L10n.tr("名称"), text: $name).textFieldStyle(.roundedBorder)
                    Text(useZIP ? ".zip" : ".7z").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 35)
                }
                Text(L10n.tr("保存到")).font(.system(size: 12, weight: .medium)).padding(.top, 4)
                DirectoryPicker(directory: $directory)
            }
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("格式")).font(.system(size: 12, weight: .medium))
                    Picker(L10n.tr("格式"), selection: $useZIP) {
                        Text("7z").tag(false); Text("ZIP").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("压缩等级")).font(.system(size: 12, weight: .medium))
                    Picker(L10n.tr("压缩等级"), selection: $level) {
                        Text(L10n.tr("仅存储")).tag(0); Text(L10n.tr("快速")).tag(1); Text(L10n.tr("标准")).tag(5); Text(L10n.tr("最大")).tag(9)
                    }.labelsHidden().frame(width: 230)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("密码（可选）")).font(.system(size: 12, weight: .medium))
                HStack {
                    SecureField(L10n.tr("设置密码"), text: $password)
                    SecureField(L10n.tr("再次输入"), text: $confirmation)
                }.textFieldStyle(.roundedBorder)
                Text(useZIP ? L10n.tr("加密 ZIP 使用 AES-256，需要支持此加密方式的解压软件。") : L10n.tr("加密 7z 同时保护文件内容与文件名。"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let validation { Text(validation).font(.system(size: 11)).foregroundStyle(.orange) }
            Divider()
            HStack {
                Text(fileName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("开始压缩")) {
                    model.createArchive(inputs: inputs, output: output, format: useZIP ? .zip : .sevenZip,
                        level: level, password: password.isEmpty ? nil : password)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }.padding(28).frame(width: 520).interactiveDismissDisabled(model.isBusy)
    }
}

struct ExtractionSheet: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: AppModel
    let archives: [URL]
    let entries: [String]?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var directory: URL
    @ViewState private var subfolder = true
    @ViewState private var password = ""

    init(model: AppModel, archives: [URL], entries: [String]?) {
        self.model = model; self.archives = archives; self.entries = entries
        _directory = State(initialValue: archives.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            SheetHeading(title: L10n.tr("解压文件"), subtitle: entries.map { L10n.format("解压所选 %d 个项目", $0.count) } ?? L10n.tr("解压全部内容"), symbol: "square.and.arrow.up")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(archives, id: \.path) { url in Label(url.lastPathComponent, systemImage: "doc.zipper").font(.system(size: 13)) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("解压到")).font(.system(size: 12, weight: .medium))
                DirectoryPicker(directory: $directory)
                Toggle(L10n.tr("为归档创建同名文件夹"), isOn: $subfolder).font(.system(size: 12)).disabled(archives.count > 1)
                if subfolder, let first = archives.first {
                    Text(L10n.format("目标：%@", directory.appendingPathComponent(AppModel.archiveStem(first)).path))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("归档密码（如有）")).font(.system(size: 12, weight: .medium))
                SecureField(L10n.tr("留空以使用打开归档时的密码"), text: $password).textFieldStyle(.roundedBorder)
            }
            Label(L10n.tr("已有文件会保留，同名文件会自动重命名。"), systemImage: "doc.on.doc")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("开始解压")) {
                    model.extract(archives: archives, destination: directory, subfolder: subfolder,
                        entries: entries, password: password.isEmpty ? nil : password)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 520)
    }
}

struct PasswordSheet: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: AppModel
    let archive: URL
    @ViewState private var password = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: L10n.tr("归档已加密"), subtitle: archive.lastPathComponent, symbol: "lock.doc")
            Text(L10n.tr("请输入正确的密码以继续操作。")).font(.system(size: 12)).foregroundStyle(.secondary)
            SecureField(L10n.tr("密码"), text: $password).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { model.cancelPasswordRequest(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("继续")) { model.submitPassword(password, for: archive) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }.padding(28).frame(width: 410)
    }
}
