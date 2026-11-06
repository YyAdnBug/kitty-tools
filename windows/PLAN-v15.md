# Kitty Tools Windows 版：第十五版方案（截图拷贝为文件）

2026-11-06。用户转来的需求：「截图可以增加复制图像为文件的选项吗，跟 PixPin 一样的，用对拷线发现截图复制不过去对话框，PixPin 就行」。
两台电脑用 USB 对拷线共用剪贴板时，对拷线的配套软件只搬文字和文件，截图拷贝放进剪贴板的是图像（`PNG` + `CF_DIBV5`），半路就丢了。
拍板页 https://claude.ai/artifact/Fbr36YjckBeUPs1UcxKPhJ（Q1–Q8），用户「全部按推荐」；Q1 定的是 **mac 先做、Windows 照同一套跟上**——就是这一份。

**这一版不是新的拍板页**：行为、默认值、文案照 mac（本机分支 `copyfile-wip`，检出 `kitty-tools-macos-copyfile`，没 push、没并进 `macos`）。
分工照 PLAN-v11 D10：**审查方已经在 Mac 上写完、没编译**，Windows 的 agent 编译、核验、手测，交接在 `REVIEW.md`「PLAN-v15」。

## 1. 做了什么（同 mac）

- **设置 › 截图「截图拷贝为　图像｜PNG 文件」**，默认图像（`Settings.ScreenshotCopyAs`：`image` / `file`，键名和值同 mac `screenshotCopyAs`，跟着导出导入）。
  在「快速保存到」下面，说明一句：「选 PNG 文件时，剪贴板里是一个图片文件，和复制一个文件一样：能粘进聊天窗口和文件夹，只认文件的跨电脑剪贴板工具也传得过去；只收图像的程序粘不进去」。
- **截图里的每一种「拷贝」都走 `ScreenshotOutput.CopyPngAsync`**：框选后的拷贝、长截图、长图标注（这三处本来就走它）、角落缩略图、钉图、截图历史的单条拷贝（这三处原来各写各的，收进来了）。
  选了文件时：
  - 剪贴板里**只放这个文件**（`ClipboardWriter.WriteFiles`：`CF_HDROP` + `Preferred DropEffect` = 复制，同在资源管理器里复制一个文件；拍板 Q3）；写不成照旧放图像。
  - 文件是 `%TEMP%\kitty-shots\copy\<编号>\截图 日期 时间.png`，每次一个新子文件夹；截图历史那条用拖出去的那一份（`DragFile`：存过的就是存的那个文件，别的是 `history\<id>\` 下的成品）。
  - 剪贴板历史照旧记成图片（Q5：临时文件清掉以后这条照样能用）；提示的小字写文件名（拷成图像时照旧写尺寸，钉图照旧不写）。
- **临时文件夹的清理**（Q4）：启动时整个清空（原来就清第一层的 PNG 和 `history\`，加上 `copy\`）；`ScheduleBackup`（启动、解锁、唤醒时的每日维护）里删一天以前的
  （`ScreenshotOutput.PurgeStaleTemp` → Core `ShotHistoryRules.StaleTemp`：第一层的 PNG、`history` / `copy` 下的子文件夹，按改于认；时间比现在还晚的不删）。
- **不跟这个设置**：识字、截图翻译（文字），剪贴板历史里的图片条目再粘贴，便签里的图片，截图历史多选拷贝（本来就是文件）。只做 PNG（Q8）。
- 设置搜索加「拷贝、复制、文件、PNG、对拷线、远程」，页头说明加「拷贝为图像还是文件」。

## 2. 和 mac 不一样的地方

- 截图历史单条拷贝成文件时，**存过盘、文件还在的给的是存的那个文件**（Windows 的 `DragFile` 本来就这样）；mac 一律是历史里的原图 + 现在的标注、借存过的文件名（mac R2）。
  两边拖出去本来就不一样，这次不动，记在这里。
- 清理挂在每日维护上（启动 / 解锁 / 唤醒），mac 挂在系统的换日通知上：Windows 没有换日事件，`ScheduleBackup` 是现成的那一处。

## 3. 手测

`HANDTEST.md` 末尾「PLAN-v15 截图拷贝为文件」1148–1154（照 mac「截图拷贝为文件」1–7 改写）。对拷线那一条只有用户能测。
