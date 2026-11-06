# 7-Zip 上游源码

`7zip/` 保存 SevenZip 动态库依赖的上游源码，直接随本仓库提交，不使用 Git submodule。

- 上游仓库：https://github.com/ip7z/7zip
- 版本：26.05（2026-10-21）
- 上游提交：`b88c6bc09339de32f7d18bbab900686b244f42ba`
- 版本定义：`7zip/C/7zVersion.h`

导入时完整保留上游的 `Asm/`、`C/`、`CPP/`、`DOC/` 和 `README.md`；这些文件没有功能修改。上游 `.gitattributes` 规则保留在本仓库根目录。SevenZip 的桥接实现和构建适配位于根目录的 `Native/` 与 `BridgeAPI/`，不混入上游源码。

上游许可证及版权说明完整保留在 `7zip/DOC/`，其中 `License.txt`、`copying.txt` 和 `unRarLicense.txt` 会随应用打包。各文件的许可仍以上游声明为准。

升级时保持上述目录布局，更新此处的版本、日期和提交记录，然后在仓库根目录执行 `./build.sh` 及四份 `check*.sh` 脚本验证兼容性。
