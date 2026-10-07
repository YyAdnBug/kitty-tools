---
name: mac-clipboard
description: 原生分支剪贴板历史规范（采集、存储、上限、搜索性能、面板交互与视觉、界面自检）。在修改 macos/KittyTools/Clipboard/**、Storage/Database.swift、Storage/Backup.swift、Settings/ClipboardTab.swift 前必须先读；或涉及 ClipboardStore / ClipboardWatcher / changeCount / 隐私标记 / 排除 App / 敏感文本 / 图片去重 / OCR / 搜索慢 / 保留天数 / 图片占用 / 收藏 / 收藏夹 / 片段 / 备注 / 片段占位符 {cursor} {clipboard:N} / 撤销栈 / 默认纯文本粘贴 / 多选粘贴 / 暂停记录 / 面板快捷键 / ⌘K 子列表 / 右键菜单 / 钉到屏幕 / 拖到别的 App / 面板视觉 / 透镜 Lens Bar / 筛选标签 / Tab 筛选 / 截图自检 / 数据库每日备份 / 数据打不开时的恢复 / damaged 文件夹等问题时。
---

# mac-clipboard

动手前先读同目录 `rule.mdc` 全文（正文唯一数据源：`.cursor/rules/mac-clipboard.mdc`）。

红线速查：
- 留下的条目只看 `ClipItem.isRetained`（收藏 ∨ 片段；收藏夹里的都是收藏，备注不算）；天数与图片占用、清空只动普通历史。
- 同内容再复制 = 原条目置顶（保留 id / 收藏 / 备注 / 收藏夹），删了还没提交的也拿回来。
- 搜索必须走 `ClipboardStore.search`（折叠缓存 + memmem，只过滤不排序、照样按天分组），改内容要清 `searchKeys`。
- 删除进撤销栈，⌘Z 连着撤，面板收起 / 退出 App 时才 `commitDeletion`；旧库升级在 `ClipboardStore.migrate`（幂等）。
- 交互：单击选中、双击（以第一下选中的为准）或 ↩ 粘贴、⌥↩ 纯文本（开了「默认粘贴为纯文本」反过来）、⌘↩ 仅复制（收起面板时再置顶）、
  ⌘1–9 直接粘贴、删除不确认可撤销；Tab 筛选面板、⇧Tab 换范围、→ 开 ⌘K、搜索为空时 ⌫ 两下删标签；Esc 逐级退出（固定着也关）；⌘P 固定、⌘W 关闭（对话框开着时先只关对话框）、⌘, 直达设置 › 剪贴板。本 App 生成的新文字经 `Paster.write(string:record: true)` 记进历史（体检 A30）。
- 右键菜单和 ⌘K 是同一份动作表（`actions(for:targets:)`，只用缓存过的判断）；操作对象 `targets` 只算看得见的勾选项；条目从列表消失的改动包在 `changingList` 里（选中挪到下一条）；⌘T ⌘O ⌘R ⌥⌘C 按类型；打开 / 在访达中显示 / 钉到屏幕没固定先收起；拖出去走 `ClipDrag`（AppKit 会话，不算粘贴）。
- 界面 = 透镜指令条 Lens Bar（720 顶锚、单列、选中行原地展开成透镜）：透镜按类型定高（常数，不量不估），上下键不改窗口高度；行标题已原样显示全的文本不画第二遍、透镜只剩元信息行（`ClipRowView.showsWholeText`，只看条目自己的数据）；范围和筛选只以搜索框里的标签出现；筛选面板和 ⌘K 共用 `Shell/ActionMenu.swift`。
- 缩略图缓存有上限（rule §1）：行图标进 `ThumbnailView.icons`（按张数），透镜和 ⌘Y 大卡进 `previews`（cost 按「宽 × 高 × 4 × 2」，48 MB），大卡档在大卡放掉时整档丢，面板都收起两分钟后 `previews` 整个清掉（空闲回收，行图标不清）；别再加不封顶的图片缓存，改上限前后跑内存探针对数。
- 后台识字在子进程里（rule §1）：`recognizePendingImages` → `OCR.recognizeTextInHelper`（本 App 带 `--ocr`），不成退回进程内识一次；⌥O 识字、截图翻译、钉图识字照旧进程内，别挪；模型闲下来由空闲回收放掉（`OCR.releaseModel()`，Vision 的私有接口，不在就不放）。
- 每日备份、打不开时的恢复在 `Storage/Backup.swift`（rule §1）：**备份里只有用户留下的**（收藏 / 片段 / 收藏夹里的条目、收藏夹、生词本、启动器收藏），普通剪贴板历史、没收藏的翻译、启动器使用记录不进备份（`Backup.dropped`；剪贴板的条件是 `ClipItem.retainedSQL`，和 `isRetained` 一起改）；另开只读连接在主线程外做，先 `quick_check` 再 `VACUUM INTO`，在拷出来的那份上删行、再 `VACUUM`、查过才轮换，坏库不备份也不动已有的备份；打不开时让用户选用备份 / 重新开始 / 退出，出问题的库**连 `-wal`、`-shm`** 挪进 `damaged-…/`（旧 `-wal` 留在原地会被重放到恢复出来的库上），不删、不循环。
- 界面自检用 SnapshotProbeTests（屏幕外渲染）；禁止为截图在用户使用时弹出面板。
