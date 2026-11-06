# SevenZip for macOS

基于本仓库 7-Zip 引擎的原生 macOS 界面。使用 SwiftUI / AppKit；应用内附带从源码编译的 `libSevenZip.dylib`，通过 C ABI 直接调用，无需安装 Homebrew、Python 或额外运行库。此界面是独立的 macOS 前端，并非 7-Zip 官方发布的 macOS 图形界面。

当前版本提供：归档目录浏览与搜索、最近打开、本地目录浏览、ZIP / 7z 压缩与内容更新、全部或所选项目解压、密码、完整性测试、进度与取消，以及 Finder 服务。双击归档默认先浏览内容。新建归档不会覆盖已有归档；解压时保留已有文件并自动重命名冲突项。

打开可写的 7z 或 ZIP 后，可向当前归档目录添加文件或文件夹、替换同名文件，以及删除所选项目；删除文件夹会包含其后代。同名替换和删除会先确认。更新先写入临时归档，成功后原子替换；原文件保存在同目录的隐藏路径 `.sevenzip-backups/<UUID>/<原归档名>`，可通过完成后的“显示备份”定位并恢复。取消或失败时不会发布未完成的归档。其他格式暂不支持内容更新，也不支持分卷创建。

双击归档内的普通文档时，应用会将该文件解压到独立、私有的临时目录，再交给系统默认应用打开，例如用 Word 打开 `.docx`。Python、Shell 等文本脚本会交给已关联的编辑器打开；默认关联是脚本运行器或没有合适的编辑器时，使用 TextEdit 查看源码。真正的可执行程序仍需要先手动解压。临时副本在成功打开后保留，由系统临时目录生命周期管理，SevenZip 退出时不会主动删除；在外部应用中保存的修改**不会自动写回原归档**，需要时可使用“添加”替换对应文件。

ZIP 的加密方式为 AES-256，密码须为不超过 99 个可打印 ASCII 字符；需要中文密码时请选择 7z。创建加密 7z 时也加密文件名。

## 构建

需要 Apple Silicon Mac，以及包含 macOS 26 或更新 SDK 的 Apple Command Line Tools。应用最低运行版本为 macOS 13，macOS 26/27 使用原生 Liquid Glass。无需安装完整 Xcode 即可构建应用和运行 smoke 检查。

```bash
xcode-select --install # 已安装 Command Line Tools 时跳过
# 在本仓库根目录（Package.swift 所在目录）执行
./build.sh
```

脚本固定编译 **arm64** 的 7-Zip 动态库与 Swift 界面，生成 `dist/SevenZip.app`。打包时检查主程序和动态库都只有 arm64 切片；不生成 Intel 或 Universal 包。编译产物和模块缓存均在 `.build/`。可用 `SEVENZIP_BUILD_JOBS=4 ./build.sh` 调整引擎编译并发数。

脚本只构建、打包并进行本地 ad-hoc 签名，不会安装、启动应用或修改系统文件关联。此开发包**未使用 Developer ID 签名，也未经过 Apple 公证**；需要对外分发时，应另外完成正式签名、公证及许可证合规工作。

## 系统语言与界面

界面支持 English、简体中文、繁體中文、日本語、Deutsch、Français、Español。按系统首选语言自动选择，未支持的语言回退到英文；兼容中文地区/脚本与其他语言的地区变体。语言或地区通知、用户偏好变化、应用重新激活时会刷新界面和菜单。系统管理的 Finder 服务标题可能要重新打开 Finder 或重新登录才刷新。

`WindowChrome.swift` 使用原生 `NSToolbar`、统一标题栏和系统窗口按钮；左上角的关闭、最小化、全屏按钮由 macOS 自身绘制。`NSSplitViewController` 管理可收起、可调整宽度的原生侧栏；macOS 26/27 自动使用系统 Liquid Glass，较老系统采用相应的原生外观。工具栏使用统一尺寸的单色 SF Symbols，搜索使用 `NSSearchToolbarItem`，支持 ⌘F、即时筛选和系统取消按钮，点击搜索框以外的位置会收起搜索框并保留筛选词。系统的“减少透明度”、强调色与外观设置由系统控制。

侧栏采用 Finder 对应的系统图标，个人收藏提供应用程序、桌面、文稿、下载、图片、音乐和影片快捷入口；位置区域以灰色图标显示已配置的 iCloud Drive、实际名称的用户目录（如 `zzp`）、系统磁盘和已挂载的可浏览卷。文件列表采用系统原生的浅蓝色文件夹图标。应用、Dock 与首页使用同一份蓝色图形资源。

本地目录和归档列表均可点击名称、大小、类型、修改日期列标题排序，再次点击切换升序与降序；排序使用原始大小和日期，文件名采用自然数字顺序，文件夹保持在文件之前。搜索结果也沿用所选排序。

工具栏的后退和前进按钮维护首页、本地文件夹与归档内部目录的浏览历史，对应快捷键为 ⌘[ 和 ⌘]；⌘↑ 返回上一级目录。刷新会保留当前归档目录，不增加历史记录。

## 启动与文件关联

```bash
open dist/SevenZip.app
```

也可以在 Finder 中双击应用。应用提供文件压缩、归档解压和文件拖放入口；压缩支持 ZIP / 7z，解压格式由内置 7-Zip 引擎决定，包括 7z、ZIP、RAR、TAR、GZip、BZip2 和 XZ。RAR 仅支持解压。

