---
name: mac-launchpad
description: 启动台（第八族）的行为红线速查：模型和不变式、App 目录、布局存哪、全屏面板、入口和互斥、触控板捏合、触发角、旧库导入、删 App、测试口径。改 KittyTools/Launchpad/** 或 Settings/LaunchpadTab.swift 前先读。
---

# mac-launchpad（速查）

完整规矩在 `rule.mdc`（= `.cursor/rules/mac-launchpad.mdc`）。动手前读全文；下面只是最容易被忘的几条。

- 和现有的「启动器」（`Launcher/`）是两个东西：名字、设置、快捷键分开。
- 布局是纯函数的事（`LaunchpadLayout`），界面不许自己拼页数组；不变式由随机操作测试锁住。文件夹 7 × 5 = 35 个一页；页边界保住，只有超容量才往后推。
- 面板是自建窗口的新例外（mac-overlay-panel §1）：无边框、不激活本 App、能当 key、层级 `.statusBar`、**每次打开新建、收起放掉**。
- 键盘走 `CommandTextField` 的 `doCommandBy`，**不装全局按键监听**；两指滑从面板 `sendEvent` 进。
- 截图 / 录屏 / 状态屏 / 正在录快捷键时不响应；打开别的功能时先收起。
- 私有 MultitouchSupport 只运行时 `dlopen` / `dlsym`；回调只拷触点、派回主线程；单测不注册回调。
- 旧启动台库只读**拷贝**（`file:…?mode=ro`；**不能加 `immutable=1`**，会跳过 -wal），不碰原件；单测自己造小库。
- 单测里不 `makeKey`、不启动 App；截图自检只跑 `SnapshotProbeTests.launchpad()`。
