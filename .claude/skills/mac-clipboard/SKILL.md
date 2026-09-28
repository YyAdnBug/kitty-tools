---
name: mac-clipboard
description: 原生分支剪贴板历史规范（采集、存储、上限、搜索性能、面板交互与视觉、界面自检）。在修改 macos/KittyTools/Clipboard/**、Storage/Database.swift、Settings/ClipboardTab.swift 前必须先读；或涉及 ClipboardStore / ClipboardWatcher / changeCount / 隐私标记 / 排除 App / 敏感文本 / 图片去重 / OCR / 搜索慢 / 条数天数上限 / 收藏片段分组 / 片段光标 {cursor} / 撤销删除 / 面板快捷键 / 面板视觉 / 透镜 Lens Bar / 筛选标签 / Tab 筛选 / 截图自检等问题时。
---

# mac-clipboard

动手前先读同目录 `rule.mdc` 全文（正文唯一数据源：`.cursor/rules/mac-clipboard.mdc`）。

红线速查：
- 留下的条目只看 `ClipItem.isRetained`；上限与清空只动普通历史。
- 同内容再复制 = 原条目置顶（保留 id / 收藏 / 备注 / 分组）。
- 搜索必须走 `ClipboardStore.search`（折叠缓存 + memmem），改内容要清 `searchKeys`。
- 交互：单击选中、双击（以第一下选中的为准）或 ↩ 粘贴、⌥↩ 纯文本、⌘↩ 仅复制、⌘1–9 直接粘贴、删除不确认可撤销；Tab 筛选面板、⇧Tab 换范围、→ 开 ⌘K、搜索为空时 ⌫ 两下删标签；Esc 逐级退出（固定着也关）；⌘P 固定、⌘W 关闭（对话框开着时先只关对话框）、⌘, 直达设置 › 剪贴板。本 App 生成的新文字经 `Paster.write(string:record: true)` 记进历史（体检 A30）。
- 界面 = 透镜指令条 Lens Bar（720 顶锚、单列、选中行原地展开成透镜）：透镜按类型定高（常数，不量不估），上下键不改窗口高度；范围和筛选只以搜索框里的标签出现；筛选面板和 ⌘K 共用 `Shell/ActionMenu.swift`。
- 界面自检用 SnapshotProbeTests（屏幕外渲染）；禁止为截图在用户使用时弹出面板。
