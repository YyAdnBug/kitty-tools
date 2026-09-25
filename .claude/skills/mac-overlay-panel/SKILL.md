---
name: mac-overlay-panel
description: 原生分支 macOS 热键浮层规范（OverlayPanel、全局热键、粘贴回原 App、浮层内输入框、划词时序、截图翻译框选遮罩、长截图）。在修改 macos/KittyTools/Shell/**、macos/KittyTools/Screenshot/**、macos/KittyTools/Translate/SelectionReader.swift、Translate/SourceTextView.swift 前必须先读；或涉及 截图 / 截图翻译 / 长截图 / 滚动截图 / 冻结帧 / 框选遮罩 / 窗口吸附 / 放大镜取色 / 钉图 / 屏幕录制授权 / ScreenCaptureKit / NSPanel / nonactivatingPanel / 浮层不显示或抢前台 / 点外关闭 / Esc / 固定图钉 / RegisterEventHotKey / 热键冲突 / 模拟 ⌘V ⌘C / 粘贴失败 / 输入法在浮层里异常 / 划词取不到词 / 设置窗被压在后面等问题时。
---

# mac-overlay-panel

动手前先读同目录 `rule.mdc` 全文（正文唯一数据源：`.cursor/rules/mac-overlay-panel.mdc`）。

红线速查：
- 浮层只用 `OverlayPanel`；显示只走 `present()`，永远不对浮层 `NSApp.activate`。（例外：截图框选遮罩 `SelectionOverlay` 见 rule §8、钉图 `PinPanel` 见 §9、长截图面板 `ScrollCapturePanel` 见 §10）
- 截图 / 截图翻译先截后选（冻结帧），截屏前先查屏幕录制授权；识字不给语言提示；遮罩画面走图层，不在 draw 里重画整张冻结帧；窗口吸附只读冻结时的 Z 序快照。
- 钉图出现时不 makeKey（不抢键盘），原位置出现。
- 长截图：框完收起遮罩在实时画面上截（`captureImage(contentFilter:configuration:)` + `sourceRect`，filter 滤掉本 App）；拼接只用逐行哈希投票，不换 Vision 配准；页脚宁大勿小；自动滚动先把光标挪进选区、移出即停。
- 标注显示与导出共用 `Annotation.draw`；输出一律用合成图（打码后的内容识别不出来）；文字输入用 NSTextView + `doCommandBy`。
- 剪贴板面板点外关（鼠标监听成对装卸，兄弟浮层豁免）；翻译浮窗失焦关；固定时翻译浮窗 Esc 也不关。
- 浮层里的输入框只用 `CommandTextField` / `SourceTextView`（doCommandBy），不用 `.onKeyPress` 抢方向键和回车。
- 热键非独占，跨进程冲突检测不到；共存期间清空 Tauri 的同名热键。
- 粘贴：hide → `Paster.write` → `pasteToFrontmost`，不加等待，⌘V 显式 `.maskCommand`。
- 划词：复制完成前禁止显示翻译浮窗。
