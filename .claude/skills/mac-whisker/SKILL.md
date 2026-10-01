---
name: mac-whisker
description: 原生分支的视觉与动效设计语言 Whisker（用户 2026-09-25 拍板「以后都按这个执行，所有效果都要」）。在新建或修改任何界面、面板、卡片、列表、按钮、图标、动画、轻提示、截图遮罩、设置页、菜单栏图标、App 图标之前必须先读；或涉及 样式 / 视觉 / 好看 / 惊艳 / 动效 / 动画 / 弹簧 / 过渡 / 圆角 / 阴影 / 毛玻璃 / 材质 / 配色 / 强调色 / 品牌色 / 选中高亮 / 刘海岛 / 灵动岛 / 轻提示 / HUD / 飞入 / 磁吸 / 显影 / 彗星边框 / 扫光 / Liquid Glass / 录屏点按圈 / 录屏按键胶囊 / 录音控制条待录态 / 减弱动态效果 等问题时。
---

# mac-whisker

动手前先读同目录 `rule.mdc` 全文（正文唯一数据源：`.cursor/rules/mac-whisker.mdc`）。可操作的方案页：https://claude.ai/artifact/1iPQSF1Vr6XswMp4mDkZyN

红线速查：
- 三种皮肤：Panel（系统毛玻璃，深浅跟随设置 › 通用的「外观」，16 pt）/ HUD（永远深色）/ Island（纯黑）。圆角、字号、颜色、曲线只从 `Shell/Style.swift` 取，不硬编码。
- 七条曲线：instant / snap 0.16·0.15 / glide 0.26·0.10 / settle 0.24 / pop 0.32·0.25 / island 0.42·0.22 / retract 0.34，外加 ambient；bounce ≤ 0.25。
- 先瞬时再动画：粘贴、连发、拖动、结果刷新 0 ms；粘贴路径无退场动画。
- 强调色 = `Style.brand`（文字 `Style.brandInk`、填充上的符号 `Style.onBrand`，截图家族 `Style.Shot.accent` / `onAccent`），全 App 统一，取自 `Shell/Accent.swift`：默认跟随系统（系统「多色」= 品牌粉），设置 › 通用可换 8 色；不用 `Color.accentColor` / `controlAccentColor`、不写死品牌粉或白字；只给光标、焦点环、主按钮、当前工具、多选勾、生成中的光；列表选中用中性灰高亮、文字不反白，一块高亮滑动（不用 matchedGeometryEffect）；设置窗侧栏例外：选中自绘，窗口 key 时强调色填充 + `onBrand` 字、否则中性灰（原生高亮关掉，rule §6 设置）；剪贴板的高亮就是透镜的底（按类型定高的常数）。浮起的菜单 / ⌘K 共用 `Shell/ActionMenu.swift`。
- 五个招牌时刻：截图咔嚓飞入（录屏飞最后一帧、录音从 HUD 飞波形，rule §5 S1）、刘海岛、译文显影 + 彗星边框、会呼吸的面板、窗口磁吸——改相关代码不能丢。
- 在 macOS 15 上就要完整，Liquid Glass 只在 `#available(macOS 26, *)` 里替换材质。
- 现成件（体检 2026-09-28）：卡片 `.cardSurface()`（不加阴影）、输入框底 `Style.inputFill`、分隔线 `Hairline()` / 描边 `shape.hairlineBorder()`（增强对比度自动 1 pt，别写死 `lineWidth: 0.5`）、带文字的主按钮 `BrandButtonStyle`（不用 `.borderedProminent` + tint）、复制对勾停 `Style.copiedHold`、列表行悬停 `Shell/HoverTracker`（不用 `onHover`）。
- 减弱动态效果 / 降低透明度 / 增强对比度都要处理；岛和飞行卡片要发 VoiceOver 播报。
- 每个新界面过一遍 rule §10 的检查清单；截图自检补新状态。
