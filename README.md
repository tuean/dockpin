# DockPin

[![build](https://github.com/tuean/dockpin/actions/workflows/build.yml/badge.svg)](https://github.com/tuean/dockpin/actions/workflows/build.yml)

**Keep the macOS Dock on the display you choose — it stops wandering to other screens.**

一个原生 Swift 写的菜单栏小工具：把 Dock 钉死在你指定的那块屏幕上，其他屏再怎么蹭底边也招不走它；睡眠唤醒、插拔显示器之后如果 Dock 落到了错的屏，还会自动把它拉回来。

```
菜单栏 📌  →  Dock 当前在：Built-in Retina Display
             锁定到：       ▸ Built-in Retina Display / DELL U2720Q / ...
             ☑ 启用固定（按住 ⌥ 临时放行）
```

---

## 为什么 Dock 会乱跑

macOS 的 Dock 是"跟着边缘走"的：它只能停在**外侧没有其他屏幕**的那条边上。几种常见的错位场景：

- 屏幕摆成**左右并排**——每块屏的左右边都可能是"空"的，鼠标一蹭边缘 Dock 就滑过去；
- **合盖 / 拔插 / 唤醒**之后，系统重算排列，Dock 留在原来的坐标上，但那个坐标已经属于另一块屏；
- 想让它待在**非主屏**上（比如合盖办公时锁到外接屏），系统没有提供这个开关。

## 方案对比

| 方案 | 效果 | 代价 |
|---|---|---|
| 系统开关：设置 → 桌面与程序坞 → 调度中心 → 关掉「显示器具有单独的空间」，注销重登 | Dock 和菜单栏只留在主屏 | 每块屏不再有独立空间，Mission Control 跨屏统一 |
| **DockPin（本工具）** | Dock 钉在你选的屏，**保留**每屏独立空间 | 需要辅助功能权限 |

## 原理

1. 用**辅助功能（Accessibility）** 权限装一个 `CGEventTap`，只订阅 `mouseMoved`；
2. 鼠标进入**非目标屏**的 Dock 边缘带（厚度取实际 Dock 厚度，通常是 75pt）时，**吞掉那条事件**——Dock 收不到"指针到边了"的信号，就不会滑出来；
3. 按住 **⌥ Option** 时全部放行，临时想在别的屏用 Dock 不受影响；
4. 监听 `NSApplication.didChangeScreenParametersNotification` 与 `NSWorkspace.didWakeNotification`：如果此刻 Dock 落在非目标屏，就把指针瞬移到目标屏的 Dock 边、再瞬移回来，把 Dock "招"回去。

判断 Dock 在哪块屏只靠 `visibleFrame` 与 `frame` 的边距差——不需要任何权限，也不依赖系统语言（`CGWindowListCopyWindowInfo` 里 Dock 的进程名是本地化的，不可靠）。

## 构建

需要 Xcode Command Line Tools（`xcode-select --install`），不需要开发者证书：

```bash
git clone https://github.com/tuean/dockpin.git
cd dockpin
./build.sh          # 产出 DockPin.app（ad-hoc 签名）
open DockPin.app
```

## 安装与授权

1. 首次启动会弹「DockPin 想要控制这台电脑」，去 **系统设置 → 隐私与安全性 → 辅助功能** 打开它；没弹窗就点 `+` 手动添加 `DockPin.app`。
2. 授权后 2 秒内自动生效，菜单里的状态会变成「已授予」。
3. 开机自启：**系统设置 → 通用 → 登录项** → `+` 选 `DockPin.app`。

> ⚠️ TCC 按**路径 + 签名**记录权限。把 `.app` 挪到别的位置（比如 `/Applications`）之后需要重新授权一次——先放定位置再授权。

## 命令行

```bash
DockPin.app/Contents/MacOS/DockPin --status     # 屏幕布局、Dock 边距、Dock 当前所在屏
DockPin.app/Contents/MacOS/DockPin --anchor     # 立刻把 Dock 拉回目标屏
DockPin.app/Contents/MacOS/DockPin --selftest   # 检查辅助功能权限与事件闸能否建立
```

日志：`~/Library/Logs/DockPin.log`。

## 限制

- 必须给辅助功能权限；没有它事件闸建不起来，只剩"手动拉回"。
- Dock 设成**自动隐藏**时，无法从 `visibleFrame` 判断它所在屏，"自动拉回"失效（手动可用）。
- 只拦 `mouseMoved`，不拦拖拽，避免影响拖窗口 / 拖文件。
- 屏幕在**堆叠**排列下（外接屏的底边被主屏顶住），Dock 本来就跑不掉，此时本工具不会有可见变化——那是系统行为，不是工具失效。
- 已在 macOS 27.2 (26B123) / Apple Silicon 上测试，最低支持 macOS 13。

## 许可证

MIT
