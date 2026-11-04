# WCGlass Offline — Rootless starter

独立重写的起步工程，不包含原 WCGlass 的二进制、专有源码或授权逻辑，也不连接原作者服务器。

## 构建
- Rootless Theos package，最低 iOS 15.0，依赖 ElleKit。
- GitHub Actions 只监听 `wcglass-offline-rootless` 分支中的本目录变更，也可手动运行。
- 构建产物在 Actions 的 Artifacts 中下载。

## 当前限制
此工程尚未实际编译或真机验证。当前只尝试 hook 系统 `UINavigationBar` 和 `UITabBar`；最新版微信可能使用自定义界面组件，不能保证所有页面生效。微信 Bundle ID `com.tencent.xin` 仍需在目标设备确认。请先在测试设备验证并备份。
