---
name: mac-overlay-panel
description: 原生分支 macOS 热键浮层规范（OverlayPanel、全局热键、粘贴回原 App、浮层内输入框、划词时序、截图翻译框选遮罩、长截图、录屏）。在修改 macos/KittyTools/Shell/**、macos/KittyTools/Screenshot/**、macos/KittyTools/Translate/SelectionReader.swift、Translate/SourceTextView.swift 前必须先读；或涉及 截图 / 截图翻译 / 长截图 / 滚动截图 / 录屏 / SCRecordingOutput / 录制边框 / 录制 HUD / 倒数 / 临时 Esc 热键 / 菜单栏停止项 / 录屏飞入 / 视频卡 / 录屏声音 / 系统声音 / 麦克风授权 / 麦克风断开 / 显示点按 / 点按圈 / 显示按键 / 按键提示 / 按键胶囊 / InputOverlay / 录音 / 录音控制条 / 待录 / 立即开始录音 / AVAudioRecorder / 录系统声音 / 录音来源 / 只录声音 / 导出 m4a / 电平 / 没听到声音 / 录音卡 / 录屏录音互斥 / 转成 GIF / GIF 卡 / 冻结帧 / 框选遮罩 / 窗口吸附 / 放大镜取色 / 钉图 / 常驻缩略图 / 快速保存目录 / 屏幕录制授权 / ScreenCaptureKit / NSPanel / nonactivatingPanel / 浮层不显示或抢前台 / 点外关闭 / Esc / 固定图钉 / RegisterEventHotKey / 热键冲突 / 模拟 ⌘V ⌘C / 粘贴失败 / 输入法在浮层里异常 / 划词取不到词 / 设置窗被压在后面等问题时。
---

# mac-overlay-panel

动手前先读同目录 `rule.mdc` 全文（正文唯一数据源：`.cursor/rules/mac-overlay-panel.mdc`）。

红线速查：
- 浮层只用 `OverlayPanel`；显示只走 `present()`，永远不对浮层 `NSApp.activate`。（例外：截图框选遮罩 `SelectionOverlay` 见 rule §8、钉图 `PinPanel` 见 §9、长截图面板 `ScrollCapturePanel` 见 §10）
- 截图 / 截图翻译先截后选（冻结帧），截屏前先查屏幕录制授权；识字不给语言提示；遮罩画面走图层，不在 draw 里重画整张冻结帧；窗口吸附只读冻结时的 Z 序快照。
- 钉图出现时不 makeKey（不抢键盘），原位置出现；按键同截图出图（⌘S 快速保存、⇧⌘S 另存为、O 识字，体检 C9 D17），按键、右键菜单和 VoiceOver 动作查同一份 `commands`；长截图时和选区相交的钉图让开（B40）。
- 录屏（rule §10 开头）：框选同截图（`SelectionView` 的 `.record` 模式），交回选区后在实时画面上录；`isCapturing` 只占框选阶段，录制状态在 `ScreenRecorder`；录制委托 nonisolated（mac-native §3）；本 App 的窗口按白名单列进过滤器例外（`ScreenCapture.recordedOwnWindows`）；边框、停止项、录制 HUD 是普通实例（HUD 状态栏层级、永不当 key，倒数的 Esc 是 `HotKeyCenter.registerEscape` 临时热键、只挂那几秒，rule §1 §4）；截图调整时按 R 切成录屏（有标注不切）；停止后最后一帧（`Result.poster`，按视频轨的结束取）按 S1 飞入、交给常驻缩略图的视频卡（`ShelfCard.Kind.video`，不另写卡片；拷贝经 `Paster.write(files:)`）；录制条的声音 / 点按开关记偏好、开录读一次（录什么挂什么空输出），麦克风授权在遮罩收起后、倒数前问（rule §8）；点按圈自己画（`InputOverlay`：层级 popUpMenu + 2 的普通 NSPanel，不用系统的 `showMouseClicks` / BGRA；窗口号由 `ScreenRecorder.exceptedOwnWindows` 并进过滤器例外，`recordedOwnWindows` 不改；本 App 窗口上的点按只画一次轻点，录不进画面的自家窗口上不画，rule §10「点按圈」）；按键提示也在 `InputOverlay`（录制条第四个开关「显示按键」，rule §10「按键提示」）：global + local 的 keyDown 监听（global 要辅助功能授权，不用 CGEventTap），键名复用 `HotKey.display`，内容和停手清空是纯状态 `InputOverlay.Keys`，本 App 的全局快捷键被 Carbon 吃掉、由 AppDelegate 的热键处理补给 `showKey`（停止录屏那一下不补），本 App 自己的密码框拿着键盘时不显示，本进程自己发的合成按键（粘贴的 ⌘V、`{cursor}` 的 ←、划词的 ⌘C）按事件源进程号滤掉（`isSynthesized`）；没有辅助功能授权时照样开录、不显示、开关弹回，系统设置放到收尾才打开（rule §8，同麦克风；两项授权都没有时警告岛并成一条、系统设置只开麦克风页）。
- 录音（rule §10「录音」）：`AudioRecorder` 分两个阶段（手测反馈第 3 批）——`open()` 待录只出控制条（不写「进行中」偏好、不建文件、不问授权、没有停止项；控制条的来源开关照写 `Prefs.audioRecordSource`），`start()` 才读来源、问 `allowsStart`、开录；待录不算在录（菜单标题、互斥、更新只看 `isStarted`，要录屏 / 退出时 `close()` 当场收掉）；设置 › 截图「按快捷键后立即开始录音」开着时直接 `start()`。AVAudioRecorder 主线程直接用、不挂委托，HUD 是 `RecordingHUD` 的 `.audio` 形态（窗口四周留 24 pt 透明边，位置按 `screenFrame` 算），录音卡是 `ShelfCard.Kind.audio`；收尾挪文件、闪退恢复、结果岛、停止项和录屏共用 `ScreenRecorder`（`Medium`），不另写一份；录屏和录音互斥（截图里按 R 那一刻就拦，`AppDelegate.recordingBlocker` 一处判断）；锁屏 / 显示器睡眠照录，系统睡眠 / 输入设备断开 / 磁盘不足停。来源是系统声音 / 两者时（第 6 批）复用录屏管线：`ScreenRecorder(…, audioOnly:)` 当引擎（左上角 64 × 64 点、1 fps、不出录屏 chrome，`onStarted` / `onHalted` / `onLevel` 交回），不能暂停（⏸ 置灰）、锁屏会停，收尾 `extractAudio` 导出 m4a（asset 留到导出完）；样本回调里只算 dB 投出来。
- 转成 GIF（rule §8 末尾，录屏录音第 7 批）：只有视频卡有「转成 GIF」，卡片持有转换 `Task`、被关掉就取消；`VideoExport.gif` 是 `@concurrent`，`CGImageDestination` 必须关全局调色板（`kCGImagePropertyGIFHasGlobalColorMap = false`），否则 Finalize 时整段帧一起量化、几百 MB；GIF 卡是 `ShelfCard.Kind.gif`。
- 长截图：框完收起遮罩在实时画面上截（`captureImage(contentFilter:configuration:)` + `sourceRect`，filter 滤掉本 App）；拼接只用逐行哈希投票，不换 Vision 配准；页脚宁大勿小；自动滚动先把光标挪进选区、移出即停。
- 标注显示与导出共用 `Annotation.drawAll`；输出一律用合成图（打码后的内容识别不出来）；文字输入用 NSTextView + `doCommandBy`。
- 剪贴板面板、启动器点外关（鼠标监听成对装卸，兄弟浮层豁免）；启动器没有固定，没执行就收起的 60 秒内再呼出保留查询（体检 A27）；两者同一位置（顶部 20%、宽 720），只开一个；翻译浮窗失焦关；固定只管点别处 / 失焦不收起，Esc、⌘W（OverlayPanel 统一处理）、再按热键一律收起（体检 A9）。
- 两张 ⌘Y 大卡由 `TransientPanel` 拿着（rule §1）：用时再建、收起 2 秒后放掉；要显示走 `open()`，对开着的那块做事读 `.panel`（nil = 没开着，别为了问一句去建）。三块主面板和设置窗一直留着，不照这个改。
- 浮层里的输入框只用 `CommandTextField` / `SourceTextView`（doCommandBy），不用 `.onKeyPress` 抢方向键和回车。
- 热键非独占，跨进程冲突检测不到。
- 粘贴：hide → `Paster.write` → `pasteToFrontmost`，不加等待，⌘V 显式 `.maskCommand`。
- 划词：复制完成前禁止显示翻译浮窗。
