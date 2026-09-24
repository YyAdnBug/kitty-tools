---
name: mac-overlay-panel
description: 原生分支 macOS 热键浮层规范（OverlayPanel、全局热键、粘贴回原 App、浮层内输入框、划词时序）。在修改 macos/KittyTools/Shell/**、macos/KittyTools/Translate/SelectionReader.swift、Translate/SourceTextView.swift 前必须先读；或涉及 NSPanel / nonactivatingPanel / 浮层不显示或抢前台 / 点外关闭 / Esc / 固定图钉 / RegisterEventHotKey / 热键冲突 / 模拟 ⌘V ⌘C / 粘贴失败 / 输入法在浮层里异常 / 划词取不到词 / 设置窗被压在后面等问题时。
---

# mac-overlay-panel

动手前先读同目录 `rule.mdc` 全文（正文唯一数据源：`.cursor/rules/mac-overlay-panel.mdc`）。

红线速查：
- 浮层只用 `OverlayPanel`；显示只走 `present()`，永远不对浮层 `NSApp.activate`。
- 剪贴板面板点外关（鼠标监听成对装卸，兄弟浮层豁免）；翻译浮窗失焦关；固定时翻译浮窗 Esc 也不关。
- 浮层里的输入框只用 `CommandTextField` / `SourceTextView`（doCommandBy），不用 `.onKeyPress` 抢方向键和回车。
- 热键非独占，跨进程冲突检测不到；共存期间清空 Tauri 的同名热键。
- 粘贴：hide → `Paster.write` → `pasteToFrontmost`，不加等待，⌘V 显式 `.maskCommand`。
- 划词：复制完成前禁止显示翻译浮窗。
