# ly minis 定制版

基于 [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis) `main` 快照。

- App 显示名：`ly minis`
- Bundle ID：`com.ly.minis`
- 上游许可证：GPL-3.0，未移除上游版权与许可证文件
- 本仓库只包含源码；iOS 构建需要 macOS + Xcode，按 `BUILDING.md` 初始化 submodules 和 native dependencies

## 注入 ly 人格

将本目录下的 `ly-profile/SOUL.md` 复制到应用运行时的 skills/memory 配置目录，或在首次启动后通过应用设置导入。不要把 API key 写进源码。