应用声明支持常见归档类型，但不会自动抢占默认打开程序。需要关联某种格式时，在 Finder 中选择该格式的文件，打开“显示简介”，在“打开方式”选择 SevenZip，再按需选择“全部更改”。双击归档或从“打开方式”选择 SevenZip，可将归档交给应用。

## Finder 右键菜单

SevenZip 使用 macOS **服务（Services）**提供右键入口：

- **使用 SevenZip 压缩**：接收所选文件和文件夹。
- **使用 SevenZip 解压**：接收所选归档。

为了让 macOS 稳定发现服务，将 `dist/SevenZip.app` 复制到 `/Applications`（或 `~/Applications`），然后至少启动一次。之后在 Finder 选中文件，右键打开“服务”子菜单。根据系统设置和菜单空间，这些服务也可能显示在“快速操作”或 Finder 菜单栏的“服务”中。

如果菜单暂未出现，前往“系统设置 → 键盘 → 键盘快捷键 → 服务”，在“文件和文件夹”一组中启用两个 SevenZip 项目；这里也可以为服务设置快捷键。系统登记可能需要短暂等待，必要时退出并重新打开应用。避免同时保留多个已注册、同名的 SevenZip 开发包。

这是 macOS 服务入口，不是 Finder Sync 扩展，也不保证成为右键菜单顶层项目。注册到系统、安装到应用程序目录以及更改文件关联均由用户自行执行。

## 验证与结构

构建后执行 `./check.sh`，可运行不依赖完整 Xcode 的引擎集成检查，包含普通及加密 ZIP / 7z 的添加、替换、递归删除、空归档、密码失败、取消、原文件备份和外部修改保护。`./check-browser.sh` 检查导航历史、临时文档隔离和路径安全；`./check-sorting.sh` 检查各列排序、自然数字顺序和缺失值；`./check-localizations.sh` 检查语言资源与自动切换。`Tests/ArchiveCoreTests/` 中另有 XCTest 用例；执行 `swift test` 需要提供 XCTest 的完整 Xcode 工具链，部分 Command Line Tools 安装不包含该模块。

- `Sources/ArchiveCore/`：加载动态库，调用类型化接口，接收条目、进度、错误与取消回调。
- `Sources/SevenZip/`：SwiftUI 主界面、操作设置窗口与 AppKit 文件打开、Services 集成。
- `BridgeAPI/include/SevenZipBridge.h`：UTF-8 C ABI，提供 `szb_list` / `szb_create` / `szb_update` / `szb_extract` / `szb_test`。
- `Native/SevenZipBridge.cpp`：使用上游 `IInArchive` / `IOutArchive` 归档接口。
- `Native/build-native.sh`：将上游格式处理器、编解码器和桥接代码编为 `libSevenZip.dylib`。
- `vendor/7zip/`：完整保留上游 `Asm/`、`C/`、`CPP/`、`DOC/` 源码布局；版本与来源记录见 [vendor/README.md](vendor/README.md)。
- `build.sh`：arm64 构建、语言资源打包和本地签名。

仓库根目录是 SevenZip 应用工程，7-Zip 作为随仓库提交的源码依赖放在 `vendor/7zip/`，无需初始化 Git submodule。`.git` 仅位于仓库根目录。构建脚本根据自身位置定位工程，因此本地仓库文件夹可以命名为 `SevenZip` 或其他名称。

```text
SevenZip/
├── Sources/
├── Native/
├── BridgeAPI/
├── Resources/
├── Checks/
├── Tests/
├── vendor/
│   ├── README.md
│   └── 7zip/
│       ├── Asm/
│       ├── C/
│       ├── CPP/
│       ├── DOC/
│       └── README.md
├── Package.swift
├── build.sh
├── check*.sh
└── README.md
```

提交源码时应包含上述目录、脚本和根目录的 `.gitignore`、`.gitattributes`。`.build/`、`dist/` 以及上游命令行工具的生成目录已忽略；发布编译好的应用时，可将打包产物上传至 GitHub Releases。

动态库放在 `Contents/Frameworks/libSevenZip.dylib`。Swift 用 `dlopen` / `dlsym` 加载 C 接口，压缩、更新和解压在应用进程内的工作线程执行，不启动或打包 `7zz` 命令行软件，也不解析终端输出。压缩直接读取原始文件，成功后原子发布临时归档；更新通过上游 `IOutArchive.UpdateItems` 保留未修改条目，由 Swift 层管理原子提交和备份。取消通过回调协作完成。C++ 异常在 ABI 边界转换为状态码。

当前桥接层拒绝符号链接输入及符号/硬链接条目提取；常规文件、目录、多来源选择、密码和选中目录递归提取均由独立集成检查覆盖。GZip、split 等外层容器按单层归档处理，例如 `.tar.gz` 先解出 `.tar`；可再打开该文件继续解压。原始引擎诊断日志使用英文。

## 源码与许可证

界面源码位于 `Sources/SevenZip/`；`Resources/Info.plist` 声明归档关联与 Finder 服务；`Resources/GenerateIcon.swift` 使用 AppKit 绘制原创图标。

7-Zip 版本以仓库的 `vendor/7zip/C/7zVersion.h` 为准。打包时会将 `vendor/7zip/DOC/` 中的 `License.txt`、`copying.txt` 和 `unRarLicense.txt` 复制到应用内 `Contents/Resources/Licenses/`。7-Zip 的主要许可为 GNU LGPL，部分代码使用 BSD 或公有领域许可；RAR 解压代码另有 unRAR 限制，不能用于开发兼容 RAR 的压缩器。分发修改版时应保留相应通知，并提供符合许可证要求的源代码。
