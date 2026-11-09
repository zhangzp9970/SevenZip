import AppKit
import SwiftUI

// An explicit wrapper alias also supports Command Line Tools SDKs without SwiftUI macro plugins.
typealias ViewState<Value> = SwiftUI.State<Value>

private let accent = Color.accentColor

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var localization = Localization.shared
    @ViewState private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isHome { welcome }
            else { fileTable }
            if model.isBusy { progressArea }
            if model.showLog { logArea }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.locale, localization.locale)
        .frame(minWidth: 560, minHeight: 400)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent, style: StrokeStyle(lineWidth: 3, dash: [8])))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.receive(urls); return !urls.isEmpty
        } isTargeted: { dropTarget = $0 }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .compress(let urls): CompressionSheet(model: model, inputs: urls)
            case .extract(let urls, let entries): ExtractionSheet(model: model, archives: urls, entries: entries)
            case .password(let url): PasswordSheet(model: model, archive: url)
            }
        }
        .alert(L10n.tr("操作未完成"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L10n.tr("好"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var fileTable: some View {
        Table(model.items, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn(L10n.tr("名称"), sortUsing: BrowserSortComparator<BrowserItem>(.name)) { item in
                HStack(spacing: 8) {
                    if item.isDirectory {
                        Image(nsImage: AppArtwork.folderIcon)
                            .resizable().renderingMode(.original).scaledToFit()
                            .frame(width: 19, height: 19)
                    } else if let icon = AppArtwork.archiveIcon(for: item.name) {
                        Image(nsImage: icon)
                            .resizable().renderingMode(.original).scaledToFit()
                            .frame(width: 19, height: 19)
                    } else {
                        Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 19)
                    }
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.encrypted { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }.width(min: 210, ideal: 320)
            TableColumn(L10n.tr("大小"), sortUsing: BrowserSortComparator<BrowserItem>(.size)) { item in Text(item.sizeText).monospacedDigit().foregroundStyle(.secondary) }.width(min: 70, ideal: 85, max: 105)
            TableColumn(L10n.tr("类型"), sortUsing: BrowserSortComparator<BrowserItem>(.kind)) { item in Text(item.type).foregroundStyle(.secondary) }.width(min: 65, ideal: 85, max: 115)
            TableColumn(L10n.tr("修改日期"), sortUsing: BrowserSortComparator<BrowserItem>(.modified)) { item in
                if let date = item.modified { Text(date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
                else { Text("—").foregroundStyle(.tertiary) }
            }.width(min: 130, ideal: 160, max: 190)
        }
        .font(.system(size: 13))
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                if model.archiveURL != nil {
                    if ids.count == 1 {
                        Button { model.activate(ids) } label: {
                            Label(L10n.tr("打开"), systemImage: "arrow.up.forward.app")
                        }
                    }
                    Button { model.selection = ids; model.beginExtraction(selectedOnly: true) } label: {
                        Label(L10n.tr("解压所选项目…"), systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button {
                        model.selection = ids
                        model.deleteSelectedArchiveItems()
                    } label: {
                        Label(L10n.tr("从归档中删除…"), systemImage: "trash")
                    }.disabled(!model.canModifyArchive)
                } else {
                    Button { model.selection = ids; model.beginCompression() } label: {
                        Label(L10n.tr("压缩所选项目…"), systemImage: "archivebox")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(model.items.filter { ids.contains($0.id) }.compactMap(\.url))
                    } label: {
                        Label(L10n.tr("在 Finder 中显示"), systemImage: "folder")
                    }
                }
            }
            if model.archiveURL != nil {
                Button(action: model.beginAddingFiles) {
                    Label(L10n.tr("添加文件…"), systemImage: "plus")
                }.disabled(!model.canModifyArchive)
            }
        } primaryAction: { ids in model.activate(ids) }
        .overlay {
            if model.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.search.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text(model.search.isEmpty ? L10n.tr("此目录为空") : L10n.tr("未找到匹配的项目")).foregroundStyle(.secondary)
                }.allowsHitTesting(false)
            }
        }
        .disabled(model.isBusy)
    }
    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center, spacing: 22) {
                    Image(nsImage: AppArtwork.applicationIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("每一份文件，妥善收纳。")).font(.system(size: 26, weight: .semibold))
                        Text(L10n.tr("浏览归档、压缩文件，或把内容解压到你需要的位置。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.top, 13)
                HStack(spacing: 14) {
                    welcomeAction(L10n.tr("打开压缩包"), subtitle: L10n.tr("先浏览内容，再选择解压"), symbol: "folder", action: model.chooseArchive)
                    welcomeAction(L10n.tr("创建压缩包"), subtitle: L10n.tr("将文件与文件夹打包为 7z 或 ZIP"), symbol: "archivebox") { model.beginCompression() }
                }
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 27, weight: .light)).foregroundStyle(accent.opacity(0.7))
                    Text(L10n.tr("将文件拖到窗口中")).font(.system(size: 13, weight: .medium))
                    Text(L10n.tr("压缩包会打开浏览；其他文件会进入压缩设置。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 27)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                if !model.recentURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("最近打开")).font(.system(size: 13, weight: .semibold))
                        ForEach(Array(model.recentURLs.prefix(4)), id: \.path) { url in
                            Button { model.openArchive(url) } label: {
                                HStack(spacing: 12) {
                                    if let icon = AppArtwork.archiveIcon(for: url.lastPathComponent) {
                                        Image(nsImage: icon).resizable().renderingMode(.original).scaledToFit()
                                            .frame(width: 26, height: 30)
                                    } else {
                                        Image(systemName: "doc.zipper").foregroundStyle(accent).font(.system(size: 20)).frame(width: 26)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                                        Text(url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                }.padding(.vertical, 7).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.seal")
                        Text(L10n.tr("支持 7z、ZIP、RAR、TAR 等常用格式的解压"))
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(38).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }.disabled(model.isBusy)
    }
    private func welcomeAction(_ title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(20).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.13)))
        }.buttonStyle(.plain)
    }
    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.jobTitle.text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if let progress = model.jobProgress { Text("\(Int(progress * 100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                Button(L10n.tr("取消"), action: model.cancel).font(.system(size: 11))
            }
            if let progress = model.jobProgress { ProgressView(value: progress) }
            else { ProgressView().progressViewStyle(.linear) }
        }.padding(18).background(accent.opacity(0.05))
    }
    private var logArea: some View {
        ScrollView {
            Text(model.jobLog.isEmpty ? L10n.tr("暂无任务日志") : model.jobLog)
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.frame(height: 135).background(Color(nsColor: .controlBackgroundColor))
    }
}
