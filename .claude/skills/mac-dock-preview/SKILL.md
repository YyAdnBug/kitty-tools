---
name: mac-dock-preview
description: 程序坞预览（第九族）的行为红线速查：私有接口和退路、听程序坞、列窗口、缩略图、切 / 关窗口、面板和时机（按鼠标位置收、不用滚动）、默认关和授权、内存、测试口径。改 KittyTools/DockPreview/** 或 Settings/DockPreviewTab.swift 前先读。
---

# mac-dock-preview（速查）

完整规矩在 `rule.mdc`（= `.cursor/rules/mac-dock-preview.mdc`）；长相和动效在 `mac-whisker` 技能的 `dock-preview.mdc`。动手前读全文；下面只是最容易被忘的几条。

- 私有接口只在 `WindowServer.swift`，运行时 `dlsym`、取不到就退回公开做法；**加新的私有接口先问用户**；第一次取符号在主线程（`prepare()`）。
- 「当 key」事件：0x100 清零、只发按下、坐标在窗口外很远（AltTab 踩过的坑），别改回老写法。
- 程序坞是 LSUIElement、没有启动通知：靠每 5 秒体检重挂。图标位置用之前 `currentFrame` 重读。
- 收不收按鼠标位置（弹着时 0.1 s 一次 `keepsOpen` + `Linger`），**不用追踪区进出**；面板永不当 key，**不用滚动视图**，放不下换行。
- 不在任何桌面上的窗口不列；缩略图一扇扇串行截；配进程先解开链接（Safari 是链接）。
- 功能开关默认关；空闲回收时收着的面板整块放掉。
- 单测只测纯函数；探针 `TEST_RUNNER_KITTY_DOCK_PROBE=1`（内存那项在屏幕右上角放一块几乎透明的面板约两秒）；截图自检 `SnapshotProbeTests.dockPreview()`；不切 / 关窗口、不挪鼠标。
