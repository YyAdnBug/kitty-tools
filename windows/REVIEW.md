# windows/REVIEW.md：审查意见

审查方（Claude，在 Mac 上）看完代码或报告后，把要改的写在这里。agent **每一批开始前先看这里**：

- 「待修」的条目先修完，再做那一批；
- 修完把条目挪到「已修」，写上提交号和一句怎么验的；
- 不同意的，在条目下面写理由，挪到「有异议」，照常做下一批，审查方回头再看。

条目编号不复用。行号按条目里写的那个提交。

## 0.2.0 发版前审查（2026-11-12）

审查方在 Mac 上只读代码，没编译。行号都按 `ecd8de3a`。

**审查范围**：`windows-v0.1.2`（45a487d0）..`origin/windows`（ecd8de3a），共 65 个提交：

- PLAN-v11 第 6–8 批：
  - 角落卡改标注、更新跳过 / 退出时装、主界面打字、托盘角标、反馈问题；
  - 指针、桌面图标、裁剪、选麦克风、长图标注；
  - 主界面高亮滑动、浮窗露回来、拉丁字母的语言。
- 用户反馈 11-04（`83040384`）。
- PLAN-v12 第 1–7 批 + 复查：汇率、面板位置、长截图匀速、工具栏靠右、状态屏、提醒。
- PLAN-v13 第 1–8 批 + 复查：便签。
- PLAN-v12 / v13 的 Windows 核验修复（`a2d4885a`…`6710a335`）。
- PLAN-v15：截图拷贝为文件。
- PLAN-v16 第 1–5 批，以及之后的 `b94b1896`、`6bfe3da3`、`ecd8de3a`。
- 0.1.2 热修并回（`1986a4b5`，那几条已随 0.1.2 发出）。
- AOT 运行时钉到 10.0.14（`5fa12aee`）。
- PLAN-v14 / v16 / v17 的方案文档。

**不在这次发布里**：

- PLAN-v17（按应用停用快捷键）只有方案，没写代码。
- PLAN-v11 第 5 批没做。
- 主检出 `kitty-tools-windows` 里，`windows/PLAN-v16.md` 有一段没提交的 §4（启动器搜便携软件，11-10）。
- 本地 `windows` 比 origin 落后一个提交，没有没推的提交。

**怎么审的**：

- 分四路只读审查，各自顺着代码读：
  - 升级、默认值、更新安装卸载；
  - 和 mac 的同步；
  - 状态屏和提醒；
  - 便签的 App 层。
- 下面每条「待修」都对着 HEAD 的代码复核过。
- 纯函数和 golden 在 Windows 上已经过了，没重查：便签 1830 个样本，提醒、状态的逐字节比对。

### 结论：修完 6 处（R69–R74）再发

**必修的四处**，都是几行的改动：

- R69：新装不弹欢迎引导，所有新用户都会碰到。
- R70、R71：状态屏里记的按键状态不对。
- R72：便签或提醒启动时出错，整个 App 就起不来。

**照修、由真机确认的两处**：

- R73：便签正文里拖动图片，会弄乱图片表。
- R74：前台是管理员程序时，状态屏挡不住键盘。

这两处是读代码加上 Windows 的平台行为推出来的，没在机器上复现；改动无害，修完由用户在下面的真机清单里确认。

**没找到的几类大问题**：

- 写坏 mac 的数据：同步只写自己的子文件夹和只增的 `images\`，删只删有墓碑的，读到更新的格式就停。
- 丢 0.1.2 的数据：库迁移只有第 10 步（`launcher_usage` 加一列，和 `user_version` 在同一个事务里）；便签是单独的库。
- 更新、安装路径坏掉：`build-release.ps1`、`KittyTools.iss`、`UpdateInstaller` / `UpdateTrust` 自 0.1.2 都没改，包名、sha256、tag 前缀 `windows-v` 都不变。
- 密钥外泄：新加的日志只有事件名、数量和异常类型。

**状态屏不会把人永久锁死**：

- 锁屏再解锁一定能结束它。Win+L、Ctrl+Alt+Del 拦不住。
- 进程闪退时，钩子、藏指针、不睡眠都跟着进程一起失效。
- 但 R70 让最常用的退出办法，在一个很常见的操作之后失灵，必须修。

**修完之后**：打包，再照下面的「真机清单」走一遍。其中状态屏真的进出、提醒真的到点、便签真的打字和重启、和真 Mac 同步，到现在**没有任何人走过**。

### 待修

#### R69（P0）新装不弹欢迎引导，开机自启也没设上 → 已修（`cc0356ad`）

> Windows 11-13：`SettingsService.FirstRun`（Save 不清），ShellRuntime 和 WhatsNewHost.Adopt 改看它。新 Dev 档 `--smoke`：onboarding.shown、smoke.onboarding shown=True；同一个档再起一次（= 升级）不弹。`--smoke` 现在在新档上等引导真的弹出（没弹 exit 3），`build-release.ps1` 跑它之前删掉 smoke 档。注销再登录自己起来没测（真机清单第 2 条）。

**位置**：

- `App/Settings.cs:537`：Load 时没有 settings.json，设 `IsNew = true`。
- `App/Settings.cs:614`：Save 一律设 `IsNew = false`。
- `Shell/WhatsNewHost.cs:38-41`：`Adopt` 在 `App.OnLaunched` 里、`ShellRuntime` 之前跑。新装时 `LastRunVersion` 是 null，于是调 `Save()`。
- `Notes/NotesHost.cs:60-61`：放示例便签时也调 `Save()`。
- `Shell/ShellRuntime.cs:877`：到这里才看 `IsNew`，已经是 false。

**后果**：

- 新装第一次打开，没有三屏欢迎引导。
- `Autostart.Set(true)` 只在引导里调（`SettingsWindow.Onboarding.cs:132`），所以新用户默认不开机启动。
- 新装只开四样功能。录制、便签、提醒、状态屏本来在引导里勾，现在没人告诉用户。
- 这是 PLAN-v16 第 3 批加 `WhatsNewHost.Adopt` 时带进来的。HANDTEST 1190 写着「引导没走」，所以一直没发现。

**怎么修**：

- `SettingsService.Load` 里另记一个 `FirstRun`：新装、设置文件坏了时为 true，`Save` 不清它。
- `ShellRuntime.cs:877` 和 `WhatsNewHost.Adopt` 改看 `FirstRun`；`IsNew` 只留给 `MarkStarted` 用。
- 补一个自检：新的测试档启动后，引导确实打开了（看日志，或在 `--smoke` 里查）。

**验**：真机清单第 2 条（沙盒里新装）。升级（已经有 settings.json）时不弹。

#### R70（P1）状态屏：按 Ctrl+Alt+Del 再「取消」之后，按住 Esc 退不出 → 已修（`9e1a6101`）

> Windows 11-13：取第一种修法——Core `HeldKeys`（键 → 最后一次按下的时刻，超过 `ExitHold.StaleAfterMs` 不算按着），连发和修饰键都按它算。单测 HeldKeys_LostReleaseStopsCountingAfterStale（Ctrl / Alt / Delete 不松，6 秒后按住 Esc 两秒退出）、HeldKeys_LostEscReleaseIsNotRepeatForever；`--status-screen-probe` 三种样式照过。真的 Ctrl+Alt+Del 没测（真机清单第 6 条）。

**位置**：

- `StatusScreen/InputBlock.cs:61`：`Down`，在 UI 线程上记哪些键按着。
- `StatusScreen/InputBlock.cs:393-395`：`repeat = !Down.Add(key)`、`modifiers = Down.Any(…IsModifier…)`。
- `Down` 只在 Start、Stop、Pause（锁屏）时清。
- `Core/StatusScreenRules.cs:71`：`ExitHold` 看 `input.HasModifiers`。

**触发**：

- 按 Ctrl+Alt+Del 进安全桌面，点「取消」回来。Ctrl、Alt、Delete 的松开发生在安全桌面上，低级钩子收不到，`Down` 里一直留着它们。
- 钩子被系统超时摘掉，或 UI 线程卡住 5 秒、钩子放行的那一刻刚好松键，也一样。

**后果**：

- 之后每一下 Esc 都算「带修饰键」，按住 Esc 永远不开始计时。
- 漏掉的是 Esc 自己的松开时，之后每一下 Esc 都被当成连发。
- 剩下的出路只有两条：
  - 按住屏幕底部的提示。关掉了「有人碰时显示怎么退出」就没有这条。
  - 锁屏再解锁。
- 手测 952 那一节正好让人「手边留着 Ctrl+Alt+Del」，用户慌了最先按的就是它。
- `ExitHold` 自己那份有 5 秒过期（`StaleAfterMs`），`InputBlock` 这份没有。

**怎么修**（二选一）：

- `Down` 改成「键 → 最后一次按下的时刻」，超过 `ExitHold.StaleAfterMs` 的当没按着；算 `repeat` 和 `modifiers` 都按这个。
- 或者直接不要 `HasModifiers`（`ExitHold` 的 `others` 已经带过期地管了修饰键），`repeat` 也按时刻过期。

补单测：按下 Ctrl 不松，6 秒后按住 Esc 两秒能退出。

**验**：真机清单第 6 条。

#### R71（P1）状态屏：进入前就按着的键，系统一连发，它的松开就被吞了 → 已修（`9e1a6101`）

> Windows 11-13：照建议——按下不是这里吞的、`GetAsyncKeyState` 已经是按着：照吞、不报给会话、不记 `KeysTaken`；鼠标键同理（X2 按 mouseData 换 VK）。只能靠 `--status-screen-probe` 验没改坏（不许真进），真按住快捷键进入没测（真机清单第 7 条）。

**位置**：`StatusScreen/InputBlock.cs:274-286`。`KeyboardProc` 收到按下，就设 `KeysTaken[slot] = true`。

**触发**：按着一个键超过系统的连发延迟（默认约半秒）时进入状态屏。比如：

- 开了「按快捷键直接进入」，快捷键按得久了一点；
- 提醒「到点进入状态屏」时，用户正按着 Shift 或方向键。

连发出来的按下被当成「这里吞的」，于是它的松开也被吞了。

**后果**：

- 系统收到过真正的按下，没收到松开。退出后它一直算按着：打字全是大写，点击变成 Ctrl+点击，直到再按一次那个键。
- 代码注释里写的「进入前就按着的，松开放过去」，只在不连发时成立。

**怎么修**：

- 钩子里收到按下时，如果 `!KeysTaken[slot]`，而且 `GetAsyncKeyState(vk) & 0x8000` 为真，说明系统早就当它按着（低级钩子里的异步状态还没算上这一下）。
- 这时照样吞掉这一下（不报给会话也行），但**不**记 `KeysTaken`，它的松开放过去。
- 鼠标键同理，看 `ButtonsTaken`。

**验**：真机清单第 7 条。

#### R72（P1）便签、提醒启动时出错，整个 App 起不来 → 已修（`ec2cc0e5`）

> Windows 11-13：两处各包 try / catch，记 notes.start-failed / reminder.start-failed、轻提示「便签这次用不了」「提醒这次用不了」。编译、全部单测、`--smoke` 过；异常那条路没真走。

**位置**：

- `Shell/ShellRuntime.cs:93`：调 `NotesHost.Start`，进到 `NotesHost.cs:43-67` 的 `Ready`：图片目录、到期清理、示例便签、`NoteFloats.RestoreAtLaunch`、`NoteDeck.Refresh` 建窗口。
- `Shell/ShellRuntime.cs:108-111`：`ReminderCenter.Start`。
- 这两处外面都没有 try。`App.OnLaunched` 的 catch 记完崩溃日志后 `throw`。

**后果**：

- 这里任何一个异常都会让 App 每次启动都退出。比如某块屏的 DPI 或位置算出怪值、一张坏图、设置里一条读得出来但不合理的提醒。
- 用户连设置都打不开，也就没法关掉这个功能。
- 违反 `NotesBackup.cs` 文件头的「便签的问题不让 App 退出」。
- 没找到一定会抛异常的地方，但出了事代价太大，改动又很小。

**怎么修**：

- 两处各包一个 try / catch：记 `Log.Error("notes.start-failed", ex)` 或 `reminder.start-failed`，轻提示「便签这次用不了」或「提醒这次用不了」，其余照常起。
- 剪贴板那一段（`:77-90`）已经是这个写法。

#### R73（P1，修完真机确认）便签：在正文里拖动一张图，图片表和正文对不上 → 已修（`0941177a`），待真机确认

> Windows 11-13：AllowDrop / CanDrag = false、DragStarting 取消、DragOver / Drop 用 handledEventsToo 拦下；`Aligned()` 对不上时 `NoteEditor.Unsaved`，底行写「这条便签有改动没存上」。`--note-editor-probe` 七条照旧。不用合成输入，真拖留给用户（真机清单第 14 条）——也要看 RichEditBox 内部的 OLE 拖动是不是真的被这几样挡住（挡不住的话底行会写「有改动没存上」，至少不再无声地丢字）。

**位置**：

- `Notes/NoteEditor.cs:105-120`：RichEditBox 没关拖放。
- `Notes/NoteEditor.cs:476-488`：新冒出来的 U+FFFC 被当成「别处来的」。
- `Notes/NoteEditor.cs:516-519`：`RemoveForeignObjects` 是异步排进队列的。

**触发**：选中一张图（或带图的一段），在正文里拖到别的位置。

- RichEdit 的内部拖动是先插、后删。
- 插进去的那个 U+FFFC 被当成外来对象，排队等着删。
- 紧接着删原位置时，外来对象还没删掉，`at` 就多数一个。

**后果**（读代码推的）：

- 往前拖：图片表删掉的是后面那一张的记录。存下去那张图就丢了，30 天后文件也被清掉。
- 往后拖：图片表和正文对不上，`Aligned()` 一直拦着。这条便签之后打的字都不交出去（日志 `notes.editor-images-misaligned`），关掉就没了。

**怎么修**：

- 正文框关掉拖放：`AllowDrop = false`，再用 `AddHandler(…, handledEventsToo: true)` 在 `DragOver` / `Drop` 里把 `AcceptedOperation` 设成 None。
- Windows 这边本来就不支持往便签里拖文件，关掉不损失功能。
- 前提不成立（RichEditBox 根本不让在框里拖图）的话，这个改动什么都不影响。
- 顺手：`Aligned()` 对不上时，现在只记日志，之后的字全不交（`:141-147`、`:581-586`）。至少在底行写一句「这条便签有改动没存上」，别无声地丢字（同 R75）。

**验**：真机清单第 14 条。

#### R74（P1，修完真机确认）状态屏：前台是管理员程序时挡不住键盘 → 已修（`8c91127e`），没测

> Windows 11-13：两条都做了——「请勿触碰」鼠标那块屏的底板去掉 NOACTIVATE、拿前台（`HudFrame.AllowActivate`）；摆好窗口后前台还不是自己、而且是提权进程（本进程没提权）就不进：快捷键进入给轻提示，提醒退成全屏（原因写在全屏上），日志 status.enter-refused elevated-foreground。`--status-screen-probe`：「请勿触碰」现在也有 foreground.restored。管理员窗口在前台那条要 UAC、不许真进，没测（真机清单第 8 条）。

**位置**：

- `StatusScreen/StatusScreenPanel.cs:33`：透出样式的窗口都是 `WS_EX_NOACTIVATE`，谁都不拿前台。
- `StatusScreenHost.cs:191-205`：进入后不看前台是谁。
- `Reminders/ReminderCenter.cs:393-397`：提醒到点自动进入时没有输入权，拿不到前台。补的那一下 vkE8 也会被 UIPI 挡掉。
- PLAN-v12 复查时列为「留给你们确认」，一直没确认。

**触发**：以管理员身份运行的终端或安装程序在前台时：

- 进「请勿触碰」（透出样式）；
- 或提醒到点自动进入任何样式。

原因是 UIPI：普通权限的低级键盘钩子，收不到发往高权限窗口的键。

**后果**：

- 「请勿触碰」挡不住键盘。别人碰到键盘，字会打进被盖住的管理员终端，可能还带着回车。
- 按住 Esc 也退不出，只能锁屏再解锁。

**怎么修**：

- 进入时让鼠标所在那块屏的底板去掉 `NOACTIVATE`、拿前台。mac 每种样式都让面板当 key。
- 进入后再查一次：前台不是自己的窗口、而且是提权进程（`Foreground.IsProcessElevated`）时，不进状态屏。提醒退成全屏提醒，快捷键进入时给一条轻提示说明原因。
- 不能真进状态屏验证（自动化不许），由用户走真机清单第 8 条确认。

### 应修（不挡这一版，能顺手就修）

**R75 便签落盘一直失败时，界面上什么都不说** → 已修（`0941177a`）：`NoteStore.SaveProblemChanged`，第一次失败轻提示一次，底行写「没存上，正在重试」，落下去就消。失败那条路没真走。

- `Notes/NoteStore.cs:521-528` 只记 `SaveProblem` 和日志。
- 只有快速记一条（`NoteCaptureWindow.cs:447`）和退出时的对话框会告诉用户。关机、注销、闪退就直接丢字。
- 修：`NoteSheetView` 底行加一句「没存上，正在重试」（同 mac）；第一次失败时轻提示一次。

**R76 zip 版「卸载并删除数据」删不干净** → 已修（`4a9fd0b9`）：PrepareForUninstall 加 NoteStore.Flush / Dispose、ReminderCenter.Stop。新自检 `--uninstall-probe`（Debug）：停完之后数据目录里每个文件试一次独占打开，修之前 locked=3（notes.sqlite3、-shm、-wal），修之后 0。

- `Shell/ShellRuntime.cs:1113` 的 `PrepareForUninstall` 只停了剪贴板、同步、更新、热键。
- 便签库没关（连接和 `-wal` 还开着），`ReminderCenter` 没停，`UninstallCleanup.Recycle` 挪不动整个目录，弹「数据目录没删干净」——和当年 R25 一样。
- 修：加上 `NoteStore.Instance?.Flush(); NoteStore.Instance?.Dispose(); ReminderCenter.Stop();`。
- 安装版走 Inno 卸载，进程先退，不受影响。

**R77 云盘里「仅在线」的文件不会被要求下载** → 这一版没修（留在应修）；0.2.0 更新日志便签第四条后面照草稿加了「右键它选『始终保留在此设备上』」。

- `Core/Sync/SyncDisk.cs:15-35` 碰到占位文件就当它不存在。0.1.x 的几类同步就是这样；mac 会调 `startDownloading`。
- 在 OneDrive 按需下载、iCloud for Windows 下，别的电脑新写的文件常常是仅在线的：
  - 便签：对方的 `erased.json` 是占位时，便签这部分一直停在「还没下载完」。
  - 另外几类：变成只往外同步。
- 不会写坏数据。
- 修：开同步时、或每一轮，给同步根目录设上 `FILE_ATTRIBUTE_PINNED`（等于资源管理器里的「始终保留在此设备上」），或者在后台调 `CfHydratePlaceholder`；占位属性也放进指纹。
- 这一版不修的话，更新日志里同步那条后面加一句：「同步文件夹在 OneDrive / iCloud 里时，右键它选『始终保留在此设备上』」。

**R78 全屏提醒建到一半失败，会留下一层压暗** → 已修（`4a9fd0b9`）：`ReminderScreen.Show` 的 catch 把已建的都撤掉、返回 false，`ReminderCenter` 退回底部的轻提醒。异常那条路没真走。

- `Reminders/ReminderScreen.cs:116-119` 的 catch 只记日志。
- 先建好的压暗层留在屏上吃点击；「点了才收」的提醒没人能收掉。
- 修：catch 里把已建的窗口 `Close()`，退回到底部的轻提醒。

**R79 锁屏通知没注册上时没有兜底** → 这一版没修（留在应修）。

- `Shell/HiddenWindow.cs:56` 不看 `WTSRegisterSessionNotification` 的返回值。
- 收不到「解锁」的话，「锁屏再解锁」这条出路就失效了；状态屏一直算开着，热键和提醒都被压着。
- 修：失败时记日志；状态屏开着时每 2 秒用 `WTSQuerySessionInformation` 查一次锁定状态（同 mac 的兜底轮询）。

### 观察（记下，不改也能发）

- **重开时可能留下两个实例**：
  - 更新后重开、数据库恢复后重开，都是先放掉单实例锁、拉起新进程，再调 `Exit()`（`App/AutoUpdater.cs:196-202`、`Storage/Recovery.cs:103-107`）。
  - `Exit` 里便签没存上会弹框，选「取消」就不退，新旧两个进程同时在跑。
  - 只在便签落盘失败时碰到。修法：这两条路径先调 `NotesHost.ConfirmQuit()`，再起新进程。
- **状态屏开着时 UI 线程卡死**：钩子 5 秒后放行，但置顶的黑窗还盖着所有屏（`StatusScreenHost.cs:296`）。钩子线程发现心跳过期时，可以顺手对这些窗口调 `ShowWindowAsync(SW_HIDE)`。
- **升级用户的默认值**：
  - 便签、提醒、状态屏默认开（没存过就算开，同 mac）。一升级屏幕右边就出药丸和示例便签，Alt+N 被占用。用户自己已经把别的动作设成 Alt+N 的，那个先注册、保得住。
  - 0.1.2 时就开着同步的用户，便签、提醒、状态这三类默认勾上，第一轮直接合；mac 的升级用户是先不勾。
  - Windows 的示例便签会同步到 Mac 上。都不丢东西，提一句。
- **「后台下好、退出时安装」默认开**（同 mac）：之后点托盘「退出」就装上新版本，没有单独确认；关掉「自动检查更新」后，已经下好的那一版照样会装。
- **卸载提示没提便签和提醒**：`installer/KittyTools.iss:332` 问「要同时删除你的数据吗？」时只列了剪贴板、设置、截图历史，便签、提醒实际也会一起进回收站。加上它们。
- **同步**：
  - 标记里的库编号变了，Windows 跟着换（`SyncRunner.cs:123-126`，0.1.x 就这样）；mac 这时停在「不是那个文件夹」。
  - 读完之后同步文件夹被删了，写的时候 `CreateDirectory` 会把它建回来；mac 不建。
- **便签编辑器**：
  - 只打开一条再换走，正文里的 U+2028 / U+0085 / 不规范的令牌被规范化后当成改动交出去，「改于」和版本钟都变了。
  - 同步的「正在编辑」只认正文框。标题框里正在打字时，那条照样会被同步换掉。
  - `_composing` 卡住（没等到 TextCompositionEnded）时，之后的字不交出去。
- **便签的设置项没进导出**：字号、行距、屏幕边缘那几项还不在设置导出的「设置」一类里（PLAN-v13 复查 VERIFY 3）。
- **未处理异常带走整个进程**：`App.xaml.cs:14-21` 的 `UnhandledException` 不设 `Handled`（0.1.x 就这样），任何一个界面事件里没接住的异常都会让整个进程退出。退出前至少调一次 `NotesHost.Flush()`，最多丢 2 秒的字。

### 验到什么程度

| 层 | 覆盖 |
|---|---|
| 编译、单测 | 852 个全过；Debug、Release AOT x64 / ARM64 零警告（PLAN-v16 第 5 批，11-07；11-12 的 `ecd8de3a` 跑了 `--ui-snapshots`）。和 mac 互通的三处 golden（便签 1830 个样本、提醒、状态）一次就过；`KITTY_NOTES_SYNC_FUZZ=2000` 过。 |
| 自检（不碰真输入） | `--status-screen-probe`（三种样式，只吞带标记的注入事件）、`--note-editor-probe`（RichEdit 七个行为点，修了三处真错）、`--notes-ui-probe`、`--copy-file-probe`、`--overlay-translate-probe`、`--panel-resize-probe`、`--reminder-sound-probe`（用静音 WAV）、`--ui-snapshots`、内存探针、空闲 CPU。 |
| 同步 | 一台 Windows 上两份 `.Dev` 数据加一个临时文件夹，便签传过去了（1055、1056）。**没和真 Mac 同步过**（便签、提醒、状态都没有）；没在 OneDrive / iCloud 的文件夹里试过。 |
| 真机手测 | 0.1.1 之后的手测 812–1211 共 400 条，带「Windows 11-0x」记号的约 86 条，其中多数是用自检、截图、单测验的，真按键、真鼠标走过的很少。用户 11-08、11-12 装过测试包，报过便签那叠看不见、窗口白边（都修了）。真机回归清单 R1–R40 这一版没走。 |
| 从来没人试过 | 真的进入状态屏（自动化不许）；提醒真的到点（全屏、边框、念出来、进状态屏、30 秒长音频）；便签长时间真打字、拖图、重启或注销后字还在不在；新装引导（所以 R69 一直没被发现）；从 0.1.2 真的升级上来；高对比度、多屏、管理员窗口在前台。 |

### 发版前必须真机走的（给用户）

用要发的那个 setup.exe，约两个小时（31–37 条是 2026-11-14 并进来的 PLAN-v19 和 PLAN-v18）。

**先跑自动的**：

- `dotnet test`；
- `build-release.ps1`（含 `--smoke`、`setup-e2e.ps1`）；
- `KittyTools.exe --update-live=0.1.2`：退出码 0，`%TEMP%\kitty-update-live\report.txt` 里写着 ok。

**安装和升级**

1. 在装着 0.1.2 的这台电脑上，双击新的 setup.exe 覆盖安装：
   - 剪贴板历史、收藏、快捷键、翻译服务和密钥都在；
   - 原来开着的功能还开着；
   - 托盘、主界面、设置侧栏里的「便签」「提醒」「状态屏」挂着「新」；
   - 屏幕右边出一条药丸（示例便签）。
2. **新装**（在 Windows 沙盒或另建的 Windows 账户里，别动自己的数据）：
   - 装完第一次打开，欢迎引导三屏出来；
   - 第三屏「登录时自动打开」勾着，能勾录制、便签、提醒、状态屏；
   - 点「开始使用」后注销再登录，Kitty Tools 自己起来了。（验 R69）
3. 设置 › 通用 › 功能 关掉「便签」：药丸、托盘里的便签、Alt+N 都没了；打开回来立刻恢复。提醒、状态屏也各拨一次。

**状态屏**（手边留着 Ctrl+Alt+Del 和 Win+L：它们拦不住，是最后的出口）

4. 设置 › 快捷键 给「状态屏」设一个键，按它，选「马上回来」：
   - 每块屏都盖住；
   - 敲字母、Win 键、Alt+Tab、滚轮、右键都没反应，底部出「按住 Esc 退出」；
   - 按住 Esc 两秒退出；
   - 退出后到记事本里打字、点击，没有哪个键像一直按着。
5. 「清洁屏幕」「请勿触碰」各进一次，各按住 Esc 退出；「请勿触碰」能看见后面的窗口。
6. 进入后按 Ctrl+Alt+Del，点「取消」，回来按住 Esc 两秒：能退出。（验 R70）
7. 打开「按快捷键直接进入排在最前面的状态」，按住快捷键两秒再松；退出后打字不是全大写，点击正常。（验 R71）
8. 以管理员身份开一个 PowerShell 放在前台，进「请勿触碰」，敲几个字母：字没进 PowerShell；按住 Esc 能退出。（验 R74）
9. 设一个退出密码：
   - 进入后按住 Esc，出密码框，输对能退出；
   - 再进一次，Win+L 锁屏再解锁：状态屏结束，快捷键恢复；
   - 进入后让电脑睡眠再唤醒：能退出，鼠标指针在。

**提醒**

10. 启动器输「提醒 1分钟 喝水」按 Enter：一分钟后屏幕底部出提醒，「稍后」「知道了」都管用；正在打字时它不抢走键盘。
11. 一条设「全屏」、一条设「闪屏幕边框」、一条设「念出来」：到点样子都对、都收得掉；边框收起后任务管理器里 CPU 回到 0。
12. 一条设「到点进入状态屏」：到点进入，按住 Esc 能退出。再给一条的提示音选一首一分钟的歌：到点放，30 秒自己停，点「知道了」马上停。

**便签**

13. 开着中文输入法，在记事本里按 Alt+N 记一条，Enter 记下；鼠标推到屏幕右边，扇出后点开接着写几句；托盘退出再打开：字都在。
14. 便签里 Ctrl+V 贴一张截图，改宽度、裁切；**选中这张图拖到上一行，再拖到下一行**，各打几个字；关掉重开：图和字都在。（验 R73）
15. 打完字一秒内锁屏、睡眠、注销各试一次：回来最后一句还在。
16. 全部便签窗口：
    - 便签墙和列表切换、搜索；
    - `# 标题`、`- [ ] 任务`（点方框切状态）、Ctrl+B；
    - 删一条去「最近删除」再放回；
    - 按住标签往外拖成浮动便签、固定，重启后还在原处。
17. （只在 Dev 数据或临时文件夹里）便签导出成 Markdown 文件夹，再导回来：不重复，图都在。

**和 Mac 同步**（新建一个空的临时同步文件夹，不用真在用的那个）

18. Windows 和 Mac 选同一个文件夹：
    - 两边各建一条便签、一条提醒、改一个状态，一分钟内互相看到；
    - 两边同时改同一条便签的不同地方，两版都在（一版在「最近删除」）；
    - Mac 上原来的东西一条没少。
19. 把同步文件夹放在 OneDrive（或 iCloud）里，再走一遍第 18 条：Mac 新写的便签能不能到 Windows。到不了的话，照 R77 在更新日志里加那句。

**别的新功能各看一眼**

20. 启动器输「100 usd」「100 美元 转 日元」：出结果，Enter 能粘贴；断网时提示「没取到汇率」。
21. 截图：
    - Enter 后角落卡上有「改标注」；
    - 标注里按 X 裁剪；
    - 设置 › 截图「截图拷贝为」选「文件」，截一张粘进资源管理器，是一个 PNG 文件；
    - 设置 › 翻译 打开「截图翻译时把译文直接盖回截图上」，按 Alt+S，译文盖在图上。
22. 划一个英文单词按 Alt+E：有道词典卡出来，喇叭是真人发音。剪贴板面板、启动器、翻译浮窗都能拖边改大小；剪贴板的「面板位置」改成跟随鼠标后跟着鼠标出现。

**卸载和收尾**

23. （在沙盒或另一个账户里）设置 › 通用「从这台电脑移除」，选删数据：数据目录整个进回收站，里面有 `notes.sqlite3`、`notes-images`、`reminder-sounds`。
24. 走完放五分钟：
    - 任务管理器里 CPU 回到 0，专用工作集 60 MB 上下；
    - 翻今天的 `logs\kitty-*.log`：没有便签的标题和正文、提醒的标题、剪贴板内容、网址。
25. R1–R40 里至少再走 R3（更新）、R6（默认快捷键，多了 Alt+N）、R8（外观、深色、150 %）。

**PLAN-v18 收口带的**（2026-11-13 加）

26. 长截图：框一块大选区（大半个屏幕）开自动滚动，一页长网页滚到底能自己停下，中途不反复「对不上」。
27. 开着「截图翻译时把译文直接盖回截图上」：Alt+S 翻一块，再拖一块别的选区 → 原来那块的译文没了、提示「选区变了，已换回原文」；拖回原处再翻，翻的是原文。
28. 两块显示器、外接屏当主显示器、笔记本放在它左边，设置 › 便签 位置选「左边」：主显示器上的药丸在左边。
29. 设置 › 关于「检查更新」能查到；中文系统上，启动器搜「命令提示符」「mlts」（L7，结果写进报告）；从启动器打开 cmd 跑 `set`，和从开始菜单打开的比，多出来的变量写进报告（L8）。
30. 中文输入法打拼音、还没选字时，翻译原文框、启动器、快速记一条、便签标题和正文里的灰色占位字都不和拼音叠在一起（L11）。

**PLAN-v19、PLAN-v18 第 1–8 批**（2026-11-14 用户「把 WebDAV 和 PLAN-v18 第 1–8 放到 0.2.0 里面」，加了这几条；详细的在 HANDTEST 1212–1224、1238–1317）

31. 设置 › 通用「同步」→「连接服务器…」，连一个**临时的测试 WebDAV**（别连真在用的网盘目录）：测试连接通过，连上后建一条便签，一分钟内服务器上出现文件；「停止同步」后凭据管理器里那条没了。
32. 截图标注：打码是模糊、「自动」能盖住截图里的手机号 / 邮箱；矩形拖边中点、Shift 等比、Alt 从中心；文字 Ctrl+= / Ctrl+- 改字号；序号拖角放大、改编号；箭头选双头；吸管取色。
33. 截图翻译盖回：框一小块（一两行字）翻 → 字不小得看不清，放不下的段进旁边的译文卡片；卡片上「看原文」「拷贝」「✕」都管用。
34. 设置 › 快捷键 加一个按应用停用的程序（比如记事本），记事本在前台时 Alt+V 不出剪贴板、切走就回来；把某个动作设成「连按两下 Ctrl」，连按能触发、平时 Ctrl+C / Ctrl+V 不误触；截图时在工具栏上右键一颗钮改它的键。
35. 启动器：设置 › 启动器 › 命令和别名 给 kill 改个别名，旧词不认、新词认；给一条命令设快捷键能直接跑；桌面上一个便携 exe 能搜到；给一个应用起别名，输全排第一。
36. 启动器的脚本：设置 › 启动器 › 脚本命令「新建脚本」建一个 PowerShell 的，在启动器里输它的关键词能跑；「用例子新建」后输「tq 北京」出天气（要联网）；输「time」「bcvt 0xff」「b64 aGk=」出几行结果，Enter 粘贴；「复制写法说明」贴给 AI、把它回的脚本「从剪贴板新建」能存能跑。
37. 启动器输「dark」Enter：深色 / 浅色切过去，再输一次切回来（**会改系统主题**，走完记得切回原来的）。

**发布之后**：把第 4、6、9、10、13–15、18 条并进真机回归清单（R41 起），这份清单就不再只管 0.1.x 的功能。

### 版本号

**全部算 0.2.0，一次发**，不拆成 0.2.0 / 0.3.0 / 0.4.0。理由：

- 各 PLAN 里写的 0.3.0（状态屏、提醒）、0.4.0（便签）都没单独发过。代码在同一条分支上互相交织（设置侧栏分组、功能开关、同步执行层、导出导入是一起改的），拆不开。
- 「新」标记的三项（`Core/WhatsNew.cs` 的 `Entries`）写的就是 0.2.0，拆版本还得改它。
- AGENTS.md「版本和发布」：各 PLAN 里的版本号只当历史看。

**做法**（交给 Windows agent）：

- `Directory.Build.props` 的 `Version` 从 0.1.2 改成 0.2.0。
- 在 `KittyTools/Resources/changelog.json` 的 `entries` 最前面加 0.2.0 一条：
  - 格式同 0.1.2：`version`、`date`、`summary`、`items:[{type, text}]`；
  - type 只用 feat / fix / perf / ui；
  - 缺这一条时 `build-release.ps1` 会中止。
- 发布时打 tag `windows-v0.2.0`，用 `--latest=false`。

### 0.2.0 更新日志草稿

直接改写成 changelog.json 的 0.2.0 条目。日期写打包那天；R77 不修的话，在「便签」第四条后面加上那句。键名用 Windows 的写法，不提别的产品。

**summary**：新增便签、提醒和状态屏：Alt+N 随手记一条，鼠标推到屏幕边上就能翻开接着写；到点的提醒能全屏、闪边框、念出来；状态屏一键盖住所有屏幕、挡住键盘鼠标。启动器能换算汇率；截图能把译文盖回原图、拷成文件、裁剪、带上鼠标指针；翻译多了有道词典和真人发音；面板能拖边改大小、记住位置。新装只开剪贴板、启动器、翻译、截图四样，别的在欢迎引导或设置里打开。

**items**：

- feat：便签：Alt+N 在任何程序里随手记一条，Enter 记下、Shift+Enter 换行；托盘、主界面、启动器里有「全部便签」，便签墙和列表两种看法，8 种纸色、搜索、归档、固定，删掉的在「最近删除」里留 30 天
- feat：便签：屏幕右边缘一条小药丸，鼠标推过去展开成一列标签，点一张就地接着写；按住标签往外拖成浮动便签，固定后重启还在原处；设置 › 便签 能换到左边、改感应范围
- feat：便签：正文能写 Markdown（标题、粗斜体、删除线、代码、引用、链接），标记只在光标那一行露出来；任务有待办、进行中、紧急、完成、取消五种状态，Ctrl+T 变成任务；六种文字颜色；能贴图、改图片宽度、裁切
- feat：便签：单独保存、每天自动备份；能整个导出成 Markdown 文件夹再导回来，也跟着设置的导出导入走；开着同步时和 Mac 版的便签互通，两边同时改了不丢字（输的那一版另存一条进「最近删除」）
- feat：提醒：设好时间到点提醒，能只响一次，也能每天、工作日、每周、每月或隔一段时间重复；每条能选全屏、闪屏幕边框、念出来，也能到点直接进入状态屏；没理会时隔几分钟再催（1–120 分钟）
- feat：提醒：启动器里一句话建提醒，输「提醒 10分钟 喝水」「remind 明天9点 交周报」直接建好；托盘和主界面有「新提醒」，也能设快捷键；提示音能选系统的 14 个或自己的音频文件；开着同步时和 Mac 互通
- feat：状态屏：一键把所有屏幕盖上一张告示，同时挡下键盘和鼠标，擦屏幕、擦键盘、人要走开一会儿时用；自带清洁屏幕、请勿触碰、马上回来三个状态，能改能加，图标能挑会动的表情或系统表情；按住 Esc 两秒退出，可以设退出密码
- feat：启动器：汇率换算，输「100 usd」「100 美元 转 日元」「美元兑人民币」直接出结果，Enter 粘贴；汇率每 6 小时取一次，断网时用上次的
- feat：截图：截图翻译能把译文按原来的位置盖回截图上，接着标注、复制、保存（设置 › 翻译「截图翻译时把译文直接盖回截图上」，默认关）；框选时能保持屏幕原色不压暗
- feat：截图：截图能拷成 PNG 文件（设置 › 截图「截图拷贝为」），往聊天程序、对拷线里粘的是文件
- feat：截图：标注里加了「裁剪」（X），截图、长图标注、截图历史里改标注都能裁；角落缩略图上能直接「改标注」
- feat：截图：截图能带上鼠标指针；截图、录屏时能临时藏起桌面图标（都在 设置 › 截图，默认关）
- feat：截图：长截图自动滚动匀速顺滑，长截图面板上能选慢、标准、快；长图标注能缩放、按住空格拖动、双击改字、画到边上自动滚
- feat：剪贴板：能把剪贴板里的文字钉到屏幕上，剪贴板历史里的文字也能「钉到屏幕」
- feat：翻译：查单词时多一张有道词典卡；英文单词用真人发音，取不到时用系统声音；卡片上的喇叭只读释义
- feat：翻译：法语、德语、西班牙语、葡萄牙语、意大利语的原文认得出来，不再当成英语
- feat：录制：录屏能选用哪个麦克风，选的不在时用系统默认的
- feat：设置：剪贴板面板、启动器能选出现在屏幕上方、跟随鼠标或上次的位置；剪贴板、启动器、翻译浮窗能拖边改大小
- feat：设置：设置侧栏按功能分组、能收起，关掉的功能收进「已关闭」；新装只开剪贴板、启动器、翻译、截图，欢迎引导里能勾别的
- feat：更新：有新版本时能「跳过这个版本」；新版本在后台下好，退出时装上（设置 › 关于 能关）
- feat：设置：关于页多了「反馈问题」；托盘图标在暂停记录剪贴板、录制中时带角标
- ui：截图：截图工具栏默认贴在选区右边，设置 › 截图 能换回居中；换工具时样式栏滑过去
- ui：主界面：方向键换格子时高亮滑过去；在主界面直接打字就转到启动器
- ui：启动器：设置 › 启动器「空搜索框里列出常用」能关；浏览器里删掉的书签、删掉的快捷链接不再以「用过的网址」回来
- ui：全局：升级上来后，便签、提醒、状态屏在托盘、主界面和设置里挂一个「新」，用过一次就消
- fix：翻译：固定着的翻译浮窗，在「划词翻译并替换」之后露回原处；录音来源选「两者」时，「没听到声音」只看麦克风
- fix：设置：换强调色后，设置窗里的开关当场变色
- fix：截图：长截图选区很大时，自动滚动不再反复「对不上」（PLAN-v18 S1）
- fix：截图：截图翻译把译文盖回后再框别处，上次的译文不再留在屏幕上；同一处再翻从原文翻（PLAN-v18 S6）
- fix：截图：识字时「1.」后面没有空格的也认成列表项，列表后面的正文单独一段（PLAN-v18 S12）
- fix：更新：公司、学校这类很多人共用一个出口的网络里，检查更新不再常被 GitHub 限流挡住；真被限流时说清楚，指到发布页（PLAN-v18 L12）
- fix：便签：屏幕边缘的便签选了哪边就放在哪边，两块显示器相接的那条边也放（PLAN-v18 L13）
- （L7 确认了才加）fix：启动器：「命令提示符」这类系统工具能用中文名和拼音搜到

### 安装包大小

**量过的数**（11-06，用 `build-release.ps1` 打包，版本号没改，和 GitHub 上 0.1.2 的附件比）：

| 产物 | 0.1.2 | 11-06 | 差 |
|---|---|---|---|
| x64 安装包 | 23.67 MB | 34.72 MB | +11.05 MB（+47 %） |
| x64 zip | 32.28 MB | 43.92 MB | +11.64 MB |
| ARM64 安装包 | 23.35 MB | 34.39 MB | +11.04 MB |

发布目录从 82 MB 变成 96 MB，增加的差不多全是状态屏的动画表情（`Resources\StatusEmoji\`，34 张图集 PNG，约 10 MB）。

**现在估计**：之后 PLAN-v16 第 5 批把这些 PNG 无损重压了 22.3 %，安装包约小 2.2 MB。x64 安装包现在大约 32.5 MB，**比 0.1.2 大约 9 MB（+37 %）**。以 0.2.0 打包时的 `SIZES.txt` 为准。

**能接受**：

- 一次性下载多 9 MB；App 内更新下载的 zip 多约 10 MB。
- 表情是状态屏和全屏提醒的主角，mac 也是随包带的。
- 改成第一次用时再下载，要给一个本该离线就能用的功能加上网络和失败的路，不值。
- 真要再压，只剩减帧或降到 128 px，会肉眼可见地变差，不建议。

### 给 Windows agent 的指令

照 AGENTS.md「每一批的流程」做一批「0.2.0 收口」：

1. `git fetch origin && git rebase origin/windows`。
2. 修 R69–R74：
   - 每条修完，把条目改成「已修（提交号）」，写一句怎么验的；
   - R69、R70、R71 补单测或自检；
   - R73 能在屏幕上拖就拖一次验证，拖不了就留给用户；
   - R74 不许真进状态屏验证，照旧只跑 `--status-screen-probe`，真进入留给用户，标「没测」；
   - R75–R79 能顺手修的修，不修的留在「应修」。
2½. 接着做 PLAN-v18 的「0.2.0 收口」五条（见下面「PLAN-v18」一节的 A）。
3. 改版本号和更新日志（照上面「版本号」「更新日志草稿」两节）。`dotnet test` 全过，AOT x64 / ARM64 零警告。
4. 打包验证：
   - `pwsh windows/build-release.ps1`（`--smoke`、`setup-e2e.ps1` 照常跑）；
   - 用新包跑 `KittyTools.exe --update-live=0.1.2`：退出码 0，report.txt 里写着 ok；
   - 把 `SIZES.txt` 里安装包和 zip 的大小和 0.1.2 比一下，写进报告。
5. 提交、推送。报告写产物路径、大小、R69–R79 各自的结果。**不发布、不打 tag**，等用户走完上面的真机清单再定。
6. 从打包的那个提交切分支 `windows-0.2.0` 并推上去（`git push origin <提交>:refs/heads/windows-0.2.0`），报告里写它指哪个提交。
   之后真机清单查出来的 0.2.0 问题修在 `windows-0.2.0` 上、重新打包，再拣回 `windows`；`windows` 接着做 0.3.0（PLAN-v19 核验 → PLAN-v18 第 1–8 批）。

### 0.2.0 收口结果（Windows 2026-11-13，Claude）

**分支**：`windows-0.2.0` → `9bb2c7c7`（打包的那个提交）。它比 `windows` 多一个提交 `46af52f5`：撤掉 PLAN-v19 的代码（63a8e278 + 编译修正 335fa2fe 里的代码文件，文档留着）。
PLAN-v19 在 0.2.0 收口开始前已经推到 `windows`，而它排在 0.2.0 之后核验、算 0.3.0、更新日志里也没有，0.2.0 不带一个没人走过的「连接服务器…」——**替用户定的**。
撤完 Sync / SyncFolder / Glyphs 和 PLAN-v19 之前（7214f94f）逐字节一样；`windows` 照旧带着 PLAN-v19 接着做 0.3.0。之后 0.2.0 的修补修在 `windows-0.2.0`、拣回 `windows`。

**修了什么**（各条的提交和验法写在上面各条、下面「PLAN-v18 › 收口结果」）：R69 R70 R71 R72 R73 R74，应修里顺手的 R75 R76 R78；PLAN-v18 S1 S6 S12 L12 L13 L7。R77、R79 没修（R77 照草稿在更新日志里加了那句）。
另外两个：`335fa2fe`（PLAN-v19 对话框按钮的 lambda 参数叫 `_`，编不过，只在 `windows` 上有意义）、`2931b88e`（自检档的新档不弹欢迎引导，见下）。

**自查**：
- `dotnet test`：`windows-0.2.0` 866 个全过（`windows` 893 个，多的 27 个是 WebDAV 的）；Debug 0 警告。
- `build-release.ps1`（x64 / ARM64 AOT 0 个 trim / AOT 警告，PRI 四个都在，`--smoke` 过——现在每次删掉 smoke 档、查新装时引导真的弹出）；`setup-e2e.ps1` 18 项全过；
  `KittyTools.exe --update-live=0.1.2` 退出码 0，report.txt：ok，下载 32 281 041 字节，sha256 对得上。内置智谱 key 在 x64 / ARM64 的 exe 里（只比对、没打印）。
- 内存探针（Release AOT，独立探针档，和上一批 PLAN-v16 第 5 批 `232e20f` 的 Release 并排起）：每一步都比上一批低 0.3–3.6 MB，只有托盘 52.1 MB（上一批 53.9）、5000 条剪贴板 57.1、
  启动器 63.3、翻译窗 64.5、截图五次后 87.5、设置五次后 100.4。**第一次量出来只有托盘 74 MB**：R69 修好以后新探针档一起来就弹欢迎引导（开着设置窗），量的不是「只有托盘」——
  `2931b88e` 改成自检档里只有 `--smoke` / `KITTY_ONBOARDING=1` 才弹（截图自检的设置页也不再被引导盖住），正常的档照弹。
- 空闲 CPU（只有托盘，静置 30 s 后量 120 s）：15.6 ms = 0.013 % 单核（基线 0.013–0.026 %）。
- 新日志：onboarding.shown、notes.start-failed、reminder.start-failed、status.enter-refused、update.check … source=manifest / api、update.manifest-unreadable / -missing、
  screenshot.overlay-restored，都只有事件名、异常类型和版本号，没有内容、地址、密钥。

**产物**（`kitty-win-v16base` 的 `windows/build/release/0.2.0/`，用户的 `D:\Apps\Kitty Tools` 没碰）：

| 产物 | 0.1.2 | 0.2.0 | 差 |
|---|---|---|---|
| x64 安装包 | 23.67 MB | 31.3 MB（32 777 336 字节，sha256 `4a9696c634d3…`） | +7.6 MB（+32 %） |
| x64 zip | 32.28 MB | 40.2 MB（42 142 722 字节，sha256 `07d21b153ac8…`） | +7.9 MB |
| ARM64 安装包 | 23.35 MB | 31.0 MB（sha256 `281adc306bc6…`） | +7.7 MB |
| ARM64 zip | — | 39.2 MB（sha256 `83a28d18e5f3…`） | |
| 发布目录 | — | x64 94.9 MB / 133 个文件，ARM64 100.5 MB / 133 个（不含 pdb） | |

（0.1.2 那一列照上面「安装包大小」一节的数，单位一样是 MiB 取一位。）另有 `windows-update.json`（L12 ②，UTF-8 无 BOM，x64 / ARM64 两项）和 `release-notes.md`。
全文 sha256 在各 `.sha256` 里。**没发布、没打 tag、没建 `windows-update` release**；发布时照 `build-release.ps1` 头部：先发 `windows-v0.2.0`（`--latest=false`），
再第一次 `gh release create windows-update --prerelease --latest=false`、把 `windows-update.json` 传上去，传完 curl 核一遍。

**没测、留给真机清单**：R69 注销再登录自己起来（第 2 条）、R70 真的 Ctrl+Alt+Del（第 6 条）、R71 真按住快捷键进入（第 7 条）、R74 管理员窗口在前台（第 8 条）、
R73 真拖图（第 14 条）、S1 真长网页（第 26 条）、S6 真遮罩换选区（第 27 条）、L13 两块屏（第 28 条）、L12 真限流 / 真清单（第 29 条）；R75、R78 的出错那条路没真走。

## PLAN-v19（同步直接连 WebDAV 服务器，issue #18，2026-11-13 用户「全部按推荐」，审查方在 Mac 上写；Windows 11-13 核验完，见本节末尾）

方案在 `PLAN-v19.md`（D1–D5 都取推荐）。一批，审查方在 Mac 上写完（`git log --grep "PLAN-v19"`），**一行都没编译、没跑过单测**（Mac 上没有 .NET SDK）。
你们在 0.2.0 打完包、切出 `windows-0.2.0` 之后核验（见「0.2.0 发版前审查 › 给 Windows agent 的指令」第 6 步），算 0.3.0 最先的一批；和 PLAN-v18 的各批不碰同样的文件。

### 写了什么

- **Core**：`Sync/WebDav.cs`（客户端：PROPFIND Depth 1、GET、PUT 带 `If-None-Match: *`、DELETE、MKCOL、一路建上级、MOVE 不覆盖；每个请求先带 Basic，
  401 带 Digest 挑战时换这个账号专门的 client；3xx 当错；multistatus 用 `XmlReader`，不认 DTD；出错分类和界面上的话）、`Sync/SyncServer.cs`
  （镜像的 pull / push、认得的文件 `Known`、账、连接 `ConnectAsync`、测试连接、删镜像、退避 `Backoff`、一轮 `RoundAsync`）。
  `SyncRunner`：`SyncRoundResult.FolderOk`（认清文件夹之后为真，连服务器时到了这一步才 push）、`RunAsync` 多一个可选的 `incomplete`（有没从服务器拿下来的：便签那部分当成有没下载完的）。
- **App**：`Settings.SyncServer` / `SyncServerUser`（不进导出）；`Syncer`（`Storage/SyncFolder.cs`）：连服务器时一分钟一轮、退避 5 / 10 / 20 / 30 分钟、状态 `busy`、
  `EnableServerAsync` / `ForgetServer` / `Dav`、密码在凭据管理器 `KittyTools/sync-server.password`（Dev 版 `KittyTools.Dev/…`）、镜像在数据目录 `sync-server\`；
  设置 › 通用「同步」：「连接服务器…」、「同步服务器」那张卡、状态行的「还有 N 个…」、页脚；对话框 `Settings/SettingsWindow.SyncServer.cs`；`Glyphs.Server`。
- **单测**：`WebDavTests`（10 个）、`SyncServerTests`（17 个，假服务器 `FakeDav` = 一个 `HttpMessageHandler` + 临时文件夹）。

### 给 Windows agent 的核验指令

1. **编译零警告**：`dotnet build windows/KittyTools.slnx -c Debug -p:Platform=x64`；`dotnet publish … -r win-x64` 和 `-r win-arm64` 零 trim / AOT 警告。
   **发布体积**和上一批比涨了多少写下来（第一次用 `System.Xml`，PLAN-v19 W8：超过 3 MB 先停下来报给审查方）。
2. **单测**：`dotnet test windows/KittyTools.Tests` 全过，特别是 `WebDavTests`、`SyncServerTests`，和原来的 `NoteSyncRunnerTests`、`SyncIntegrationTests`（`SyncRunner` 动过）。
   过不了先看是不是测试写错了（审查方没跑过），改了什么记在下面；别为了变绿删测试、改断言的意思。
3. **要特别看的编译点**：
   - `WebDav.cs`：`WebDavFailure` 是带位置参数的 record，`FromStatus` 里 `new(WebDavError.Busy, RetryAfter: …)` 这种命名参数；`CredentialCache` 的集合初始化（三个参数的 `Add`）；
     `ByteArrayContent { Headers = { ContentType = … } }` 嵌套的对象初始化；`XmlReaderSettings.XmlResolver = null`（如果报过时，删掉这一行，`DtdProcessing.Prohibit` 就够了）；
     `HttpRequestException.HttpRequestError`（.NET 8 起）。
   - `SyncServer.cs`：`Known` 里 `return cond ? (SyncFile.MaxBytes, 3) : null;`（返回 `(long, int)?`，靠目标类型）；`ServerLedgerJson` 源生成（`ServerLocal` 是带主构造函数的 record）；
     async 本地函数 `PrepareAsync` 改外面的 `left`。
   - `SettingsWindow.SyncServer.cs`：`ContentDialog` 的 `PrimaryButtonClick` / `SecondaryButtonClick` 里先 `args.Cancel = true` 再起一个不等的 Task；`Closing` 里正在测试 / 连接时不让关。
   - `Glyphs.Server` 用的是 `\uE8CE`（MapDrive，映射的网络驱动器）：截图里看一眼是不是这个样子，不对换成 Segoe Fluent Icons 里像服务器 / 网络驱动器的那个。
4. **占位**（W1）：`SyncServerTests.PlaceholdersForWhatIsNotFetchedYet` 在 Windows 上才验得到 `FileAttributes.Offline`；另外真跑一次时看镜像目录里没拿下来的文件属性带「脱机」，拿下来后没了。
5. **真服务器**：`$env:KITTY_WEBDAV = "地址|用户名|密码"` 跑 `SyncServerTests.LiveServer`。**只用测试账号**（AGENTS：用户真实的账号要先问）：审查方 Mac 上的 Apache mod_dav 开在局域网里
   （起法在 mac `webdav-wip` 的 `macos/HANDTEST.md`「WebDAV 同步」开头），或者用户另给的 Nextcloud / 坚果云测试账号。有条件再把 Apache 换成 Digest 跑一次（D2 的 Digest 那条只有这里测得到）。
   结果写下来：服务器是什么、访问日志里空闲一轮几个 PROPFIND、只 GET 对方变了的、图片先 PUT 临时名再 MOVE、标记第二次 PUT 回 412。
6. **手测**：`HANDTEST.md`「PLAN-v19」1212–1224。要真 Mac 的那几条（5、7）能做就做，不能标「没测」。
7. **截图**（`0.3.0-v19/`）：「同步」没开（两个按钮）、对话框（空的、http 橙字、测试连接成功 / 失败、问合不合在一起）、开着连服务器（正常、还有几个没拿下来 / 没传上去、请求太多），
   浅色、深色、高对比度。
8. **自查**：内存探针（开着连服务器同步时多多少）；空闲 CPU（同步关着时为 0；开着时一分钟一轮）；新日志里没有服务器地址、用户名、密码（`sync.server-*` 那几行只记个数和出错的种类）。

### 替用户定的 / 和方案不一样

- 对话框放在 `SettingsWindow.SyncServer.cs`（partial），不是方案写的 `SyncServerDialog.cs`：和别的页一样拆文件，用得到 `JoinNote`、`BuildPage`。
- 连接那一串（看文件夹、没有就建、拒绝的几种、写标记）放进 Core 的 `SyncServer.ConnectAsync`，`Syncer.EnableServerAsync` 和单测共用。
- 电脑编号除了 `SyncFolderRules.IsDeviceName`，还要不带小写字母、不是 Windows 的保留名（CON、NUL、COM1……）：两边自己生成的编号都是大写 UUID，小写的、保留名的只会是别的程序写的。
- 本机的镜像写不进去（盘满了）是单独一种出错 `WebDavError.Disk`（「这台电脑上的同步副本写不进去…」），mac 是算成「连不上」。
- 「选择文件夹…」之前先 `ForgetServer`（以前连过服务器、没停干净时把密码和镜像清掉）。
- 便签同步关着时 pull 照样拿便签和图片（同 mac）：只在 merge 时不用；ponytail，关着便签又连服务器的人多拿几个文件。

### Windows 核验结果（2026-11-13，Claude 在 Windows 上，`windows` 线）

照上面「核验指令」八条：

1. **编译**：只有一处错——`SettingsWindow.SyncServer.cs` 两个按钮的 lambda 参数叫 `_`，`_ = Task` 成了给参数赋值（CS0029），改名 `sender`（`335fa2fe`）；
   其余一次编过，Debug 0 警告；AOT x64 / ARM64 0 个 trim / AOT 警告。`XmlReaderSettings.XmlResolver = null` 没报过时，留着。
   **发布体积**比 0.2.0（同一批代码去掉 PLAN-v19）多 x64 +1.04 MB、ARM64 +1.07 MB（94.91 → 95.95、100.50 → 101.57 MB，全在 exe 里），没到 3 MB。
2. **单测**：893 个全过（WebDavTests 10、SyncServerTests 17，原来的 NoteSyncRunnerTests、SyncIntegrationTests 也过），一个测试都没改。
3. **编译点**：第 3 条列的几处都编过；`Glyphs.Server`（`\uE8CE`）截图里是一个连着网络的驱动器，像服务器，留着。
4. **占位**：`PlaceholdersForWhatIsNotFetchedYet` 在 Windows 上过；真跑（下面第 5 条的自检）：一台先建 71 条便签，另一台第一次连，第一轮镜像里 42 个带「脱机」属性的占位、
   状态「还有 42 个没拿下来」，第二轮 2 个，第三轮 0，便签 33 → 73 条，中途没报错、没删东西。
5. **真服务器**：没有用户另给的测试账号，审查方 Mac 上的 Apache 在那边的局域网、这台够不着，所以写了一个本机的 WebDAV 测试服务器（Python 标准库、只听 127.0.0.1、Basic 或 Digest，
   不进仓库，在会话的临时目录里）。`SyncServerTests.LiveServer`：Basic、Digest 各跑一次，都过。另加测试档自检 `--sync-server-probe=<目录>`（`App/SyncServerProbe.cs`，
   连 `KITTY_SYNC_PROBE` 给的服务器，走真的 `Syncer.EnableServerAsync` / `RoundAsync`，可以先建便签、带图），两份 Dev 档轮流连同一个文件夹，访问日志看到：
   - 空闲一轮只有 3 + 2 × 台数个 PROPFIND（一台 5 个、两台 7 个），没有别的请求；
   - 另一台回来时只 GET 对方的那几个文件，自己的不拿；
   - 图片先 PUT `images/.kitty-<编号>.partial` 再 MOVE 成正式名，`images/` 里没留下 .partial；
   - 标记只 PUT 一次（第二台读到标记不写）。「标记第二次 PUT 回 412」要两台同一刻第一次连才碰得到，没造出来，靠单测。
   **发现**：服务器要 Digest 时，换成 Digest 的 client 之后**每个请求还是先回一次 401** 再带上认证（.NET 的 `SocketsHttpHandler` 不预先带 Digest，`PreAuthenticate` 只管 Basic），
   请求数翻倍：按次数限流的 Digest 服务器上，「一轮 40 个」实际是 80 次。没改（要自己算 Digest 的 nonce / nc；常见网盘、NAS 的 WebDAV 都是 Basic），记在这里给审查方定。
6. **手测**：HANDTEST 1212–1224 各条后面注了验到哪；要真 Mac 的、要网盘客户端的、断网、真限流、卸载没测。
7. **截图**（`windows-shots` 的 `0.3.0-v19/`）：`--ui-snapshots` 加了 `settings-sync-*`（要 `KITTY_SNAPSHOT_DAV`、`KITTY_SNAPSHOT_DAV_SHARED` 指着本机测试服务器）：
   没开、对话框（空的、http 橙字、测试连接成 / 不成、问合不合在一起）、连上（正常、还有几个没拿下来 / 没传上去、请求太多），浅 / 深。高对比度没截（要改系统主题，照旧不动）。
   截图里看出来两处排版，改了：转圈藏着时说明文比下面的橙字多缩进 8 px（列间距照留）；问句的正文在对话框里居中、和左对齐的标题错开。
8. **自查**：Release 探针档，只有托盘：连着服务器 54.2 MB、没开同步 53.9 MB（+0.3）；空闲 CPU 连着服务器 0.013 %（量的 120 秒里正好两轮）、关着 0.013 %；
   日志里 `sync.server-*` 只有个数和出错种类，几份测试档的日志里都没有服务器地址、端口、用户名、密码；settings.json 里没有密码。

## PLAN-v18（mac 0.7.3 之后的改动，2026-11-13 用户「给我命令吧，我让 windows agent 开始实现」= D1–D13 按推荐）

方案在 `PLAN-v18.md`。**你们自己写、自己编译、自己验**，照 `AGENTS.md`「每一批的流程」走，一批一个（或几个）提交，报告写在提交正文里；
这一节下面每批记一句：做了什么、量到的数、替用户定的、没做成 / 没测的。手测接着 `HANDTEST.md` 末尾编（PLAN-v19 占到 1224，从 1225 起）；
截图推到 `windows-shots` 的 `0.2.0-v18/`、`0.3.0-v18-<批>/`。

**mac 的源码**：PLAN-v18 §1 每一行都有提交号，`git show <提交号>` 看正文和 diff，`git show origin/macos:macos/KittyTools/<路径>` 看整个文件；
mac 的单测在 `macos/KittyToolsTests/`，样本和期望值能搬就搬。只看行为，不搬 AppKit 的写法。

### A. 0.2.0 收口（R69–R74 修完之后、改版本号之前）

| 条 | 要做的 | 怎么验 |
|---|---|---|
| S1 | `Core/ScrollPacer.cs` 的 `Frame` 加封顶：比上次接上的那一帧最多领先半个选区高（换成滚轮单位要除以 `Gain`），到顶就不发；`After` 判断「到头」改成「自上次接上以来发过」，封顶时一帧没发、画面也没动照样算到头。mac `176ad8b1`（`ScrollCapture.room` / `maxLead`） | 单测：拼接慢（连着几帧不调 `After`）时 `Posted − PostedAtReference` 不超过半个选区高；封顶后画面不动能停 |
| S6 | 截图翻译盖回：翻之前记下（选区，原图块）；`ScreenshotSession.SetSelection` / `ClearSelection` 一处兜住，选区一变就把原图块贴回冻结帧、重建 `_bitmap` / `_layer`、提示「选区变了，已换回原文」；同一选区再翻从原图块截；翻到一半选区变了不贴。mac `758c4d44` | `--overlay-translate-probe` 加一步：翻 → 换选区 → 冻结帧那块和原图逐字节相同；真机清单第 27 条 |
| S12 | `Core/OcrText.cs`：列表记号「1.」「1)」后面不要求空白（小数、版本号别认成列表：照 mac `43931601` 的判断）；列表项后面接着的正文另起一段 | 单测照 mac `ScreenshotOverlayTests` / `ScreenshotTests` 里这次加的几条 |
| L12 ① | `App/UpdateHttp.cs` 遇到 403 / 429 抛一个能认出来的错；`UpdateService` 的轻提示和关于页那一行说「GitHub 限流了，稍后再试或到发布页下载」，带发布页链接 | 单测或本地测试源回 403 / 429 |
| L12 ② | **更新清单**：`build-release.ps1` 多出 `windows-update.json`，键照 mac 的 `macos-update.json`（`version`、`page`），zip 按架构分两份（`x64` / `arm64` 各一个 `{url, sha256, size}`）；**格式发布后只加新键**。App 先读 `https://github.com/YyAdnBug/kitty-tools/releases/download/windows-update/windows-update.json`（`IsAllowedDownloadUrl` 已经认这个地址），解析写成 Core 纯函数：版本不比当前新、地址过不了白名单、缺字段都当「读不到」，读不到退回现在的 API；下载照旧核 `.sha256`。**别建 `windows-update` 这个 release**（发布由用户做）：把两步写进 `build-release.ps1` 头部注释和发布说明——第一次 `gh release create windows-update --prerelease --latest=false`，以后每版 `gh release upload windows-update windows-update.json --clobber`，传完 `curl -fsSL` 那个地址核一遍 | 单测：清单解析、坏清单、退回 API；本地 file:// 测试源走清单那条路 |
| L13 | `Core/Notes/NoteDeckLayout.cs`：删掉 `IsJoined` / `FreeEdge`，每块屏都放选的那条边（`:508`）；Alt 拖药丸贴鼠标所在那一半的边、不管相接（`:578`）；设置 › 便签 两处文案删掉「两块显示器相接的那条边不放…」（`SettingsWindow.Notes.cs:65`、`:132`）。`NoteDeckLayoutTests.cs:275-312` 锁的是旧规则，**这是用户改了规则**（mac issue #11，方案 A），照新规则改写，不算为了变绿改断言；加一条照 mac 的 `externalMainKeepsTheChosenEdge` | 单测；真机清单第 28 条 |
| L7 | 先在中文 Windows 上看：启动器搜「命令提示符」「mlts」搜不搜得到。**搜不到**才改 `Launcher/AppCatalog.cs:171`：扫描时取显示名（`SHGetLocalizedName` 或 `SHGetFileInfo(SHGFI_DISPLAYNAME)`），英文文件名也留在可搜的名字里；更新日志草稿里那条（L7）留着。**搜得到**就不改，删掉草稿里那条，这里记「没复现」 | 真机清单第 29 条 |

真机清单第 26–30 条、更新日志草稿的几条 fix 已经加在上面「0.2.0 发版前审查」里。L8、L11 不改代码，只在真机清单里看。

**收口结果**（Windows 2026-11-13，提交正文里有全文）：

- S1 → `73cef009`：`ScrollPacer.Frame` 封顶半个选区高（`MaxLead`、`Room`），「到头」改看自上次接上以来发满一格；光标在面板附近时不对账（同 mac）。单测照 mac 的样本 + 拼接慢 120 帧不调 After + 封顶后能停。
- S6 → `b3af5a04`：Core `InPlaceOriginal`，`SetSelection` / `ClearSelection` 一处兜住。**和指令不一样**：`--overlay-translate-probe` 只走识字和合成、不起真遮罩，加步骤验不到冻结帧，改成 Core 单测逐字节（`InPlaceOriginalTests`）；真遮罩留真机清单第 27 条。
- S12 → `94c5e59b`：ListMarker 不要求空白（紧跟数字、点的不算），列表项后面左边缩回半个字的另起一段。单测照 mac 那张截图的行框。
- L12 → `78d1ea49`：① 403 / 429 认成限流、关于页和轻提示写清楚、「打开发布页」；② `windows-update.json`（Core `UpdateManifest`、`build-release.ps1` 生成、头部写了两步发布命令），**没建 `windows-update` release**。**和指令不一样**：清单读到了就以它为准（同 mac），版本不比当前新**不**退回 API——已是最新的用户占多数，退回等于每次都走 API、限流照旧。
- L13 → `1a0e4b48`：删 IsJoined / FreeEdge，锁旧规则的三个单测照 mac 改写（用户改了规则）。
- L7 → `845e027e`：**复现了**（这台中文 Windows 11 上搜「命令提示符」「mlts」只有网页搜索），标题取 SHGFI_DISPLAYNAME、英文文件名也能搜，子文件夹名同样取显示名；更新日志那条留着。
- 顺带：`2931b88e` 自检档的新档不弹欢迎引导（--smoke、KITTY_ONBOARDING=1 除外）——R69 修好后内存探针的「只有托盘」量成了带设置窗的 74 MB。

### B. 0.3.0（`windows-0.2.0` 切出去、PLAN-v19 核验完之后）

> **2026-11-14 用户：「把 WebDAV 和 PLAN-v18 第 1–8 放到 0.2.0 里面」**。下面写的「0.3.0」都并进 0.2.0：版本号回到 0.2.0，0.3.0 那条更新日志并进 0.2.0（长截图的两条修合成一条）；
> 「新」只留便签、提醒、状态屏三条（一版最多 3 个），脚本命令、WebDAV 不标；`windows-0.2.0` 用一个合并提交指到 `windows` 的同一棵树（不强推），在那里重新打包。真机清单加了 31–37 条。

照 `PLAN-v18.md` §3 第 1–8 批，D1–D13 都按推荐。几点：

- **第 1 批**：S2 改了抓帧节奏，长截图进行中和结束后的空闲 CPU 都量一下写进报告；S14–S19 长图标注窗口一起改；标注样式加字段后，旧的截图历史照读（单测拿一条旧格式的样式串）。
- **第 2 批**：S7 照 PLAN-v16 S1b 的「小选区」原文 + mac `96e78116` `077501b7`（`43931601` 的「单行的段先保原字号」也在这批）；S8 先写随机版面的测试再改；S9 的窄栏和 S7 的卡片是一扇窗。
- **第 3 批**：PLAN-v17 整份 + PLAN-v18 L10 的两句；S3 照 D4；L9 照 D6（Raw Input，管理员窗口在前台时收不收得到写进报告）。
- **第 4 批**：L2、L4、L3；`ReminderPhrase.cs:370` 的用法提示照 mac `15bcac45` 写用户打的那个词。
- **第 5 批**：L5、L6 + PLAN-v18 §6（= 主检出里没提交的 PLAN-v16 §4，便携软件）。
- **第 6–8 批**：脚本命令 L1，照 D7–D9；mac 的代码在 `Launcher/Script*.swift`、`Shell/Subprocess.swift`，规矩在 mac 的 `.claude/skills/` 里搜「脚本」。三轮评审修的口子（看全文不可跳过、看不见的字符不放行、密码不拿去搜、停得掉）都要有，各写单测。
- 0.3.0 的「新」标记三项、版本号、更新日志在最后一批定。

#### 各批结果（Windows agent 写）

- **第 1 批（`a40e5b53` S5 S2、`b066b09c` S16 S14、`11707cad` S17、`39cf9750` S15 S18 S19）**：长截图手动滚的节奏和「对不上」的提示、尺寸胶囊先放选区外、打码改高斯模糊 + 改名 + 模糊在前、八个手柄 / Shift 保比例 / Alt 从中心、一键打码（手机号 / 邮箱 / 卡号 Luhn / 身份证校验位）、文字字号 12–72、序号改编号和拖角改大小、双头箭头、吸管取色。AOT x64 / ARM64 0 警告；906 测试；`--overlay-translate-probe` 真识字认出电话、邮箱、订单号不盖。
  内存全量（39cf9750 vs 0.2.0 包，这份也带着 PLAN-v19 的同步代码）：只托盘 54.2 / 53.5 MB，开截图遮罩 76.2 / 74.6，最后静置 98.6 / 96.7（+0.7…+1.9 MB）。
  没做：长图标注窗口里的「自动」、吸管、A− / A+、改编号（只做在截图遮罩里）；S2 没像 mac 那样叠着截、不被滚轮叫醒。没量：长截图进行中的 CPU（没有不靠合成输入开长截图的自检）。手测 1238–1246。
- **第 2 批（`a744f513` S11，`git log --grep "PLAN-v18 第 2 批"`）**：mac 第二轮排版整段搬进 Core `ScreenshotOverlay.Layout`（同段原字号 → 原位 → 往右撑 → 用周围空白居中，都要「在图里、不碰别段原文和已排好的段、那块是空的」；字号下限 10 pt × DPI 和基准的 3/4 取大，基准本来就小的不缩；放不下的进 Leftovers），去字只在原文框里取字色、留原文的段一个像素不动、色块里的字不连段外一起抹；`ITextMeasure` 加 Extent / SplitsWord / Ascent（Win2D 那边按字符区块认断行——`CanvasLineMetrics` 带 bool 字段，CsWinRT 封送不了，Debug 也一样抛）。
  界面：翻完总挂卡片（`SelectionOverlayWindow.TranslationCard.cs`，窄栏 = 「译文」｜看原文｜拷贝｜✕，有放不下的段时列原文一行 + 译文全文、可选中），位置是 Core `SelectionChrome.TranslationCard`（mac cardPlacement 的单测换成左上原点照搬），尺寸胶囊给卡片让位；Esc / 选区一变 / 切录屏 / ✕ 收。
  单测 920（新 14：mac 的十个排版 + 400 个随机版面、去字不动图标、卡片位置、标题和提示）；`--overlay-translate-probe` 新加「小选区」两条：150 % 下紧贴一行 → 图不变、1 段进卡片；上下留 40 像素 → 用空白排、不进卡片。
  替用户定的：卡片在 Windows 上没有 mac 的「从边长出来」，用工具栏同一个入场（Pop，往选区那边让 6）；卡片里的字是 WinUI 可选中的 TextBlock，右键菜单是系统的「复制 / 全选」（mac 关了右键菜单是因为系统菜单压在遮罩下面，WinUI 的在同一扇窗里）。
  没测：真翻译服务、真点卡片和 Esc 顺序（HANDTEST 1247–1257）。
  内存全量（478efded vs 0.2.0 包，各两轮取第二轮）：只托盘 53.4 / 53.4 MB，开截图遮罩 75.2 / 75.1，最后静置 99.4 / 97.8；空闲 CPU 0.021 %（静置 30 s 后量 300 s；量 120 s 那次是 0.052 %，同一个包，抖动）。
- **第 3 批（`git log --grep "PLAN-v18 第 3 批"`）**：PLAN-v17 整份 + L10 两句、S3、L9。
  - 按应用停用（Core `HotKeyBlock`，`Shell/HotKeyBlocker.cs`）：前台切换挂 `EVENT_SYSTEM_FOREGROUND`（进程外、不轮询），取 exe 名算规则交给 `HotKeyManager.Apply`——规则不变什么都不做，变了只注销 / 补注册变了的那几个 id（失败原因不清）。前台是 Kitty 自己时沿用上一个外部前台（L10 ①）；名单、全屏开关一保存就按此刻的前台重算（L10 ②，`ShellRuntime.OnSettingsChanged`）。截图停着期间只记规则（H4）。全屏游戏 = `QUNS_RUNNING_D3D_FULL_SCREEN` / `PRESENTATION_MODE`，前台变时和热键按下时各查一次。设置页一节 + 全屏开关、托盘一项（用最后一个不是任务栏 / 桌面 / 资源管理器 / 我们的窗口）、导出导入 `hotKeyBlockedExes` `hotKeyBlockFullscreen`。
  - 截图时的键（Core `ShotKeys`，24 项：mac 的 21 项 + 截图翻译、自动滚、裁剪）：设置 › 快捷键「截图时」两组、工具栏右键改键（钮亮粉底、Esc 只取消改键）、悬停提示 / 速查表 / 长图标注窗口都按现在的键；固定的键、截图里重复、和全局快捷键一样的不收；导出导入 `shotKeys`（读文件时重复的丢掉）。`HotKeyRules.TryParse` 补认标点键和「VKxx」（Format 本来就会写，读不回来）。
  - 连按两下 Ctrl / Alt / Shift（Core `ModifierTaps` 照 mac 的状态机，毫秒；`Shell/ModifierTapListener.cs`）：Raw Input `RIDEV_INPUTSINK` 挂在隐藏窗口，只在有动作设成连按时才注册；`hDevice == 0`（SendInput，含我们自己粘贴的 Ctrl+V）滤掉；中间按了普通键作废。记成修饰键自己、写法「Ctrl+Ctrl」；Alt / Shift 的副作用写在那一行下面。
  - 验：单测 938（新 18：HotKeyBlock 6、ShotKeys 4、ModifierTaps 8）；`--hotkey-block-probe`（Debug，假装前台换 exe、不发按键）全对，注册 / 注销 20 次切换中位 0.015 ms、最长 0.045 ms（第一次带上开 / 关 Raw Input 1.6 ms）；AOT x64 / ARM64 0 警告（96.4 / 102.0 MB）；截图 settings-hotkeys-block(-empty)、settings-hotkeys-shot-*、shot-rebind（浅深）。内存全量和空闲 CPU 随第 4 批补。
  - 替用户定的：托盘那一项认「最后一个外部窗口」时跳过 `XamlExplorerHostIslandWindow`、`Windows.UI.Core.CoreWindow`（开始菜单、通知中心）；截图时的键多出截图翻译、自动滚、裁剪三项（Windows 工具栏上有）；连按两下只听键盘，中间点了鼠标也算（听鼠标要收每一下移动，`ponytail:`）；同一个连按键只认第一个动作，第二个那一行写「和「…」重复」。
  - 没测：W3（管理员窗口在前台时 RegisterHotKey / Raw Input 收不收得到）、W4 远程桌面、独占全屏游戏、真按键（录制框、截图里改过的键、连按两下）、托盘那一项（HANDTEST 1258–1271）。
  - 空闲 CPU 0.021 %（静置 30 s 后量 300 s，同第 2 批）。内存全量（3979f9fe vs 478efded）：只托盘 53.7 / 53.6 MB，开启动器 63.9 / 63.1，开截图遮罩 77.5 / 76.2，最后静置 99.5 / 99.0。
- **第 4 批（`git log --grep "PLAN-v18 第 4 批"`）**：L2、L4、L3 + `15bcac45` 的用法提示。
  - 命令和别名（Core `LauncherCommandTable`，照 mac LauncherCommands）：12 条关键词命令（open find quit hide forcequit kill port ip cb fy remind currency，提醒 / 汇率默认英文）+ 12 条系统命令，每条别名 + 开关；`LauncherModel.Search` 一开头把别名换回原关键词交给原来那一套，原关键词改掉 / 关掉的挡住；补全提示换词或不出；关掉的系统命令搜索、常用、收藏里都藏；汇率关掉不换算、不取表。提醒的用法提示写用户打的那个词。
  - 设置：启动器页「命令与网页搜索」两行推子页（命令和别名、网页搜索与快捷链接），通用页「功能 ›」一行推子页；两行的小字照 mac 的 summary（Core `SettingsSummary.Features`、`WebSearch.Summary`）。别名撞了（别的命令、网页搜索关键词）描橙框。
  - 命令快捷键（L3，`Launcher/LauncherCommandKeys.cs`）：表里「快捷键」一列，和全局快捷键、别的命令查重；HotKeyManager 每条命令一个固定热键号（1000 起、这次运行不复用）；注册跟着启动器功能开关和那条命令的开关；停用名单「全部」连它们一起停。按了：系统命令直接跑、要确认的打开启动器填好；关键词命令打开启动器填好「别名 」。导出导入 launcherCommandAliases / launcherCommandsOff / launcherCommandHotKeys。
  - 验：单测 945（新 7：命令表 5、设置小字 2）；`--hotkey-block-probe` 加了命令快捷键四条（名单外注册着、「全部」停、只停几个不管、重新注册热键号还是 1000）全对；截图 settings-sub-*（浅深）；AOT x64 / ARM64 0 警告（96.6 / 102.2 MB）。内存全量、空闲 CPU 随第 5 批补。
  - 替用户定的：脚本命令（第 6–8 批）没有，表里先只有关键词、系统两组，筛选只留「只看开着的」；子页页头的图标是通用的齿轮；命令快捷键不能设成连按两下。
  - 没做：mac 启动器 ⌘K 里「改别名…」直达这一行（要动启动器的操作菜单，跟脚本那几批一起做）。没测：真打字、真按命令快捷键、导出导入（HANDTEST 1272–1280）。
  - 空闲 CPU 0.031 %（静置 30 s 后量 300 s）。内存全量（0a4fc679 vs 3979f9fe）：只托盘 54.4 / 55.0 MB，开启动器 63.7 / 64.3，开截图遮罩 77.9 / 77.8，最后静置 100.8 / 103.0（没涨）。
- **第 5 批（`git log --grep "PLAN-v18 第 5 批"`）**：§6（= PLAN-v16 §4 便携软件，P1–P4 照推荐）、L5、L6。
  - 便携软件（`Launcher/AppSources.cs`、Core `PortableApps`）：A1 桌面（当前用户 + 公用，顶层 .lnk / .exe，副标题「桌面」，和开始菜单按目标去重）；A2 App Paths（HKCU + HKLM，Windows 目录下的不要）；A3 资源管理器的 UserAssist（ROT13 + 72 字节，已知文件夹 GUID 用 SHGetKnownFolderPath 换；设置开关「把运行过的程序也列出来」默认开、不导出）；A4 应用文件夹和单个程序（往下两层、500 个、2 秒超时；找不到的灰着不删；文件搜索结果是 exe 时 Ctrl+K「添加到启动器的应用」）；A5 名单（unins / setup / update / crash / helper… 和说明里的卸载 / 安装 / 更新；没图标的不收；同一个文件夹说明一样的留 64 位那个）+ 「从启动器里隐藏」（按目标，设置里能恢复，跟着导出导入）；A6 打开 exe 时工作目录是它自己的文件夹。
  - 应用别名（Core `AppAliases`，D10）：键 aumid: / exe:（解析出来的 exe 折成 %ProgramFiles% 这类、小写，不用 .lnk 路径），输完整的别名时那个应用排第一；设置 › 启动器 › 应用（别名、应用文件夹、隐藏的应用三块，D10「同一页」）；导出导入 launcherAppAliases / launcherAppFolders / launcherHiddenApps。
  - 按使用习惯排（L6，照 mac ea0c2813）：同一输入 28 天、1024 条、q/(q+0.5)；在更长的输入下选过的按一半算；提到固定行前面只认一字不差（LauncherUsageStore.Chose）；同分时按 UserAssist 记的最后运行（exe 那组 + .lnk 那组）近的在前。旧断言 `Exp(-14/3)` 换成 `Exp(-14/28)`：规格改了（注释写着），不是为了变绿。
  - 验：单测 952（新 7：PortableApps 3、AppAliases 3、同分按系统记的使用 1）；`--launcher-script` 在 .Dev 档给计算器起别名 zz9 → 输 zz9 计算器排第一、输 zz 不出；本机实测 App Paths 27 个、运行记录 14 条（新收 0 个：都已在开始菜单里或被名单拦下）、桌面 0 个，A1–A3 加起来 391 ms（后台线程，主要是给 27 个 App Paths 程序取图标；PLAN 写的目标是 100 ms，没达到，见下）；截图 settings-sub-apps（浅深）；AOT x64 / ARM64 0 警告（96.7 / 102.4 MB）。内存全量、空闲 CPU 随第 6 批补。
  - 替用户定的：A5「没图标的不收」用的是取不取得到 PNG 图标（ShellIcons.LoadPng），没另调 ExtractIconEx；App Paths 的程序也要有图标才收；A3 的副标题写所在文件夹名。
  - 没达到：A1–A3 391 ms > 100 ms（取图标占大头；在后台线程、扫完才换列表，界面不卡；要压就把 App Paths 的图标改成第一次显示时再取）。没测：真桌面上的便携软件、真文件夹、隐藏 / 恢复、工作目录、导出导入（HANDTEST 1281–1289）。
  - 空闲 CPU 0.037 %（静置 30 s 后量 300 s）；内存全量（第 5 批 vs 第 4 批，两份一起跑）：只托盘 51.7 / 52.0 MB，开启动器 58.1 / 63.1，开截图遮罩 72.5 / 77.5，最后静置 96.4 / 98.8（都没涨）。
- **第 6 批（`git log --grep "PLAN-v18 第 6 批"`）**：L1 之一——脚本库和运行（照 mac 7c5ea76e 起的几批，D7 D9）。
  - Core `ScriptCommand`（头部字段同 mac：@kitty.* / @raycast.*，注释多认 ::、REM；按扩展名选解释器：.ps1 → powershell -NoProfile -ExecutionPolicy Bypass -File、.cmd / .bat → cmd /d /s /c、.py 有 py.exe 才认；.sh / .js 记「Windows 版只认…」）、参数（JSON、下拉、密码、percentEncoded、引号）、列表输出、清颜色码和回车、看不见的字（⟦U+…⟧，不放行）；Core `ScriptLaunch`（cmd 的命令行、PATH 从注册表的系统 + 用户重拼、环境加 KITTY_*、UTF-8 判断）。
  - `Launcher/ScriptLibrary.cs`（数据目录 scripts + 自己加的文件夹，顶层、每次呼出后台重读，读不成的记原因，下载来的去掉不可信图标）、`ScriptRunner.cs`（不开窗口、标准输入空、工作目录是脚本的文件夹、默认 60 s，超时 / 停止 / 输出 4 MB 都是 Kill(entireProcessTree)；.py 和存成 UTF-8 的批处理按 UTF-8 读（批处理先 chcp 65001），别的按 OEM 代码页；:Zone.Identifier 下载标记）、`ScriptHost.cs`（下载来的先开窗看全文、1 秒后「正在运行」带「停止」、按 mode 交出结果）、`ScriptTextWindow.cs`（看全文 / 全部输出两用）。
  - 启动器：新种类 Script（行尾「脚本」、命令家族紫），搜标题 / 拼音 / 文件名 / 别名，别名一字不差排第一；「别名 空格 参数」（内置命令先认）一行写各参数；Enter 补「别名 空格」/ 缺必填响一声 / confirm 上膛 / 跑；密码参数不记使用。命令和别名表最上面加「我的脚本」组（别名、开关、快捷键）。
  - 验：单测 965（新 13：ScriptCommand 9、ScriptLaunch 4）；`--script-probe`（新，Debug，临时文件夹真跑）全过：ps1 中文 + 带空格和 & 的参数、退出码、工作目录 / KITTY_SCRIPT_DIR、cmd 存 UTF-8 和 GBK 都不乱码、超时 1 s 停下、停止后子进程 ping 0 个、下载标记；**PowerShell 冷启动约 200 ms**（第二次 190 ms）；`--launcher-script` 在 .Dev 档 scripts 放一个 .ps1：搜得到、「nh 世界」副标题「名字：世界」、Enter 跑完 215 ms；AOT x64 / ARM64 0 警告（97.6 / 103.3 MB，比第 5 批 +0.9 MB）。内存全量、空闲 CPU 和第 7、8 批一起量，记在第 8 批。
  - 替用户定的：mac 在启动器面板里原地看全文 / 全部输出，Windows 的启动器失焦就收，挪到一扇普通窗口；批处理按文件是不是 UTF-8 决定要不要 chcp 65001；.ps1 不带 BOM 的中文 PowerShell 5.1 读成乱码（`ponytail:`，说明里写存成带 BOM）。
  - 没做（第 7、8 批）：列表模式、下拉参数打字时列选项、全部输出认终端颜色、设置页（文件夹、读不成的、新建、怎么写、给 AI 的写法说明）、自带的命令（D8）。没测：粘贴 / 复制 / 全文、confirm、看全文那扇窗、快捷键跑脚本（HANDTEST 1290–1298）。
- **第 7 批（`git log --grep "PLAN-v18 第 7 批"`）**：L1 之二——参数和输出。
  - 列表脚本（mode list）：「别名 空格 参数」停 0.25 s 后台跑（还在打字就撤掉），每行一条结果（Core `ScriptText.Lines`：「标题⇥副标题」或 Script Filter 的 JSON），接着打字重跑；filter 的只跑一次、按打的字过滤；Enter 打开 url / path 或粘贴值，valid=false 响一声，Tab 补 autocomplete；出错那一行写原因。
  - 下拉参数：正在打的那个参数是下拉的就列选项（行尾「选项」、底栏「选这个」），Enter / Tab 补进框（带空白的括引号），交给脚本的是 value；引号参数、密码参数（行上 •••、不记使用）在第 6 批的 Core 里。
  - 全部输出那扇窗认终端颜色（Core `ScriptTerminal`：SGR 8 / 16 / 256 色、24 位、粗体 / 暗 / 斜体 / 下划线 / 删除线，别的控制码去掉、截在一半的先不显示；0–15 按深浅色调过），可选中的 RichTextBlock、边跑边来最多 0.1 s 重画一次。
  - 验：单测 968（新 3：ScriptTerminal）；`--launcher-script`（.Dev 档）：列表脚本「ls9 ab」两行「ab-1 第一」「ab-2 第二」，下拉参数「dw 」列出「毫秒」「秒」；AOT x64 / ARM64 0 警告（97.7 / 103.3 MB）。空闲 CPU 0.037 %；内存全量记在第 8 批（三批一起跑）。
  - 第一次量第 7 批时它一启动就退（Microsoft.UI.Xaml.dll 0xc000027b）：是我拷探针包时把 exe 改名成 KittyProbe.exe、没把 KittyTools.pri 跟着拷成 KittyProbe.pri（找不到资源），不是代码的问题；补上后照常跑。
  - 替用户定的：列表那几行的 Ctrl+C 没做（mac 的 text.copy；Enter 粘贴照常），列表结果不进使用记录。
  - 没测：列表的 Enter / Tab、filter、选项补进框、彩色输出那扇窗（HANDTEST 1299–1303）。
- **第 8 批（`git log --grep "PLAN-v18 第 8 批"`）**：L1 之三——设置、自带的命令（D8）、写法说明；0.3.0 的版本号、更新日志、「新」。
  - 自带的七条（Core `BuiltinTools`，头部同 mac 那几个 .sh：time json uuid bcvt url b64 regt）：C# 算、不起进程，`ScriptRunner` 认出解释器 kitty-builtin 时直接调；排在自己的脚本后面（同关键词用自己的），走同一条路（别名、开关、快捷键、列表 / 粘贴 / 全文）；json / regt 不带文字时读剪贴板（`ReadTextForPin`，标了隐私的不读）。「切换深色模式」做成系统命令 dark（写 AppsUseLightTheme + SystemUsesLightTheme，广播 ImmersiveColorSet，提示里说切成了哪个）。命令和别名表多「自带的命令」一组。
  - 设置 › 启动器「脚本命令 ›」子页（`Settings/SettingsWindow.Scripts.cs`）：启用开关、「怎么写脚本 ›」、让 AI 来写（复制写法说明、从剪贴板新建——`ScriptTextWindow.ReviewNew` 先看全文，看不见的字不让存）、脚本文件夹（新建脚本对话框：名字 / 关键词 / 结果给谁 / 用什么写，存好用文件的「编辑」打开；在资源管理器中打开）、没有自己的脚本时「用例子新建」、其他文件夹（添加 / 移除、找不到的橙字）、读不成的脚本（橙字 + 在资源管理器中显示）。「怎么写脚本」子页照 mac ScriptGuide：让 AI 来写、三步上手、查天气的例子、9 个字段、列表、用什么跑、安全和同步。
  - Core `ScriptTemplates`：新建的模板（PowerShell / 批处理 / Python × 六种结果，都读得回一条命令）、文件名、重名加数字、.ps1 存成带 BOM 的 UTF-8 / .cmd 不带、从剪贴板认脚本（只取第一个代码块，按围栏的语言或 :: / REM 认批处理）、给 AI 的写法说明（字段同 mac，语言和规矩换成 Windows 的：PowerShell 5.1、不用 PS7 写法、`[Console]::Error.WriteLine`、输出按 GBK 读）。默认脚本文件夹第一次建时放两个样板：查天气.ps1（tq，要联网）、数字数.ps1（zs）。
  - 启动器 Ctrl+K：自己的脚本多「编辑脚本」「在资源管理器中显示」。
  - 0.3.0：`Directory.Build.props` 0.3.0；`changelog.json` 0.3.0 一条（12 条：feat 10、fix 1、ui 1）；「新」两条——脚本命令（启动器页「脚本命令」一节）、WebDAV（通用页「同步」一节），都只在设置里，拨过脚本命令的开关 / 新建过脚本 / 点过「连接服务器…」算碰过（`WhatsNewHost.TouchSection`）。0.2.0 那三条照旧（0.2.0 升上来不再标）。
  - 验：单测 977（新 9：BuiltinTools 5、ScriptTemplates 4；WhatsNew 加了 0.2.0 → 0.3.0 那几句）；`--script-probe` 全过，新加：模板存成的 .ps1 / .cmd 真跑出「你好，用户名」、临时文件夹第一次建时两个带 BOM 的样板读得出 tq / zs、自带 time 走 ScriptRunner 0 ms、bcvt 写错退出码 1；`--launcher-script`（.Dev 档）time / bcvt / regt / b64 / dark 的行；截图 settings-sub-scripts / script-guide / script-fields / commands / launcher（浅深）；AOT x64 / ARM64 0 警告（97.9 / 103.5 MB）。
  - 空闲 CPU 0.047 %（静置 30 s 后量 300 s）；内存全量（第 8 批 vs 第 7 批 vs 第 6 批）：只托盘 52.2 / 52.4 / 53.0 MB，开启动器 58.3 / 58.1 / 59.2，开截图遮罩 71.7 / 71.7 / 73.2，最后静置 94.9 / 94.1 / 95.2（都没涨，第 8 批比第 7 批静置多 0.8 MB，在抖动范围里）。
  - 替用户定的：自带的七条做成 C#（D8 推荐），头部和 mac 一样；样板放两个（查天气同 mac 的例子，数字数是 Windows 加的、不联网）；mac 的「拖进来导入」「命令的查找路径」没做（Windows 直接放进文件夹就行、PATH 每次从注册表读）；从剪贴板新建时 AI 前后的话自动去掉（mac 要求第一行是 #!）；「新」的两条都是设置里一节（Windows 设置页里一节标题后的「新」没画，只有侧栏的点）；新建脚本用文件自己的「编辑」打开（.ps1 双击就跑了）。
  - 没做：启动器里脚本行画头部写的图标（都画统一的脚本图标）；⌘K 里「改别名…」直达命令表那一行；「防止睡眠」（等 issue #3）。没测：dark 真切（会改系统主题）、uuid 粘贴、json 的全文窗、新建对话框和从剪贴板新建的窗口、查天气联网（HANDTEST 1304–1317）。

### 停下来问用户

- 建 / 改 `windows-update` 那个 release、打 tag、发布；
- 要加不是微软的包（这一版不该有）；
- 要用真实的账号、服务器、同步文件夹。

## PLAN-v17（按应用停用快捷键，2026-11-10 用户「全部按推荐」）

方案在 `PLAN-v17.md`，PLAN-v16 做完再做。一批，你们自己写、自己编译、自己验；做完在这一节下面记一句：做了什么、量到的数（注册 / 注销耗时）、
W3 管理员窗口和 W4 远程桌面的实测结果、替用户定的、没做成 / 没测的。

- **做完了（2026-11-14，随 PLAN-v18 第 3 批）**：结果、量到的数、替用户定的、没测的写在上面「PLAN-v18 › 各批结果 › 第 3 批」。W3、W4 都没测（要 UAC / 远程桌面）。

## PLAN-v16（跟上 mac 0.7.1 之后的新东西，2026-11-07 用户「让 windows agent 实现」）

方案在 `PLAN-v16.md`。**这一版你们自己写、自己编译、自己验**，五批照 `AGENTS.md`「每一批的流程」走、一批一个（或几个）提交，报告写在提交正文里，
这一节下面每批记一句：做了什么、量到的数、替用户定的、没做成 / 没测的。手测从 HANDTEST 1156 起。开始前先把上面「PLAN-v15」核验完。

- **第 1 批（翻译反馈四条 = PLAN-v14，`git log --grep "PLAN-v16 第 1 批"`）**：有道词典（只查单词和短语、不当主结果、不进静默替换）、认得 mac 的系统翻译和不认识的种类（留着、不开卡、灰字）；卡片喇叭只读释义、读音行带两个小喇叭、英文单词真人发音（3 秒取不到退系统声音）、设置「朗读」两行（键名同 mac）；剪贴板 / 启动器 / 翻译浮窗用系统拖边改大小（下两角也能拖），设置三页「面板大小」。Debug、AOT x64 / ARM64 0 警告，803 测试（新 15 个）；`--panel-resize-probe` 46 条全过；空闲 CPU 0.039 %（同上一轮）；内存并排起三份只托盘没涨（细节在提交正文）。替用户定的：下两角能拖、en-GB 没装退 en-US。没测：真拖、真听、真联网有道、Mac 同步来的系统翻译（HANDTEST 1156–1168）。
- **第 2 批（截图和钉图，`git log --grep "PLAN-v16 第 2 批"`）**：截图翻译把译文盖回截图（开关默认关，Core ScreenshotOverlay / OverlayPixels 照 mac 的分段、拟合、去字、基线、行内代码块；Win2D 画字）、框选时保持原色、钉住剪贴板内容（文字排成卡片）、剪贴板历史文字条目「钉到屏幕」。0 警告，828 测试（新 25 个）；`--overlay-translate-probe` 浅 / 深样图真识字 + 真合成全过（Release AOT 也跑了）；内存全量和 2706ec5 比每一步不超过 +4 MB；空闲 CPU 0.013 %。替用户定的：Windows 识字把一行切成几段时先接回一行。没测：真截屏、真翻译服务、真按键钉图（HANDTEST 1169–1183）。
- **第 3 批（启动器和设置窗，`git log --grep "PLAN-v16 第 3 批"`）**：空搜索框可以不列常用（开关默认开）；浏览器里删了的书签、删了的快捷链接不再以「用过的网址」回来（launcher_usage 加 listed 列，Schema 第 10 步）；关于页更新日志只展开当前版本；设置侧栏照 mac 分组、组能收起、关掉的功能进「已关闭」，新装只开四样、引导里能勾；升级上来的新功能在托盘（「新」）、主界面、侧栏标出来，用一次就消。0 警告，844 测试（新 16 个）；内存全量和第 2 批比每一步 +1.2…+4.0 MB（多在设置窗）；空闲 CPU 0.026–0.078 %。替用户定的：WhatsNew 三项记作 0.2.0、托盘用文字「新」、测试档默认不种新装功能。没测：真浏览器删书签、真点侧栏、引导、真升级（HANDTEST 1184–1191）。
- **第 4 批（状态和提醒的图标、提示音，`git log --grep "PLAN-v16 第 4 批"`）**：图标格子最后一格「其他表情」（叫系统表情面板 Win + .，只收一个表情字，Segoe UI Emoji 画；JSON 里 emoji 键、symbol 写空，没挑的逐字不变，同步那一行和 mac 排好序的键逐字比）；提醒的提示音能选文件（拷进 reminder-sounds\、20 MB 内、放得出来才收、同名同内容复用 / 不同加数字，最多放 30 秒，「知道了」「稍后」、关功能、开始录屏录音时停，没在用的开始运行时清掉），催促「自定义…」1–120；「+」新提醒 Windows 本来就是保存才进列表。0 警告，850 测试（新 6 个）；`--reminder-sound-probe` Debug 和 Release AOT 都全过；内存全量每一步不高于第 3 批；空闲 CPU 0.026 %。替用户定的：叫表情面板发 Win + .、mac 认而 Windows 文件名不许的编号照存不拼路径。没测：表情面板真出来、真到点放长音频 30 秒、录屏时停、真同步（HANDTEST 1192–1202）。
- **第 5 批（上一轮核验留下的，`git log --grep "PLAN-v16 第 5 批"`）**：药丸窗口就是药丸那么大（12 × 高，没边框，系统最小宽高靠 WM_GETMINMAXINFO 放开），感应范围是压在下面的一扇看不见的分层小窗；便签墙卡片标题去 # 按标题字号、列表画圆点；补认测试换成分得出来的场景（不补认会悄悄丢一笔，先验过红）；动画表情 PNG 无损重压 -22.3 %（tools/png-squeeze.cs，WIC 解出来逐字节相同，安装包约小 2.2 MB，JPEG XR 没用）；货币候选截图补拍（测试档拍启动器时关掉书签和历史）。0 警告，852 测试（新 2 个）；内存全量和第 4 批比只有启动器 / 翻译窗两步 +2 MB 左右、别的都低；空闲 CPU 0.013 %（药丸和感应条在）。替用户定的：圆点（mac 是淡色「-」）、DWM 圆角、无损不上有损。没测：真鼠标推到边上扇出、感应范围 8 / 44、不显示药丸、状态屏里的表情（HANDTEST 1203–1208）。
  - 11-08 用户试装后反馈「便签看不到、点不了」：标签列也被系统的最小宽撑大（136，边框外壳下 70）往屏幕外伸，居中的标签落在屏幕外。标签列改用和药丸同一个没边框的外壳（NoteDeckUi.Shell），实测 30 宽贴边；`--notes-ui-probe` 加了「窗口伸到屏幕外」的检查（截图拍整扇窗，看不出这个）。HANDTEST 1209。
  - 11-12 用户反馈两处：换强调色开关不当场变（主题字典里的强调色画刷第一次用时就建好了，现在 ApplyAccent 把浅 / 深两套里那几把画刷就地改色，HANDTEST 1210）；便签的窗口外面一圈白线（DWM 的 1 像素细边框，加上药丸和标签列 WinUI 留着的 3 像素 WS_DLGFRAME：都去掉，NoteDeckUi.NoOutline + WM_NCCALCSIZE，HANDTEST 1211）。

## PLAN-v15（截图拷贝为文件，2026-11-06 用户「全部按推荐」，审查方在 Mac 上写、**没编译**）

方案在 `PLAN-v15.md`（同 mac `copyfile-wip`）。一个提交，`git log --oneline --grep "PLAN-v15"`。你们只编译、核验、修编译错和屏幕上不对的地方，改了什么记在这一节下面。

- **改了哪些文件**：`App/Settings.cs`（`ScreenshotCopyAs`）、`Storage/ArchiveService.cs`（导出导入 `screenshotCopyAs`，只认 `image` / `file`）、
  `Screenshot/ScreenshotOutput.cs`（`CopyPngAsync` 多了 title / source / showSize / existingFile 四个可选参数和拷成文件那一支；`TempFolder`、`WriteCopyFileAsync`、`PurgeStaleTemp`）、
  `Screenshot/ScreenshotCard.cs`、`PinWindow.cs`、`ShotHistoryWindow.cs`（三处拷贝改成调 `CopyPngAsync`）、`Shell/ShellRuntime.cs`（启动时多清 `copy\`；`ScheduleBackup` 里调 `PurgeStaleTemp`）、
  `Settings/SettingsWindow.cs`（「截图拷贝为」一张卡、搜索词、页头说明）、Core `ShotHistoryRules.StaleTemp` + 单测 `ShotHistoryTests.StaleTempKeepsTheLastDay`。
- **要特别看的编译点**：`PurgeStaleTemp` 里两种 `Select` 出来的元组（`(path, DateTime)`）拼成一个 `List` 再传给 `StaleTemp(IEnumerable<(string Path, DateTime ModifiedUtc)>)`，名字不同、类型一样；
  三处调用方里 `ClipboardWriter` 可能只剩 `using` 没用上（`ShotHistoryWindow` 的多选拷贝、录制条目还在用 `WriteFiles`）；`ScreenshotCard.CopyAsync` 外面的 `try` / `catch` 留着。
- **核验**：`dotnet build` 零警告、`dotnet test` 全过（新加 1 个）、Release AOT 两个架构零警告；设置 › 截图浅色 / 深色各截一张（「截图拷贝为」那张卡在「快速保存到」说明下面）；
  然后走 `HANDTEST.md` 1148–1154（1150 对拷线标「没测」，留给用户）。
- **别补写剪贴板**：同日的 `49d3b01e`（拷成文件后补写两遍）已经 revert——mac 上实测补写让点按钮那条也传不过去了。手测 1155 记下
  Ctrl+C 和点按钮各自能不能传；Ctrl+C 不行的话照 PLAN-v15 那段改成延迟渲染，交审查方。
- **替用户定的**：钉图拷成图像时提示照旧不写尺寸（原来就不写）；「剪贴板被别的程序占着」统一成角落卡原来那句「…，稍后再试」；清理挂在 `ScheduleBackup`（启动、解锁、唤醒）上，Windows 没有换日事件。

### Windows 核验结果（2026-11-07，Claude 在 Windows 上，基于 origin/windows `80af19a`）

1. **编译**：一次就过，没有编译错。Debug x64、Release AOT x64 / ARM64 **零警告**（加了自检之后两个架构又发了一遍，照样零警告）；审查方说的几处编译点都没事
   （`PurgeStaleTemp` 的元组名字不同、类型一样，能拼；三处调用方没有多余的 `using` 警告）。
2. **单测**：789 个全过（788 + `ShotHistoryTests.StaleTempKeepsTheLastDay`）。
3. **设置 › 截图**：浅色 / 深色各一张真窗口（`--ui-snapshots` 里给截图页加了一张 WGC 的 `settings-screenshot-*-window.png`），「截图拷贝为」那张卡在「快速保存到」说明下面，默认「图像」，
   深色下字和下拉都看得清。截图在 windows-shots `0.4.0-v15/`。
4. **自检 `--copy-file-probe=<目录>`**（新加，只在测试档，`App/CopyFileProbe.cs`）：不开截图界面、不发按键，直接调 `CopyPngAsync` 的几组参数，每步读回剪贴板，提示卡各拍一张。
   Debug 23 条全过、Release AOT x64 的 exe 也跑了一遍（同样全过）。测了：默认 image；图像 = PNG + DIBV5、没有 HDROP；文件 = 只有 CF_HDROP 一个文件 + Preferred DropEffect 1、
   文件在 `copy\<编号>\截图 日期 时间.png`、内容就是这张、同一秒再拷是新子文件夹；剪贴板历史两种都记成图片、来源对（截图 / 截图历史 / 钉图）；截图历史给的现成文件原样用、不在了另写；
   钉图提示「已复制钉图」（文件时小字是文件名、图像时没有小字）；另一根线程开着剪贴板时两种都返回 false、提示「没能复制 / 剪贴板被别的程序占着，稍后再试」；导出导入带着走、不认识的值不改；
   `PurgeStaleTemp` 删两天前的、留新的；Dev 重启后 `copy\`、`history\` 都清空了。
   - **怎么没碰用户的剪贴板**：自检开头备份剪贴板、结束写回去；自检期间每次写入都带 `ExcludeClipboardContentFromMonitorProcessing` + `CanIncludeInClipboardHistory = 0`
     （`ClipboardWriter.QuietForProbe`，只在测试档生效），用户开着的正式版和 Win+V 都不记；`TMP` 指到临时目录，正式版拖出去的 `%TEMP%\kitty-shots` 没动。
   - 为了自检加的产品代码只有两处：`ClipboardWriter.QuietForProbe`（测试档以外不生效）、`ClipboardFormats.ReadForProbe`（只读）。
5. **手测**：HANDTEST 1148、1151–1154 能用自检和代码验的那部分写了「Windows 11-07」；1149（聊天程序 / 画图）、1150 / 1155（对拷线）、真按 Ctrl+C、资源管理器里粘、Win+V、
   真锁屏解锁都**没测**，留给用户。没补写剪贴板（照旧编码完写一次）。
6. **没改审查方的代码**：PLAN-v15 的产品代码原样能用，这次只加了自检和截图。

## PLAN-v13（便签，2026-11-05 用户「继续新会话剩下的，现在不检查，最后一次性检查」）

方案在 `PLAN-v13.md`（不是拍板页，行为照 mac 0.6.0 起的便签，`macos` b7a55e33；Windows 自己定的在 §3）。和 PLAN-v12 一样**全部在 Mac 上写、一行都没编译**，
中间不交给你们核验；全部写完后统一核验（核验指令就在下面，覆盖 PLAN-v12 + PLAN-v13）。下面每批写清写了什么、要特别看的编译点、替用户定的。

### 给 Windows agent 的核验指令（PLAN-v12 第 1–7 批 + 复查 + PLAN-v13 第 1–8 批 + 复查，审查方 2026-11-05）

这一份**取代** PLAN-v12 那一节底下的核验指令（那份照旧有效，内容都并进来了）。PLAN-v12 第 1–7 批、`83040384`、`36aafcdf`（v12 复查）和 PLAN-v13 第 1–8 批、`git log --grep "PLAN-v13 审查方复查"`（v13 复查）
都是审查方在 Mac 上写的，**一行都没编译过**。你们只编译、核验、修编译错和屏幕上不对的地方；改了什么在对应那批下面记一句（改了什么、为什么），不许为了变绿删测试、改断言、改 golden。

1. **拿代码**：`git fetch origin && git rebase origin/windows`。`git log --oneline --grep "PLAN-v12"` 有第 1–7 批，`83040384`、`36aafcdf` 在；`git log --oneline --grep "PLAN-v13"` 有第 1–8 批和「审查方复查」那个提交。
   PLAN-v13 中间几批单独编译不过（互相引用后面批次的类），**从最后一个提交起编译**，不用逐个提交编。
2. **编译零警告**：`dotnet build windows/KittyTools.slnx -c Debug -p:Platform=x64`；`dotnet publish windows/KittyTools/KittyTools.csproj -c Release -r win-x64` 和 `-r win-arm64`，零 trim / AOT 警告；
   发布目录里有 `KittyTools.pri`、`Microsoft.UI.Xaml.Controls.pri`、`Resources\StatusEmoji\`（34 张 PNG + `manifest.txt` + `LICENSE.txt`）。各批「要特别看的编译点」写在那一批下面（v12 在 PLAN-v12 一节，v13 在本节）。
3. **单测**：`dotnet test windows/KittyTools.Tests` 全过。PLAN-v12 新加的见 PLAN-v12 那份指令第 3 条；PLAN-v13 新加的：`NoteTasksTests`、`NoteImagesTests`、`NotePaperTests`、`NoteMarkdownTests`、`NoteStylesTests`、
   `NoteBookTests`、`NoteSyncTests`、`NoteSyncRunnerTests`、`NoteUndoTests`、`NoteCaptureRulesTests`、`NoteWallTests`、`NoteDeckLayoutTests`、`NoteFloatLayoutTests`、`NoteMarkdownFilesTests`。
   **和 mac 互通的底线**：`NoteSyncTests` 的 golden（`Fixtures/notes-sync-golden.json`，1830 个样本逐字节）、`ReminderTests.Canonical_MatchesMacByteForByte`、`StatusScreenTests.Sync_MatchesMacAndPlans`——过不了先把实际输出贴在那一批下面，别改 golden。
   再跑一遍随机测试：`$env:KITTY_NOTES_SYNC_FUZZ=2000`（报告里写耗时）。
4. **先验便签的编辑器**（PLAN-v13 第 4 批那 7 个 RichEdit 行为点）：它决定便签能不能用。任何一条不对按那里写的退路改，记在第 4 批下面，再往下走。
5. **状态屏只走自检**：`KittyTools.exe --status-screen-probe=<临时目录>`。任何测试、自检、截图都**不许真的进入状态屏**；要真进入的手测留给用户，标「没测」。
6. **手测**（`HANDTEST.md`）：PLAN-v12 那几段（906–1042，见 PLAN-v12 那份指令第 5 条），PLAN-v13：1043–1044（第 1 批）、1045–1053（第 2 批）、1054–1063（第 3 批）、1064–1076（第 4 批）、1077–1096（第 5 批）、
   1097–1118（第 6 批）、1119–1132（第 7 批）、1133–1139（第 8 批）、1140–1147（v13 复查）。要真鼠标拖、第二块屏、真的 Mac 的，能做的做，做不了的标「没测」；结果写在那一条后面。
   同步、导入导出只用临时文件夹和 `.Dev` 的假数据，不碰用户真实的同步文件夹和便签。
7. **截图**：v12 各批目录见 PLAN-v12 那份指令第 6 条；PLAN-v13：`0.4.0-v13-batch-4/`（正文：标题 / 粗斜体 / 任务五态 / 颜色 / 代码块 / 图片）、`0.4.0-v13-batch-5/`（快速记一条、全部便签窗口的墙和列表、设置 › 便签、速查表「便签」）、
   `0.4.0-v13-batch-6/`（药丸、扇出的标签列、预览卡、打开的便签、浮动便签）、`0.4.0-v13-batch-7/`（裁切对话框、图片宽度菜单），浅色、深色、高对比度各一张。先在 `../kitty-shots` 里 `git fetch origin && git reset --hard origin/windows-shots`；只截自己的窗口。
8. **自查**：内存探针（`KITTY_MEMORY_PROBE=1`，和 `1986a4b5` 比，涨超过 5 MB 写原因；便签窗口都关着时不该多出东西）；只有托盘静置 60 s 空闲 CPU 为 0——**屏幕边缘那叠静置时没有计时器**（扇着、开着时每 150 ms 看一次鼠标，收回后停），
   提醒边框挂着时 30 Hz、收起后回到 0；新日志里没有剪贴板内容、原文、译文、URL、提醒和状态的标题、**便签的标题 / 正文 / 文件路径**。
9. **版本**：PLAN-v12 第 1–2 批是 0.2.0、第 3–7 批是 0.3.0，PLAN-v13 是 0.4.0；版本号、更新日志、`build-release.ps1` 等核验完再一起定，**不发布、不打 tag**。


### Windows 核验结果（2026-11-06，Claude 在 Windows 上，worktree 基于 origin/windows `7d226f9`）

一次性核验 PLAN-v12 第 1–7 批 + 复查、PLAN-v13 第 1–8 批 + 复查（git log 里没有 PLAN-v15，第 8 条不适用）。改了什么记在各批下面，提交：
`a2d4885`（编译错、两条测试的期望值）、`4be88e7`（便签编辑器）、`8cfa2f1`（状态屏底板白边）、`2bc9e3a`（标题框多一个 ×、便签截图自检）、`6710a33`（深色下快速记一条 / 那叠是浅色亚克力）。

1. **编译**：从 `7d226f9` 起编，Debug 有 6 处编译错（都在 PLAN-v13：`Path` 撞名、少 `using KittyTools.Ui`、两处 `OriginalSource ==` 引用比较 CS0252、`Span` 跨 `await` CS4007、
   测试里三处可空警告和 `Note` 方法 / 类型同名），改完 Debug x64、Release AOT x64 / ARM64 **零警告**。发布目录里有 `KittyTools.pri`、`Microsoft.UI.Xaml.Controls.pri`、
   `Resources\StatusEmoji\`（34 张 PNG + `manifest.txt` + `LICENSE.txt`）。Release AOT 的 exe 跑过内存探针（能起、能走完）。
2. **单测**：788 个全过。三处 golden（`NoteSyncTests` 1830 个样本、`ReminderTests.Canonical_MatchesMacByteForByte`、`StatusScreenTests.Sync_MatchesMacAndPlans`）**没动、一次就过**。
   `KITTY_NOTES_SYNC_FUZZ=2000`：两个随机测试共约 0.26 s。**改了两条审查方新写的断言**（不是 golden，期望值本身错了，理由在 PLAN-v13 第 1、3 批下面），请审查方看一眼。
3. **便签编辑器**：新加 `--note-editor-probe=<目录>`（测试档，`App/NoteEditorProbe.cs`）用 TOM 走那 7 条，结果见第 4 批下面。**有三处真不对、已修**：占位的 U+FFFC 被 RichEdit 洗成空格
   （图放不上、交出去的正文丢令牌——复查 VERIFY 1 的退路：1×1 占位图）、`GetText` 带末尾段落符（正文每读一次多一个换行）、点方框的坐标原点不对。
4. **状态屏**：只跑了 `--status-screen-probe`，三种样式都 swallowed=2、touches=1、active-after-hold=False；透出样式底板右边一条白边修了。没真的进入过。
5. **手测**：HANDTEST 906–1147 里验过的 34 条写了「Windows 11-06」，其余要真按键 / 真拖 / 等到点 / 第二块屏 / Mac 的都没测（每节开头写了）。
   同步只用临时文件夹 + 两份 `.Dev` 数据（1055、1056 过），没碰真实的同步文件夹和便签。
6. **截图**：windows-shots `0.2.0-v12-batch-1/` `0.2.0-v12-batch-2/` `0.3.0-v12-batch-3/` … `0.3.0-v12-batch-6/`、`0.4.0-v13-batch-4/` … `0.4.0-v13-batch-7/`，浅 / 深各一张；高对比度没截（要改系统主题，我们不动系统设置；编辑器那张用的是便签自己的「增强对比度」）。`0.2.0-feedback-1104/`、`0.3.0-v12-batch-7/` 没有新图（要真的长截图、等到点的边框）（目录和缺的见各批）。
7. **自查**：内存（Release AOT、专用工作集、`KITTY_MEMORY_PROBE=1`，和 `1986a4b5` 同一台机器先后跑）：只有托盘 54.3 / 67.6 MB、5000 条剪贴板 58.8 / 71.8、剪贴板面板 59.6 / 71.6、启动器 64.0 / 73.0、翻译窗 65.1 / 76.2、截图 78.0 / 92.2、截图五次 85.4 / 93.9、设置窗开过 98.1 / 93.9（**+4.2 MB**：多了状态屏 / 提醒 / 便签三页）、静置 99.0 / 94.6（+4.4）。前面几步现在反而低 9–13 MB，原因没查（两边都是新的探针档、第一次启动）；没有一项涨超过 5 MB。只有托盘那一步里便签的药丸已经建着（示例便签），便签的其他窗口都关着。探针最后「录屏之后两分钟」那一步被我的 15 分钟超时截掉了，没读到。 空闲 CPU（Release、只有托盘 + 药丸，静置 30 s 后量 120 s）：46.9 ms / 120 s（0.039 % 单核），`1986a4b5` 同样量 15.6 ms（0.013 %）；`1986a4b5` 第一次启动那回也有 46.9 ms / 60 s，差在一两次唤醒、在测量粒度（15.6 ms）上，没找到新的周期计时器（提醒没开的时候不排计时器，那叠静置时 Watch 不跑）。 日志：全部测试档的日志里搜不到示例便签的标题 / 正文 / 图片路径、启动器的查询、汇率、网址（HANDTEST 1139、929）。
8. **安装包**：`build-release.ps1`（版本号没改，产物名还是 0.1.2，只用来比大小，没发布）和 GitHub 上 windows-v0.1.2 的附件比：x64 安装包 23.67 → 34.72 MB（**+11.05 MB，+47 %**）、x64 zip 32.28 → 43.92 MB（+11.64 MB）；ARM64 安装包 23.35 → 34.39 MB（+11.04 MB）、zip 31.36 → 42.92 MB（+11.56 MB）。发布目录 82 → 96 MB（x64），差不多全是状态屏的动画表情 `Resources\StatusEmoji\`（10 MB 的 PNG，本来就压过，打包几乎不再变小）；exe 29.9 MB。要压就减帧（24 → 12 fps 已经减过）或者换成 WebP / 首次用时再下载。
9. 版本号、更新日志、`build-release.ps1` 没动，没发布、没打 tag。

### 第 1 批：核心模型（Core）→ 已写（审查方，`git log --grep "PLAN-v13 第 1 批"`，没编译）

照 mac `Notes/Note.swift`、`NoteTasks.swift`、`NoteImages.swift`、`NotePaper.swift`、`NoteMarkdown.swift`、`NoteStyles.swift`（纯函数那一半）：

- `Core/Notes/NoteText.cs`：`NoteRange`（mac NSRange）、`NoteText.Line`（NSString.getLineStart 的口径：\n \r \r\n U+0085 U+2028 U+2029）、字位簇计数、Swift 的空白口径。
- `Note.cs`：模型（**不可变 record，时间一律整数毫秒 long**，`Clock` 是 `IReadOnlyDictionary<string,long>`、改的时候换整张表；相等照 mac 的 Equatable，自己写的 `Equals`）、
  收拾（NUL、标题 200 字 / 1 KB）、纸色的存法（预设 + tint）、显示标题 / 摘要。
- `NoteTasks.cs`（五种状态、Ctrl+T、回车续行、Tab、「- [ ]」自动转换、和 Markdown 互转、进度）、`NoteImages.cs`（令牌、宽度五档、插图落点）、`NoteColor.cs`（六种文字颜色）、
  `NotePaper.cs`（8 种纸色、自定义纸色的 OKLCH 推导、对比度、颜色菜单那份表、最近用过）、`NoteMarkdown.cs`（不用正则的扫描器、代码块、加标记、粘贴网址成链接、颜色、HTML 互转、plain）、
  `NoteStyles.cs`（一行 → 样式区间、叠层、要重排哪几行、代码块角色变了的行、行距三档和各个比例）。
- 单测：`NoteTasksTests` 12、`NoteImagesTests` 16、`NotePaperTests` 11、`NoteMarkdownTests`（mac `NoteMarkdownTests.swift` 全部 + `NoteBatch8Tests` / `NoteBatch8bTests` 里测这几个纯函数的）、
  `NoteStylesTests`。期望值照 mac 原样；跳过了哪些写在各测试文件头。

**要特别看的编译点**：源码里不能有原样的 U+2028 / U+2029（写文件的工具会把 `\uXXXX` 写成原字符，提交前扫过、都换回了转义；要是哪里还有，CS1010）；
`NoteStyles.Kind` / `Shape` 是 record struct + 工厂（mac 带关联值的枚举）；`NoteMarkdownTests` 里 `using Span = …NoteStyles.Span;` 和 `System.Span<T>` 同名不同元数；
`NoteMarkdown.Url` 用 `Uri.TryCreate`（Windows 上 `/usr/bin` 这种会被当成文件路径，测试里有这一条，过不了先看实际返回）；`NoteMarkdownTests` 有三条 0.5 秒的计时断言（Debug，线性的活，慢机器上可能紧）。

**替用户定的**：`NoteMarkdown.Url` 比 .NET 的 `Uri` 严（开头空白不认、http / https 后面必须是 `//`），对齐 mac `URL` 的结果。


**Windows 核验（2026-11-06）**：编译过；源码里没有原样的 U+2028 / U+2029。`NoteMarkdownTests.PlainAndStrippingRemoveColorMarkers` 最后那条（注明 mac 没有、移植时补的）
期望 `R(15, 1), R(17, 6)`，实际 `R(14, 1), R(16, 6)`：`"前\n `[字]{red}`\n[字]{red}"` 第三行行首是 14，「[」在 14、「]{red}」在 16，代码对、期望数错一位——**改了期望值**（`a2d4885`）。
`NoteMarkdown.Url` 那几条、三条 0.5 s 计时都过。

### 第 2 批：仓库、图片目录、备份、导出导入第七类 → 已写（审查方，`git log --grep "PLAN-v13 第 2 批"`，没编译）

照 mac `NoteStore.swift`、`NoteImageStore.swift`、`NotesBackup.swift`、`NoteSample.swift`、`Storage/SettingsArchive.swift` 的便签那一类：

- **Core**：`NoteBook`（仓库的内存那一半：视图、改动的全部规则——钟、状态 / 顺序时刻只往前走、挪顺序取中间值 / 整列重排、软删、墓碑、到期清理、
  空白便签、导入合并 `Adopt`、同步落地 `ApplySync`、换编号 `SwitchDevice`、搜索的折叠缓存、摘要缓存；落盘交出 `PendingWrites`）、
  `NoteEntry`（导出文件的一条：宽松读、收拾、写 JSON）、`NoteImageRules`（文件名、上限、孤儿 30 天的账 `.orphans.json`）、`NotesBackupPlan`（名字、留 7 份、恢复的对话框文字）、`NoteSample`。
  单测 `NoteBookTests`（照 mac `NoteStoreTests` 的内存规则移植，期望值原样；要真库的那几条跳过，写在文件头）。
- **App**：`Notes/NoteStore.cs`（notes.sqlite3，表结构照 mac：notes / note_erased / note_meta；停手 250 ms、连着改满 2 s 落盘，失败 5 s 起翻倍重试）、
  `NoteImageStore.cs`（notes-images\，WIC 读宽高、别的格式转 PNG、裁切另存新图、30 天清理）、`NotesBackup.cs`（每日 7 份 + 打不开时问三选一）、
  `NotesHost.cs`（启动、到期清理、示例便签、锁屏 / 睡眠 / 退出前落盘、每日备份）。`Sqlite.cs` 加了 `BindDouble` / `GetDouble` / `GetNullableInt64`；
  `SyncDevice.Rotate(string id)`（便签认出库被退回去时用指定的新编号）。
- **设置和接线**：`Settings` 加了便签的一组键（名字同 mac `Prefs.notes*`；这台电脑自己的状态不在导出白名单里）、`Feature.Notes`、热键 `noteCapture`（**Alt+N**）/
  `noteNew` / `noteAll`（不设默认键）、`Theme.Family.Notes`（系统黄，色块上的符号用黑）、`ShellRuntime`（启动、锁屏 / 睡眠 / 退出前落盘、每日备份）。
- **导出导入第七类「便签」**：`SettingsArchive.Notes`（原样的 JsonElement，读的时候逐条宽松解）、`ArchiveSection.Notes`、`ArchiveService.Build` / `Apply` / `ExportProblem`、
  每日自动备份带便签（便签这次用不了时不带这一类）、导入对话框多一项、结果里说新增 / 更新 / 没存上 / 这次用不了。

**要特别看的编译点**：`NoteBook` / `NoteStore` 用到第 3 批的 `NoteSync.Tombstone` / `Merge`；`NotesNewerException` 是带主构造函数的异常类；
`NoteImageStore` 是主构造函数的类、属性名 `Directory` 盖住了 `System.IO.Directory`（文件里一律写全名）；`NoteImageStore.StoreFileAsync` 里 `Task.Run<StoreResult>(async () => …)`；
WIC 的 `BitmapDecoder.HeifDecoderId`、`DecoderInformation.CodecId`；`NoteStore` 的 SQL 参数是 `?1`…`?16`（按位置绑）。

**替用户定的**：电脑编号用同步那一个（`SyncDevice`，kitty.sqlite3），剪贴板的库打不开时用便签库 note_meta 里自己记的；图片孤儿的账写 `.orphans.json`（mac `.orphans.plist`，两边不互读）；
图片的显示尺寸按 96 DPI = 1:1 算（mac 72 DPI）；`NoteStore` 不做 mac「正文超 64 KB 时字数和进度停手再算」（ponytail，写在 `NoteBook` 文件头）；
打不开时的对话框问完不用重启（便签的库是单独的，开好就接着起便签那几样）。


**Windows 核验（2026-11-06）**：编译过、没改。新的 `.Dev` 数据第一次启动有 `notes.sqlite3`、示例便签、`notes-backups\notes-<今天>\`（库 + images\）。
打不开时的三选一、导出导入的便签一类、退出时落不下去的对话框没测（要真点）。

### 第 3 批：同步（和 mac 同一个文件夹）→ 已写（审查方，`git log --grep "PLAN-v13 第 3 批"`，没编译）

照 mac `NoteSync.swift`、`NoteSyncFolder.swift`（逐函数移植，字节一字不差）、`NoteSyncDisk.swift` + `NoteSyncer.swift`（执行层，只取先后）：

- **Core**：`Notes/NoteSync.cs`（合并：版本钟、冲突另存那条的编号、墓碑、状态 / 顺序各自后改的赢）、`NoteSyncFolder.cs`（标记、便签文件的写法和从严的读法、erased.json、
  一轮 `Round`、刹车、写出去 `Publish`、共用图片的清理 `ImagePurge`、认出库被退回去了 `Regressed`）、`NoteFileHeader.cs`（Swift 的 JSON 字符串 / Double / ISO 写法）、
  `NoteSyncPart.cs`（仓库交给同步的几样 + 读写文件夹的便签那部分 `NoteSyncDisk`）。
- **golden**：`tools/notes-sync-golden.swift` 直接编 macos 分支的 `Note` / `NoteSync` / `NoteSyncFolder` / `NotePaper` / `NoteImages` / `NoteTasks`（加最少的桩）在 Mac 上跑出
  `KittyTools.Tests/Fixtures/notes-sync-golden.json`（1830 个样本：哈希、另存编号、钟、Double、ISO、JSON 字符串、便签文件写 44 / 读 146、墓碑、标记、账、merge 149、round 51、
  publish 7、regressed 5、imagePurge 8）。`NoteSyncTests` 逐个比（再加 mac `NoteSyncTests` / `NoteSyncFolderTests` 的用例和随机测试：`KITTY_NOTES_SYNC_FUZZ=<次数>` 多跑）。
- **执行层**：`SyncRunner` 多一个可选的 `NoteSyncPart`（不传 = 和以前一样，现有的单测不用改）：认清文件夹 → 便签按钟认「库被退回去了」、要换编号就先换（在写任何东西之前）→
  别的几类照常 → 合便签（Round → 刹车 → 正在编辑的先不换 → 落下去 → Publish）→ 写（便签文件要动的那一轮 epoch +1、device.json 最后写）。
  标记是更新的格式写的：整轮停在「请更新」（以前 Windows 把它当成「别的东西」）。`SyncDisk.Fingerprint(kinds, notes)` 把每台的 notes/、erased.json、images/ 也算进去（不然只有便签变了的那一轮会被跳过）。
- **App**：`Syncer.NotesPart()`（勾着「便签」、便签功能开着、便签库开着才有）；`NoteStore.SwitchDevice(ids, old, new)`（先落盘再 `SyncDevice.Rotate(new)`）；
  `NoteEditing`（哪几条正在编辑：前台窗口里拿着焦点的编辑器、挂着组字的；同步拿下来的图通知编辑器）；设置 › 通用 › 同步第一行「便签 · 连同正文里的图片」（默认开）、页脚和「合在一起」的说法加上便签。
- 单测：`NoteSyncTests`（golden + 移植）、`NoteSyncRunnerTests`（两台内存里的 NoteBook 共用临时文件夹：新建传过去、改了跟上、两边各改、永久删除、刹车、正在编辑的先不换、认出退回去了换编号）。

**要特别看的编译点**：`NoteSyncFolder` 里大量 C# 12 写法（集合表达式 `[]`、`cond ? list : []`）；`NoteSync.Merge` 有个属性就叫 `Note`（和类型同名）；`SyncRunner.RunAsync` 里
`Task.Run` 返回四元组（`(bool, List<string>?, HashSet<Guid>?, List<string>?)`）；`snapshot.Notes?.Folder.Devices.TryGetValue(id, out var noteDevice) == true` 之后用 `noteDevice`
（C# 10 起的明确赋值）；`NoteEditor.IsInWindow` 用 `XamlRoot.ContentIslandEnvironment.AppWindowId`。**这几批的提交单独拿出来不一定编得过**（第 3 批用到第 4、6 批的 `NoteEditor` / `NoteFloats`），以最后一批为准。

**替用户定的 / 和 mac 不一样**：
- 电脑编号、epoch 全 App 一个（`SyncDevice`，mac 存在便签库里、只有便签文件动了才 +1）：只有便签库被单独恢复时 epoch 认不出来，靠钟（`Regressed`）认；整个数据目录被恢复（epoch 退回）时，
  和自己那份不一样的便签也一起换编号（同 mac「自己子文件夹里记的比库里的大」那条）。
- 便签那部分出了问题只停它自己（mac 是整轮停），别的几类照常同步。
- 没有 mac「读的缓存按路径 + 文件号 + 时刻 + 大小认」：每轮把便签文件都读一遍（指纹没变的那轮整轮跳过，所以只在有变化时读）。ponytail，几千条便签一轮读几 MB。
- `SyncFolderRules.ParseDevice` 比 mac 严（epoch 必须有、format 必须是 1）：更新版本写的 device.json 在 Windows 上算读不出来，便签这部分会停在「还没下载完」。留给 mac 真改了格式再说。
- `NoteImageRules.Identifier`（本机图片目录）用 `Guid.TryParseExact("D")`，比 mac 的 UUID 解析宽一点点（.NET 认每段前的 `+`）；同步文件夹里的图片名用 `NoteSyncFolder.ImageId`（严格）。


**Windows 核验（2026-11-06）**：golden 1830 个样本一次对上。`NoteSyncRunnerTests.RollbackSeenWithoutNotesIsCaughtUpLater` 最后一条断言「合完之后钟里没有 WIN-A」必然不成立：
补认（`~notes-switch-from`）那一下确实把那条从 WIN-A 换到了新编号，但同一轮接着合并时，文件夹里 WIN-A 那份（「第二版」）和它是并发的两版，冲突另存一条、钟并起来，
WIN-A=2 是从文件夹那份并进来的（实际：`{新编号=2, WIN-A=2}`，另存的「第二版」一条）。**改成查补认那一下**：节点记下 `SwitchDevice` 的调用，断言最后一次是
（含这条, "WIN-A", 新编号）（`a2d4885`）。另外这条用例分辨不出「有没有补认」：书的编号是 `() => Device.Id`，恢复后打的字本来就记在新编号名下，不补认合出来也一样——要测补认得另设场景，留给审查方。
真跑：两份 `.Dev` 数据 + 临时文件夹，A 上 8 条示例便签一两轮后 B 上都有（标题、纸色、固定一样），文件夹里是 `devices\<编号>\notes\<便签编号>.md`。

### 第 4 批：正文编辑器（RichEditBox）→ 已写（审查方，`git log --grep "PLAN-v13 第 4 批"`，没编译）

照 mac `NoteTextView.swift`（+Images）的行为，做法是 PLAN-v13 §3.1：

- `Notes/NoteEditor.cs`：RichEditBox 包一层。**存的是纯文本**，编辑器里的字和存的字差两处：段落符 \r ↔ \n、图片令牌 ↔ 一个 U+FFFC（图片表按出现顺序对应，改字时按改前改后的差跟着挪；别处拖进来的对象拿掉）。
  样式只改格式：一行 → `NoteStyles.Spans` / `Runs` → 字体、字号、粗斜体、划线、颜色、隐藏，段落上行高（Exactly）、段前段后、缩进；**只重排受影响的行**（`Pending` / `LinesCovering` /
  `NeighborLines` + 代码块角色变了的行），整段换字先排开头 4000 字、其余停手后一段段补。**Markdown 的标记**：拿着焦点时选区碰到的那几行淡淡露出来，别的行 `Hidden`。
  **组字期间不重排、不交出去**（TextCompositionStarted / Ended）。会超 1 MB 的那一次改动退回、响一声。
- **撤销自己管**（`Core/Notes/NoteUndo.cs`）：`Document.UndoLimit = 0`，Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z 走自己的栈；打字按「1 秒内、光标接着、空白后另起」分组，命令自己一组。单测 `NoteUndoTests`。
- `NoteEditor.Input.cs`：回车续列表 / 任务、Tab / Shift+Tab 缩进、「- [ ]」加空格自动转换、Ctrl+T、Ctrl+B / I / Shift+X / E、Ctrl+F 查找条、Ctrl+C / X 拷的是存的形式、
  粘贴一律纯文本（选中一段粘网址 = 链接）、点方框切换、Ctrl+点链接打开、右键菜单（剪切 / 拷贝 / 粘贴、格式 ›、任务状态 ›、文字颜色 ›）。代码块里这些都不做。
- `NoteEditor.Images.cs`：载入时把占位的 U+FFFC 一张张换成图（`InsertImage`，宽按令牌或原图、不超过可用宽）；粘贴 / 插图先存进图片目录再插（每张独占一行）。宽度档位和裁切在第 7 批。

**要特别看的编译点 / 屏幕上要看的**（都是没法在 Mac 上验的 RichEdit 行为，任何一条不对先记在这里，退路写在后面）：
1. `CharacterFormat.Hidden` 真藏了吗、光标会不会停在藏着的字中间、`GetText(TextGetOptions.None)` 带不带藏着的字（要带）。藏不住的退路：标记不藏，只淡色（`MarkerInk`）。
2. **字号单位**：代码按「TOM 的 Size 是磅、XAML 的 FontSize 是 DIP」乘 0.75（`PointsPerDip`）；屏上正文的字和设置里的字号不一样大就改这一个常数。
3. `TextChanging` 的 `IsContentChanging` 在只改格式时是 false（不然每改一次格式都当成改字）；改格式的时候 `_applying` 也挡着。
4. `InsertImage` 之后 `GetText` 里是一个 U+FFFC；替换占位的 U+FFFC 时选区不乱跳。
5. `SelectionChanged` 在 `TextChanging` 之后来（撤销分组拿「改之前的光标」靠这个顺序）。
6. `DisabledFormattingAccelerators = All` 之后 Ctrl+B / I / U 不再被 RichEdit 自己吃掉、能到 `PreviewKeyDown`。
7. 点方框：`GetRangeFromPoint(…, ClientCoordinates)` 的坐标是不是相对 RichEditBox（点不中就换成相对内部 ScrollViewer 的坐标）。

**替用户定的**（MAC-DIFF 第 8 批一起记）：任务方框是存着的那个字本身（Segoe UI Symbol），不是 mac 自己画的圆角方框；引用块没有左边的竖线（只缩进 + 色条色的字）；
代码块的底是一行行的字底色，不是整块圆角矩形；查找条是自己的一个输入框（Enter 下一个、Shift+Enter 上一个），不是系统的；撤销按 1 秒分组（mac 是系统默认）。


**Windows 核验（2026-11-06，`--note-editor-probe`，`4be88e7`）**：
1. `Hidden` **真藏**：没焦点时「# 」「**」Hidden=On，光标在那一行时露出、别的行照藏；`GetText(None)` 带着藏着的字。`SetRange` 落在藏着的字中间会被挪到后面（6 → 7），往右挪一格停在藏着的字前面（不进去）。
   **但 `GetText(None)` 带着 RichEdit 末尾那个段落符**（空文档读出来是 `\r`、`SetText("a\r")` 读出来是 `a\r\r`），原来的 `ReadText` 以为不带：正文每读一次末尾多一个换行、交出去就存下了。修：去掉末尾那一个。
2. 字号：正文 15 DIP 时 `Size` 是 11.25 磅，屏上一个汉字宽 15、和同字号的 TextBlock 一样——**0.75 对**。
3. 只改格式时 `TextChanging` 来，`IsContentChanging=false`：对。
4. **`SetText` 把普通的 U+FFFC 洗成空格**（`a FFFC b` → `0061 0020 0062`）：图片表 1 张、字里 0 个：图放不上，`Body` 里没有令牌（修前自检读到的 `Body` 和原来不一样），`Aligned()` 拦着一直不交出去。
   照复查 VERIFY 1 的退路改成放 1×1 的透明占位图：`InsertImage` 对一个字的范围**是替换**（长度不变、读出来是 U+FFFC），再换真图也是替换；选区不乱跳。改了 `Replace`、`ApplyChange`、`InsertImages` 三处（`PlainForm` + `PlacePlaceholders`）。修后：载入带图的正文 → 一个 U+FFFC、真图换上、`Body` 和原来一字不差。
5. 顺序：`TypeText` 时先 `TextChanging`（IsContentChanging=true）、再一串我们自己排版的 TextChanging（false）、最后 `SelectionChanged`：对。
6. `DisabledFormattingAccelerators=All` 设上了；Ctrl+B / I / U 能不能到 `PreviewKeyDown` 要真按键，**没测**。
7. **`GetRangeFromPoint(ClientCoordinates)` 的原点是正文第一个字**（内边距里面，第一个字的框是 (0, 0)），而且是**整篇的坐标**（滚了 500 之后第一个字的 y 还是 0）：按相对 RichEditBox 的点去取，横竖都差一个内边距、滚动后差得更多。
   修：`TextPoint` 按 RichEditBox 里那个 ScrollViewer 的内容取点；自检里没滚 / 滚了都点中了。
另外：紧急的方框用了 `TaskUrgentMark`（mac 红底上感叹号的颜色，白 / 黑），Windows 的方框就是那个字本身，深色纸上几乎看不见——改成红色。
截图（`0.4.0-v13-batch-4/`）：标题、粗斜体、划线、行内代码、红 / 蓝字、五种任务、引用、代码块、图片，浅色 / 深色 / 增强对比度（`Configure` 的 contrast，不是系统高对比度主题：系统主题我们不改）。

### 第 5 批：窗口和入口 → 已写（审查方，`git log --grep "PLAN-v13 第 5 批"`，没编译）

- `Notes/NoteCaptureWindow.cs`（快速记一条，`Alt+N`）：和剪贴板面板、启动器同位置同宽、同一套外壳，三块只开一个（`OverlayHost.Show` 先收起它）；目的地 = 新便签 + 最近改过的 8 条（Ctrl+1–9）；
  Enter 记下、Shift+Enter 换行（组字时不提交）、Tab 去标题框；Esc 清空（轻提示「恢复」）、Ctrl+W / 再按快捷键 / 点别处留着草稿（`notes-draft.json`，停手 1 秒、收起、退出前存）。
  规则在 `Core/Notes/NoteCaptureRules.cs`。
- `Notes/NoteSheetView.cs`：一条打开着的便签（色条、纸色圆点、标题、任务 / 固定 / ⋯ / 关闭、正文 `NoteEditor`、底下小字）。**全部便签窗口的右栏、便签墙的编辑卡、那叠里打开的、浮动便签都是它**，
  外面那层只给 `Host`（怎么关、浮不浮）。Ctrl+K 操作菜单（固定、颜色 ›、任务、归档、删除、浮在屏幕上 / 收回边缘、在全部便签里打开、导出为 Markdown…、便签设置）、Ctrl+P、Ctrl+Shift+A、
  Ctrl+Shift+Delete、Ctrl+.、Ctrl+,。`Notes/NoteColorFlyout.cs`：颜色菜单末尾「其他颜色…」= `ColorPicker` 浮层（边拖边变、关掉落盘、最近 8 个记这台电脑）。
- `Notes/NotesWindow.cs`：全部便签窗口（普通窗口、Mica）。全部 / 归档 / 最近删除 + 搜索；便签墙（瀑布流 `Core/Notes/NoteWall.cs`，分固定的 / 其他，点一张盖一层放大成编辑卡）/ 列表（左列 + 右栏，「全部」里拖动排序）；
  右键菜单、删除 / 归档后能撤销，Ctrl+N / Ctrl+F / Ctrl+1 / Ctrl+2 / Delete / 焦点不在输入框时 Ctrl+Z 放回刚删的。规则在 `Core/Notes/NotesWindowRules.cs`。
- 入口：热键三项（`ShellRuntime.OnHotKey`）、托盘一节（快速记一条、新建便签、全部便签）、主界面一节（三格，截图与录制之后、状态屏之前，同 mac）、启动器三项（`LauncherActions`，原定第 8 批，顺手做了）、
  设置 › 快捷键「便签」一节、速查表「便签」一类四组（照 mac 的四组，只写 Windows 这边真有的键）、设置 › 便签（`Settings/SettingsWindow.Notes.cs`：正文字号、行距、Markdown 样式、屏幕边缘那一节、数据）。
  `NotesHost.NewNote`（那叠开得了在那叠里，不然全部便签窗口里新建）/ `Open(id)` / `ApplyFeature`（关 = 落盘、收起快速记一条、关全部便签窗口、浮着的收起、那叠收起；开 = 固定着的浮回去）。
  `Shell/Displays.cs` 多了 `All()`（每块屏的名字、整块、工作区、缩放、是不是主屏），设置页「显示器」和那叠 / 浮动便签用。
- 单测：`NoteCaptureRulesTests`（草稿、目的地、接在后面、恢复、存前检查、选中跟随、拖动落点、相对时间、字数）、`NoteWallTests`（瀑布流、斜度、方向键、命中、拖动落点、编辑卡）。

**单独这一批编译不过**：它引用第 6 批的 `NoteDeck`、`NoteFloats` 和第 7 批的 `NotesTransfer`（第 2 批起 `NotesHost` 就引用了 `NoteFloats`）。核验从最后一个提交起，不用逐个提交编译。

**要特别看的编译点 / 屏幕上要看的**：
1. 快速记一条和剪贴板面板、启动器、主界面互斥（呼出一块收起另外两块）；它是 `OverlayWindow` 那一套外壳吗、点外面收起、不进 Alt+Tab。
2. `NoteSheetView` 在三种外面（列表右栏、编辑卡、浮动便签）里都能打字、Ctrl+K 弹得出菜单（`MenuFlyout.ShowAt` 挂在「⋯」按钮上）。
3. 便签墙：卡片的高是按 `TextBlock.Measure` 量的（窗口代码里），窗口拉宽拉窄时列数跟着变、不闪；编辑卡收回后焦点回到墙上。
4. `ColorPicker` 浮层：边拖边变不卡（仓库 `SetColor` 是攒着落盘），关掉后「最近用过」多一个。
5. 设置 › 便签：屏幕边缘关着时那一节变灰；「显示器」只有一块屏时不出现；导出 / 导入在便签功能关着时也能点。
6. 托盘、主界面、启动器、速查表里「便签」那几项的名字、顺序、快捷键和设置 › 快捷键一致；关掉便签功能后全部不见、Alt+N 交还系统。

**替用户定的**：便签墙不能拖动排序、卡片一次全画（mac 能拖、分批建；几百条以内够用，文件头 ponytail）；托盘「便签」一节不画节标题（Windows 托盘菜单都不画）；
全部便签窗口 Ctrl+Z 放回刚删的只认这次打开以来删的（mac 同）；速查表里 mac 有、Windows 还没有的键（便签墙上方向键挑卡片、Enter / 空格放大）没写，记在 MAC-DIFF（第 8 批）。


**Windows 核验（2026-11-06）**：编译错（`a2d4885`）：`NoteCaptureWindow` 的 `Path` 和 `Shapes.Path` 撞名、`NoteSheetView` 少 `using KittyTools.Ui`（`SearchLine`）、`NoteSheetView` / `NotesWindow` 的
`e.OriginalSource == header` 是 CS0252（换 `ReferenceEquals`）。屏幕上：便签的标题框拿到焦点时 TextBox 自带的清除钮（×）挨着关闭钮，两个 × ——`SearchLine.HideClearButton` 压掉（`2bc9e3a`，打开的便签、浮动便签、快速记一条三处）。**深色下快速记一条是浅色亚克力、白字看不清**：`NoteCaptureWindow` 在设 `Content` 之前就设了 `AcrylicBackdrop`，它连上时没有内容、按浅色定死、也挂不上主题变化；挪到 `Content` 之后（`6710a33`，第 6 批的药丸、标签列同样）。
新加 `--notes-ui-probe=<目录>`（测试档，`App/NotesUiProbe.cs`）放示例便签、依次打开各扇窗、只抓自己的窗口；截图 `0.4.0-v13-batch-5/`：快速记一条、便签墙、编辑卡、列表、设置 › 便签（浅 / 深）。
看到的（没改）：便签墙卡片上标题行的「# 」「## 」留着（加粗、列表的标记去掉了）——和 mac `plain` 一样（mac 也不去标题），mac 的卡片是带样式画的，要不要对齐留给审查方；编辑器里「- 」列表就是原样的「- 」，没有换成圆点。
要真按键 / 真拖的（互斥、Esc、拖动排序、Ctrl+K、取色浮层）都没测。

### 第 6 批：屏幕边缘那叠和浮动便签 → 已写（审查方，`git log --grep "PLAN-v13 第 6 批"`，没编译）

- `Notes/NoteDeck.cs`：`NoteDeck`（几块屏：什么时候有、放哪、只展开一块、叫停、新建 / 打开、按住 Alt 拖药丸、全屏时收起）+ `NoteDeckBay`（一块屏：状态机 `Core NoteDeckState`
  的 `EffectsOf` → 露出 / 收起 / 拿键盘 / 还键盘 / 落盘；扇着、开着时每 150 ms 看一眼鼠标——离开热区 150 ms 收、4 秒没动静收、没拿键盘的便签在别处按了左键收；静置时没有计时器）。
- `Notes/NoteDeckWindows.cs`：药丸（亚克力小窗，一条便签一道色块）、标签列（纸色标签往下压、竖排标题、「+N」、「+」、拖动排序、右键菜单）、预览卡、打开的便签（`NoteSheetView`，
  拿前台；失去前台 = 点了别处；按住头部空白处拖出 `NoteFloatLayout.Detaches` 那么远 = 浮到屏幕上）。四扇都是 `HudFrame.Apply`（置顶、不进 Alt+Tab、不抢焦点）或同样的外壳。
- `Notes/NoteFloats.cs`：浮动便签（第 5 批起就被引用）：一张一扇窗、能拉大小、置顶、最多 5 张（最久没碰的收回）、按住头部挪、松手夹进工作区、固定着的重启后回原处。
  规则在 `Core/Notes/NoteFloatLayout.cs`（+ `NoteFloatSet`），那叠的排法、热区、拖药丸、竖排标题、状态机在 `Core/Notes/NoteDeckLayout.cs`；单测 `NoteDeckLayoutTests`、`NoteFloatLayoutTests`。
- 接线：`ShellRuntime` 显示器变了（`WM_DISPLAYCHANGE`）、工作区变了（`WM_SETTINGCHANGE` + `SPI_SETWORKAREA`）重摆，设置保存后那几项真变了才重摆；截图（框选 / 录屏选区留着打开的便签，识字、截图翻译收没固定的）、
  长截图（收没固定的）、状态屏（全收）开始时 `NoteDeck.Suspend`；`Displays.All()` 改成主显示器排第一（那叠的摆法认第一块是主显示器）。

**要特别看的编译点 / 屏幕上要看的**：
1. `NoteDeck.UpdateHook` 用 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` + `[UnmanagedCallersOnly]` 函数指针（同 `HiddenWindow` 的窗口过程写法）；AOT 下回调要能进来（全屏视频 / 游戏前台时药丸收起，切走后回来）。
2. 药丸、标签列、预览卡是 `HudFrame.Apply` 的不抢焦点窗：点它们时原来的程序不该失去前台；`PointerEntered` 在不拿前台的窗口上要能来（来不了就把药丸改成 `WS_EX_NOACTIVATE` 之外的写法，记在这里）。
3. 打开的便签 `Foreground.Restore` 之后真拿到键盘（直接能打字）；按 Esc 收回之后键盘回到原来的程序（`_previous`）。
4. 标签上的竖排字：`RotateTransform` 90° + 按横排量的尺寸占位；中文一字一格、英文整段转过来；排不下有「…」。
5. 拖动排序：按着标签上下拖，松手落到 `DragTarget` 那一格；没拖开就是点了一下。
6. 拖出浮动便签：按住打开的便签头部空白处往外拖，浮动便签出来后系统接着挪（`WM_NCLBUTTONDOWN` + `HTCAPTION`，鼠标还按着）。

**替用户定的**（MAC-DIFF 第 8 批一起记）：没有透明面板，四件各是一扇不透明小窗（药丸 / 标签列是亚克力）；「感应范围」= 药丸那扇窗的宽（mac 是药丸外面一圈看不见的感应区），
「不显示药丸」= 只留亚克力的一条；扇出、打开、收回没有动画；全屏判定是「前台窗口盖满那块屏」（不是桌面、不是我们自己的窗口）；标签的倾斜（mac 微微斜着）没做；
打开的便签旁边没有 mac 那张跟着它的标签（标签列里那张描粗边表示打开着）。


**Windows 核验（2026-11-06）**：编译过。自检加了几个测试用的口子（`NoteDeck.ProbeBay`、`NoteDeckBay.ProbeHold` / `ProbeWindows`、`NoteFloats.ProbeWindows`）：
扇着时每 150 ms 看鼠标，真的鼠标不在那叠上会立刻收回，`ProbeHold` 挡住这一下。`PillEntered` → 标签列、`Hover` → 预览卡、`TapTab` → 打开的便签、`NoteFloats.Float` → 浮动便签都出得来，
深色下药丸、标签列也是浅色亚克力（同第 5 批，`6710a33` 修了）。截图 `0.4.0-v13-batch-6/`（浅 / 深）。药丸那扇窗是带系统细边框的白底小卡（约 122×127 px），里面一列色块，比 mac 的药丸宽得多（「感应范围 = 药丸那扇窗的宽」）。
`SetWinEventHook` 的全屏判定、不抢焦点、Esc 还键盘、拖出浮动便签、竖排字以外的真鼠标操作都没测。

### 第 7 批：Markdown 导出导入、图片的宽度和裁切 → 已写（审查方，`git log --grep "PLAN-v13 第 7 批"`，没编译）

- `Core/Notes/NoteMarkdownFiles.cs`（agent 照 mac `NoteMarkdownFiles.swift` 的纯函数移植、我对过 API）：文件名（清理、截断、重名加号；另外替换 Windows 不许的字符、给 CON / NUL 这类设备名加 `_`）、
  导出文件夹名、文件头（时间按传进来的时区、毫秒，同 mac；手写的 ISO 读法，怪的值当读不出）、正文哈希、三种换法（任务 / 颜色 / 图片）、读文件的解码（去 BOM、严格 UTF-8、换行统一）、
  自家文件 / 别处文件 → 便签、在别处改过没有、导入完怎么说。单测 `NoteMarkdownFilesTests` 18 个（mac 的用例原样移过来 + Windows 的几个；要真文件系统的那几个跳过，写在文件头）。
- `Notes/NotesTransfer.cs`：导出全部（新建「Kitty Tools 便签 日期」、attachments\、写坏一个就停）、单条导出（`FileSavePicker`，owner 是那扇窗的 `XamlRoot.ContentIslandEnvironment.AppWindowId`）、
  导入（「导入…」= 选择文件… / 选择文件夹…两项；线程池上读、换、存图片，UI 线程上 `Adopt`；图片路径相对 .md 的文件夹，绝对路径 / 网址 / 跑出去 / 符号链接不认）。
- 图片（`NoteEditor.Images.cs`、`Notes/NoteImageCrop.cs`、`NoteImageStore.PngOfAsync`）：右键选区里的图 → 图片宽度五档、裁切…（对话框：四角拖大小、框里挪、框外重拉；另存一张新图，宽度按比例换算，一步撤销）、拷贝图片（转 PNG 写剪贴板）。

**要特别看的编译点 / 屏幕上要看的**：
1. `XamlRoot.ContentIslandEnvironment.AppWindowId` 在那叠 / 浮动便签的窗口里拿得到（拿不到时 `FileSavePicker(default)` 会不会抛：抛了就改成传那扇窗的 `AppWindow.Id`）。
2. 导出的 .md 和 mac 导出的逐字一样（时间是本地时区、毫秒；`body-hash`）：能拿到 Mac 时两边各导一份同一条便签比一下（HANDTEST 1132）。
3. 右键一张图时 RichEdit 的选区是不是正好那一个 U+FFFC（右键不选中的话「图片宽度」那几项不出现：那就在 `RightTapped` 里先把光标处的对象选上）。
4. 裁切对话框里 `BitmapImage` 是不是已经按 EXIF 转正（对话框里的图和裁下来的对得上：拿一张手机竖拍的 JPEG 试）。

**替用户定的**：「导入…」是两项的小菜单（Windows 的选择框不能同时选文件和文件夹）；裁切只有自由比例、用对话框（mac 原地一层、7 种比例）；没有拖右下角改宽的把手；
文件名额外替换 Windows 不许的字符、设备名前加 `_`；导入时文件名排序用当前区域的不区分大小写比较（mac 是自然顺序）。


**Windows 核验（2026-11-06）**：编译错 1 处（`NotesTransfer.StoreAsync` 里 `AsSpan().SequenceEqual(await …)` 跨 await，CS4007；拆成 `SameBytes`，`a2d4885`）。
裁切对话框截图（`0.4.0-v13-batch-7/`，挂在全部便签窗口上）。图片宽度菜单是 `MenuFlyout`，弹在窗口外面的单独弹出窗里，WindowShot 抓不到，没截；导出 / 导入要选文件夹，没测。

### 第 8 批：和剪贴板、启动器、翻译打通，收尾 → 已写（审查方，`git log --grep "PLAN-v13 第 8 批"`，没编译）

- 从剪贴板面板 / 启动器粘进便签：`OverlayWindow.ShowOverlay` 记粘贴目标时，前台是自己的窗口但便签正文拿着焦点（`NoteEditing.Focused()`）也认它；粘的时候照常还前台 + Ctrl+V，
  正文自己的粘贴接住（纯文本、图片照第 4 批）。那叠里打开的便签：前台换成自己的窗口（剪贴板面板、启动器、翻译浮窗）不算点了别处（`NoteDeckBay.SheetDeactivated`）。
- 便签里划词翻译：前台是便签、正文里选了字 → 直接读选区（`NoteEditor.SelectedText` 去掉图片令牌，不发 Ctrl+C、不碰剪贴板），替换照常粘回那扇便签窗口；
  「划词翻译并替换」在便签里直接换掉选区（`TranslateHost.ReplaceInNoteAsync`：译完时还是那条、选的还是那段才换，不然只复制）。
- 启动器三项在第 5 批已经做了；`MAC-DIFF.md` 加「便签」一节（长期例外 + 还没对齐），`STATUS.md` §1 加一段现状。

**要特别看的**：
1. 剪贴板面板从便签里呼出再粘：Ctrl+V 进的是 RichEditBox 自己的粘贴（`NoteEditor.PasteAsync`，纯文本），不是 RichEdit 默认的带格式粘贴。
2. 那叠里打开的便签：呼出剪贴板面板时它不收；面板关了之后焦点回到便签（`Foreground.Restore` 到便签那扇窗）。
3. 翻译浮窗的「替换」粘回便签窗口时，`Paster.Paste` 的「目标是管理员程序」那一步对自己的窗口不误判。


**Windows 核验（2026-11-06）**：编译过、没改；三条都要真按键（粘回、划词），没测。启动器搜「便签」的三项见第 5 批。

### 审查方复查（2026-11-05，`git log --grep "PLAN-v13 审查方复查"`，同样没编译）

四个没写过这些代码的 agent 分头读了第 1–8 批（数据层、同步执行层、正文编辑器、窗口和入口），对照 mac。确定的错改在这个提交里，
VERIFY（要在 Windows 上跑才知道）和没改的列在后面，核验时顺手看。

**改了的**（编译错 4 处）：
- 编译：`NoteSyncPart.cs` 少 `using KittyTools.Core.Sync;`；`NoteGeometry` 是 Core 的 internal（App 里用了）→ public；`NoteDeck.CheckFullScreen` 用了指针要 `unsafe`；
  `NotesWindow` / `NoteCaptureWindow` 里叫 `Current` 的私有属性盖住了 `Window.Current`（CS0108）→ `SelectedNote` / `CurrentDraft`；`NotesHost._queue` 只写不读 → 删。
- 同步：正在编辑的只扣下「这一轮要换进来的」那几条（以前正在打字的那条一直不写出去）；一轮有扣下的、没下载完 / 读不出来的、到期要删的共用图时不记成「安静」；
  共用图片下载时云盘占位 / 刚没了 / 超过上限的跳过，不让整轮失败；认出库被退回去时，自己那份里**没有的**那条也换编号；那一轮便签没合（没勾、没准备好）时编号照换、
  旧编号记在 `sync_ledger` 的 `~notes-switch-from`，便签能合的那一轮按它补认（`ISyncDevice.NotesSwitchFrom`）；自己的 device.json 读不出来时不认退回、不重写它。
  新单测 `EditingANoteStillPublishesIt`、`RollbackSeenWithoutNotesIsCaughtUpLater`。
- 数据：每日备份 / 导入前备份超过 32 MB 时依次去掉最大的一类（便签 / 剪贴板 / 生词本）再写（以前整份不写、导入也一直被拦）；SQLite 打开坏文件时把句柄关掉（不然恢复时挪不开坏文件）；
  退出时便签落不下去先问（重试 / 继续 / 取消，`NotesHost.ConfirmQuit`，同 mac）；便签库备份里图片出错只记日志；裁切后的图带原图 DPI；不合理的 DPI 按 96；
  编码结果用 DataReader 读；导入的便签编号只认标准 UUID 写法；剪贴板的库等着恢复时便签照常落盘、清理、备份；`SwitchDevice` 没有 SyncDevice 时的分支真换编号。
- 编辑器：`ApplyChange`（剪切、粘贴、替换、Ctrl+T 这些命令）跟着改图片表、过 1 MB 上限；按删除键 / 有选区时按改之前的位置认改了哪一段（几张图的 U+FFFC 一样，删一张会对错）；
  组字中间的拼音不进撤销、确认后超上限整回退；外面换了正文清撤销栈（同 mac）；换一条之前先交出去上一条；收起的窗口 / 编辑卡放掉编辑器里的那条（`NoteEditor.Release`，不然空白便签删不掉）；
  只读（最近删除）时命令、粘贴、撤销都不做、不交出去，自己改格式时临时放开 RichEdit 的只读；有图的行行高用「至少」；粘贴先后同 mac（图片文件 → 字 → 位图）、粘成链接要开着 Markdown 且选区里没图；
  标记只在选区碰到的那几行露；拷贝 / 剪切走 `ClipboardWriter`（剪贴板被占着不抛）；组字中不空转排版；撤销栈总字数封顶 800 万、改图片宽度各是一步；Shift+Enter 是普通换行；
  查找条开着时 Esc 先关它；图片表和 U+FFFC 对不上时这一下不交出去（记日志 `notes.editor-images-misaligned`），免得把图片令牌整个丢掉。
- 窗口：药丸放好后要露出来（以前启动后一直不出现）；那叠里 Esc / Ctrl+W 连那一列一起收、关闭钮 / 归档 / 删除回到那一列（以前反了）；标签列没变就不重建（拖动排序、按下后才出的预览卡不再丢指针，打字也不白重建）；
  「一直展开」静置时不跑计时器；全屏判定用 DWM 的可见边框；全屏时「一直展开」那一列也收；菜单浮出去往里挪 48；浮动便签没挪没改大小时不存设置（以前打一个字存一次）；
  全部便签窗口的整页重排攒 250 ms；菜单、取色浮层不限在窗口里；退出时存快速记一条的草稿；设置页脚的说法改对。

**VERIFY / 没改的（核验时看，不对就记在这里）**：
1. **编辑器的占位**：`Replace` / `InsertImages` 用 `SetText` 放的是普通的 U+FFFC 字，再 `InsertImage` 换成图。RichEdit 要是把普通的 U+FFFC 洗成空格，`Aligned()` 会一直拦着不交出去（日志里有
   `notes.editor-images-misaligned`）：那就改成放一张 1×1 的占位图（`InsertImage`），而不是字。也看 `InsertImage` 对一个字的范围是替换还是插在前面、`GetText(None)` 会不会带最后那个段落符。
2. 同步：云盘的「仅在线」文件（OneDrive 按需、iCloud for Windows）不会被要求下载——别人的 `erased.json` 是占位时便签那部分一直停（「还没下载完」）；指纹只看时刻和大小，占位下载完不变。
   要的话用 `CfHydratePlaceholder` 在后台要下载、把占位属性也放进指纹。`device.Epoch > 0` 才认退回（mac 没这个条件）；标记换成别的库时 Windows 照样合（mac 停「不是那个文件夹」）；共用图的账每轮都写。
3. 数据：便签的设置项（字号、行距、Markdown、屏幕边缘那几项）还没进设置导出的「设置」一类（mac 注册了默认值的都跟着走）；恢复流程里 `Needed = null` 早了一点、`ForgetDevice` 用的连接会开 WAL。
4. 编辑器：复制带图的一段再粘回来，是令牌的字、重开才是图（mac 粘回附件）；`InsertImage` 给的是原图（mac 解缩略图）；组字中插图 / 同步来的图换上去没等组字结束；撤销 / 命令后不滚到光标处；
   窗口变宽变窄时「铺满」的图不跟着变；多行选区碰到代码块时 Ctrl+T / 加标记只看第一行；图片位置挪了时异步放图只比那个位置是不是 U+FFFC。
5. 窗口：标签右键「其他颜色…」挂在不拿焦点的标签列窗口上，十六进制那一栏可能打不了字；关掉的窗口里的 `NoteSheetView` 只在 `Unloaded` 时退订；感应范围 8 时药丸窗约 13 DIP 宽，看系统让不让窗口这么窄。


**Windows 核验（2026-11-06）**：VERIFY 1 **确实如此**——RichEdit 把普通的 U+FFFC 洗成空格，按写的退路改成 1×1 占位图（第 4 批下面）；`InsertImage` 对一个字的范围是替换；`GetText(None)` 带最后那个段落符（也修了）。
VERIFY 2–5 没测。

## PLAN-v12（跟上 mac：先把没有的功能做出来，2026-11-05 用户「先把未实现的功能实现」）

清单和分批在 `PLAN-v12.md`（不是拍板页，行为照 mac）；分工同 PLAN-v11 D10。

### 给 Windows agent 的核验指令（PLAN-v12 第 1–7 批 + `83040384`，审查方 2026-11-05）——已并进「PLAN-v13」一节顶上那份，照那份做

这几批连同 `83040384`（用户反馈 2026-11-04 那一节）都是审查方在 Mac 上写的，**一行都没编译过**。2026-11-05 用户定：窗口、合成、输入钩子这次也在 Mac 上写，你们只编译、核验、修编译错和屏幕上不对的地方。按下面的顺序做，改了什么在对应那批下面记一句（改了什么、为什么）。

1. **拿代码**：`git fetch origin && git rebase origin/windows`；`git log --oneline --grep "PLAN-v12"` 应该有第 1–7 批七个提交，`83040384` 也在。
2. **编译零警告**：`dotnet build windows/KittyTools.slnx -c Debug -p:Platform=x64`；`dotnet publish windows/KittyTools/KittyTools.csproj -c Release -r win-x64` 和 `-r win-arm64`，零 trim / AOT 警告；
   发布目录里有 `KittyTools.pri`、`Microsoft.UI.Xaml.Controls.pri`、`Resources\StatusEmoji\`（34 张 PNG + `manifest.txt` + `LICENSE.txt`）。各批「要特别看的编译点」写在那一批下面。
3. **单测**：`dotnet test windows/KittyTools.Tests` 全过。新加 / 重写的：`ExchangeRatesTests` 11、`ScrollPacerTests` 13、`PlanV12Batch2Tests` 4、`StatusScreenTests` 17、`ReminderTests` 18（审查方复查加了 2 个）。
   `ReminderTests.Canonical_MatchesMacByteForByte`、`StatusScreenTests.Sync_MatchesMacAndPlans` 是和 mac 互通的底线，过不了先把实际输出贴在那一批下面，别改 golden。**不许为了变绿删测试、改断言。**
4. **状态屏只走自检**：`KittyTools.exe --status-screen-probe=<临时目录>`（测试档；Probe 模式只吞带标记的注入事件，真的键盘鼠标照常能用，屏幕会被盖住约 15 秒）。
   任何测试、自检、截图脚本都**不许真的进入状态屏**；提醒的「进入状态屏」也一样。要真进入的手测条目留给用户，标「没测」。
5. **手测**（`HANDTEST.md`）：906–917（`83040384`，自动滚动那半照 932 起那一节走）、918–931（第 1 批）、932–951（第 2 批）、952–976（第 3 批）、977–981（第 4 批）、982–999（第 5 批）、1000–1014（第 6 批）、1015–1030（第 7 批）、1031–1042（审查方复查）。
   要真鼠标拖、真按键、等到点、第二块屏、真的 Mac 的，能做的做，做不了的标「没测」留给用户；结果写在那一条后面。同步（1013、1015）只用临时文件夹和假数据，不碰用户真实的同步文件夹。
6. **截图**：各批一个目录推到 `windows-shots`：`0.2.0-feedback-1104/`、`0.2.0-v12-batch-1/`、`0.2.0-v12-batch-2/`、`0.3.0-v12-batch-3/`、`0.3.0-v12-batch-4/`、`0.3.0-v12-batch-5/`、`0.3.0-v12-batch-6/`、`0.3.0-v12-batch-7/`，要哪几张写在那批的「你们做的」里。
   先在 `../kitty-shots` 里 `git fetch origin && git reset --hard origin/windows-shots`；只截自己的窗口（状态屏、提醒全屏的图用自检出的），推之前自己看一遍。
7. **自查**：内存探针（`KITTY_MEMORY_PROBE=1`，和 `1986a4b5` 比，哪一项涨超过 5 MB 写原因）；只有托盘静置 60 s 空闲 CPU 为 0（有开着的间隔提醒时每分钟看一次空闲，不算；提醒边框挂着时 30 Hz 换透明度，收起后回到 0）；
   新日志里没有剪贴板内容、原文、译文、URL、提醒和状态的标题。
8. **版本**：第 1–2 批是 0.2.0、第 3–7 批是 0.3.0；版本号、更新日志、`build-release.ps1` 等这几批核验完再一起定，**不发布、不打 tag**。

### 审查方复查（2026-11-05，`36aafcdf`，同样没编译）

用户要求交给你们之前先由没写这些代码的人独立审一遍：四路分头读了 83040384 和第 1–7 批的 diff 和它们调到的现有代码，对照 mac（`origin/macos`）。
确定的错已经改在 `36aafcdf`（提交正文是全表），各批下面「审查方复查」记了改了哪几处、留给你们确认的几处。**三处确定的编译错**：
`StatusPreset.OneLine` 的字符字面量里是 U+2028 / U+2029 原字符、`StatusScreenHost._probe` 只写不读（CS0414）、状态屏编辑框的 lambda
用到后面才赋值的 `dialog`（CS0165）；另把 `TickerText` 补成 partial（可能的 CsWinRT1028）。

### 第 1 批：启动器汇率换算（N1）→ 已写（审查方，`git log --grep "PLAN-v12 第 1 批"`，没编译）

照 mac `ab0fab4a`、`cf621790`：
- `Core/ExchangeRates.cs`：解析（连接词、口语、繁体、倍数、算式金额、货币在前、只问汇率）、换算和格式（小数位按币种、不到 1 的 4 位有效数字、金额 1 按汇率精度）、
  用法提示、货币候选、用过的货币、汇率表的验（`FromReply`）和存（`Encode` / `Decode`）。货币表 `Core/Resources/currencies.txt` 是在 Mac 上用系统 Locale 生成的（`tools/currency-table.swift`，159 种）。
- `Calculator`：`Result` 多一个 `Note`，`ItemFor` / `ResultFor` 收汇率表和本机货币（单位 → 进制 → 汇率 → 算式）；`IsUnit`；`Digits` 改 internal 给汇率用。
  `LauncherItem.Note`（行右侧替掉种类名的小字），`LauncherMatch.PromptMatch` + `PromptMatchKind`（mac promptMatch，这次只有汇率用）。
- `Launcher/ExchangeRateStore.cs`：联网取（两个源依次试，5 s，不带 Cookie，只收 gzip / deflate），存数据目录 `exchange-rates.json`。
- `LauncherModel`：计算那一行先看汇率（没有表时「正在取汇率…」占位、停 0.3 s 再取，打字路过撤掉，取到换掉那一行）；没计算结果时列货币候选；用法提示的 Exact / Partial；
  占位行 Enter / Ctrl+Enter 只响一声；粘贴、复制过的换算记进 `Settings.LauncherRecentCurrencies`；Ctrl+K 的复制项用汇率表。
- 面板：`KindName` 先看 `item.Note`；`PanelFooterText` 汇率提示写「汇率」、候选写「货币」；`KindTile` 两种都是计算的橙、计算器图标；速查表加 currency 一行。
- 单测 `ExchangeRatesTests`（11 个）。

**你们做的**：
1. 编译、零警告，`dotnet test` 全过（新加的 11 个）。要是 `currencies.txt` 没进程序集（`IsoCodes.Count` 不是 159），看 Core 的 csproj 里那行 `EmbeddedResource`。
2. 走 HANDTEST 918–931（联网那几条用 Dev / 探针档）；927 断网可以拔网线或者临时关网卡，做完恢复。
3. 截图：汇率结果、占位行、用法提示、货币候选（浅 / 深），推 `windows-shots` 的 `0.2.0-v12-batch-1/`。
4. **别动 `83040384` 里长截图控速那半**：第 2 批照 mac 重做（速度放在长截图面板上、匀速小段滚动）；它的「剪贴板面板跟随鼠标」留着，第 2 批加「上次位置」和启动器那一行。这次先编译过它（在 REVIEW「用户反馈 2026-11-04」下面记一句）。

**审查方复查（2026-11-05，`36aafcdf`）**：改了——取到的表里没有那种货币时那一行换成「没取到汇率」（以前「正在取汇率…」一直挂着；mac
`calculationRow ?? placeholder(failed: true)`）；撤掉的那次取表也换进内存；`ExchangeRates.Suggestions` 先滤掉设置文件里不认得的货币代码
（以前 `Currencies[code]` 抛 KeyNotFoundException）；`Calculator.Normalize` 把全角 ￥ £ ¢ ₩ 折成半角（mac widthInsensitive）；
`ExchangeRateStore` 读正文也 5 秒超时（`ResponseHeadersRead` 时 `HttpClient.Timeout` 只管到响应头）；「提醒 …」那几行不能收藏、Tab 不补
（`CanFavorite`、`LauncherText.Completion`，mac 的 `.reminder` 两样都没有）。HANDTEST 1041、1042。


**Windows 核验（2026-11-06）**：编译过、11 个单测过（`IsoCodes.Count` 159）。Dev 档联网取到 11-05 的汇率：「100 usd to cny」「100 usd」出大字结果、右侧「人民币 · 11-05 汇率」；「汇率」出提示行。
截图 `0.2.0-v12-batch-1/`（结果、提示行，浅 / 深）；货币候选那张的查询写错了（「jp」不触发候选）、而且拍进了真实浏览器的书签，没推。断网、6 小时缓存、Ctrl+K 没测。

### 第 2 批：面板位置、长截图控速、工具栏靠右（N2 N3 N4）→ 已写（审查方，`git log --grep "PLAN-v12 第 2 批"`，没编译）

2026-11-05 用户定：这一版连窗口、合成、输入钩子都在 Mac 上写，Windows 只编译、核验、修编译错。照 mac `b923b882`、`389289d4`、`0f83c117`：

- **N2 面板位置**：设置 › 剪贴板「面板」、设置 › 启动器第一组各一行「面板位置」：屏幕上方（默认）/ 跟随鼠标 / 上次位置（`Settings.ClipboardPanelPosition`、
  `LauncherPanelPosition`，值同 mac `top / mouse / last`——`83040384` 写的 `pointer` 没发过，直接换掉）。`OverlayWindow.PositionAtPointer` 按
  `MonitorLayout.Placement` 摆；上次位置用 `MonitorLayout.Relocate`（记着的那块屏不是鼠标所在屏时换算到同一相对位置，mac `relocated`）。
  **面板能拖了**：`_host` 上收没被控件处理掉的按下（`AddHandler(…, handledEventsToo: false)`，再挡一道 TextBox / ButtonBase / ScrollBar / Thumb），
  挪出 4 DIP 才抓指针、`AppWindow.Move`，松手记 `ClipboardPanelLeft/Top`、`LauncherPanelLeft/Top`（int?，这台电脑的状态，不导出）。
- **N3 长截图控速**（重做 `83040384` 的那半）：`Core/ScrollPacer` 换成 mac 389289d4 的做法——`Frame(seconds)` 每帧按速度发一小段滚轮（零头留到下一帧、
  一帧最多按 50 ms 算），`Captured()` 开抓前记一共发了多少，`After(step, shift)` 拼完对账校准倍率（新旧各半、夹在猜的 1/20–20 倍）、对不上退回一半并放慢一半、
  连着 4 帧对不上停、发了滚轮却连着 3 帧不动 = 到头。和 mac 不同的两处写在文件头：单位是滚轮单位（到头还要自上次接上以来发满一格，老程序攒满一格才滚）、
  不翻滚轮正负号。`ScrollingCapture`：自动滚动时 `CompositionTarget.Rendering` 每帧发（`SendWheel` 不再每次把光标挪进选区又挪回去）、抓帧 160 ms；
  开始 / 按 A 接着滚时光标不在选区（或在面板上）才挪到选区中间；光标在面板附近 16 DIP 先不发，移出选区 = 暂停（按 A）。
  速度在 `ScrollPreviewPanel` 按钮行上面一排三个 `ToggleButton`（只在自动滚动的那一轮有），点了 `ScrollingCapture.SetSpeed` 下一帧生效、存 `ScrollCaptureSpeed`；
  设置 › 截图 里那一行删了。`ScrollStitcher` 的改进（重叠在整帧里找、`Similar` 提前返回、`Probe`）和「和上次拼上的一样就不拼」照留。
- **N4 工具栏靠右**：`SelectionChrome.Toolbar(…, alignRight)`（栏右边线对齐选区右边线，翻到上方不变，放进选区往里收 10）、
  `HudPlacement.Compute(…, alignRight)`（开录后的控制条，贴在选区里面时往里收一个间距）；设置 › 截图「工具栏位置」靠右（默认）/ 居中（`ScreenshotToolbarAlign`）。
  长图标注不用这两个，照旧居中。
- **导出导入**：`ArchiveService.PreferencesOf` / `ApplyPreferences` 加 `clipboardPanelPosition`、`launcherPanelPosition`、`screenshotToolbarAlign`（键名和值同 mac，
  读的时候只认那几个值）。拖到的位置、长截图速度不导出。
- 单测：`ScrollPacerTests` 重写（13 个：速度、校准、每帧零头、平滑窗口校准到目标速度、一次滚一屏、攒满一格的老程序、到头、对不上、不发不算停、换档；
  模拟的期望值在 Mac 上用 Python 照抄一份跑过），新加 `PlanV12Batch2Tests` 4 个。`MAC-DIFF.md` 删掉 83040384 加的两条（mac 现在也有）。HANDTEST 932–951，
  906–912、917 的自动滚动那半标成被取代。

**你们做的**：
1. 编译 Debug x64、Release AOT x64 / ARM64，零警告；`dotnet test` 全过（`ScrollPacerTests` 13 个、`PlanV12Batch2Tests` 4 个，原有的 `SelectionChromeTests`、
   `HudPlacementTests`、`ScrollCanvasTests` 照旧过）。要特别看的编译点：`ScrollingCapture` 新加了 `using Microsoft.UI.Xaml.Media;`（和嵌套的 `record struct Tick`、
   `_timer.Tick` 同名不该冲突，冲突就把记录改名 `Beat`）；`OverlayWindow` 里 `PInvoke.GetCursorPos(out _dragStartCursor)` 写的是 `System.Drawing.Point` 字段；
   `ScrollPreviewPanel` 的 `readonly ToggleButton[] _speeds` 在构造函数里赋值。
2. **先确认 `CompositionTarget.Rendering` 在自动滚动时真的每帧都来**：日志 `scroll.auto-stopped` / `scroll.done` 带了 `render-frames=`，滚 5 秒应该是 300 左右（60 Hz）。
   要是只有几十（XAML 不重绘时不来），把 `BeginAutoScroll` 里挂 Rendering 换成一个 16 ms 的 `DispatcherQueueTimer`（`OnRendering` 本来就按两次之间的实际时长算），记在这里。
3. 走 HANDTEST 932–951。944 要改系统的滚轮设置，测完改回；943 挑资源管理器详细信息视图。真鼠标拖面板、点速度钮这些自己走不了的，写「没测」留给用户。
4. 截图：设置 › 剪贴板 / 启动器「面板位置」、设置 › 截图「工具栏位置」、靠右的工具栏、长截图面板带速度那一排（浅 / 深），推 `windows-shots` 的 `0.2.0-v12-batch-2/`；
   自动滚动录 3–5 秒短视频（只录测试窗口 + 面板）。

**审查方复查（2026-11-05，`36aafcdf`）**：改了——拖面板不再抢列表（`OverlayWindow.IsControl` 多挡 `ScrollViewer` 和 `CanDrag` 的元素：
行靠 Tapped、不处理按下，以前按住一动就成了挪面板，剪贴板条目拖到别的 App 也被抢）；「上次位置」记着的那块屏拔了（左上角不在任何屏上）
退回屏幕上方，不夹到最近那块的边上。HANDTEST 1040。**留给你们确认**（没改）：
- `ScrollPacer`：每条 WM_MOUSEWHEEL 只算 `zDelta / 120`、丢掉余数的老程序，每帧发几个单位时画面不动，发满一格再 3 帧不动会被判成到头；
  真碰到就在「这一轮一次都没接上过」时退回整格发。
- `ScrollStitcher.MovingColumns` 拿同一行号比 [0, 帧高)：画布高过「240 + 帧高」后，Probe 的 240 行起是最新一帧，和整张拼时比的不是同一段
  （R43 起就这样，只走模糊兜底那条路）；`ScrollCanvasTests` 要是哪天对不上先看这里。去掉 800 行上限后对不上的帧要试整帧高那么多位置，量一下 4K 选区的耗时。
- `CompositionTarget.Rendering` 在长截图面板没建出来时可能一帧都不来（看日志 `render-frames=`，是 0 就换 16 ms 的计时器）。
- 自动滚动到头 / 对不上停下后按 A 接不着（A 只在暂停时注册），mac 有 ▶ 能重来；`HudPlacement` 的间距 8 和录制条的 10 差 2 DIP。


**Windows 核验（2026-11-06）**：编译过（那几个担心的编译点都没出错）、`ScrollPacerTests` 13 个 / `PlanV12Batch2Tests` 4 个过。`render-frames=` 要真的长截图自动滚动才有，**没测**；拖面板、点速度钮没测。
截图 `0.2.0-v12-batch-2/`：设置 › 剪贴板、截图（浅 / 深）。

### 第 3 批：状态屏（N5）→ 已写（审查方，`git log --grep "PLAN-v12 第 3 批"`，没编译）

照 mac `StatusScreen/`（0.4.0）、mac-overlay-panel §11、mac-whisker/status-screen.md。这次窗口、合成、输入钩子都是审查方在 Mac 上写的，**哪儿编不过、屏幕上不对就直接改**，改了记在这里。

- **Core**：`StatusPreset.cs`（模型、自带三个、`Sanitized` / `Load` / `Merged`、列表操作、摘要、和 mac 一字不差的 JSON `Write` / `Read` / `ReadList`、表情清单 `StatusEmojiCatalog`）、
  `StatusScreenRules.cs`（`ExitHold` 退出判断、`Passcode` 退出密码——数字按扫描码认、小字 / 结束的一句话、防残影、提示和眼睛的摆位、`RandomPeek`）。单测 `StatusScreenTests` 15 个。
- **拦输入** `StatusScreen/InputBlock.cs`：单独线程上 `WH_KEYBOARD_LL` + `WH_MOUSE_LL`，键盘、鼠标键、滚轮回调返回 1 吞掉，鼠标移动放行（16 ms 报一次给会话）；
  连发、修饰键在 UI 线程上按「哪些键按着」算；锁屏 `Pause`（摘钩子）、每分钟 `Refresh`（先装新的再摘旧的）。
  **Probe 模式只吞 `dwExtraInfo == 0x4B495454` 的注入事件**，真的键盘鼠标照常放行：自检用它，`SendProbeKey` 发带标记的按键（`RawInput` 是手写的 40 字节 INPUT）。
- **画面**：熄屏 / 告示 = 每块屏一扇不透明的整屏 WinUI 黑窗（没边框、`DWMWCP_DONOTROUND`、置顶、先 DWM cloak 画几帧再显形）；
  **透出 = Win32 分层黑窗（整体透明度 0.68 / 高对比度 0.82）+ 一扇 HUD 小窗放那一列 + 一扇放胶囊**（透明 WinUI 窗在用户机器上是白的，0cc29cf7）。透出不冒眼睛。
  `StatusScreenView.cs`（那一列、胶囊、密码框、缩小的预览）、`StatusScreenPanel.cs`（每屏的窗）。鼠标所在那块拿前台（压住任务栏），会话每秒 `SetWindowPos(HWND_TOPMOST)` 再提一次。
- **表情** `StatusScreen/StatusEmoji.cs` + `Resources/StatusEmoji/`：在 Mac 上用 `tools/status-emoji.swift` 把 Fluent Emoji Animated（MIT，许可随包）转成帧图集 + 静止画面 + `manifest.txt`；
  160 像素一格、12 fps（9.5 MB；24 fps 要 18 MB）。播放：`LoadedImageSurface`（ms-appx）→ 表面画刷铺满精灵 → 外面 `InsetClip` 只露一格 → `Offset` 离散关键帧无限循环（合成器里跑）。加载完之前是静止画面。
- **会话** `StatusScreen/StatusScreenHost.cs`：进入（截图 / 长截图中响一声不进、录屏 / 录音中提示、拦截建不起来提示）、每秒小字和提到最上面、按住 2 秒、密码框、退出提示 3 秒、眼睛、
  锁屏（WTS 7）收起 + 暂停、解锁（WTS 8）结束、显示器变化（WM_DISPLAYCHANGE）重摆、`SetThreadExecutionState` 管电源、退出后拦截等按键松开（最多 2 秒）、App 退出时当场撤（`FinishSession`）。
  密码在凭据管理器（`Credentials.Target("statusScreenPasscode")`）。
- **选状态的面板** `StatusScreen/StatusPicker.cs`（快捷键先出它；设置里开了「直接进入」就进第一个）。热键动作 `statusScreen`（不设默认键）、`Feature.StatusScreen`、家族色（木色 / 提醒的琥珀也加了）、
  设置 › 状态屏（`SettingsWindow.StatusScreen.cs`）、速查表一类、导出导入四个键（同 mac）、关于页素材出处、复制即译在状态屏里不弹、MAC-DIFF。
- 功能图标 `FeatureIcons.cs` 重新生成多了 `Reminders`：mac 的 `icons/feature/kitty.reminders.svg` 拷到了仓库根的 `icons/feature/`（**这一个文件在 `windows/` 外面**，同 mac 一字不差，两边共用那套源）。
- HANDTEST 952–976。

**你们做的**：
1. 编译 Debug x64、Release AOT x64 / ARM64 零警告；`dotnet test` 全过（新加 `StatusScreenTests` 15 个）。发布目录里有 `Resources\StatusEmoji\*.png`（34 张）、`manifest.txt`、`LICENSE.txt`。
   要特别看的编译点：`InputBlock` 的 `StatusInputKind? kind = message switch {…, _ => null}`、`RawInput` 显式布局；`StatusScreenPanel` 里 `Native.CreateWindowEx` / `WNDCLASSEXW` 照 `ShotFlash` 写的；
   `StatusEmoji` 的 `CompositionStretch` / `LoadedImageSurface.LoadCompleted`；`StatusPicker` 里 `e.Key - VirtualKey.Number1`（枚举相减是 int）；`SettingsWindow.StatusScreen.cs` 的 `DropDownButton`。
2. **先跑自检，别真的进入**：测试档 `--status-screen-probe=<目录>`（屏幕会被盖住约 15 秒，真的键盘鼠标照常能用）。日志看 `status.probe-key … swallowed≥2 touches=1`、`status.probe-hold … active-after-hold=False`；
   看图：三种样式进入后、被碰之后（告示样式应有胶囊和眼睛、标题晃过）。要是 Probe 的事件没被吞（swallowed=0），先查 `KbdllHookStruct.ExtraInfo` 的偏移（x64 / ARM64 都是 16）。
3. 屏幕上要看的（自检看不出来的）：透出的分层压暗层是不是黑的半透明（不是白的 / 全黑）；告示窗一露面有没有白闪；任务栏有没有被盖住（没盖住就记在这里，试 `SetWindowPos` 的时机）；
   表情是不是在动（`LoadedImageSurface` 走 ms-appx 在发布包里取得到；取不到就退回静止画面，日志 `status.emoji-load-failed`）；进度环 2 秒走满。
4. 手测 952–976 里要真按键的留给用户（写「没测」）；974 自检能跑。截图：设置 › 状态屏（浅 / 深）、编辑对话框、选状态的面板、三种样式（自检的图）、速查表那一类，推 `windows-shots` 的 `0.3.0-v12-batch-3/`。
5. 内存：进入 / 退出各量一次（每块屏一两扇 WinUI 窗 + 一张约 4 MB 的图集）；静置 CPU 回到 0。

**审查方复查（2026-11-05，`36aafcdf`）**：改了——编译错：`OneLine` 里的 U+2028 / U+2029 原字符（C# 把它们当换行）、`_probe` 只写不读
（CS0414）、编辑对话框的图标按钮 lambda 用到后面才赋值的 `dialog`（CS0165，建按钮的循环挪到 dialog 之后）、`TickerText` 补 partial。
逻辑：`InputBlock` UI 线程 5 秒没报平安（`Heartbeat`，会话每秒 Tick 报一次）就放行——mac 的拦截挂在主线程上，卡住时系统自己停，这里以前
卡住就谁也出不去；放过自己补的 vkE8（`Foreground.Restore` 拿前台用的，以前被自己吞了、第二次 SetForegroundWindow 照样失败，还算一次触碰）；
只吞「按下也是这里吞的」键和鼠标键的松开，进入前就按着的（快捷键里的 Ctrl、选状态时按的 Enter、正在拖）松开放过去（照样报给会话）。
整屏黑窗按客户区补那圈看不见的边（同 `SelectionOverlayWindow.FixClientArea`，第 0 批实测约 3 px）；眼睛的方向不再装进 WinRT 的 `Tag`；
提示收起、密码框收起后指针再藏（mac 同样）；重摆失败退出时也发 `Exited`；`StatusEmoji` 放合成层包 try/catch，画不出的图标（mac 来的系统表情）
用 Segoe UI Emoji 画。HANDTEST 1034–1036。**留给你们确认**（没改）：
- 透出样式谁都不拿前台（底板、压暗层都是 NOACTIVATE）：前台是管理员程序时低级钩子收不到发给它的键（UIPI），字照样打进去、按住 Esc 也退不出。
  真是这样就让鼠标所在那块屏的底板去掉 NOACTIVATE 再拿前台（mac 每种样式都让面板当 key）。
- 读屏播报挂在 Grid / Border 上：它们默认没有自动化 peer，`RaiseNotificationEvent` 可能什么都不做；不响就在根上放一个透明 TextBlock 专门播报。
- `WM_DISPLAYCHANGE` 在隐藏窗口的窗口过程里同步整套重建（插拔时常连着来好几次），卡就改成 `DispatcherQueue.TryEnqueue` 合并成一次。
- 锁屏后只靠 WTS_SESSION_UNLOCK 结束（mac 另有 2 秒一次的兜底轮询），万一没收到，热键、复制即译、提醒会一直被压着。
- `Stop()` 的 Join 超时以后旧钩子线程退出时会摘掉下一次 Start 装上的钩子（句柄是静态字段）；只在线程 2 秒退不出时才会碰到。

**替用户定的**：透出样式的做法和不冒眼睛（见上）；表情 160 像素 12 fps；不藏鼠标指针；标题整行入场、小字直接换、选中卡片不长成整屏（ponytail，MAC-DIFF 记了）；
退出密码按扫描码认数字；拦截不放过注入事件（别的程序模拟按键也被挡，只有自检标记的例外——自检只在 Probe 模式里认它）；速查表里「用鼠标按住提示」那一行不画键帽。


**Windows 核验（2026-11-06）**：编译过；`StatusScreenTests` 过（`a2d4885` 里给 `planned[1]` 补了 `!`，可空警告）。`--status-screen-probe` 三种样式：status.probe-key swallowed=2 touches=1、
status.probe-hold active-after-hold=False，日志没有 `status.emoji-load-failed`，两帧之间表情的姿势不一样（在动）。**透出样式的底板窗口比那一列宽、右边约 35 px 没画（白）**：底板铺满整扇窗、那一列居中（`8cfa2f1`）。
截图 `0.3.0-v12-batch-3/`：三种样式（自检的图）、设置 › 状态屏（浅 / 深）。压暗层、任务栏、白闪这些要看整块屏的，自检只抓自己的窗口，没看；编辑对话框、选状态的面板没截。

### 第 4 批：状态屏的入口（N5）→ 已写（审查方，`git log --grep "PLAN-v12 第 4 批"`，没编译）

第 3 批已经带了选状态的面板、设置页、导出导入、速查表；这一批是剩下的三个入口（mac buildStatusMenu、HomePanel、LauncherItem.statusPreset）：

- 托盘菜单：`TrayMenu` 支持子菜单（`Item.Children`，`MF_POPUP`；菜单项 id 改成平铺表里的位置，子菜单里的也排进来），「状态屏 ›」= 选择状态…（快捷键）/ 各状态 / 管理状态…。
- 主界面：最后一节「状态屏」一格，同它的快捷键（`RunAction` → `StatusPicker.ToggleOrEnterFirst`）。
- 启动器：每个状态一行（`LauncherActions.StatusPrefix` + id），右侧 `Note = "状态屏"`、`priority: 1`，名字里加「状态屏」和它的拼音；Enter 晚 200 ms 进入（启动器先收起）、不记使用。
  ponytail：行里是木色色块，不是 mac 那样的表情静止画面（LauncherRowView 只认色块 / 图标），要做给 `LauncherItem` 加一个表情 id 再在行里画 `StatusEmoji.Still`。

**你们做的**：编译零警告、`dotnet test` 全过；手测 977–981（托盘子菜单要真点）；截图：托盘子菜单（只截菜单那一块）、主界面带状态屏那一格、启动器搜「状态屏」，推 `windows-shots` 的 `0.3.0-v12-batch-4/`。

**审查方复查（2026-11-05）**：这一批（托盘子菜单、主界面、启动器的状态行）没找到要改的。


**Windows 核验（2026-11-06）**：编译过。启动器搜「状态屏」三个状态各一行（表情、右侧「状态屏」）、主界面截图在 `0.3.0-v12-batch-4/`；托盘子菜单要真点，没测没截。

### 第 5 批：提醒（N6 的模型、执行层、各种方式、设置页）→ 已写（审查方，`git log --grep "PLAN-v12 第 5 批"`，没编译）

照 mac `Reminders/`（`ceaf2897`、`58f638f3`、`83f2dda5`）和 `macos/PLAN.md` §10「提醒」：

- **Core**（单测 `ReminderTests` 13 个；第 6 批又加 1 个，共 14 个）：`Reminder.cs`（模型、示例、收拾、合并、列表操作、摘要、和 mac 一字不差的 JSON——同步用的那一行是 mac `SyncRecords.encoder` 的写法，
  测试里的 golden 是在 Mac 上用 mac 的结构体真编出来的；导出文件里时刻写 ISO 8601，同 mac `.iso8601`）、`ReminderSchedule.cs`（下一次什么时候响、间隔的时段、
  `ReminderState`、`ReminderCheck` 到点 / 错过 / 下一次、`ReminderAlerts` 方式和提示上写什么）、`ReminderPhrase.cs`（一句话建提醒，第 6 批启动器用）、
  `Sync/ReminderSync.cs`（第 6 批接进同步）。时刻存成 mac 的 Date（2001 起的秒数，double），当地日历用传进来的 `TimeZoneInfo`。
- **执行层** `Reminders/ReminderCenter.cs`：一个计时器指向最近要响的那一刻；锁屏 / 解锁（WTS 7 / 8）、醒来（PBT_APMRESUMESUSPEND）、改系统时间（WM_TIMECHANGE）、
  设置里的列表变了、退出状态屏（`StatusScreenHost.Exited`）时重看；有间隔提醒时每分钟 `GetLastInputInfo` 看空闲（5 分钟算离开）。
  状态存 `Settings.RemindersState`（不导出、不同步）。声音：提示音一律 `PlaySound("SystemNotification")`（mac 的 14 种提示音名照存，同步不丢），朗读走现成的 `Speech`。
- **方式**：轻提醒 = `NoticeHost.Pin`（新加的「挂着」模式：不自己收、× = 知道了、别处来的提示收起后再露出来、`Nudge` 晃一下）；边框 = `Reminders/ReminderGlow.cs`
  （每屏四条 8 DIP 的分层窄窗，点穿）；全屏 = `Reminders/ReminderScreen.cs`（借状态屏的压暗层 + HUD 底板，按钮、1 秒内不算、倒数、Enter / Esc）；
  进入状态屏 = `StatusScreenHost.Enter(id, quiet: true, fallbackToFirst: true)`（`Enter` 现在返回进不去的原因，进不去退成全屏写原因）。
- `Feature.Reminders`、热键动作 `reminderNew`（不设默认键，处理在第 6 批）、家族色、设置 › 提醒（`SettingsWindow.Reminders.cs`：列表 + 每行开关 + 编辑对话框 + 「稍后」推多久）。
- HANDTEST 982–999。

**你们做的**：
1. 编译零警告；`dotnet test` 全过（新加 `ReminderTests` 13 个，第 6 批后 14 个——`Canonical_MatchesMacByteForByte` 是和 mac 互通的底线，过不了先别动别的，把实际输出贴在这里）。
   要看的编译点：`Notice.cs` 新加的 `Pin` / `Unpin` / `Nudge`（`_pin` 是可空元组）；`ReminderCenter.NextUp` 里的可空元组；`SettingsWindow.Reminders.cs` 的 `DatePicker.Date`（DateTimeOffset）；
   `ReminderPhrase` 的三个 `GeneratedRegex`（零宽后顾 `(?<!点\s)`）。
2. 手测 984–999 要等到点，先用「2 分钟后」的一次性提醒走一遍轻提醒、全屏、边框、进入状态屏；993 的空闲判断把间隔改成 15 分钟。
3. 截图：设置 › 提醒（浅 / 深）、编辑对话框（一次 / 间隔）、挂着的底部提示、全屏、边框（只截自己的窗口），推 `windows-shots` 的 `0.3.0-v12-batch-5/`。
4. 内存：全屏出来、收掉各量一次；只有托盘静置时提醒不占 CPU（没有开着的间隔提醒时不轮询空闲）。

**替用户定的**：提示音只有系统的通知声一种（mac 有 14 种，名字照存）；边框是实色细边、不呼吸（ponytail）；全屏又合进一条时整个重建；
「暂停全部」和「N 分钟后提醒我」放在托盘子菜单（第 6 批）；编辑对话框里间隔的「到」用 0:00 表示到半夜。

**审查方复查（2026-11-05，`36aafcdf`）**：改了——**和 mac 互通**：`Reminders.Sanitized` 以前比 mac 现在的严（mac 90dbc589 起提示音能选个人声音、
「file:」音频，催促能自定义 1–120 分钟；0aea7ec8–7c203b88 起图标能是后加的 12 个表情、「pack:」动画表情、系统表情），收拾成默认值再同步回去会把
mac 上选的抹掉；改成照 mac 认（`IsValidChime`、`MaxNag`、`StatusEmojiCatalog.IsStorable`），`NagChoices` 换成 mac 那一排，编辑框里这台没有的声音、
自定义的催促多列一项留着（以前改个标题一保存就换掉）。状态没放宽：mac 把 0.7.1 不认得的表情放在 emoji 键，这一版读到整类停下、不动数据（mac 设计的退路）。
`ReminderMath.LocalToUtc` 夏令时照 mac（跳过的钟点取之后第一刻，重复的取第一次）。`ReminderCenter`：醒来不清锁屏标记（mac didWake 只清 isAway；
以前醒来停在锁屏界面时照样响、全屏倒数到 0 把一次性的删了）；在状态屏里 `Present` 先都收着、退出时 `Recheck` 再摆，用快捷键进状态屏时全屏提醒自己收起
（Windows 两边都置顶、每秒互相往上提）。`ReminderScreen`：底板 Alt+F4 关不掉（以前关了压暗层留在屏上、「点了才收」的再也收不掉）、先隐身画好再显形、
内容按值比（以前 Snoozes 比引用、列表一变就重新出场倒数重来）、鼠标不在任何屏上时第一块拿前台、标题 × 0.8（mac）。`Nudge` 不晃别处的提示。
HANDTEST 1031、1037–1039。**留给你们确认**（没改）：全屏提醒收起后键盘焦点落到哪扇窗口（底板抢过前台，按顺序一扇扇关时可能交给别的屏上还没关的底板；
回不到原来的程序就在 Show 时记下 `Foreground.Get()`、Close 后还回去）；挂着那条每次重新露面都会被读屏再念一遍；呼吸曲线是 `(1 − cos πt) / 2`、mac 是
easeInEaseOut（差不到 0.01）。


**Windows 核验（2026-11-06）**：编译过、`ReminderTests` 过（`Canonical_MatchesMacByteForByte` 没动；`a2d4885` 给 `planned[0]` 补了 `!`）。设置 › 提醒截图 `0.3.0-v12-batch-5/`（浅 / 深）。
到点的几种方式要等到点，没测没截（挂着的提示、全屏、边框）。

### 第 6 批：提醒的入口、导出导入、同步（N6）→ 已写（审查方，`git log --grep "PLAN-v12 第 6 批"`，没编译）

照 mac `LauncherModel`「提醒 …」、`addReminderMenu`、`HomePanel`、`ReminderSync`：

- **启动器**：`Core/ReminderPhrase.cs` 加 `ReminderLauncher`（行的目标、`Items`、`Prompts`）。「提醒 / tx / remind + 空格」只列提醒：认得出时间的先是「提醒我：…」（Enter 那一刻再解析一遍、
  过了只响一声、建好收起启动器并提示），再是标题对得上的已有提醒（Enter = 打开 / 暂停，启动器不收、当场刷新那一行；Ctrl+Enter / Ctrl+K「在设置里编辑」），
  认不出时间 / 写了重复的 / 时间过了末尾一行提示（Enter 只响一声）；单输关键词时本地结果后面一行「新建提醒…」（Tab / Enter 补全）。都不记使用。
  三个关键词在 `WebSearch.ReservedKeywords` 里留给提醒。色块、图标：`LauncherActions.FamilyOf / GlyphOf`、`KindTile`（提示行）。动作菜单里的图标用 Segoe（`Clock` / `Pause` / `Play`），不是功能图标的路径。
- **快捷键 `reminderNew`**（不设默认键）：`ShellRuntime.NewReminder` 打开启动器填好「提醒 」；启动器功能关着时打开 设置 › 提醒。
- **托盘**「提醒 ›」子菜单：新建提醒…、下一个（`ReminderCenter.NextUp`）、5 / 10 / 25 分钟 / 1 小时后提醒我（标题「时间到了」）、暂停全部 1 小时 / 暂停到明天 ↔ 恢复提醒、管理提醒…。
- **主界面**最后一节「提醒」一格（新建提醒）；**速查表**加「提醒」一类。
- **导出导入**：`ArchiveService` 写 `remindersSnoozeMinutes` 和 `reminders`（`Reminders.WriteArchive`，时刻 ISO 8601，同 mac）；导入按编号合并（`Reminders.Merged`：本机独有的不删、过期的一次性提醒不加）。`RemindersState` 不导出。
- **同步**：`SyncFolder.ReminderSource`（`ReminderSync.Values / JoinKey / Plan`，账本记在 `sync-ledger.json`，同网页搜索、翻译服务），`Settings.SyncReminders`（默认开）、
  设置 › 通用 › 同步多一行「提醒」（提醒功能关着时不同步，同别的几类）；`SyncRunner.Title`、`SyncFolderRules.IsSyncedKind` 认 `reminders`；合在一起的说明里加了提醒。MAC-DIFF 同步那条改成五类。
- 单测：`ReminderTests.Launcher_ItemsAndPrompts`（建一条、列全部、认不出时间、重复的、关键词提示、三个关键词留给提醒）。HANDTEST 1000–1014。

**你们做的**：
1. 编译零警告；`dotnet test` 全过（`ReminderTests` 14 个）。要看的编译点：`LauncherModel.Execute` 里 `case LauncherKind.Action when ReminderLauncher.IsReminder(item.Target):` 要排在普通 `case LauncherKind.Action:` 前面（已经是）；
   `TrayMenu` 用的是 `Core.Reminders` / `Core.ReminderSchedule`（这个文件没有 `using KittyTools.Core;`）；`$"{until.ToLocalTime():H:mm}"` 的格式串；`ShowSettings(welcome: false, "reminders")` 的非尾随命名参数（别处已有同样写法）。
2. 手测 1000–1014。1013 的同步用两个临时数据目录（`.Dev` 那一套）+ 临时文件夹；能拿到 mac 写的同步文件夹样本就对一下 `reminders.json` 里的行和 mac 一字不差（`ReminderTests` 的 golden 已经对过）。
3. 截图：启动器「提醒 10分钟 喝水」、「提醒 」列全部、认不出时间那行、托盘「提醒」子菜单（只截菜单）、主界面那一格、速查表那一类、设置 › 通用 › 同步多出的那一行（浅 / 深），推 `windows-shots` 的 `0.3.0-v12-batch-6/`。

**替用户定的**：「N 分钟后提醒我」「暂停全部」放在托盘子菜单（mac 在菜单栏菜单）；启动器里的提醒行是琥珀色块 + 提醒图标，不是每条自己的表情（同第 4 批状态行的 ponytail）；
已有提醒按 Enter 是打开 / 暂停（不是打开编辑框，编辑走 Ctrl+Enter）；同步「提醒」默认开、跟着提醒功能的开关走。状态屏的状态列表的同步在第 7 批补上了。

**审查方复查（2026-11-05，`36aafcdf`）**：改了——导入时本机没存过提醒 / 状态（还是示例 / 自带的）就直接用文件里的、不并进示例（mac `list ?? incoming`）；
导出文件里的「0001-01-01T00:00:00Z」读回 distantPast（mac 的 distantPast 是儒略历 0001-01-01，比 .NET 早两天，用真 Swift 核对过；以前导一次，
间隔 / 每周的提醒在同步里个个像改过）；`ReminderPhrase` 关键词和去首尾按全部空白认（全角空格），标题首尾一次去掉空白和「，,、。:：」。
单测 `Sanitized_AndLoad` 的两个输入换成 mac 现在单测里的（催促 121、提示音 "../Nope"；原来的 3、"Xylo" 在 mac 现在的规则下合法），断言没改；
新加 `Sanitized_KeepsWhatMacCanStore`、`LocalToUtc_DaylightSavingLikeMac`。golden 没动（两行用真 Swift 重编核对过）。HANDTEST 1032、1033。


**Windows 核验（2026-11-06）**：编译过。启动器「提醒 10分钟 喝水」「提醒 」「提醒 随便几个字」三张截图 `0.3.0-v12-batch-6/`（浅 / 深）；同步那一节在两份 `.Dev` 数据的真同步里写出了 `reminders.json` / `statuses.json`。Enter、托盘子菜单没测。

### 第 7 批：补齐状态屏和提醒剩下的 → 已写（审查方，`git log --grep "PLAN-v12 第 7 批"`，没编译）

用户 2026-11-05：「先继续剩下的，然后 Windows 的 agent 在一起检查」。第 3–6 批报告里「没做 / ponytail」的几项，除了用户定过不做的（选中卡片长成整屏）和长期例外（透出样式不冒眼睛）都补上了：

- **状态屏的状态接进同步**（mac `StatusPresetSync`）：`Core/Sync/StatusPresetSync.cs`（一个状态一条、顺序一条、第一次合标题一样的只留一个；没存过交出去的是自带的三个，同 mac）、
  `StatusPresets.Canonical`（mac `SyncRecords.encoder` 那一行，golden 在 Mac 上真编的）；`SyncFolder.StatusSource`、`Settings.SyncStatuses`（默认开）、设置 › 通用 › 同步多一行「状态屏的状态」（说明同 mac），
  `SyncRunner.Title`、`SyncFolderRules.IsSyncedKind` 认 `statuses`。提醒那一行的说明也换成 mac 的。
- 设置 › 状态屏 / 提醒 页开着时列表被同步换了就重建（`OnSyncChanged` 多认这两页）；保存前比一次引用，旧了就提示、重建、不写（同网页搜索 E19）。
- **启动器里状态和提醒的行画自己的表情**（mac `presetEmoji`）：`LauncherItem.Emoji`，`LauncherRowView.Icon` 先看它（`StatusEmoji.Still`），没选表情的照旧是色块。
  顺手修：设置页和启动器判断深色用的是 `Theme.ElementTheme`（「跟随系统」时是 Default，深色系统下「开会」「黑猫」不垫浅底），换成 `Theme.EffectiveTheme`。
- **提醒边框改成渐变 + 呼吸**（mac `ReminderGlow`）：`Reminders/ReminderGlow.cs` 重写成 `UpdateLayeredWindow` 逐像素透明的四条窄窗（28 DIP，贴边 0.85 → 0，预乘 alpha；位图交给系统后当场放掉），
  呼吸只换整体透明度（不带位图的 `UpdateLayeredWindow`），UI 线程 30 Hz 计时器按 `Core/ReminderGlowCurve` 算；减弱动态效果时淡入完停表。
- **提示音**：`Reminders.WindowsChimes`——mac 的 14 个名字各对一个 `%WINDIR%\Media` 里的声音（叫法按 Windows 的声音起，存的照旧是 mac 的名字），编辑框里声音选「提示音」时多一个下拉框、选了试听；
  `ReminderCenter.PlayChime`（文件没有就放系统的通知声）。
- **标题逐字浮现**（mac `GlyphEmerge` + `StatusEntrance`）：`Core/StatusScreenRules.cs` 的 `StatusEntrance` 时间表；`StatusScreenView.PlayEntrance`（状态屏和全屏提醒共用）把标题拆成每字一个 `Run`、
  每帧（`CompositionTarget.Rendering`）按时间表设各自画刷的透明度，播完换回整行；整行同时浮上来字号的 0.1。只在状态屏的动画开着、没减弱动态效果时做（同 mac `screen.animates`）。
  ponytail：没有逐字模糊、逐字上浮（Run 只能换颜色）。
- **小字的数字滚过去**（mac `Ticker`）：`Shell/Ui/TickerText.cs`，变了的数字旧的滑出去淡掉、新的从另一边滑进来（`Motion.SlideFrom/SlideTo/Fade`，snap、0.12 s），已经多久往上、倒数往下；
  不做动画的地方整行一个 TextBlock。`StatusScreenView.Column.Footer` 的类型换成它（调用处只用 `.Text`）。
- **全屏提醒原地换内容**：又合进一条时压暗层和窗口都不动，底板里换成新的一列重新出场（`ReminderScreen.Fill`）。
- **状态屏藏鼠标指针**（mac `setHiddenUntilMouseMoves`）：进入后 `ShowCursor(false)`，钩子报来第一下挪动就放回来，退出时一定放回；自检（Probe）不藏。
- 快捷键页、速查表里状态屏那一行照它实际做的事写（mac `rowTitle`）：「选一个状态进入」/「进入排在最前面的状态」（`SettingsDefaults.RowTitle`）。
- 单测：`StatusScreenTests` 加 `Sync_MatchesMacAndPlans`（golden 4 行）、`Entrance_StaggersGlyphsThenRest`；`ReminderTests` 加 `Glow_GradientAndBreath`、`Chimes_EveryMacNameHasItsOwnWindowsSound`。
  MAC-DIFF 状态屏那节更新、加了提醒一节。HANDTEST 1015–1030。

**你们做的**：
1. 编译零警告、`dotnet test` 全过。要看的编译点：`ReminderGlow` 的 `BitmapInfo`（头 40 字节 + 一个颜色表位置）、`UpdateLayeredWindow` 传 null 指针的那次调用；
   `TickerText` 重写的 `OnCreateAutomationPeer`（Grid 的子类）；`StatusScreenView.EmergeTitle` 往 `TextBlock.Inlines` 加 `Run` 再换回 `Text`；`ReminderScreen.Fill` 里 `IsLoaded` 分两路；
   `StatusScreenHost.ShowCursor` 的 `LibraryImport`。
2. 屏幕上要看的：边框是渐变不是实色、在呼吸、四个角略亮、点得穿（分层窗要是整条黑 / 整条不显示，先看 `reminder.glow-update-failed` 日志和预乘）；
   标题逐字淡入有没有闪一下整行（`Inlines` 换回 `Text` 那一帧）；小字滚动时宽度不跳（Segoe UI 的数字等宽）；全屏提醒合进一条时压暗层不闪；状态屏自检里指针不藏（自检不藏是对的）。
   每样只在自检档（`--status-screen-probe`）和真的到点的提醒里看，**别真的进入状态屏**。
3. 截图 / 短视频推 `windows-shots` 的 `0.3.0-v12-batch-7/`：边框（只截一条边的窗口）、启动器带表情的状态行和提醒行（浅 / 深）、编辑框的提示音下拉框、同步那一节多出的一行；
   标题逐字浮现、小字滚动各录 3 秒（自检档、只录告示那块屏）。

**替用户定的**：14 个提示音对哪个 Windows 声音、叫什么（`Reminders.WindowsChimes`，第一个是系统的通知声）；边框的呼吸用 UI 线程计时器（不上 DirectComposition）；
标题逐字只做淡入（没有模糊）；小字滚动一个字一个 TextBlock；设置页那两张列表被换掉时的提示文字；状态的同步默认开。

**审查方复查（2026-11-05，`36aafcdf`）**：这一批里改到的（详见第 3、5、6 批下面那几段）：`TickerText` 补 partial；指针在提示、密码框收起后再藏；
全屏提醒原地换内容时按值比；`StatusEmoji` 画不出的图标的退路。


**Windows 核验（2026-11-06）**：编译过（`TickerText`、`ReminderGlow` 的位图头、`LibraryImport` 都没出错）。启动器状态 / 提醒行前面是各自的表情（截图在第 4、6 批的目录）。边框呼吸、标题逐字浮现、小字滚动没录（边框要等到点；逐字浮现在自检里只拍了静止的两张）。

## PLAN-v11（0.1.0 之后还没做的，2026-11-03 用户「全部按推荐」）

方案和分批在 `PLAN-v11.md` §3；分工照 D10（同 PLAN-v10 D5）。每批审查方写好的推上来、**没编译**，你们编译、单测、在屏幕上验，编译错直接修，在这一节对应那批下面记一句。

### 第 1 批：数据与隐私（M2 M3 M4 M7 M8 M10）→ 已写（审查方，`git log --grep "PLAN-v11 第 1 批"`，没编译）

- **M2**（mac E4）改小保留期先问：`ClipboardStore.PruneCount`、`ShotHistory.PruneCount` 干跑；设置页的四个上限下拉框换成 `LimitCombo`（会删东西就弹确认，取消回原值）；说明文案 `Core/Retention.PruneWarning`（单测同 mac）。
- **M3**（mac E5）：
  - `ShellRuntime.FinishSession`：托盘退出、装完更新重启、**关机 / 注销（`WM_ENDSESSION`，以前没处理）**都走它——先停录屏 / 录音保存（M10 那一半），再提交撤销栈、按「退出时清空」清普通历史；
  - 开着「退出时清空」时启动先清一次（`ClipboardService.Start`）；
  - 所有可写连接 `PRAGMA secure_delete = ON`（`Sqlite.cs`），清空普通历史后 `wal_checkpoint(TRUNCATE)`（`Database.TruncateWal`）。
- **M4**（mac E6）马赛克打进历史原图：`Core/MosaicBurn`（格子和取色同 `AnnotationRenderer.DrawMosaic`，它的 `Average` 改成调这里；单测 `MosaicBurnTests`）；截图遮罩 `OriginalForHistory` / `AnnotationsForHistory` 不带马赛克；改标注回写 `ShotHistory.UpdateAnnotations(…, maskedOriginalPng)` 先写好打过码的原图（临时名 + 改名）再换标注；长图标注 `WriteBack` 直接打在 `_bgra` 上（两个调用处回写完都关窗口）。「模糊」那档打进原图的是方块（ponytail 写在 `MosaicBurn.cs` 文件头）。
- **M7**（mac E10）：`ClipSync.Plan` 的最后一个参数从「现在」改成「本机最旧那条的时间」（`ClipboardStore.OldestCopiedAt`），新来的排在它之前、各差 1 毫秒（单测 `ArrivingClipsGoToTheEndOfHistory`、`ArrivingClipMergedWithLocalTextKeepsTheLocalTime`）。
- **M8**（mac E19）：设置窗订阅 `Syncer.Changed`（`OnSyncChanged`），开着网页搜索 / 翻译那一页、列表被同步换了（比引用）就重建；开着对话框 / 下拉框时先不动；网页搜索的 `Save`、翻译服务的拖动排序存之前比一次引用，旧了就提示、重建、不写。
- **M10**（mac E23）：更新下载能取消——进度提示的「取消」、托盘那一项「正在下载 37% · 取消」、关于页进度条旁的「取消」；取消后提示「已取消更新」、回到「有新版本」。

**你们做的**：
1. 编译 Debug x64、Release AOT x64 / ARM64，零警告；`dotnet test` 全过（新加 `MosaicBurnTests` 3 个、`RetentionTests.PruneWarningSaysHowManyAndWhichKind`、`SyncSourceTests` 2 个）。要特别看的编译点：`SettingsWindow.LimitCombo` 里 `SettingsUi.Combo` 的 `changed` 传了空操作、另挂 `SelectionChanged`；`OnSyncChanged` 是表达式体的 void 方法；`ScreenshotSession.RecordHistory` 里 if 块中的局部函数 `UpdateMaskedAsync`。
2. 走 `HANDTEST.md` 812–826。815、818 要真注销 / 重启（只能在这台机器的测试账号或 `.Dev` 数据上做，别动用户的真数据）；817 用 `findstr` 搜库文件。
3. `WM_ENDSESSION` 里 `RecordingHost.Stop()` 要做重封装，录得长的时候看一眼系统有没有出「这个应用阻止关机」的界面（超过约 5 秒才会出）；出了就在这里记一句，审查方再看要不要先停录制、重封装留给下次启动的恢复。
4. 截图：812 的确认框、824 的提示、825 托盘那一项（浅 / 深各一张），推 `windows-shots` 的 `0.1.1-batch-1/`。

**Windows 收口（2026-11-03，worktree `kitty-win-011`）**：

- **编译**：Debug x64 一处错——`RecordingHost` 整个类是 `unsafe`，第 3 批加的 `RecoverOnStartupAsync` 在里面 `await`（CS4004）。类上的 `unsafe` 去掉，唯一用指针的 `GetWindowRect(…, &rect)` 换成 `out var rect`。审查方点名的三处（`LimitCombo` 的空 `changed`、表达式体的 `OnSyncChanged`、if 里的局部函数）都没问题。之后 Debug x64、Release AOT x64 / ARM64 零警告（发布目录四个 .pri 都在），`dotnet test` 481 个全过；Release x64 `--smoke` 退出码 0。
- **812–813**：Dev 数据（`KITTY_DEV_SUFFIX=v11b1`，`sqlite3` 塞了 3 条两天前的普通历史 + 收藏 + 新的）。设置窗用 UIA 的 Select / Invoke 操作（不发按键）：选「1 天」→ 弹「保留普通历史改成「1 天」？」「会删掉 3 条普通历史，收藏和片段不受影响。」；取消 → 回「7 天」、一条没少；再选点「删除」→ 日志 `clipboard.retention count=3`。改成「90 天」、「图片最多占用」改大 → 不弹。深色同样（`KITTY_APP_THEME=dark`）。截图 `812-dialog-light/dark.png`。
  - 小问题（没改）：删完之后同一页「图片当前占用 … 共 N 条」还是删之前的数，换一页再回来才对。
- **815 / 817**（关机那条路，用自己的进程模拟）：开「退出时清空」，给自己那个进程的隐藏窗口发 `WM_QUERYENDSESSION` + `WM_ENDSESSION`（`SendMessageTimeout`，不是真注销）→ `app.end-session`、`clipboard.cleared-on-quit count=2`，收藏还在；`-wal` 从 12 KB 截成 0，`findstr /m kitty-secret-0815` 在 `kitty.sqlite3` 和 `-wal` 里都搜不到（那条正文 3000 多字，带溢出页）。**真的注销 / 重启没做**：这台是用户正在用的账号。
- **816**：开着「退出时清空」按 PID 结束进程、塞两条普通历史再开 → `clipboard.cleared-on-launch count=2`，收藏还在。
- **818**（撤销栈里的删除）：没测，要在面板里按 Delete。代码上 `FinishSession` 先 `CommitDeletion` 再清。
- **819–822**：`--ui-snapshots` 加了一张 `shot-history-original.png`（`OriginalForHistory` 出的、存进 `shots\<编号>.png` 的那张）：马赛克那块是方块、别的标注都没画，和导出那张对得上位置。真截图 → 历史 → 改标注那条路（820）、长图（821）、只打马赛克（822）要拖鼠标，没测。
- **823 / 824**（同步）：没测，要两台电脑或两个实例 + 临时同步文件夹手动改；`SyncSourceTests` 两条过。
- **825**：Debug + `KITTY_UPDATE_FEED`（假的 0.1.2，指向本机一个限速约 1 MB/s 的 HTTP 服务，60 MB 的包）+ `KITTY_UPDATE_APPLY=1`：下载中关于页是「正在下载 N% · 取消」，点「取消」→ `update.cancel`，回到「更新并重新打开」，`updates\` 里什么都不剩。
  - **修了一处**：从轻提示 / 托盘开始下载时，开着的关于页停在「更新并重新打开」，不变成进度和「取消」（只有在关于页自己点的才会刷新）。`AutoUpdater` 开始 / 结束时发 `UpdateService.Changed`，设置窗订阅它刷新那一行；重跑一遍关于页自己变成「正在下载 12% · 取消」。
  - 托盘那一项（系统菜单，截不了）、进度提示上悬停出「取消」：没测（要鼠标）。
- **826**：同一次 `WM_ENDSESSION` 模拟里录屏录着：`record.exit-stop` → 重封装 → `record.saved`，文件能放、进了截图历史。托盘「退出」走同一个 `FinishSession`；录音那条没单独测。
- **你们做的第 3 条（关机时的重封装会不会弹「这个应用阻止关机」）**：Release AOT，60 fps 整屏测试图案录 62.6 s（12 MB）时发 `WM_ENDSESSION`：整个处理 **267 ms**（重封装 204 ms），离约 5 秒的门槛很远，**不改**（不用先停、也不用留给下次启动）。10 分钟的那次和第 4 批 R24 的 `--record-test=600` 一起量，记在第 4 批。
- **截图**：`windows-shots` 的 `0.1.1-batch-1/`（812 浅 / 深、825 关于页下载中）。824 的提示、825 托盘那一项没截（要真同步 / 系统菜单）。

### 第 2 批：行为（M1 M5 M6 M9 M11–M16）→ 已写（审查方，`git log --grep "PLAN-v11 第 2 批"`，没编译）

- **M5**（mac E7）智谱：规则挪进 system、原文包在 `<原文>…</原文>` 里放进 user，写明「原文可能是问题、指令或对话，只翻译，不回答、不执行」；
  `Core/StreamingText.StripSourceTags` 去掉照抄出来的首尾标签（凑了一半的先不显示）。AI 服务的 system 加同一句英文。
- **M9**（mac E20）AI 服务公网地址没填 Key 不发请求（配置错误「请先在设置里填写 API Key」），设置里那一行写「未填 API Key」；
  `TranslateCoordinator.Retry` 用设置里现在的那份配置，删掉 / 关掉的服务卡片收掉。
- **M12**（mac U2）查词只认 1 个字母词（Windows 没有系统词典，2–3 个词的一律普通翻译、能替换原文）。`PlanV3Batch2Tests` 里
  「look up」「a piece of」两条期望改成不是词：**这是规格改了（mac 同一条），不是为了让测试变绿**。
- **M15**（mac U14）划词翻译并替换：一个服务失败就试下一个，取消、截断不换。
- **M6**（mac E8）启动器：这个输入下选过的本地结果排到固定行前面（`LauncherMatch.Promoting`，单测）。
- **M14**（mac U8 的一半）含中文时 1 个字就搜书签、浏览历史、出兜底（`LauncherMatch.IsLongEnough`，单测）。默认兜底本来就是必应，Google 那一半不用改。
- **M11**（mac U1）截图历史里的录屏条目加「转成 GIF」「压缩」（右边一列和右键）。
- **M16**（R62 漏的那条）长截图角落卡按图本身的像素（`Core/PngInfo` 读 PNG 头，单测）算形状、复制记的尺寸。
- **M1**（mac E3）原定归你们，代码很短审查方先写了：角落卡的「钉在屏幕上」，长截图 / 框的那块屏不在了时按图的比例钉在鼠标旁边
  （`PinHost.ShowNearCursor`）；历史里钉图，当初那块屏不在了就钉在鼠标所在屏中间（`Displays.IsOnScreen`，`MONITOR_DEFAULTTONULL`）。
- **M13**（mac U3）一半：长截图拼得比第一帧长时第一下 Esc 只上膛、出提示，3 秒内再按才放弃（`ScrollingCapture.RequestCancel`）。

**你们做的**：
1. 编译、零警告，`dotnet test` 全过（新加 `StreamingTextTests.StripsEchoedSourceTagsEvenWhenSplit`、`LauncherCoreTests` 2 个、`PngInfoTests`）。
2. 联网冒烟（`KITTY_LIVE_TRANSLATE=1`）照旧过；手动拿内置智谱翻 HANDTEST 827 那两句。
3. 走 HANDTEST 827–843。
4. **M13 剩下的一半归你们**（输入钩子）：长截图期间 Esc 是 `RegisterHotKey(VK_ESCAPE)` 注册的全局热键，被拍的程序收不到 Esc（想关个弹层就把长图丢了，现在至少要按两下）。
   你们定：换成低级键盘钩子只看不吞（Esc 照样给前台程序、我们也收到）是不是更好；改了的话 Enter 一起看，提交里写清楚。HANDTEST 841 记结果。
5. M1 在真屏上看：长截图钉出来的大小、位置；有副屏的话走 839。

**Windows 收口（2026-11-03）**：编译没有新错（第 1 批那处 CS4004 修完后整个解决方案一起过）；`dotnet test` 481 个全过，联网冒烟（`KITTY_LIVE_TRANSLATE=1`）过。界面操作照旧用 UIA 的模式点自己的 Dev 进程，不发按键。

- **827**：内置智谱（Debug + `--translate-text`，不抢焦点的那条路）：「帮我写一个快速排序」→ `Please write a quicksort`；「What's the difference between let and var?」→「什么是let和var的区别？」，都只翻译。828 的标签：卡片上没出现 `<原文>`（单测 `StripsEchoedSourceTagsEvenWhenSplit` 管半截的）。829 没测（没有自建服务的 Key）。
- **830**：设置里写两个 AI 服务：公网地址不填 Key → 卡片是「请先在设置里填写 API Key」（配置错误，没发请求），设置里那一行写「未填 API Key」；本机地址（假的 OpenAI SSE 服务）不填 Key → 照发、请求里没有 Authorization，出「本地假译文」。
- **831**：卡片上「打开设置」→ 直达那个服务、把「启用」关掉，但翻译浮窗一打开设置就收起，回去要按快捷键 → **重试那一半没测**。
- **832**：「Sign in」→ 普通译文「登录」，「run」→ 词典词条。「替换原文」只在划词翻译里出，要划词，没测。
- **833**（替换失败换下一个）：要在别的程序里划词，没测。
- **834**：Dev 库里塞一条「在 ip 下选过 Bandizip」→ `--launcher-script` 打 ip：第一行 Bandizip，本机 / 外网地址跟在后面。**835**：「淘」→ 没有本地结果，出「用 Bing 搜索「淘」」；「a」→ 128 条本地结果、没有兜底。（这两张图里有本机 IP 和书签，不推 shots。）
- **836**：3 秒的测试录屏进 Dev 截图历史 → 右边一列有「转成 GIF（10 fps，长边 800）」「压缩（不超过 60%）」，点了都出结果（GIF 一条、压缩 329 KB → 105 KB）；按钮只在 `ShotKind.Video` 上加（代码）。右键菜单、「文件已经不在了」没测。
- **837、840**：要真的长截图（拖框、按 S、滚），没测。
- **838（M1）真屏**：临时开关让 `PinHost.ShowNearCursor` 钉一张 1280 × 9000 的图（同角落卡那条路）：钉在鼠标旁边、整张都在、竖长。**顺手发现并修了**：钉图窗口留着系统细边框，`MoveAndResize` 给的是整个窗口，图被塞进小一圈的客户区——普通钉图缩小 1–2%（糊、偏几个像素），细长的长图钉图横向压了约 8%（144 × 1106 显示 158 × 1113 的图，左右的边框比上下多）。改成先量出边框再加回窗口，客户区正好是图的像素、落在原位；缩放也加上边框。验：1 px 黑白竖条的图钉出来逐像素没有灰（一像素对一像素）；长图钉图 160 × 1114 = 158 × 1113 + 边框。
- **839**：只有一块屏，没测。
- **841（M13 剩下的一半）**：**改成低级键盘钩子、只看不吞**（`Screenshot/EscapeKeyWatch.cs`）：长截图期间 Esc 照样给被拍的程序（关弹层不再丢长图），我们这边也收到、走 `RequestCancel`（拼长了第一下只上膛）。钩子在单独线程的消息循环上（同录屏的 `InputHooks`），UI 线程拼图忙也不会被系统因超时摘掉；只认真的按下，注入的、按住不放的自动重复不算（不然按住 Esc 一秒就连按两下放弃了）。**Enter 不改**、照旧是临时热键吞掉：完成那一下要是也给了网页，正好落在焦点所在的链接 / 按钮上。按键是物理按的才算，这里没法自动验，**留给用户**（HANDTEST 841 改成了期望的样子）。
- **842**：830 的状态字浅色截了；836 的菜单、840 的提示、深色没截。
- **843**：翻了 Dev 档这几次的日志：没有原文、译文、假服务的地址、IP、应用名。

### 第 3 批：REVIEW 剩下的小条（R40 R41 R48 R50 R51 R52）→ 已写（审查方，`git log --grep "PLAN-v11 第 3 批"`，没编译）

- **R40**：对着现在的代码看过，翻译历史的 Shift+Tab 筛收藏、删改成 Ctrl+Delete（不再和搜索框里删字抢 Delete）、Ctrl+H / W / P 都已经在 PLAN-v9 翻译那批（8a–8e）里好了，没改代码。
- **R41**：启动器认 Ctrl+W（速查表加了一行）；钉图右键加「恢复 100%」（「存储」S10 已经加了）。**设置窗按 Esc 关 / 返回不做**：Windows 的设置窗没有按 Esc 关的习惯，详情页顶上已经有「‹ 返回」。
- **R48**：复制大图（截图、钉图、角落卡、截图历史、剪贴板监听）改走 `ClipboardStore.RecordImageAsync`：写盘和 SHA-256 在线程池上（`ImageStore.Stage` 写成 `staged-*.tmp`），UI 线程只查重、入库、改名（`Adopt`）；查重命中删暂存的；启动清孤儿时顺带清 `staged-*.tmp`。`ImageStore.Save` 删了。透镜的图记住上一张（`ClipLensView._lastImage`），同一条刷新不再从盘上解码。顺带：钉图「复制」记的尺寸也按图本身（同 M16）。
- **R50**：日志常驻一个 `StreamWriter`（AutoFlush、共享读写删），写之前看日期，跨天换文件、顺手清 7 天前的；`Shutdown` 关文件。**没换成后台队列**（一行几微秒，ponytail 写了量出来卡再换）。
- **R51**：固定面板只挂一次 Tick；`{cursor}` 往回挪 50 下一批发（500 下从约 4 s 变成约 80 ms）；链接预览缓冲从 `ArrayPool` 借、只扫新读进来的那段、空闲回收丢带头图的那几条；翻译历史加普通索引（迁移第 9 步 `translations_source_target`）；录屏 / 录音的闪退恢复挪到线程池（`RecoverOnStartupAsync`，恢复期间又开了新录制时不清它的临时路径）；透镜里文件条目的存在性挪到线程池（先按「在」画，查完再改）；空闲回收时清搜索的折叠副本。**保留规则改用 long 不做**：5000 条每次复制多出的短字符串不到 1 ms，要改就得换 Core 的类型和十几条单测。
- **R52**：删了 `ScreenshotOutput` 的 `PngAsync` / `CopyAsync` / `QuickSaveAsync` / `SaveAsAsync`、`SqliteStatement.BindBlob`、`ListHighlight.GlideTo` / `HideHighlight`、`SearchLine.FocusBox`、`Theme.KindTint`、`SyncDevice.NextCounter`（连 `WriteRawClock`）、`Paster.SendHotkey`、`Speech.TagFor`、`AudioRules.WritePcm16`、整个 `MicaBackdrop.cs`、`NetstatOutput` 连它的测试（`NetstatParsingTests`）。`HeightChange`、`TranslateReplaceHotKeySeen` 早就没了；`GetBlob`、`IsBuiltin`、`ResetBinding`、`BackupFiles`、`ApplyingRatio` 现在有人用，留着。
  重复：`ImageCodec.ToBitmapAsync`（钉图、角落卡换过去；设置窗那份是先给 ImageSource 再填，形状不一样，留着；透镜、放大卡几处各有解码尺寸，没动）；「留着的条目」规则收成 `Core/Retention.IsRetained`，剪贴板库、同步、导入四处都调它。

**你们做的**：
1. 编译、零警告（`TreatWarningsAsErrors` 开着：删代码后有没有冒出没人用的私有字段、`using` 之外的警告），`dotnet test` 全过（少了 `NetstatParsingTests` 一个）。
2. 走 HANDTEST 844–853。
3. **飞入卡按卡片大小解码**（R52 最后一条）：`ScreenshotCard.LoadImageAsync` 现在是 `ImageCodec.ToBitmapAsync(_png)`，加 `decodeWidth`（卡片宽 × 缩放）就是按卡片大小解码；先量一下截图后的内存省多少、飞入开头几帧糊不糊，再决定用不用（记在这里）。
4. `Mp4Remux.TryRemuxWithTimeout` 现在在线程池上跑（以前在 UI 线程）：闪退恢复走一次（HANDTEST 851），看重封装成功、提示照常出。

**Windows 收口（2026-11-03）**：编译、零警告（删代码后没冒出没人用的字段），`dotnet test` 481 个全过（`NetstatParsingTests` 那个随死代码删了，数目和第 2 批之后一样是因为第 1、2 批加了几个）。

- **飞入卡按卡片大小解码（你们做的第 3 条）→ 用了**。临时开关连开三张 4K（3840 × 2160）的角落卡，量专用工作集（Debug，各跑两次）：整张解码 **+69.5 / +69.3 MB**，按卡片大小 **+5.7 / +5.4 MB**，一张 4K 省约 21 MB。「飞入开头几帧糊不糊」不存在了：0.1.0 起卡片不飞、直接在右下角原大小淡入，卡片也不放大。`UniformToFill` 会裁掉一边，所以解码宽度取「宽铺满」和「高铺满」要的较大那个。拖出去、双击打开用的还是原图。
- **846–847**（临时开关，Debug）：`RecordImageAsync` 复制 22 MB 的 PNG：UI 线程最长卡 **0 ms**（每 5 ms 往 UI 线程排一次空操作量的）；同一份数据按以前的做法（UI 线程上两次 SHA-256 + 写盘）**30 ms**。4K 截图那张 0.5 MB 的前后都是 1–2 ms。同一张连复制两次：历史还是一条、`images\` 里只有 `1.png` `2.png`，没有 `staged-*.tmp`。钉图上按复制、截图历史里复制没走（要按键）。
- **849**：`logs\` 里先放两天前的假文件 `kitty-20261020.log`（14 天前）、`kitty-20261030.log`（4 天前）→ 启动后 14 天前的删了、4 天前的还在；开着时 `Get-Content` 读得了今天的日志。真跨午夜没等（每写一行比一次日期，代码看过）。
- **851**：Dev 档录屏录到第 7 秒按 PID 结束 → 再开：`tray.added` 在启动后 209 ms、`shell.ready` 222 ms，之后 `record.remux ok=True ms=31`（线程池）、`record.recovered`。提示的样子没截（合成层）。顺带：结束进程后马上（不到 1 秒）再开的那一次直接退了、没写日志，隔一会儿再开就好——像是旧进程的单实例互斥量还没放，用户这么快重开的机会不大，没追。
- **844**：速查表「启动器」组里有 Ctrl+W 一行（`ShortcutsSheet.cs:338`），启动器 `VirtualKey.W when control` 收起；真按没测。**845、848、850、852** 要鼠标 / 按键 / 网络盘，没测。
- **853**：内存探针里 `clipboard.caches-released`、`launcher.caches-released` 都出了（面板收起两分钟后）；重新取回头图没测。
- **自查清单**：
  - Release AOT x64 / ARM64 零警告；内存探针（Release AOT、`KITTY_MEMORY_PROBE=1`）和 0.1.0 那份构建（4e25334）同一台机器前后各跑一次，每一步都没涨，大多略降：只有托盘 56.8 → 56.2，剪贴板面板 63.8 → 62.7，启动器 70.0 → 68.8，翻译窗 72.4 → 70.3，截图五次 94.7 → 92.3，静置两分钟 94.8 → 92.6 MB。
  - **两个录屏步骤每次 +26 MB、两分钟后不降**（121.3 → 146.6），**0.1.0 那份同样是 +26.2 / +25.3**，不是这一版引入的；`STATUS.md` 里 R27 记的「+3.2 / +0.3」已经不对了。没在这一版追，记在下面「新发现」。
  - 空闲 CPU（Release，只有托盘，静置 30 s 后量 60 s）：0 ms。

**新发现（不在 PLAN-v11 里，没修）**：
- 录屏后的内存：内存探针的「录 5 秒 640 × 360 的窗口」两次各 +26 MB 不回落（0.1.0 起就这样）。R27 当时修的是「D3D 设备没销毁」，可能有别的东西又留住了设备或帧池。
- 截图历史里录屏条目的尺寸写的是「480 × 270」（整屏 2560 × 1440 录的），像是记成了缩略图的尺寸（`836-history-video.png`）。

### 第 4 批：R24 重测 + 回归清单 + 打 0.1.1 → 回归清单已写（审查方，`git log --grep "回归清单"`）；0.1.1 已打包、装上，没发布（R24 还没过，见下）

- **G**（D9）：`HANDTEST.md` 开头换成按功能分组的「真机回归清单」R1–R40（每条「做什么 → 期望 → 细节在哪」），812–853 这一版的手测接在后面；
  1–811 和原来的发版冒烟清单 18 步原样挪到 `docs/archive/HANDTEST-2026-11.md`（编号不变，REVIEW 和 PLAN 里的「HANDTEST N」照旧能查）。`AGENTS.md` 自查清单第 7 条跟着改了。

**你们做的**（第 1–3 批编译、走完 812–853 之后）：
1. R24：拿重写过的探针（`f07feaa`）对着会动的画面重测音画同步，结果记在 R24 下面。
2. 版本号和更新日志 → **审查方已写**（`git log --grep "0.1.1 更新日志"`）：`Directory.Build.props` 改成 0.1.1，`changelog.json` 加了 0.1.1（17 条：12 fix、1 feat、3 ui、1 perf，
   含 0.1.0 发布之后的深色开关 / 彗星 / 减弱动态效果闪退那次）。你们走 812–853 时哪条没做成、行为和写的不一样，就把那一条改掉或删掉；
   日期写的是 2026-11-03，打包那天改成那天。
3. `build-release.ps1` 打包、`setup-e2e.ps1`；用新包跑 `--update-live=0.1.0`。
4. 用 setup.exe 装上，从头走一遍真机回归清单 R1–R40，没过的记在这里。**不发布**，发不发由用户定（发布一律 `--latest=false`）。

**Windows 收口（2026-11-03）**：

- **R24**：重测了，还没过；测试音的旧文件修了，剩下的锯齿要逐帧解码才分得清（数和分析写在 R24 末尾）。10 分钟那次查出 **0.1.0 就有的「超过一分半的录屏、录音只存下前 90 秒」**，修了（`557181b`，R24 第 6 条），更新日志加了一条。
- **更新日志**：照手测改了三条（钉图一像素对一像素、长截图 Esc 照样给被拍的程序、角落缩略图少占内存，都并进原来那条），加了 90 秒截断那条，摘要开头提了它；日期就是打包这天 2026-11-03。其余 17 条和实际一致；「替换原文」「划词翻译并替换换下一个」「同步」那几条这边没能真机走（见第 1、2 批），照审查方写的留着。
- **打包**：`build-release.ps1`（Windows PowerShell 5.1 + vswhere 的 PATH），`--smoke` 过；`windows/build/release/0.1.1/`：
  - x64：82 MB / 95 个文件（不含 pdb），zip 30.8 MB `358fbd53ab3c…`，安装包 22.6 MB `86048cb27e52…`
  - ARM64：87.5 MB / 95 个文件，zip 29.9 MB `1e2fd01a0582…`，安装包 22.3 MB `9582819fa354…`
  - exe 是 `0.1.1+557181b`；内置智谱 key 两个架构的 exe 里都有（只比对、没打印）。
- **`setup-e2e.ps1`**（x64 zip）：18 项全过。**`--update-live=0.1.0`**（新包的 exe，探针档）：退出码 0，`report.txt`「version=0.1.0 testMode=False ok=True 下载 32219713 字节，sha256 对得上」。
- **装上**：x64 setup `/SILENT /DIR="D:\Apps\Kitty Tools"` 覆盖用户的真实安装：装前 exe 是 `0.1.0+47bac20`（11-01 12:37），装后 `0.1.1+557181b`（14:43），「应用」登记 0.1.1。程序被安装包叫退了；静默装完**没有自己重开**（向导那条「装完打开」在静默时不跑），这边从资源管理器重新打开了。
- **真机回归清单 R1–R40**：这台机器上能不按键、不点别的程序走的只有下面这些；**其余（R1 的向导、R5–R7、R9–R37 的大部分、R39 讲述人）都要真按键 / 鼠标，没走，留给用户**：
  - R2：装后版本 `0.1.1+557181b`；Release `--ui-snapshots` 的关于页：版本 0.1.1、图标不糊、更新日志最上面是 0.1.1（2026-11-03）。「程序开着时双击安装包先问要不要重装」是向导里的，没走。
  - R3：`--update-live` 过（上面）；取消下载在 Debug + 本机假发布列表上走过（第 1 批 825）。真的「更新并重新打开」要等发布后。
  - R8：浅 / 深色各界面 `--ui-snapshots` 出了 150 张（Release）；150% 和高对比度没测（只有一块 100% 的屏，没切高对比度）。
  - R12 / R13 / R31 的一部分：第 1 批走过（812–817、819 用探针图）。
  - R25 / R26：长截图没走；钉图那半边第 2 批真屏看过（838）。
  - R28：截图历史里的转 GIF / 压缩第 2 批走过（836）。
  - R30：按 PID 结束录屏后再开，第 3 批走过（851）；托盘退出前先保存走的是同一个 `FinishSession`，第 1 批用 `WM_ENDSESSION` 走过（826）。
  - R38：`--crash-test`（Release 探针档）→ `crash-*.log` 有时间、阶段、版本 0.1.1.0、系统、堆栈；再开写了 `crash-seen`（提示出了一次）。这几次 Dev / 探针档的日志里搜不到原文、译文、网址、IP。
  - R40：Release 只有托盘静置 60 s CPU 0 ms；专用工作集只有托盘 56 MB（探针档带 5000 条剪贴板）；收起两分钟后 `clipboard.caches-released` 出了（内存探针）。
- **截图**：`windows-shots` 的 `0.1.1-batch-3/`（角落卡按卡片大小解码后、关于页浅 / 深）。
- **发布**（2026-11-03 用户：「发布0.1.1」）：https://github.com/YyAdnBug/kitty-tools/releases/tag/windows-v0.1.1 ，tag 指 `557181b`（exe 就是从它打的），不是 latest（latest 仍是 macos-v0.7.1）、不是预发布，8 个文件（两个架构的安装包、zip 和各自的 `.sha256`），说明用的是 `release-notes.md`。走 REST API：先建草稿、传完再发布。发布后用 0.1.0 的 Release 构建（探针档）检查更新：`update.check newer=True version=0.1.1`。

### 0.1.2 热修（2026-11-04 用户「可以开始 0.1.2」）→ 审查方已写（分支 `windows-0.1.x`，`ba556a37`，没编译）

**为什么**：GHSA-p3jp-9v83-76w9（.NET Brotli 解码越界写，高危，2026-11-03 公布，< 10.0.14 都有）。0.1.1 是 10.0.13 打的，
链接预览（默认开）的 HttpClient 开着 `AutomaticDecompression.All`：复制一个恶意网址就会去解它给的 Brotli。windows 分支上已经有 0.2.0
做了一半的东西，所以从 tag `windows-v0.1.1` 开 `windows-0.1.x`，只带三样：`5fa12ae` 的运行时钉 10.0.14（拣过来是 `db2379e`）、
`989cd77` 里的 `WgcScaler.cs`（窗口录屏每次多 24 MB 不回落；0.1.1 到第 7 批之间这个文件没动过，整段照搬）、版本 0.1.2 + 更新日志两条。

**用户报的：截图完会闪一下**（「我记得之前没有」，可能是最近哪次优化带出来的）。审查方看了 0.1.0 → 0.1.1 截图收尾那条路（复制 / 存完 → `Finish` 关遮罩 → 角落卡淡入 + 「已复制截图」胶囊）上的改动，没找到一眼能认出的。嫌疑按可能性：
1. `9853db1` 角落卡按卡片大小解码（`ToBitmapAsync(png, decodeWidth)`）：卡片先露出深色底、图后到，或者图在 `Motion.Appear` 中途换上来。
2. `b2414c1` 复制后 `RecordImageAsync` 挪到后台、`75d6f86` `Theme.Brush` 的兜底色（胶囊 / 卡片某一帧的底色不对）。
3. 只在 windows 分支上有的（如果用户装的是更新的测试包）：F5 / F6（默认关）、C4 工具栏动效。

**你们做的**：
1. **先查闪烁**：0.1.0、0.1.1、windows 分支最新各打一份 Release（探针档），用自己的满屏测试图案当背景，走一遍「框选 → 复制」（要的话加个探针：程序里定好选区、直接调复制，不发按键），WGC 录整块屏、`--video-frames` 逐帧看收尾前后那半秒（只在本机看，整屏的帧不推）。定出是哪个提交、哪一帧不对再修：
   - 0.1.1 就有 → 修在 `windows-0.1.x` 上，再 `git cherry-pick -x` 到 `windows`，0.1.2 的更新日志补一条；
   - 只有 windows 分支有 → 只修 `windows`，记在 0.2.0 那几批下面。
   - 三份都不闪（复现不出来）→ 记下试了什么，问用户闪的是整屏、右下角的卡、还是顶上的胶囊。
2. **编译 `windows-0.1.x`**：Debug、Release AOT x64 / ARM64 零警告，`dotnet test` 全过；`obj` 里的 `project.assets.json` 不能再有 10.0.13 的编译器 / 运行时包（`runtime.win-*.Microsoft.DotNet.ILCompiler`、`Microsoft.NETCore.App.Runtime.win-*`，有 `Microsoft.NETCore.App.Runtime.NativeAOT.win-*` 的话也要 10.0.14）。
3. **窗口录屏的内存**：这条分支上没有 `--record-memory-probe`（第 7 批才加的），录一扇窗口两三次、看专用工作集不再一次涨一截、文件能存下就行（数在 windows 上第 7 批已经量过）。
4. **打包**：`changelog.json` 的日期改成打包那天，跑 `build-release.ps1`（带 `--smoke`），新包跑 `--update-live=0.1.1` 要过；装着 0.1.1 的临时目录里走一次 App 内更新到 0.1.2（`--update-test` + 本机假发布列表，同第 6 批的做法）。
5. **不发布、不打 tag**，报告写产物路径和 sha256，提交推到 `windows-0.1.x`。**别把 `windows-0.1.x` 并进 `windows`**（你们推前要 rebase，带着合并提交会出事）：发布后审查方并。

**Windows 验收（2026-11-04，`windows-0.1.x` 到 `df0e466`，没发布、没打 tag）**：

- **截图完闪一下 → 找到了，是「已复制截图」那条提示第一次露面时白闪**：0.1.0（`34e37df`）、0.1.1（`557181b`）、windows（`835e9fb`）各打一份 Release AOT
  探针包（临时探针，没提交）：主屏铺一张自己的静态色块图案，程序里开截图、定选区、复制（不发按键；复制那一步不写系统剪贴板，免得进用户真的剪贴板历史），
  WGC 逐帧录整块主屏（KITTY_HUD_CAPTURE=1 放开提示 / 角落卡的不进截图），每帧量提示、角落卡两块的平均色。**三份一样**：遮罩一帧收掉、角落卡淡入都干净；
  底部提示先**黑**约 150 ms，再**跳到近白（242–249）**，约 270 ms 才暗到深色亚克力（70）。同一进程里第二条提示没有白（44 淡到 70）；取消截图那条路三份都干净。
  - 原因：提示窗口到第一次 `ShowCore` 才设 `_root.RequestedTheme`，亚克力接上时按的是系统主题。这台机器系统浅色、App 设了深色，第一次露面从浅色过渡到深色。
  - 修：`a8b96c7`（建窗口时就设深浅色，一行），`git cherry-pick -x` 到 windows；0.1.2 更新日志补一条（`df0e466`）。同一探针：原样「黑 → 242 → 70」，修后「黑 → 52 → 70」。
  - **没修的**：每次复制提示都先黑约 150–200 ms（复制那会儿 UI 线程忙，XAML 还没画上），三个版本都有、不是回归。试过启动后隐身预热提示窗口：
    只去掉了空闲时第一条的一帧黑，复制时照样黑，还要处理层级，热修里没留。
  - 用户今天 17:31 那三次截图日志里没有复制、没有存储（是取消掉的），取消那条路录出来是干净的。**0.1.2 装上以后如果还闪，要问用户闪的是哪一块、在复制还是取消之后。**
  - 只看了 WGC 录下来的帧，没请用户用眼睛看修后的样子。
- **编译**：Debug x64、Release AOT x64 / ARM64 零警告，`dotnet test` 481 个全过。`project.assets.json`：`Microsoft.DotNet.ILCompiler`、`runtime.win-x64 / win-arm64.Microsoft.DotNet.ILCompiler`、
  `Microsoft.NETCore.App.Runtime.win-x64 / win-arm64`、`Microsoft.NETCore.App.Runtime.NativeAOT.win-x64 / win-arm64` 都是 10.0.14；两个架构的 exe 里是 `10.0.14+0427b9a`。
  还剩 10.0.13 的只有 `Microsoft.NET.ILLink.Tasks`（编译期的裁剪器）、`Microsoft.NETCore.App.Host`、AspNetCore / WindowsDesktop 的运行时包（列在下载里，不进 AOT 的 exe）。
- **窗口录屏的内存**：把 windows 上的 `RecordMemoryProbe` 临时拷进 0.1.1 和 0.1.2 的探针包（没提交），同一进程连录 3 次 640 × 360 的窗口（帧是 626 × 353，走 WgcScaler），
  专用工作集：0.1.1 是 32.9 → 49.8 → 73.8 → 98.1 MB（每次 +24 MB、不回落）；0.1.2 是 33.0 → 48.9 → 50.6 → 51.1 MB。三个文件都存下了（151 帧，重封装成功）。
  正式包 `--record-test=8 --record-resize` 也录了三次，都 `record.saved`。
- **打包**：`build-release.ps1`（x64 解压跑了 `--smoke`）。exe 里有内置智谱 key（只数了出现次数），版本 `0.1.2+df0e466`。产物在 `kitty-win-012\windows\build\release\0.1.2\`：
  - `KittyTools-0.1.2-windows-x64.zip`  `01f471277363a1cf9f2a3b069069c8f29ab66702013815ae3112d066244c5caf`
  - `KittyTools-0.1.2-windows-x64-setup.exe`  `8f00c1f8315bcf7c3809b90bd24f869345d0e5589f393777670e285242851b76`
  - `KittyTools-0.1.2-windows-arm64.zip`  `ead741e6485ee7075b27540135def09a2382284888120c55b817e342a10db7b5`
  - `KittyTools-0.1.2-windows-arm64-setup.exe`  `060fc086c0275fd4386b5b05f2178aa5356eab90d60aaedbe5d48d9f2d05bf9b`
- **更新**：新包 `--update-live=0.1.1` 过（exit 0，下了 32270403 字节、sha256 对得上）。0.1.1 的 x64 zip 解压到临时目录当「已安装的 0.1.1」，探针档 +
  `--update-test` + `KITTY_UPDATE_FEED`（本机假发布列表，`file://` 指这次的 zip）+ `KITTY_UPDATE_APPLY=1`：`update.check newer=True version=0.1.2` →
  `update.installed files=95` → 重开 `update.relaunched version=0.1.2 removed-old=72`，exe 变成 `0.1.2+df0e466`；23 个 `.old` 留到下次（旧进程还在退，第 6 批记过，原来就有）。
  没碰真 GitHub 的发布、没碰 `D:\Apps\Kitty Tools`。

**第二轮（2026-11-04 用户「还有什么需要完善的吗，都完善了再发 0.1.2」）→ 审查方已写（`windows-0.1.x` 到 `0428a27`，没编译）**：
挑的是 0.1.0 起就有、改动小、windows 上已经修好或一眼能修的；0.2.0 的新功能、C5 / C6 这类行为调整不带。
- `7d0b807` 复制截图后提示先黑一块（上面「没修的」那条）：`NoticeHost.ShowCore` 第一次露面不再当场 `ShowWindow`，排到 `DispatcherQueue` 低优先级（空闲时就是下一拍），
  复制后关遮罩、建角落卡那 150–200 ms 做完再露；排着的时候被收了就不露（`_revealed`）。已拣到 windows（`a57a0f7`）。
- `0428a27` 拣两条：R24 的帧时间（`989cd77` 里 `WgcRecorder` 那一行 + `RecordingPipeline.FrameTime` + 单测，探针没带）、第 6 批的录屏尺寸（`b14faa2` 的 `VideoSizeAsync`）；
  0.1.2 更新日志改成 5 条。

**你们做的**：
1. 编译 `windows-0.1.x`：Debug、Release AOT x64 / ARM64 零警告，`dotnet test` 全过（多了 `FrameTimeFollowsTheCaptureClock`）。
2. 提示：同一个探针录复制截图，**App 浅色、深色各一遍**（系统浅色不动），提示那块不该再有黑底、白底；再弹一条空闲时的提示（比如托盘「暂停记录」），出来不该比原来慢。
   要是低优先级排一拍还是黑（UI 线程空下来之前 XAML 已经被排了别的活），改成截图遮罩那套：先 DWM 隐身露出来，等画上第一帧、再过 4 次合成且 ≥ 50 ms 才显形，300 ms 兜底（`SelectionOverlayWindow.SetCloaked`）。
3. 录屏：`--record-test` 录一段带系统声音的，文件能存下、能播；截图历史里这一条的尺寸是视频的（整屏录的不再是 480 × 270）。
4. 重新打包（日期照旧 2026-11-04，过了这天就改成打包那天），`--smoke`、`--update-live=0.1.1`、假发布列表 0.1.1 → 0.1.2 再走一遍。
5. **都过了就发布**（用户已经说了「都完善了再发 0.1.2」）：在 `windows-0.1.x` 最后那个提交上打 tag `windows-v0.1.2`，照 0.1.1 走 REST API——先建草稿、
   传 8 个文件（两个架构的安装包、zip 和各自的 `.sha256`）、说明用 `release-notes.md`，再发布；**不标 latest**、不是预发布。发布后用 0.1.1 的 Release 构建（探针档）
   检查更新要看到 `update.check newer=True version=0.1.2`。哪一步没过就别发，记在这里。结果记在这一节下面；`windows-0.1.x` 照旧别并进 `windows`，审查方并。

**第二轮 Windows 验收（2026-11-04 / 05，`windows-0.1.x` 到 `45a487d`，已发布 `windows-v0.1.2`）**：

- **提示闪：7d0b807 没过，按第 2 条的后备方案改成隐身露面（`45a487d`，已拣到 windows = `fb6e253`）**。探针同第一轮（临时，没提交）：Release AOT，主屏铺静态色块窗口（不激活），
  `ScreenshotSession.StartSynthetic()` 开遮罩（合成冻结帧，不抓桌面），程序里调 `CopySelectionAsync`（ClipboardWriter 用环境变量短路），`KITTY_HUD_CAPTURE=1`，WGC 录整块主屏，
  量提示窗口中间那块每帧的平均色。系统浅色不动，App 外观用设置里的浅色 / 深色。
  - `0428a27`（7d0b807）：复制后提示**深浅两种外观都是一块白（255）约 120–135 ms**，再一帧黑、才是亚克力。同一探针拿 7d0b807 之前的 `Notice.cs` 对照：深色黑约 150 ms、浅色白约 170 ms。
    原因：遮罩关掉后 UI 线程空了一拍，低优先级那一拍就排到了、窗口露出来，之后才建角落卡（又忙 120–170 ms），XAML 这段时间画不上。
  - 改：`ShowCore` 第一次露面先 DWM 隐身再 `ShowWindow`，第一次 `CompositionTarget.Rendering` 之后再过 4 次合成且 ≥ 50 ms 才显形，300 ms 兜底，收起时还藏着就不再等；
    藏着时内容淡到 0，显形后 `Motion.FadeIn`（`Appear` 只有终点关键帧，同一扇窗口第二次露面时从上回的 1 起步，等于不淡入，逐帧录到的）。
  - 改后：浅色、深色各录两遍，每遍复制两次 + 一条空闲提示，另各两遍只弹空闲提示：**每一次第一帧都是空的亚克力（深 44–45、浅 247–249），再淡到 81 / 217，没有 0 / 255 的帧**。
    只等 1 或 2 次合成（不要 50 ms）时，第一次复制仍有一帧 0（深）/ 255（浅），所以照遮罩留 4 次 + 50 ms。
  - **代价（用户批准照发）**：空闲提示（托盘「暂停记录」那条）第一帧从 44–56 ms 变成 98–124 ms；原来那一帧是空白，到正常颜色是 80–100 ms。
  - 只看了 WGC 逐帧录下来的，没请用户用眼睛看。探针退出时进程码 0xC000027B（`app.exit` 之后、`d3d.still-referenced`），7d0b807 之前那版探针也有，是探针自己收尾；正式包 `--smoke` 退出 0。
- **编译**：Debug x64 0 警告，`dotnet test` 482 个全过（含 `FrameTimeFollowsTheCaptureClock`）；`build-release.ps1` 两个架构的 Release AOT 0 警告，x64 解压跑 `--smoke` → `smoke.ok`；
  两个 zip 里的 exe 都是 `0.1.2+45a487d`，运行时 `10.0.14+0427b9a`，内置智谱 key 在（只数了出现次数）。打包是 2026-11-04 打的，日期没改；05 日没重打（重打要改日期、多一个提交，exe 就不是 45a487d 了）。
- **录屏**：正式 x64 包 `--record-test=8`（系统声音开着，测试图案窗口带提示音）：`record.remux ok=True`、`record.saved`，loopback 832 包。文件 8.3 s，H.264 2560 × 1440 30 fps +
  一路 AAC 48 kHz 双声道；用 windows 分支 Debug 的 `--video-frames` 逐帧解码 250 帧，间隔 33.3 ms 全匀、单调。截图历史这一条 `pixel_width × pixel_height` = 2560 × 1440（不是 480 × 270）。
  `--record-test` 录完不退出，用同一探针档 `--quit` 收的（`app.exit-forced` 是 R53 的 2 秒兜底，原来就有）。
- **更新**：新包 `--update-live=0.1.1` 过（32270403 字节，sha256 对得上）。0.1.1 的 x64 zip（sha256 和已发布的一致）解压到临时目录，`--update-test` + 假发布列表（`file://`）+
  `KITTY_UPDATE_APPLY=1`：`update.check newer=True version=0.1.2` → `update.installed files=95` → `update.relaunched version=0.1.2 removed-old=72`，exe 变成 `0.1.2+45a487d`，23 个 `.old` 留到下次（同第一轮）。
- **产物和 sha256**（`kitty-win-012\windows\build\release\0.1.2\`，第一轮那 4 个已被覆盖）：
  - `KittyTools-0.1.2-windows-x64.zip`  `d2e4ea83dce229097bd08444fec111c825ac44a02925c83102e7858731bdb63a`
  - `KittyTools-0.1.2-windows-x64-setup.exe`  `07b19f4ed7223a5a7fdfe5e7da3baeb705d94d8152ed0f7a650c90cca0637e95`
  - `KittyTools-0.1.2-windows-arm64.zip`  `4c2b18d6d7175210a25c8c41e03a3b705ea9edfffe973e8917f23f50a64bdebe`
  - `KittyTools-0.1.2-windows-arm64-setup.exe`  `22c0a80a47331847391ffc2e218a1a0fe80f0260ece00243e23cfa70ac021396`
- **发布（2026-11-05，用户批准）**：tag `windows-v0.1.2` → `45a487d`（只推了这一个 tag），REST API 建草稿、传 8 个文件、说明用 `release-notes.md`、再发布：
  https://github.com/YyAdnBug/kitty-tools/releases/tag/windows-v0.1.2 ，不是预发布、没标 latest（latest 仍是 `macos-v0.7.1`）；从发布页下回来的 x64 zip sha256 对得上。
  0.1.1 的 Release 构建（`0.1.1+557181b`，探针档，真 GitHub）启动后 `update.check newer=True version=0.1.2 localFeed=False`。
- 没碰 `D:\Apps\Kitty Tools`（用户那份一直开着）；`windows-0.1.x` 没并进 `windows`。

### 0.2.0 第 6 批：F4 F7 F8 F9 F10 + 录屏尺寸 → 已写（审查方，`git log --grep "PLAN-v11 第 6 批"`，没编译）

用户 2026-11-03 定：0.2.0 先从第 6 批写（第 5 批 F1–F3 要和 mac 0.8.0 同一份规格，mac 还没开始，往后放）。

- **F4**（mac X7）角落卡「改标注」：`ShotHistory.IdFor(png)`（`ConditionalWeakTable`，RecordAsync 写完、UpdateAnnotations 换成品时记下交给历史的那几份 PNG → 编号）；
  卡片悬停的胶囊里多一个只有图标的「改标注」、右键菜单也有，点了收起卡片、走 `ScreenshotSession.StartEditing`（同历史里双击）。历史关着时没有。
- **F7**（mac X11）更新：
  - 「跳过这个版本」：`Settings.UpdateSkippedVersion`；`UpdateService.OfferedVersion`（没跳过的新版本）换掉托盘、主界面、启动器底栏和内置动作里的 `AvailableVersion`，关于页照样写（「已跳过」）；「有新版本」轻提示多一个按钮。
  - 后台下好、退出时装：`Settings.UpdateInstallOnQuit`（默认开，关于页一个勾选框，自动检查关着时变灰）；`UpdateFlow` 拆成 `PrepareAsync`（下载、校验、解压、比版本）+ `Install`，
    `RunAsync` 行为不变（单测 `PrepareLeavesInstallUntouchedUntilInstall`）；`AutoUpdater.PrepareInBackgroundAsync` 下到 `updates\ready-<版本>`，不弹进度；
    `InstallReadyOnExit` 只在用户自己点「退出」时装（`ShellRuntime.Exit(installUpdate: true)`：托盘、主界面、启动器）——**关机 / 注销、安装程序和卸载的 `--quit`、数据库恢复重开都不装**
    （装到一半被结束会半新半旧；装进马上要被覆盖 / 删掉的目录会留 `*.old`）；装了写 `updates\installed-on-quit.txt`，下次启动 `AutoUpdater.AfterLaunch` 清 `*.old`、提示「已更新到 x」、删掉没装的 `ready-*`。
    下好以后点「更新」直接装上重开；后台下着时点「更新」→ 亮出进度，下完直接装。
- **F8**（mac X12）主界面打字：`_keys.CharacterReceived`，可打印字符（不含空格）→ 收起、还前台，`OverlayHost.SetLauncherQuery` + 打开启动器。
- **F9**（mac X13）托盘角标：`tools/app-icon.swift` 加 `AppIconPaused.ico`（灰底白边两道竖条，和录制红点同一个位置；在 Mac 上生成的，旧的两个图标一字节没变）；
  **录制中的红点 `AppIconRecording.ico` 以前生成了却从没接上**，这次一起接：`Tray.Refresh` 按 录制中 > 暂停记录（剪贴板功能开着时）> 平时 换图标和悬停提示，
  `RecordingHost.Changed` / `AudioHost.Changed` / 暂停开关 / 功能开关时调；两个 .ico 进 csproj 的 Content。
- **F10**（mac X14）关于页「反馈问题」：`Core/FeedbackLink`（只预填版本、架构、系统版本；单测 2 个）。
- 0.1.1 收口查出来的：截图历史里录屏条目记视频本身的宽高（`ShotHistory.VideoSizeAsync`），不再是封面缩略图的 480 × 270。

**你们做的**：
1. 编译、零警告，`dotnet test` 全过（新加 `FeedbackLinkTests` 2 个、`UpdateFlowTests.PrepareLeavesInstallUntouchedUntilInstall`）。
2. 走 HANDTEST 854–870。F7 那几条用 `--update-test` + 本机假发布列表（`KITTY_UPDATE_FEED` 指向一个列着更高版本的 JSON、zip 用 `build-release.ps1` 打的测试包），别碰真 GitHub 和用户的真实安装。
3. 要在屏幕上看的：角落卡三个胶囊在窄卡（168 宽附近）上挤不挤；托盘两个角标在 100% / 150% 下清不清楚；主界面打字转启动器时焦点、前台对不对。
4. 截图：角落卡悬停、关于页（有新版本 / 已下好 / 已跳过）、托盘两个角标（只截自己的图标那一块），推 `windows-shots` 的 `0.2.0-batch-6/`。

**Windows 验收（2026-11-03）**：

- **编译**：Debug x64、Release AOT x64 / ARM64 一次过、零警告；`dotnet test` 486 个全过。审查方这一批的代码没有编译错。
- **F7 更新**（Release AOT 装进临时目录当「已安装的 0.1.1」、探针档 + `--update-test` + `KITTY_UPDATE_FEED` 指本机假发布列表；
  测试包是另开一个临时 worktree 把版本临时改成 0.1.9、跑 `build-release.ps1` 打的，没提交；没碰真 GitHub、没碰 `D:\Apps\Kitty Tools`）：
  - 858 过：启动 12 s 后 `update.check newer=True` → `update.prepare` → `update.ready`（0.4 s），`updates\ready-0.1.9\Kitty Tools\` 是解压好的程序，安装目录的 exe 还是 0.1.1；主界面底栏「更新到 0.1.9」，关于页「0.1.9 已下好，退出时安装」+「现在重新打开」。
  - 859 过：主界面「退出」（UIA Invoke，不发按键）→ `update.installed-on-quit files=97`，exe 变成 0.1.9；再打开 `update.relaunched removed-old=97`，`*.old`、`ready-*`、`installed-on-quit.txt` 都没了。
  - 860 过：下好以后点主界面「更新到 0.1.9」→ 没再下载，`update.installed` 后带 `--updated` 重开（`removed-old=74`：旧进程还在退，有 23 个 `.old` 留到下次，这是原来就有的）。
  - 862 过：下好以后给隐藏窗口发 `WM_ENDSESSION` → `app.end-session`、没有 `installed-on-quit`，exe 还是 0.1.1；下次启动先删 `ready-*`、12 s 后重新下好。
  - 863 前半过：关于页取消勾选（UIA Toggle）→ 设置里 `updateInstallOnQuit: false`，重开后只有 `update.check`、没有 `update.prepare`。装在 `C:\Program Files` 那半没测。
  - 857：**查出一个问题，修了**——后台已经下好时点「跳过这个版本」，关于页照样写「0.1.9 已下好，退出时安装」，可退出时 `InstallReadyOnExit` 不装跳过的版本，字和行为对不上（下好的那一份也一直留着）。改成跳过时 `AutoUpdater.DiscardReady` 删掉 `ready-x`，关于页先看跳过再看下好。修后：「有新版本 0.1.9（已跳过）」+「更新并重新打开」，日志 `update.ready-discarded` → `update.skip`，主界面底栏不再挂；假发布列表换成 0.2.0 → 又挂出「更新到 0.2.0」。
  - 861（后台下着的时候点「更新」/ 托盘「取消」）没测：本机 file:// 的 30 MB 0.4 s 就下完，点不到中间。
  - 每次托盘 / 主界面退出都有 `app.exit-forced`（R53 的兜底，2 秒后结束进程），原来就有，和这一批无关。
- **F9 托盘角标**：三个 .ico 的 16 / 20 / 24 / 32 px 那几张放大拼在浅 / 深任务栏底上看：24 px（150%）暂停的两道竖条和红点都清楚；16 px（100%）红点清楚、暂停竖条只有 1 px 宽、挤但认得出。
  这台机器上新托盘图标收在「^」里，`tray.rect` 指的是那个箭头，**真任务栏上 100% / 150% 的样子没拍到**（要点开「^」，留给用户）；高对比度没看。`--clipboard-paused` 启动时 `Tray.Add` 就按暂停取图标（读代码）。
- **F4 角落卡**：`--ui-snapshots` 的 `shot-card-hover`（约 210 DIP 宽）三个胶囊放得下；量出来带字的两个胶囊加「改标注」圆钮一排约 176 DIP，原来按 168 宽切到只留图标，168–195 宽的卡会挤出去——改成有「改标注」时 196 起才带字。854–856 要真截图、悬停、点，没走。
- **没走的**（要真按键 / 鼠标，留给用户）：854–856、861、864–865（主界面打字转启动器）、866–867 的真托盘、868（单测 `FeedbackLinkTests` 过）、869、870 高对比度。
- **截图**：`windows-shots` 的 `0.2.0-batch-6/`：关于页（有新版本 / 已下好 / 已跳过，假发布列表）、角落卡悬停、托盘三个图标放大对照。

### 0.2.0 第 7 批：F5 F6 F11 F12 C1 C4 + 录屏后的内存 + R24 → Windows 边写边验（2026-11-04）

提交：`c5bf3d9`（F5 F6）、`6e997b5`（F11）、`fd778a4`（F12）、`aff7dc6`（C1）、`3946063`（C4）、`5fa12ae`（AOT 编译器钉 10.0.14）、`989cd77`（录屏内存、R24 时间戳），
再加最后这条（报告、手测、截图自检）。手测 HANDTEST 883–905。截图 `windows-shots` 的 `0.2.0-batch-7/`。

**做了什么**

- **F5 截图带上鼠标指针**（设置 › 截图，`screenshotCursor`，默认关）：按快捷键那一刻 `GetCursorInfo`，BitBlt 完 `DrawIconEx` 画进指针所在那块屏的冻结帧，热点对齐；指针藏着时不画。截图和「截取上次区域」都走它，录屏照旧用自己的「显示光标」。
- **F6 截图、录屏时隐藏桌面图标**（设置 › 截图和录制页同一个 `captureHideDesktopIcons`，默认关）：`Screenshot/DesktopIcons` 把桌面那扇图标列表（Progman / WorkerW → SHELLDLL_DefView → SysListView32 FolderView）`ShowWindow` 藏起来——截冻结帧那一下、录一块区域的整段（录一扇窗口不藏），完了显示回来；不碰资源管理器「显示桌面图标」那个写注册表的设置。按引用计数（录着时截图）。藏之前写标记文件，闪退 / 被结束后下次启动 `RecoverAfterCrash` 显示回来。
- **F11 裁剪**：十种工具之外一个「裁剪」（撤销左边，键 X；截图遮罩里 X 原来没用）。遮罩里开着裁剪时在选区里拖框（框外压暗、粉色虚线），松手选区换成它；从截图历史改标注时选区缩在原图里面（用裁剪或拖边）就回写同一条、原图换成裁过的、`pixel_width/height` 跟着改；长图标注里拖出要留下的一段，原图和标注一起裁，回写历史时原图和宽高跟着换。`Core/ImageCrop`（单测）。
- **F12 录屏选麦克风**（设置 › 录制「录哪个麦克风」，`recordMicrophoneDevice`，默认跟随系统）：WinRT `DeviceInformation` 列设备、Id 换成 WASAPI 端点 Id（`Core/AudioEndpoints`，单测）；录屏时 `GetDevice` + `GetState`，不在就用系统默认的，录制条上橙字「选的麦克风没连着，用的是系统默认的」（图标照常「在录」）。录音不受影响。
- **C1 长图标注**：Ctrl+0 适合宽度 / Ctrl+1 实际大小 / Ctrl+= Ctrl+- 和 Ctrl+滚轮按 `Core/ZoomSteps` 一档一档（单测）、样式弹层多一排选项（同截图遮罩的表）、双击文字重新编辑、拖到窗口上下边自动滚、按住空格拖动平移。文件头那条 ponytail 去掉，MAC-DIFF 跟着改（顺手把主界面那句改成 C2 之后还剩的）。
- **C4 截图样式托盘**：换工具时位置从旧处按 Settle 滑过去（`Motion.SlideFrom`）、宽度从旧宽变到新宽（`Motion.WidthFrom`），色点 / 粗细点选中时 pop（`Motion.PopScale`）；减弱动态效果时直接换。ponytail 去掉。
- **录屏后的内存**：查清了、修了（见下）。
- **R24**：查出录制的时间戳问题、修了；验收照旧没过，原因写在 R24 末尾。
- **顺带**：2026-11-04 `Microsoft.DotNet.ILCompiler 10.0.13` 出了高危公告（GHSA-p3jp-9v83-76w9，NU1903 当错误），AOT 发布和 Debug 还原都失败——csproj 把 SDK 自带清单里的编译器包（一直）和运行时包（只在发布时）改成 10.0.14（`5fa12ae`）。装了带 10.0.14 的 SDK 以后可以删。

**怎么验的、量到的数**（没有发按键；只拍自己的窗口；测试数据都在 Dev / 探针档和临时目录）

- 编译：Debug x64、Release AOT x64 / ARM64 零警告，PRI 齐；`dotnet test` 492 个全过（这一批新加 6 个：`PlanV11Batch7Tests` 5 个、`FrameTimeFollowsTheCaptureClock`）。
- F5（`--capture-probe=cursor`，只写日志、不存屏幕内容）：同一时刻带 / 不带指针各截一次，只比指针附近 ±64 px——只有 12 × 18 的一块变了（120 px，I 形指针），左上角离指针点 (5, 8)，就是 I 形的热点。
- F6（`--capture-probe=icons|icons-crash`）：图标列表 before=True during=False after=True，标记文件放手后删掉；藏着时直接结束进程 → 标记还在 → 再启动 `desktop-icons.recovered`、标记删掉。这台机器桌面被窗口盖着，藏前藏后整屏只变了 32 px——**桌面露出来时看得见的效果要用户看一眼**（HANDTEST 885）。
- F11：`--long-annotate-probe=9000` 1200 × 9000 裁掉头尾各 500 行、左右各 100 列 → 1000 × 8000，标注从 (100, 3896) 挪到 (0, 3396)；`--ui-snapshots` 多一张 `shot-crop`（合成冻结帧上拖着裁剪框）。从历史打开裁完回写同一条没在真屏上走（要真按键）。
- F12（`--record-test`，Dev 档，只录测试图案）：设一个不存在的端点 Id → `audio.mic-device-missing hr=0x80070490` → `audio.mic-open`（默认），录制条 UIA 读到「麦克风：在录」+ 橙字；第一次写的时候录制条把它判成「麦克风：断了」（原来按备注里有没有「麦克风」判断），改了。设置页下拉框（UIA 展开）：跟随系统 + 3 个设备 + 「选过的麦克风（没连着）」。
- C1（`--long-annotate-probe`）：缩放 Ctrl+1 1.000 → 往下两档 0.670 → Ctrl+0 回到适合宽度；重新编辑 texts=1 same-id=True changed=True undo=True；自动滚：指针停在下边 8 DIP，1 秒滚 863 DIP，正画的矩形底边跟到第 2146 行。
- C4（`--toolbar-anim-record`，合成冻结帧，WGC 只录遮罩）：3.9 s / 235 帧逐帧看，矩形 → 文字时托盘约 8 帧（0.13 s）滑到文字下面、宽度跟着变。
- **逐帧解码**（`Recording/VideoFrames`，`--video-frames`）：宽高不是 16 的倍数的录像（2566 × 1446）解码器按补齐后的 2576 × 1456 排行、又不给 IMF2DBuffer，按 width × 4 当行距整帧斜着错开——改成先试 Lock2D、拿不到按「长度 ÷ 补齐到 16 的行数」。
- 空闲 CPU：Release AOT 只有托盘静置 60 s，0 ms。
- 内存探针（全量，Release AOT）：见下面「录屏后的内存」最后一条。

**录屏后的内存**（0.1.0 起「每录一次 +26 MB、两分钟后不回落」）

- 新自检 `--record-memory-probe=<次数>`：自己的小窗口连录 N 次、每次后等 20 s 量专用工作集和托管堆，最后静置 130 s；`KITTY_RECMEM_PART=device|pool` 只建 D3D 设备 / 只抓帧不编码，`KITTY_RECMEM_SOFTWARE` / `_NOREMUX` / `_GC` 换软件编码器、不重封装、每轮后强制 GC。
- 修前（每次 5 s，Release AOT）：完整录 33 → 49 → 73 → 98 → 121 MB，静置不降，托管堆一直 6 MB；只建设备、只抓帧：第一次 +12 MB 之后不涨；软件编码器每次 +9 MB；不重封装照涨；每轮后强制 GC 就封顶（63.8 → 静置 47.4）。每次停下都有 `d3d.still-referenced refs=3`。
- 根因：窗口录制的帧常是奇数尺寸（这次 626 × 353），每帧都走 `WgcScaler` 的 Win2D 缩放，`WgcInterop.SurfaceOf` 包出来的 `IDirect3DSurface` 从不关，每个都拿着纹理和整个 D3D 设备（连驱动里的编码缓存），录完空闲时不 GC 就一直留着。录整屏（偶数尺寸）不走这条路，所以 R27 那时量整屏没看到。
- 修后：连录 4 次 47.5 → 50.2 → 51.2 → 51.8 MB，静置 51.7，不再有 `d3d.still-referenced`。还剩每次约 +1 MB，没再追。
- 全量内存探针（Release AOT，`KITTY_MEMORY_PROBE=1`，新的空探针档）：录屏后静置两分钟 **+4.1 MB**、再录一次 **−0.1 MB**（修前 +26.6 / +25.2）。其余各步：只有托盘 41.9、5000 条剪贴板 44.5、剪贴板面板 / 启动器 / 翻译窗 45.6 / 52.1 / 53.3、截图后 / 第二次 / 五次后 68.9 / 71.9 / 76.5、设置窗开过以后 87.5、静置两分钟 87.7 MB。只有托盘比 0.1.1 的 56.2 低 14 MB：那次的探针档里带着 5000 条剪贴板，这次是新档，不是这一批省出来的。

**替用户定的**

- 裁剪键用 X（C 是取色、截图遮罩里 X 原来没用）；裁剪不进撤销（长图标注里裁完撤销栈清空，截图遮罩里改的是选区、本来就不进撤销），写成 ponytail。
- 从历史打开时「选区缩在原图里面」都算裁剪、回写同一条，不只是用裁剪工具裁的。
- 隐藏桌面图标只管截冻结帧那一下和「录一块区域」，录一扇窗口时不藏；长截图不藏。
- 选的麦克风录到一半拔掉：照旧那一路停掉、「麦克风断开了」，不中途换到默认的。「录哪个麦克风」那一行在「麦克风」关着时不变灰。
- F12 设备列表用 WinRT 的 DeviceInformation（名字和系统声音设置一致），不自己读属性存储。

**没做成 / 没测的**

- R24 验收没过（R24 末尾）。
- 真鼠标 / 键盘的部分都没走：F11 真拖框、从历史打开裁完回写，C1 双击 / 空格 / Ctrl+滚轮，F12 真选一个非默认麦克风、拔插——留给用户（HANDTEST 883–905）。
- 150% 屏上指针的大小、两块屏、高对比度：这台只有一块 100% 的屏，没切高对比度。
- 桌面露出来时藏图标的样子（这台桌面一直被窗口盖着）。

### 0.2.0 第 8 批：C2 C5 C6 C8 → 已写（审查方，`git log --grep "PLAN-v11 第 8 批"`，没编译）

用户 2026-11-03「接着写第 8 批」。方案里这一批带的「收尾」（版本 0.2.0、`changelog.json`、`STATUS.md`）**没做**：第 5 批（等 mac 0.8.0）和第 7 批还没做，0.2.0 的最后一批再收尾。

- **C2** 主界面：选中高亮改成格子底下单独一块、`Motion.SlideTo` 滑过去（Snap；刚排出来时直接落位），格子本身不再改底色；位置算法 `Core/HomeLayout.TileOrigin`（和 `Height`、`Render` 同一套排法，单测 `TileOriginFollowsSectionsAndRows`）。
  开着时订阅 `RecordingHost.Changed` / `AudioHost.Changed`，录制开始停止时重排、焦点留在原来那一格。钉图两格照旧只在打开时排（ponytail 写在文件头）。
- **C5** 划词翻译并替换：固定着的、为了取词收起的浮窗，替换完（成没成都算）不抢焦点地在上次的位置露回来（`TranslateWindow.Reappear`；`TranslateHost` 那一段包进 try / finally）。
- **C6** 录音「没听到声音」只看麦克风那一路：`AudioCaptureSet.MicrophonePeak`（每一路本来就记着开录以来的峰值）经 `AudioRecorder` / `AudioHost.MicrophonePeak` 给到 `AudioHud`，和 −70 dB 换算的振幅比。电平条照旧是两路混在一起的。
- **C8** 拉丁字母的原文：`Langs.Detect` 加一个可选的识别参数（Core 照旧没有 P/Invoke；单测 `LatinScriptAsksTheRecognizer`），翻译时传 `LanguageRecognizer.Recognize`——
  系统自带的 ELS「Microsoft Language Detection」（`elscore.dll`，`MappingGetServices` / `MappingRecognizeText` / `MappingFreePropertyBag`，`LibraryImport`，结构体照 elscore.h 写在文件里）。
  不到 3 个词、认不出、认成 11 种以外的照旧按英语；复制即译的「值不值得翻」那一处不传（只看是不是 null，不用多问一次系统）。

**你们做的**：
1. 编译、零警告，`dotnet test` 全过（新加 `TileOriginFollowsSectionsAndRows`、`LatinScriptAsksTheRecognizer`）。
2. **C8 的结构体要先在真机上验**：`MAPPING_ENUM_OPTIONS`、`MAPPING_PROPERTY_BAG`、`MAPPING_DATA_RANGE` 是照头文件手写的（x64 / ARM64 都是 8 字节对齐，最后两个位域合成一个 uint）。翻一句法语看日志有 `lang.els-ready`、识别出 fr；
   要是 `MappingGetServices` 返回错误或者崩了，先对一遍 `sizeof`（C++ 里 `sizeof(MAPPING_ENUM_OPTIONS)` 应该是 80、`sizeof(MAPPING_PROPERTY_BAG)` 64、`sizeof(MAPPING_DATA_RANGE)` 72），修不好就让 `Recognize` 直接返回 null、记在这里。
3. 走 HANDTEST 871–882；871 的滑动录 3–5 秒短视频（只录主界面），和截图一起推 `windows-shots` 的 `0.2.0-batch-8/`。

**Windows 验收（2026-11-03）**：

- **编译**：同第 6 批，零警告、486 个单测全过。
- **C8 过**（Release AOT 探针档 + Debug，`--translate-text`，不抢焦点）：三个结构体照 elscore.h 对过 sizeof（80 / 64 / 72），`MappingGetServices` 一次成功，日志 `lang.els-ready`，没有 `lang.els-unavailable`、没崩。
  浮窗顶上源语言胶囊（UIA 读的）：「Bonjour tout le monde, comment allez-vous aujourd'hui」→ 法语，「Guten Morgen, wie geht es dir heute」→ 德语，只有「Bonjour」一个词 → 英语（不到 3 个词不问系统）；
  第一语言英语、第二语言法语时法文原文 → 法语译成英语（878）。日志里搜不到原文、译文。
- **C2 过**：加了自检开关 `--home-slide-record=<目录>`（测试档；`HomePanel.ProbeMove` 直接挪选中，不发按键，WGC 只录主界面这扇窗口），又加了逐帧解码 `VideoFrames`（Media Foundation SourceReader，每帧自己的时间戳）和 `--video-frames=<mp4>|<目录>|<每几帧>`（Debug）。
  解出来看：按一下之后约 0.2 s 里高亮在两格之间一帧帧挪过去（871）；`KITTY_REDUCED_MOTION=1` 时一帧就落到下一格（872）。短视频 4.4 s / 174 KB。
- **没走的**：873–874（拨开关、开着主界面时开录）、C5（875–876，要在记事本里选字按快捷键）、C6（877，要麦克风）、879 的朗读、881（没有精简系统）——留给用户。
- **截图**：`windows-shots` 的 `0.2.0-batch-8/`：主界面高亮滑动的短视频、主界面浅 / 深。

### 用户反馈 2026-11-04：长截图自动滚动太快、剪贴板面板跟随鼠标 → 已写（审查方，`git log --grep "自动滚动按实际"`，没编译）

> 长截图控速那半已被 PLAN-v12 第 2 批重做（速度挪到面板上、匀速顺滑地滚），下面「你们做的」第 2、3 条的自动滚动部分照 932 起那一节走；剪贴板位置换成三档。

用户原话：「滚动截图滚动速度过快，添加支持速度控制，或者看看市面上的解决办法」「粘贴板期望翻译的浮窗一样可以跟随鼠标」。

- **长截图的步子**（`Core/ScrollPacer.cs`，单测 `ScrollPacerTests`）：以前每拍固定发一格滚轮（120），一格滚多远各程序不一样，矮选区一格就滚出了画面、之后帧帧对不上、页面照滚长图不长。
  现在照 mac `ScrollCapture.autoScroll`：按上一拍实际拼上的行数算「一个滚轮单位几像素」，下一步只发够滚出选区高度一个比例的量（不到一格的 `mouseData`，高精度滚轮的程序按比例滚）；
  对不上就往回退半步、步子减半，连着 4 次停下；不到一格画面没动（老程序攒满 120 才滚）就加到一格；整格 3 次不动 = 到头，停下。
  比例是新设置 设置 › 截图「长截图自动滚动」慢 / 标准 / 快 = 12% / 25% / 40%（`ScrollCaptureSpeed`，默认 normal；同类产品里 ShareX 给「间隔 / 滚几格」两个旋钮，CleanShot 和 mac 自己控速，这里两者合一）。
- **拼接的重叠不再限 800 行**（`ScrollStitcher.FindOverlap` / `FuzzyOverlap` 在整帧高度内找，同 mac 的 `match`；`MaxOverlap` 常量删了）：不然选区超过约 800 像素高时每步必须滚得多才对得上，「慢」就慢不下来。
  `ScrollCanvas.Probe` 跟着改成「HeadRows（往上滚是 MaxStickyRows）+ 新帧高」，保证要比的那一截是连着的；`Similar` 反对票超过 `samples / 10` 就提前返回（对不上的帧要试上千个位置）。
- **`ScrollingCapture`**：每拍记上一次拼上的那帧的行哈希（`_reference`），和它逐行一样就不拿去拼（整片纯色时随便哪个重叠都对得上，以前会凭空长空白），再用 `ScrollPacer.Classify` 分「长了 / 没动 / 对不上」喂给步子；
  拼的那一拍改成返回 `Tick`（`_work` 的类型跟着变，`Complete` 里取 `.Canvas`）；`SendWheel(delta)` 收滚轮量、负数往回退；叫停时 `StopAutoScroll` 写状态行；按 A 继续时 `_pacer.Reset()`。
- **剪贴板面板位置**（`Settings.ClipboardPanelPosition`，top / pointer，默认 top；设置 › 剪贴板「面板」组「面板位置」）：`OverlayWindow.PositionAtPointer` 在剪贴板 + pointer 时用 `MonitorLayout.NearPointer`（和翻译浮窗同一个），启动器照旧屏幕上方；
  `ApplyHeight` 改高度时夹进这次那块屏的工作区（`_work`），贴着屏幕下沿出现的面板长高时往上挪、不出屏。顺手把 `PositionAtPointer` 那段编码坏掉的注释重写了。
- `MAC-DIFF.md` 截图、剪贴板各加一条（两项都是 mac 没有的）；设置窗搜索词加了「跟随鼠标」「自动滚动」等。

**你们做的**：
1. 编译 Debug x64、Release AOT x64 / ARM64，零警告；`dotnet test` 全过（新加 `ScrollPacerTests` 12 个，其中 `TallSelection_SmallStepStillStitches` 是 1500 行高、每步 180 的拼接；原有的 `ScrollCanvasTests`、`PlanV3Batch6Tests`、`ScrollStitcherStillColumnsTests` 要照旧过——重叠上限去掉、`Probe` 变了）。
   要特别看的编译点：`ScrollingCapture` 里嵌套的 `private readonly record struct Tick` 和 `_timer.Tick += …` 同名（成员访问，应该不冲突；冲突就把记录改名 `Beat`）；`Task.Run` 的 lambda 几个分支都返回 `new Tick(…)`；`SendWheel` 的 `unchecked((uint)(…))`。
2. 拿 `--long-annotate-probe` 那套或者真网页量一下：1440 × 1300 的选区、对不上的帧（随便两张不相干的图）拼一次多久（`FuzzyOverlap` 现在最多试 1300 个位置，有提前返回），超过 200 ms 记在这里。
3. 走 HANDTEST 906–917。909 要改系统的滚轮设置，测完改回。908 的「矮选区」挑一个一格滚很多的程序（设置、资源管理器的详细信息视图）。
4. 截图：设置 › 截图 那一行、设置 › 剪贴板「面板位置」浅 / 深，剪贴板跟随鼠标出现在右下角翻到左上的样子，推 `windows-shots` 的 `0.2.0-feedback-1104/`。

## 深色下的开关和输入框、翻译卡的彗星边框（2026-11-01 用户截图，审查方在 Mac 上写、**没编译**）——已修（75d6f86 + 12397aa）

**现象**：深色下设置窗「搜索设置」的字、开关关着和开着的圆点都是黑的；翻译卡生成中的彗星边框和 mac 不一样（几段台阶）。
用户：「如果做不到 macos 这种效果就按照 windows 的去实现」。

**审查方改的**：
- 根因：`Theme.Brush` 从代码里取 WinUI 自己的主题画刷（`TextFillColor*`、`SystemFillColor*`）。那一份全 App 共用、颜色是 `{ThemeResource}` 绑着的，
  按 App 的主题（跟系统）解，还会把共用的那份改掉（R15 当时就量到 Default 解出浅色）。截图取色：开关描边、搜索框底是深色值，
  关着的圆点和占位字（都接 `TextFillColorSecondaryBrush`）是浅色那套的 #9E000000。现在浅 / 深色时 `Theme.Brush` 只取 `Kitty.*`，
  别的键直接给兜底色；新加 `Theme.PrimaryText()`，`SecondaryText / TertiaryText / Critical / Caution / Success` 的兜底按深浅两档给
  （值同 WinUI），10 处调用点换过去；高对比度照旧取系统的。
- `Styles.xaml` 浅 / 深两套里给死 `ToggleSwitchKnobFill{On,Off}*`、`TextControlForeground*`、`TextControlPlaceholderForeground*`（字面色，值同 WinUI 默认）；
  开着的圆点两套都是白（同 mac；WinUI 深色是黑）。
- 彗星：还是同一条描边上的虚线，改成 16 层嵌套的段（`Core/CometPath.Layers`，叠起来是 mac 那条亮度曲线，单测比过），光头照 mac 的角度匀速换算成描边位置
  （`CometPath.HeadTrack`，64 个关键帧：扁卡片上长边中间慢、绕短边快）；卡片长高时接着当前方向走；减弱动态效果时停住不藏（同 mac）。
  没换成 Windows 的进度条：这一版能做得像 mac，做不像再换（见第 4 条）。

你们做的：
1. 编译 Debug / Release AOT 零警告，`dotnet test` 全过（新的 `CometPathTests` 6 个）。
2. 外观深色 + 系统浅色、外观深色 + 系统深色各开一次设置窗截图（剪贴板页、翻译服务详情），推 `windows-shots` 的 `0.1.0-dark-fix/`；走 HANDTEST 805–807。
3. 录一段 3–5 秒的翻译卡生成中（只录自己的浮窗），走 808–811；`--ui-snapshots` 里有生成中那张的话一起看。
4. 彗星看着还是不对（有缝、台阶、亮度不对、慢的地方不在长边正中）先照 809 调起点；调不好就按用户说的换 Windows 的做法：生成中卡片底边一条
   `ProgressBar IsIndeterminate`（强调色、2 高、贴着圆角里面），删掉 `_comet` 那套，`CometPath` 一起删，提交里写清楚。

**Windows 这边做的（2026-11-01，Claude 在 worktree `kitty-win-rel010`，修的提交 12397aa）**：
- 75d6f86 原样一次编过：Debug x64、Release AOT x64 / ARM64 零警告，`dotnet test` 471 个全过（含 `CometPathTests` 6 个）。
  修完 472 个（加了一条起点的单测），三种构建照旧零警告；Release x64 的 exe 跑过整套 `--ui-snapshots`（149 张，没崩）。
- **深色（805–807）没改代码，过了**。系统是浅色；「系统深色」用新开关 `KITTY_APP_THEME=dark`（自检档里把 App 主题定死）模拟，
  没去改系统设置。设置窗用 WGC 抓真窗口（带毛玻璃底），外观深色时两种系统取色一样：关着的圆点 #D0D0D0、开着的 #FFFFFF（强调色上），
  「搜索设置」占位字 #CFCFCF，输入框的字 #FFFFFF、占位字 #D4D4D4；外观浅色时关着的是深灰点。807 截图里看得到的几处
  （剪贴板底栏键帽、空状态说明、速查表「全局」）深色下清楚；「有新版本」那行、快捷键冲突红字、网页搜索橙字、测试连接绿勾
  自检里没有那几种状态，没看。悬停 / 按下开关、高对比度要鼠标和改系统设置，留给用户。
- **彗星（808–811）在 Windows 上量出来不像 mac，修了，没换进度条**。办法：`WindowShot.RecordRawAsync` 只抓翻译浮窗、60 fps 存原始帧，
  沿描边算每帧光的位置和速度。
  - 修前：光在**长边中间最快**（约 2000 px/s）、短边和角上最慢（约 110 px/s），正好反过来，一圈里还冒出一个半彗星。
    原因不是起点：合成层的 `StrokeDashArray` 是 **DIP**（放一段 30 的虚线量出来 30 px），不是 D2D 那样按描边粗细的倍数；
    代码按粗细 1.5 除了周长，虚线图样一圈只有周长的 2/3。改成直接用周长。
  - 起点也差一点：同一次实测，描边从左边 `(left, top + r)` 起、先走左上圆角再走上边（不是「左上圆角之后」），`PointAt` 照这个顺序重排，加单测。
  - 修后：上、下长边正中约 90–110 px/s，绕左右两头 1300–1500 px/s，慢的位置换算回光头正好是 W/2 和 1.5W + H（长边正中）；
    一圈 2.4 s；亮度沿描边平滑（光头前约 74 px 升到最亮，后面约 150 px 降到 0.35 档，16 层每档差 1/16，1.5 px 粗的线上看不出台阶）。
  - 810：本机假 OpenAI 流式服务 + `--translate-text`（新开关 `KITTY_COMET_RECORD_LIVE` 录浮窗），卡片一行行长高，光接着当前位置走，出完淡掉。
    出完时「整圈闪一下」帧里没看清（静止后 WGC 不再给帧），留给用户看。
  - 811：新开关 `KITTY_REDUCED_MOTION=1` 当作系统关了动画效果。**一翻译 App 就闪退**（0xC000027B）：`SetShimmer` 对从没扫过的骨架条
    `StopAnimation("Translation.X")` 抛 ArgumentException——早就有的，不是 75d6f86 带来的，修了。修完发现光在卡片每长一行时跳一次
    （重排关键帧照样按时间往前挪），改成减弱时不挪，现在停在同一个方向，出完淡掉。
    CPU（Debug，各 10 秒，进程时间）：生成中 16 层 7–10%、1 层 6–7%、6 层（以前的段数）7.3%，减弱动态效果约 6%；等待 3–7%（减弱约 1%）——和以前差不多。
- 截图、修前修后的逐帧拼图和 mp4 在 `windows-shots` 2da802f 的 `0.1.0-dark-fix/`（README 写了每张是什么）。
- **另外发现、没修**：流式出完以后浮窗比生成中矮 20 px，最后一行贴着窗口底边，卡片的下内边距和下边框被裁掉
  （`0.1.0-dark-fix/translate-done-bottom-clipped.png`，7 行译文时出现）。和彗星无关，审查方看是哪边的高度算少了。

## 重发 0.1.0：App 内更新修复（2026-10-30 用户真机报，审查方在 Mac 上写、**没编译**）

**2026-10-30 用户定：删掉已发的 `windows-v0.1.0`、`windows-v0.1.1`（连同 tag，审查方删的），把功能图标和这次的修复一起重新发成 0.1.0**。版本号回到 0.1.0，`changelog.json` 只剩一条 0.1.0（功能图标并进去了）。下面原来写的 0.1.2 都按「重发的 0.1.0」理解。

**现象**：装 0.1.0，有 0.1.1，点「更新并重新打开」→ 显示正在下载 → 按钮又变回「更新并重新打开」，没更新上。
**原因**：`UpdateHttp.SendAsync` 跟随跳转时 `location.ToString()`。GitHub 的资产地址 302 到 `release-assets.githubusercontent.com`，
那个地址的查询串里有 `response-content-disposition=attachment%3B%20filename…`（`.sha256` 那个的签名里还有 `%2B`）；
`Uri.ToString()` 把 `%20` 还原成空格，`EnsureTrusted` 见到空格就当不可信、抛 `update-untrusted-url`，第一跳就失败（日志应该有
`update.untrusted-url`、`update.download failed`）。以前的验证都碰不到：`--update-e2e` 走本地文件，`UpdateFlowTests` 是假传输，
「检查到 0.1.1」只读 API（API 不跳转）。
**审查方改的**：`Core/UpdateTrust.NextHop`（`AbsoluteUri`，转义原样保留）+ 两条单测（用 0.1.1 真跳转地址的形状）；`UpdateHttp` 改用它；
新开关 `--update-live=<版本>`（`App/UpdateLive.cs`，`Program.cs` 接在 `--update-e2e` 后面）：用正常的白名单从真 GitHub 下载那一版的
zip 和 `.sha256` 并校验，不装，报告 `%TEMP%\kitty-update-live\report.txt`；AGENTS「版本和发布」加了「发版前跑一次」。版本号回到 0.1.0（重发）。

你们做的：
1. 编译 Debug / Release AOT 零警告，`dotnet test` 全过（`NextHopKeepsPercentEscapes`、`NextHopResolvesRelativeLocation`）。
2. 先在旧版（之前装的 0.1.0 / 0.1.1）的日志里确认原因：点更新那一下有 `update.untrusted-url`。不是这个的话停下来报告，别发。
3. 打 0.1.0 的包（先删掉旧的 `windows\build\release\0.1.0\`），走 HANDTEST 802（覆盖装）、804（关于页图标）。
   - 顺带修的：设置 › 关于的 128 App 图标很糊（用户截图）——`AppIconImage` 按原尺寸向系统要图标，ico 里没有 128 那档，系统挑 64 放大两倍；
     改成要的像素超过 64 就取 256 那张交给 XAML 缩小（`SettingsWindow.LoadAppIconAsync`）。
4. 都过了照上次的命令发 `windows-v0.1.0`（不标 latest、不标预发布）；发完马上用新包跑 HANDTEST 801（`--update-live=0.1.0`，从刚发的 release 真下载、校验），不 ok 就把这次的 release 删掉、停下来报告。

**Windows 这边做的（2026-11-01，Claude 在新 worktree `kitty-win-rel010`）**：
- 原因确认：用户的 `%LOCALAPPDATA%\KittyTools\logs\kitty-20261030.log` 15:44:51–15:53:35 点了 8 次更新，每次都是
  `update.untrusted-url` → `update.download failed InvalidOperationException: update-untrusted-url`。
- **关于页图标的修复没生效**（34e37df）：9c66556 还是走 `ShellIcons.LoadPng`，而 exe 的 `SHGetFileInfo(SHGFI_ICONLOCATION)` 回来的文件名是空的，
  `LoadFromIconLocation` 返回 null、退回 32 px 的大图标再放大——Release 的 `--ui-snapshots` 里关于页的图标是 32 放大四倍。改成
  `ShellIcons.LoadPngFromIconFile` 直接对 exe 调 `SHDefExtractIcon`（要 256 回来就是 256×256）；启动器 / 剪贴板照旧走 `LoadPng`。
  启动器里 exe 的图标大概也是这样（32 那张缩放），发版前没动，留着。
- Debug x64、Release AOT x64 / ARM64 零警告；`dotnet test` 465 个全过（含两条 NextHop）；Release x64 跑过 `--ui-snapshots`（145 张，关于页浅 / 深都清楚）；
  setup-e2e 18 项全过；内置智谱 key 在两个 exe 里。
- HANDTEST 801：发完用新包 x64 的 exe 跑 `--update-live=0.1.0` → 退出码 0，`version=0.1.0 testMode=False ok=True 下载 32219713 字节，sha256 对得上`。
  802：x64 setup `/SILENT /DIR="D:\Apps\Kitty Tools"` 覆盖了真实安装（原来登记 0.1.1、exe 是 0.1.0+4b90ed6）→ exe 0.1.0+34e37df、登记 0.1.0，
  重新打开正常（日志 app.start → shell.ready）。关于页只写「版本 0.1.0」，提交号只在 exe 的文件属性里。真窗口里的关于页留给用户看。
  804：只有一块 100% 的屏，100% 下关于页看过（截图），150% / 200% 没测；欢迎引导第一屏的 64 图标走同一条路，没单独截图。
- 发布：`windows-v0.1.0` 指 34e37df，不是 latest（latest 仍是 macos-v0.7.0）、不是预发布，8 个文件。上传中途 x64 zip 断了一次（草稿状态，续传后才发布）。

## 0.1.1 功能图标（PLAN-v10 §6，2026-10-30 用户「现在换」，审查方在 Mac 上写、**没编译**；已并进重发的 0.1.0）

审查方做的：`icons/` 从 macos 拣过来；`Shell/FeatureIcons.cs` 是 Mac 上 `swift icons/build-icons.swift windows` 生成的（26 个，别手改）；
`Ui/KindTile.cs` 认出 `"F1 "` 开头的就用 `XamlReader.Load` 解析成 `Path`，放进 24 × 24 的 `Viewbox`、占色块的 0.6；调用的地方
（`SettingsWindow` 的 `Pages` / `FeatureTile` / 麦克风权限行 / `HotKeyGlyph`、`SettingsUi.Header`、`ShortcutsSheet` 左栏和组头、
`LauncherActions.GlyphOf`、`KindTile.GlyphOf` 的 Clip / Translate / fy）换成 `FeatureIcons.*`；版本 0.1.1，`changelog.json` 加一条。

你们做的：
1. 编译 Debug x64 和 Release AOT，**零 trim / AOT 警告**（`XamlReader.Load` 这一路要实测；真不行就在 `KindTile` 里自己把 `M L C Q Z` 解析成 `PathGeometry`，生成的数据只有这五种命令、都是绝对坐标）；`dotnet test` 全过。
2. `--ui-snapshots`，把设置侧栏、快捷键页、速查表、主界面、启动器内置动作各截一张浅色、一张深色，推到 `windows-shots` 的 `0.1.1-icons/`；和 mac 0.7.0 同一处对着看。
3. 走 `HANDTEST.md` 794–800。
4. 图标看着不对（偏、糊、太大太小、哪处还是旧字形）直接改 `KindTile` 或调用处，提交写清楚；图形本身要改的告诉审查方（改 `icons/feature/` 再两边各自生成）。
5. 都过了再照 0.1.0 那次的命令打 0.1.1 的包、发 `windows-v0.1.1`（不标 latest、不标预发布）。

**Windows 这边做的（2026-10-30，Claude 在 worktree `kitty-win-claude`）**：
- **`XamlReader.Load` 在 AOT 里崩**（4592f65）：AOT 编译零警告，但 Release 的 exe 一启动建设置窗就 `InvalidCastException`
  （`KindTile.Symbol`，crash 日志 stage=xaml）——Load 拿回来的对象转不成 `Path`。照第 1 条的后路改成自己解析：
  `Core/PathData.cs`（F0/F1、M L Q C Z、绝对坐标，别的命令报错），`KindTile` 拼成 `PathGeometry`；测试项目链接
  `FeatureIcons.cs`，26 个都能解析、坐标都在 24 格里。改完 Release x64 / ARM64 零警告，`dotnet test` 463 个全过，
  Release x64 跑 `--ui-snapshots` 不再崩。**以后加 `XamlReader` 一类的东西，得跑一次 Release 的 exe 才算验过。**
- `--ui-snapshots` 加了启动器 `launcher-icons-*`、`home-light/dark`、`shortcuts-sheet`（速查表左栏 + 截图那一类）、
  `settings-about`、`icons-scale`（aabd713）。Release 出的 11 张在 `windows-shots` 的 `0.1.1-icons/`（580325c）。
- 和 mac 对照：这台机器上没有 mac，对的是代码——`HotKeyGlyph` / 侧栏 `Pages` / `LauncherActions.GlyphOf` 和 mac 的
  `HotKeyAction.symbol`、`SettingsTab.symbol` 一一对得上；剩下还用 Segoe 字形的都是 HANDTEST 写了「照旧」的
  （暂停记录、复制即译、钉图开关、设置、速查表、关于、退出、截图 · 标注 / 出图 / 长截图 / 翻译 · 历史的组头、工具栏和菜单）。
- HANDTEST 794–800：
  - 794 侧栏和页头：浅 / 深看过（截图），每行都是新图标、没有空的，关于那行是 App 图标。**关于页在 Windows 上没有页头**
    （`BuildAbout` 是品牌页：128 的 App 图标 + 字标），所以「页头 32 的色块是猫头」这一句不适用，`FeatureIcons.About`
    目前在 Windows 上没有地方画出来——要不要在哪里用猫头，审查方定。高对比度没看（要改系统设置）。
  - 795 功能开关和麦克风权限行：看过（settings-general 截图），和侧栏同一个图，麦克风行是麦克风。
  - 796 快捷键页、797 速查表（左栏五类 + 截图那一类的组头；剪贴板组头）、798 主界面、799 启动器搜「截图」「剪贴板」
    「录」「主界面」「fy」：都看过截图，符合；799 选中行时底栏左边小色块是种类（命令）的 Segoe 字形，没变。
    启动器那几项是自检里直接塞查询，没在真启动器上打字（不在桌面上合成按键）。
  - 800 清晰和缩放：这台机器只有一块 100% 的屏，**150% / 200% 没在真屏上看**（改显示缩放是系统设置，我不动）；
    用 `icons-scale`（放大变换，矢量照样按最终尺寸栅格化）看了 1、1.5、2 倍：边缘干净、在色块里居中。
    「打开设置窗、速查表不比以前慢」没量；解析结果按字符串缓存，每个色块只新建一份几十段的 PathGeometry。
- 图形本身没发现要改的。
- **打包和发布**（1727146）：`build-release.ps1` 零警告，智谱默认 key 在两个 exe 里；`setup-e2e` 18 项全过。
  x64 setup.exe `/SILENT /DIR="D:\Apps\Kitty Tools"` 覆盖了真装的 0.1.0（exe 12:56:58 → 15:32:04，版本 0.1.1+1727146），
  重新打开没崩，第二次启动弹出的主界面是新图标。`windows-v0.1.1` 发了（tag 指 1727146，不是 latest、不是预发布，8 个文件；
  这台机器没有 gh，照 0.1.0 用凭据管理器的 token 走 REST API）。latest 还是 `macos-v0.7.0`。
  0.1.0 的构建拷一份用探针档开着，12 秒后 `update.check newer=True version=0.1.1`。
  - x64：zip 32,214,408 B `40c585c6cbb289a09e9be611c08053b7273059e005b3990d72dac2a56185bc91`；
    setup 23,635,890 B `ac911dd55396e7a2ac3178db2aab0693d84e55f02fb727d0f87982f9d960edc3`
  - arm64：zip 31,297,762 B `427de8613e8cd1b55f473f88c77a2dc4db3b2cf928d43a96ca82d8454d17250d`；
    setup 23,299,535 B `2ea714679f8c444788f77e0e580f6ac0e38d929c57a5ed3b9ebb479dfa3622d5`

## 0.1.0 收口（PLAN-v10，2026-10-29 用户「全部按推荐」）

剪贴板、翻译、启动器、截图、录屏 / 录音都对齐 mac 了，**先把 0.1.0 收口发出去**（PLAN-v10 D1），这期间不加新功能（D3）。
审查方已经先改了（`git log --grep "0.1.0 收口"`，没编译）：启动器、录屏默认开（D2：`Shell/Feature.cs` 去掉 `DefaultOn`，欢迎页的快捷键说明跟着改）；`changelog.json` 的 0.1.0 条目按现在的功能重写。

**你们做**（照顺序，每一步卡住先在下面记一句）：
1. `git fetch && git rebase origin/windows`（2026-10-30 起 windows-wip 改名 windows），编译、`dotnet test`、`--ui-snapshots`，编译错直接修（记一句）。
2. 走 `HANDTEST.md` 开头的发版冒烟清单 18 步（数据目录用 `.Dev` 那一套的空目录）。**第 4 步启动器、第 12–14 步录屏 / 录音这次要走**：这两样哪个过不了，就只把它在 `Feature.IsOn` 里改回默认关（D2），在下面写原因。
3. 走 PLAN-v10 §2 第 3 步的优先手测（剪贴板 6b / 6d / 6f、翻译 8a / 8c / 8d、启动器 7a–7d 挑、截图标注 5a–5e 挑、识字放大 625–627、闪白和边框 663–666 / 675、录屏录音 629–642 / 669–674、设置 652 / 656–658），外加亲眼看一次轻提示还看得见（`054022bd` 起设了 `WDA_EXCLUDEFROMCAPTURE`，这台机器上设了它的分层窗口不显示，见 `2136e58b`；轻提示不是分层窗口、按理没事）。识字放大（625–627）请拿同一块区域截一张放大前（`054022bd` 之前的包）和放大后的对比，结果记下来，D6 看它决定要不要做本地 PaddleOCR。
4. 问题记在下面「收口问题」：现象、怎么复现、日志里相关的几行（不贴剪贴板内容、原文、译文）、你们判断的 P0 / P1 / P2。窗口、合成、抓屏、输入钩子这类在屏幕上才看得出来的，你们直接修（D5），提交正文写清楚；其余的审查方按条修。
5. P0 / P1 都修完后：`build-release.ps1` 出 x64 / ARM64 的 zip、setup.exe 和 `.sha256`，跑 `setup-e2e.ps1`，报告写产物路径。**不发布**：发不发由用户定，发布时一律 `--latest=false`。

**审查方 10-29 另做的**（用户要求，没编译）：
- 设置各页的布局对齐 mac（侧栏顺序、搜索设置、组说明写在组下面、功能页「启用 X」+ 关着变灰、快捷键页分组和录制框、关于页品牌页……），手测 HANDTEST 676–691，不一样的地方和原因写在新文件 `MAC-DIFF.md`。编译错你们直接修。
- **2026-10-30 改了**：2026-10-30 用户：「windows 现在所有的功能都叫 0.1.0，之前说的 0.2.0 没有」——windows-next 上做完的第 0–6 批、收尾、主界面都并进 `windows`，跟 0.1.0 一起发，发完删掉 windows-next；版本号和 `changelog.json` 收回 0.1.0。所以收口要对着合并后的代码重来一遍：第 1 步编译 / 单测 / `--ui-snapshots`（编译错直接修）→ 按 `HANDTEST.md` 692–793 把并进来的那几批在屏幕上验 → 下面「windows-next 里留给你们的」那几样 → 第 5 步打包。
- （10-29 原来的安排）用户同时要「继续实现没做的功能」：定的是**新功能在 `windows-next` 分支上做**（PLAN-v10 §3 的 0.2.0 各批），windows（原名 windows-wip）照旧只收口；0.1.0 打完包再把 windows-next 并回来。你们收口期间不用管 windows-next。

**windows-next（原「0.2.0」，2026-10-30 已并进 windows、算进 0.1.0）里留给你们的**（D5：窗口、合成、抓屏、输入钩子这类；现在就做、做完再打包，审查方写好的那一半在各批的提交里）。
2026-10-29 用户又说这一半也由审查方先写：下面标了「已写」的是审查方写好、没编译的，你们编译、在屏幕上验、有问题直接改；没标的还没写。
- 第 0 批 R43 → 已写（只 BitBlt 选区、找重叠在线程池，HANDTEST 742–748）：长截图只抓选区那块屏（现在每拍 `ScreenCapture.CaptureAll()`），找重叠挪进线程池。拼接已经改成 `ScrollCanvas`。
- 第 2 批 S7 → 已写（`ShotFlash`）：「截完图放哪」选「都不要」时右下角闪一下（mac：一块小的白光淡出），现在什么都不出（`Screenshot/ShotFeedback.cs` 的 ponytail）。
- 第 2 批 S9 → 已写（`ScreenshotCard` 改成一叠，见 HANDTEST 733–741）：角落缩略图最多叠三张、双击打开、存过以后「在资源管理器中显示」、右键菜单（含「在历史里看」）（`Screenshot/ScreenshotCard.cs`）。
- 第 4 批（录制）：R1 R6 R7 R12 → 已写（HANDTEST 733–741）；R5 → 已写（HANDTEST 742–748）。原文：R1 录完的角落卡（和截图的角落卡同一叠）、R5 清晰度（标准 = 长边封顶 1920，Settings 和设置页一起加）、
  R6 倒数挪到录制条上（`RecordingCountdown` 现在按「开始前倒数」0 / 3 / 5 秒出轻提示，审查方写了）、R7 录制条上的声音状态图标、
  R12 角落卡设 `WDA_EXCLUDEFROMCAPTURE`（这台机器上设了它的分层窗口不显示，角落卡是 WinUI 窗口、按理没事，要亲眼看）；
  R3「显示光标」审查方只接了 WGC 那条（`IsCursorCaptureEnabled`），GDI 那条如果还在用，看一下光标是不是本来就没录。
  R10 待录控制条上的来源开关审查方写了（`AudioHud`），宽度 400 放不放得下要看一眼。
- 第 6 批 S11 S12 → 已写（HANDTEST 751–764）：S11 选区旁边一块预览面板 `ScrollPreviewPanel`（直接从 `ScrollCanvas` 的条带取样，
  只在没有正在拼的那一拍时取；滚轮往回看、指示条、双击回到最新，纯函数在 Core 的 `ScrollPreview`）；S12 `LongAnnotateWindow`
  （`CanvasVirtualControl` + 4096 行一条的位图，出图也一条条画；标注模型 / 画法 / 命中 / 手柄全用截图遮罩那套，
  `AnnotationRenderer.Draw` 加了 `frozenAt` 给荧光笔垫当前那条）。入口：历史里「改标注」放不进屏幕的、长截图面板的「标注」。
  要你们特别看：CanvasVirtualControl 放在 ScrollViewer 里滚动时有没有空白块；30000 行的出图耗时和显存；面板贴在选区里时
  （选区差不多整屏）拍出来的帧里有没有面板（设了「不进录屏」）。
- 第 0b 批 主界面（托盘左键，PLAN-v10 §5；规格在 windows-wip 的 PLAN-v10 a1fc4519）→ 已写（HANDTEST 765–779）：`Shell/HomePanel.cs` + Core 的 `HomeLayout`（分节、
  折行、高、选中移动、任务栏在哪条边、贴着托盘摆在哪，`HomeLayoutTests`）。D3 原本窗口 / 托盘 / 焦点归你们边写边验，用户让审查方先写了。
  要你们特别看：点托盘时前台变成任务栏，「划词翻译」靠 `RunningProcesses.TopAppWindow()` 找回原来的窗口，在记事本里实测一次；再点托盘收起靠
  收起后 300 ms 内的 NIN_SELECT 不开，按住鼠标久一点会不会又打开；`Shell_NotifyIconGetRect` 在图标收进「^」时给的矩形；
  格子用 ToggleButton / Button 换了模板资源，深色 / 高对比度下悬停和按下的底色对不对。
- 截图历史的多选、快捷键、拖出去（mac 1ec2ca9a / 933c1dd9 / 0de6c18b / 605f41c8，PLAN-v9 之后 mac 新加的）→ 已写（HANDTEST 780–790）：
  分组是好几个 GridView，系统多选跨不了组，改成 SelectionMode None + ItemClick、选中自己管（Core 的 `ShotHistoryRules.Click / Span / Moved / Summary`，
  `ShotHistorySelectionTests`）。要你们看：PreviewKeyDown 先拿方向键以后 GridView 自己的焦点框跟不跟；拖好几张到资源管理器 / 微信；
  `SHOpenFolderAndSelectItems` 一次选中好几个文件。
- **Windows 编译记录（2026-10-29，Claude 在 worktree 里，e7e8b85）**：三处编不过，修在 59e10ad，别的一次编过。
  `HomePanel.OnActivated` 的 `WindowActivatedEventArgs` 和文件里 `using Windows.UI.Core` 的同名类型撞了（CS0104），写全 `Microsoft.UI.Xaml.`；
  `HandleForProbe`、`ShowSelf` 里 `(IntPtr)hwnd.Value` 要 unsafe（CS0214），整个类标 unsafe 又让里面的 await 编不过（CS4004），
  改成一个 `private static unsafe IntPtr Pointer(HWND)`；`PlanV4Tests.FrameRateIsThirtyOrSixty` 的 `Assert.AreEqual(30, DefaultFps)`
  被分析器当成恒真（MSTEST0032，测试项目里是错误），断言留着、那一行用 pragma 关掉分析器。修完 Debug x64 0 警告 0 错误，459 个单测全过。
- 长截图接不上移动端网页（mac 0ff55dd7）→ 已写（HANDTEST 791–793）：容差比较只比在动的列、只让有字的行投票（`ScrollStitcher.FuzzyOverlap`），
  `ScrollStitcherStillColumnsTests` 两个场景在旧算法上都失败（Python 移植比过：侧栏一帧接不上、移动端接成 191 行），新算法 130。整行哈希那条路没动。
- 0.2.0 最后一批的收尾 → 已写；2026-10-30 版本号和 `changelog.json` 收回 0.1.0（两条合成一条，23 项）：`build-release.ps1` 要你们在 Windows 上跑，产物路径写进 STATUS §6。
- 第 3 批 S10 → 已写（右键「透明度 N%…」和悬停的透明度钮都打开一个带滑块的小浮层）：钉图透明度 10–100% 的滑块（mac 在右键菜单里；WinUI 的 MenuFlyout 放不了滑块，可以换成 Flyout 或右键菜单里一项打开小浮层，你们看着定）。右键的「存储」「翻译」、托盘 / 启动器的「隐藏 / 关闭全部钉图」审查方写了。

**收口问题**（你们往下加，审查方修完在条目后面写提交号）：

- （没有 P0 / P1。下面「合并后重新收口」里记的都是 P2 或观察）
- P2：「录制条、长截图预览不显示」（用户报的）多半是看屏幕的方式：用户经网易 UU 远程看这台电脑，设了 `WDA_EXCLUDEFROMCAPTURE` 的窗口（录制条 RecordingHud、预览面板、角落卡、轻提示）远程画面里本来就抓不到；带 `KITTY_HUD_CAPTURE=1` 关掉这个标记时三样都抓得到、位置和内容都对。还没跟用户确认（坐在电脑前直接看一次就知道），代码没改。
- P2：录屏 60 fps 档录测试图案窗口，文件属性是 57.32 帧/秒（30 档是 30.00）；WGC 的帧不是每 1/60 s 都来，平均略低，没查。

**合并后重新收口（2026-10-30，Claude 在 worktree `kitty-win-claude`，本地分支 `windows` 跟踪 origin/windows，代码 addc854 起）**：
- 编译：Debug x64 `--no-incremental` 0 警告 0 错误，合并后的代码没有编译错（59e10ad 修过的三处之外）。`dotnet test windows\KittyTools.slnx`：459 个全过。
- `--ui-snapshots`：128 张、日志没有失败，推到 windows-shots `0.1.0-merge/`（b8154b0）。新的几张看过：主界面 home、录制条带声音图标、待录条（400 宽放得下来源两个图标和「开始」「关闭」，100%）、角落卡、截图历史、通用页的备份三行。
- 加了 Debug 自检 `--long-annotate-probe=`（9482dae），屏上跑：
  - 751 / 752 预览面板：喂四拍往下滚的帧，面板里的预览跟着长、「800 × 600 → 950 → 1300 → 1800」，「放弃」「标注」「完成」都在。**走了一半**（往上滚、753 往回看、754 自动滚动暂停没测）。
  - 742「都不要」闪一下：白色圆角块出在右下角、抓得到（不设不进录屏）。**走了一半**（没走真截图那条路、减弱动画没测）。
  - 759 / 763 长图标注：1200 × 30000 打开、滚到接缝和滚到底都没有空白块；跨 4096 行的矩形、荧光笔、马赛克画面和出图里都连着（马赛克 10 px 一块，接缝两边对齐）；出图 598 ms，进程峰值工作集约 1 GB（含自检自己造的两份 144 MB 原图）。GPU 内存没看。
- 录屏（测试图案窗口，Debug，数据目录 `.Dev.rec1030a`、保存到临时目录）：
  - 746 整屏 2560 × 1440 选「标准」→ 1920 × 1080、30.00 fps，录完角落出视频封面卡，封面是整屏、不是只有左上角。
  - 748 录 2560 宽的窗口选「标准」→ 1920 × 1080。
  - 697 60 fps → 57.32 帧/秒（见上面 P2）；30 fps → 30.00。
  - 738 录完的卡出来了（封面）；拷贝 / 拖出 / 右键没测。
- 692 同步静置：开着同步（临时文件夹）跑 4 分半，`sync.round` 只在头两轮（第二轮 written=0），之后每 20 秒都跳过、不写；这段时间进程 CPU 合计 234 ms。改之前的对比没量。
- **没测**（要按键 / 点鼠标 / 拖窗口 / 真网页 / 换系统设置，这台机器上不用合成按键，留给用户）：693–696、698–741 里除上面几条外的全部（含 733 倒数在录制条上、734 拔麦克风、735–737 角落卡叠三张和右键、740 角落卡肉眼可见）、743 钉图透明度滑块、744 / 745 真长截图、747、749–750 挤压弹开、753–758、760–762、764、765–779 主界面（托盘点击、划词翻译找回前台、再点收起、溢出区矩形、键盘、高对比度）、780–790 截图历史多选和拖出去、791–793 移动端网页长截图。
- 打包（4b90ed6 之后重打的那份）：`build-release.ps1`（Windows PowerShell 5.1 + vswhere 进 PATH）0 个裁剪 / AOT 警告；两个 exe 里都有内置智谱 key。
  x64 zip 32,145,501 B（`144ef100…`）、setup 23,593,287 B（`5af0ce67…`）；arm64 zip 31,228,984 B（`1c0ed7c0…`）、setup 23,257,966 B（`4e4cac35…`）；四个 `.sha256` 都对得上。
- setup-e2e：第一次跑卡在第 1 步——静默装到 `C:\Windows\Kitty Tools` 时安装程序弹了错误框停住（`NextButtonClick` 里的 `MsgBox` 不认 `/SUPPRESSMSGBOXES`），**4b90ed6** 改成 `SuppressibleMsgBox`；改完五步 18 项全过，重打的最终包又跑一次也是 18 项全过。
- 真装：x64 setup.exe `/SILENT /DIR="D:\Apps\Kitty Tools"` 覆盖用户的 Inno 安装（原来是 11:37 的包，不是旧安装程序，没先卸），退出码 0，安装程序让开着的旧进程自己退了；exe 时间 12:56:58、登记 0.1.0。打开后日志 app.start → tray.added → overlay.prewarmed、没有 hotkey.failed，托盘图标在。按键的功能没在真装上试。
- REVIEW「留给你们的」：R43（只抓选区、后台拼）只验了拼接和面板，真滚动没测；S7 白块看得见；S9 角落卡一叠没测；R1 卡出来了；R5 清晰度过；R6 / R7 只看了截图里的录制条；R12 没肉眼看（远程画面看不到，见上）；R3 GDI 光标没看；R10 宽度 100% 放得下、150% 没看；S11 / S12 见上；主界面、截图历史多选没测；S10 滑块没测。

**第 1、5 步记录（2026-10-29，Claude 在 worktree `kitty-win-claude` 里，代码 1e12834）**：
- 编译：rebase 到 1e12834（含 2ad8b45 收口、1e12834 设置布局），Debug x64 `--no-incremental` 0 警告 0 错误，没有要修的编译错。`dotnet test`：424 个全过。
- 打包：`build-release.ps1` 出了 x64 / ARM64 的 zip、setup.exe 和 `.sha256`，0 个裁剪 / AOT 警告，两个发布目录都有 `KittyTools.pri` 和 `Microsoft.UI.Xaml.Controls.pri`，两个 exe 里都有内置智谱 key。x64 zip 30.4 MB（`2a6ad24b…`）、安装包 22.3 MB（`bc63868a…`）；ARM64 zip 29.5 MB（`b5c891d5…`）、安装包 22 MB（`7d6fb4eb…`）。
- `setup-e2e.ps1 -Zip …x64.zip`：五步 18 项全过、退出码 0（测试名 e2e983032，回收站里多一个 `KittyTools.Probe.e2e983032`，可以清掉）。
- 两处环境上的事（不是代码问题）：这台机器没有 `pwsh`，两个脚本都用 Windows PowerShell 5.1 跑的（`powershell -ExecutionPolicy Bypass -File …`，脚本带 BOM，能跑，e2e 的输出在 5.1 的控制台里中文乱码、结果不受影响）；内置 key 的 `windows/Secrets.props` 只在主 checkout 里，在别的 worktree 打包要先拷过去，不然包里没有默认 key（10-29 上午用户发现过一次）。
- 没做：第 2–4 步的冒烟清单和手测（要按键、看屏幕，留给用户）。

## v9 翻译分工（2026-10-28，用户：「全部按推荐」，PLAN-v9-translate D1–D3 按推荐）

翻译对齐 mac（`PLAN-v9-translate.md`）由 **审查方（Claude）在 Mac 上写、不编译**，8a–8e 一次写完、一起推。你们负责编译、单测、`--ui-snapshots`、手测（HANDTEST 581–620）；编译错直接修，在这一节下面记一句。

**归审查方的文件**（这一轮别的 agent 先别改；真要改先在这里写一句再动）：`KittyTools/Translate/**`、`Settings/SettingsWindow.Translate.cs`、`Shell/Speech.cs`、`Storage/TranslationHistory.cs`、`Core/{TranslateSession,HistoryListLayout,InlineMarkdown,HistoryExport,WordLookup,AiEndpoint,ServiceBadge}.cs` 和它们的测试。

- **新文件**：`Translate/{TranslateCardView,TranslateHistoryView,HistoryMenu}.cs`、`Settings/SettingsWindow.Translate.cs`（翻译页整个从 SettingsWindow.cs 挪过来，`SettingsWindow` 改成 partial）、`Shell/SystemSound.cs`、`Core/{TranslateSession,HistoryListLayout,InlineMarkdown}.cs`，测试 `TranslateSessionTests`、`HistoryListLayoutTests`、`InlineMarkdownTests`。`CardState` 挪进 Core（`KittyTools.Core.CardState`）。
- **重写的**：`TranslateWindow.cs`（整份）、`TranslateCoordinator.cs`（整份）、`TranslateHost.cs`（整份：`ShowTextNear` 没了，截图翻译走 `ShowRecognized`；新 `TranslateAndReplace`）、`HistoryExport`（输出照 mac 变了，`HistoryExportTests` 的期望值跟着换成 mac 的那一组）、`Speech`（`Toggle` / `Speaking`，事件只挂一次、回 UI 线程发）。
- **动了别人的文件**（都是加东西）：`App/HotKeyDefaults.cs`（`translateReplace` 加在表末尾）、`Shell/Feature.cs`、`Shell/ShellRuntime.cs`（热键分发、`ShowSettings` 多一个 `service` 参数）、`Shell/Glyphs.cs`（Swap、Key、VolumeOn、ClearInput、Pinned、ReplaceBack）、`Shell/Ui/SearchLine.cs`（`MakePlain` 抽出来给原文框、历史搜索框用）、`Screenshot/ScreenshotSession.cs`（截图翻译那几行）、`Settings/ShortcutsSheet.cs`（翻译两组）、`Settings/SettingsWindow.cs`（`ShowPage` 的 service 参数改成进详情子页、左栏换页时收起子页、删了翻译页和旧的导出对话框）、`App/Settings.cs`（四个新字段、默认宽 420、删 `TranslateReplaceHotKeySeen`）。
- **编译时留意**：`TranslateWindow` 用 `UIElement.PreviewKeyDownEvent` 在根上统一接键；卡片的彗星边框是 `ElementCompositionPreview.SetElementChildVisual` 挂的 `ContainerVisual`（两个 `ShapeVisual`）、画刷转的是 `CompositionLinearGradientBrush.RotationAngleInDegrees`；正文是 `RichTextBlock`（Markdown 用 Run / Hyperlink 拼）；历史列表是 Canvas + 前缀和；服务详情的模型框是 `AutoSuggestBox`；`TranslateHttp.GetTextAsync` 是新的 GET。
- **要截的图**（`--ui-snapshots` 现在只截了输入翻译空着的那一张）：浅 / 深各一张——空状态（三个入口的快捷键）、两张卡生成中（彗星边框 + 骨架）、一张完成一张配置错误、截断、历史（分组 + 选中 + 收藏星标）、历史 Ctrl+K 菜单、设置 › 翻译（字号预览卡）、服务详情（AI，模型下拉）。
- **Windows 编译记录（2026-10-28，Claude 在 worktree 里）**：
  - `Translate/TranslateWindow.cs`：CS4004「无法在不安全的上下文中等待」——类声明是 `unsafe partial class`，新加的 `ExportAsync` 里的 `await` 因此不让编。去掉类上的 `unsafe`，只给用指针的 `ApplyNoActivateStyle` / `RemoveNoActivateStyle` 两个方法标 `unsafe`。这一处修完 Debug 0 警告 0 错误（XAML 那几个 WMC0001 是它连带的），别的都一次编过。
  - **跑起来修的**（动了归审查方的 `TranslateCardView.cs` / `TranslateWindow.cs`，各一个提交，正文有量法）：彗星边框改成沿描边走的几段虚线（原来画刷绕卡片左上角转，一半时间整圈没光，`999f32b`）；长结果出来时底部渐隐不出（`8fac8e1`）；深色渐隐比卡底暗一截（`42f7c45`，还是近似，真要一致得上遮罩）；出字时每段都重建四个按钮（Release 两张卡同时出字 CPU 40–126% → 12–63%、工作集 +100 MB → +19 MB，`3a02df2`）；固定着的浮窗在不激活的入口（复制即译、剪贴板 Ctrl+T）点外面照样收起（8a 之前就有，`06fdab6`）。另外 `15493ed`：发布包里没有 `Resources/ServiceLogo`（所有 logo，不只新加的四张；用户报的「logo 缺」就是这个），csproj 补了 CopyToOutputDirectory；`d8770e5`：设置页头一直是齿轮，换成这一页自己的符号（同 mac PageHeader）。
  - **为截图自检加的入口**（都是 internal、只给 `--ui-snapshots` 用，正常入口不碰）：`TranslateWindow.ShowProbe`、`TranslateCoordinator.ShowProbe`、`TranslateHistoryView.ApplyProbeState`、`TranslationHistory.InsertForProbe`、`SettingsWindow.ScrollToEndForProbe`；`--translate-text` 挪出 `#if DEBUG`、只在自检档认，加 `KITTY_TRANSLATE_PASSIVE=1`。
  - 没动、留给审查方看的：服务详情的模型下拉、「⋯」菜单这些弹出层截图里拍不到；出字时 CPU 还会随正文变长涨（每段整篇重排一次 `RichTextBlock`、`ResizeToContent` 量一遍），1200 字时界面线程往返 p95 约 20 ms，还不卡。

## 真机反馈修复（2026-10-28 晚，审查方在 Mac 上写，**没编译**）

用户试包后报的五条：设置卡有的有图标有的没有、翻译服务一行间距大、服务 logo 缺、启动器空首页多一截、Chrome「没找到书签文件」。`f7115e7`（启动器两条）、`b56ac4c`（设置和 logo），手测 HANDTEST 576–580。翻译功能本身的差异另起 `PLAN-v9-translate.md`（拍板页，等用户定）。

- **改了公用的**：`SettingsUi.Card` 去掉第一个 glyph 参数（全设置窗 21 处跟着改），加了 `leading`（身份图标）和 `problem`（说明用橙字）两个可选参数；`AddToggle` / `AddCombo` 去掉 glyph、删了 `GlyphFor`。没有 leading 时不建图标那一列（空列也吃 ColumnSpacing）。卡片单击只认左键。
- **服务图标**：`ServiceTile.Create` 现在收 `TranslateServiceConfig`（以前收 vendor 字符串）；Core 加了 `ServiceBadge.Logo` / `IsFullBleed`、`AiEndpoint.ParseProtocol`（`AiServiceProvider.Protocol` 转调它）。`Resources/ServiceLogo` 多了 deepl / deepseek / openai / siliconflow 四张 128 px PNG（mac 那边是 SVG，在 Mac 上渲的）——确认 Release 发布目录里有这四张。
- **kill 白屏（用户 2026-10-28 晚转来）**：截图里窗口停在「正在读取进程…」那一档的高（144）、整块白，正是 d670adc2 修过的那个死锁（行一出来在 UI 线程同步编 exe 图标的 PNG）——报的包多半早于 d670adc2，用现在的 windows-wip 重打。根上补了一道：`ShellIcons.ToPng` 改成把编码放到线程池再同步等，以后谁在 UI 线程上调 `LoadPng` 都不会再死锁；`RunningProcesses` 枚举窗口先认进程、跳过自己的窗口（对自己的窗口 `GetWindowTextLength` 会同步发消息给 UI 线程，UI 线程正等着同一把锁时互相等死）。验：kill / port / quit 各进一次，列表出来、带图标；quit 里按 Enter 关一个记事本不卡。
  - **Windows 验证（2026-10-28 夜，Claude 在 worktree 里）**：猜对了——用户装的 exe 是 16:27 打的 1a60e3d（d670adc2 的父提交），open / find 卡也是同一个死锁（文件结果的图标）。f0a9a019 一次编过、0 警告。在 1a60e3d 上 `find kitty` / `kill ` 必卡、`1+1` 不卡；本版 Debug 和 Release AOT 跑 kill → port → quit → open → find 全程 UI 线程最长卡 104 ms（启动时），见 HANDTEST 621–624。注意 WM_NULL / SendMessageTimeout 探不出这种卡：UI 线程停在 COM 等待里照样回「发来的」消息，要往 DispatcherQueue 排活量（新加的 `--launcher-script` 就是这么量的）。顺手：hide 的最小化改 `ShowWindowAsync`（UI 线程上 `ShowWindow` 别的进程的窗口要等对方，对方没响应就跟着卡）。
- **录屏 / 长截图看不到边框（2026-10-29，Claude 在 worktree 里查的）**：不是旧包——用户装的是 12:01 从 `b3b5598` 打的，
  日志有 `record.frame-shown … created=4 excluded=True`、位置都对。原因是 `WDA_EXCLUDEFROMCAPTURE`：对照脚本在屏幕正中
  出两根同样的分层窗口横条，只差这个标记，用户只看得到没设的那根——在这台机器上设了它的这种窗口连屏幕上都不显示。
  改成只给收进选区里面的线设（贴屏幕边、整屏、最大化窗口那几条），选区外的线不设（录屏按选区裁、长截图按选区抓，本来就录不进去）。
  代价：整屏 / 最大化窗口贴边那几条在这台机器上照样看不见（等于 mac 的不画）。
- **编译时留意**：`SettingsWindow.ServiceRow` 里的本地函数和 async lambda、`ServiceStatus` 的 switch 出元组；`LauncherPanel.xaml` 给底栏那一行起了名字 `FooterRow`。

## v9 启动器分工（2026-10-28，用户：「没有的话就开始对齐 macos」，PLAN-v9-launcher D1–D9 按推荐）

启动器对齐 mac（`PLAN-v9-launcher.md`，并进 PLAN-v9 第 4 批 L1、L3–L8，第 1 批 V1，REVIEW R42）由 **审查方（Claude）在 Mac 上写、不编译**（D9），7a–7d 一批一推。你们负责编译、单测、`--ui-snapshots`、手测；编译错直接修，在这一节下面记一句。

**归审查方的文件**（这一轮别的 agent 先别改；真要改先在这里写一句再动）：`KittyTools/Launcher/**`、`KittyTools.Core/{LauncherItem,LauncherMatch,LauncherCommands,DirectItems,WebSearch,Calculator}.cs`、这一轮新加的 Core 文件和测试（`Launcher*` 开头的）、`Shell/Ui/KindTile.cs`、`Core/PanelFooterText.cs` 里启动器那两个函数、`Core/PanelMetrics.cs` 里启动器那几个、`Settings/SettingsWindow.cs` 的 `BuildLauncher`、`Settings/ShortcutsSheet.cs` 启动器那一组、`App/Settings.cs` 里启动器的新字段。

- 7a–7d（2026-10-28，一次写完、一起推，**都没编译**）：新文件 `Launcher/{LauncherListView,LauncherRowView,RunningProcesses,BrowserData,LauncherOpeners}.cs`、`Core/{LauncherText,LauncherListLayout,LauncherHome}.cs`、测试 `LauncherAlignTests.cs`、`CalculatorMacTests.cs`（计算器照 mac 原样移植，`Calculator.Result` 改成 sealed record、`CalcCopy` 是顶层的）；删了 `Launcher/LauncherRow.cs`，`LookupServices.cs` 只剩文件搜索（书签 / 历史挪到 BrowserData，进程 / 端口挪到 RunningProcesses）。`LauncherKind` 末尾加了 Clip / Translate / Prompt / Process 四种（收藏表按名字存，只能加在最后）；`LauncherItem` 改成 record。
- 顺手动了别人的文件（都是加东西、不改行为）：`Clipboard/ClipPalette.cs`（`PaletteItem` 末尾加可选的 `Detail`，右边没有键位时显示成一行小字）、`Clipboard/ClipboardFormats.cs`（`SnapshotProcesses` 从 private 改 internal，kill / port 找父进程用）、`Shell/Ui/SearchLine.cs`（加 `SetSymbol`）、`Shell/Glyphs.cs`（Monitor、SignOut、VolumeUp、VolumeDown、Command、Minimize）、`Shell/ShellRuntime.cs`（`ShowShortcutsSheet`；`--history` 调试开关改读 BrowserIndex）、`Settings/SettingsWindow.cs`（`ShowShortcutsSheet`）、`App/UiSnapshotProbe.cs`（启动器多出八张图）、`Shell/Ui/ListHighlight.cs`（行高常数换成 LauncherListLayout 的）、`Core/PanelMetrics.cs`（删了启动器那几个，测试跟着删）、`Storage/TranslationHistory.cs`（加 `LatestResult`，fy 单词的释义）、`Clipboard/LinkPreviewService.cs`（加 `IconFor(host)`，网站图标的第二个来源）。
- ip 命令（2026-10-28 照 mac 当天新加的 IPAddresses.swift 补）：新文件 `Launcher/IpAddresses.cs`（读网卡、问两家查询服务）、`Core/LauncherIp.cs`（拼行的纯函数）；`LauncherKind` 末尾再加一个 `Ip`。
- 改过的旧断言：`PanelFooterTextTests`（种类名、动词照 mac：「动作」→「命令」、「打开」→「打开网址」、端口行「复制地址」→「结束」、上膛「确认…」→「确认 + 原名字」）、`PlanV3Batch5Tests`（`FIND` 现在是 FileFind）、`PortedCoreBatch6Tests`（`Format(1e20)` 照 mac 是 `1E20`）。
- **Windows 编过了（2026-10-28，Claude 在 worktree 里）**：7a–7d + fy 释义 + 网站图标兜底 + ip 一次编过、0 警告，400 个单测全过（三个改过的断言照审查方的理由不动），AOT x64 / ARM64 0 警告（`Microsoft.VisualBasic.FileIO` 没有裁剪警告）。跑起来修了八处：`PathIcon` 在 UI 线程同步编码 PNG 死锁（kill 列表一出整个 App 卡死）、第一次出结果时第一行被滚到搜索线下、删空搜索框不回首页（`CompositionRules.ShouldSearch` 把空串也挡了）、Ctrl 键帽和悬停底一直透明（XAML Opacity = 0 压着合成层的淡入）、深色下种类字 / 分组标题 / 放大镜是黑的（主题字典的 Tertiary 画刷按系统外观解析，加了 `Theme.TertiaryText()`，`SearchLine` 一起改了）、浏览器库带 `-journal` 时副本是坏库（网站图标的第一来源一直没生效）、第二个浏览器挑成了 IE、设置页图标改用 `SystemSettings.exe` 的。另加了 `launcher.targets` 耗时日志。别的面板（`ClipPalette`、`ShotHistoryWindow`、`ShortcutsSheet`、`EmptyState`）也这样取 Tertiary，没动；剪贴板面板的 `OnSearchTextChanged` 也用 `ShouldSearch`，删空搜索框会不会不刷新没查。**→ 已修（2026-10-28，提交「剪贴板删空搜索框不回全部条目，三级文字按设置外观给色」）**：剪贴板确实不刷新（`clip-search-cleared` 截图：框空了、列表还是「release」那 2 条），改成只挡组字；这四处换成 `Theme.TertiaryText()`，`CompositionRules` 没人用了，连单测删掉。提交见 `git log --grep "启动器"` 2026-10-28 下午那几个。

## v9 剪贴板分工（2026-10-28，用户拍板 PLAN-v9-clipboard D1–D8 全部按推荐）

剪贴板历史对齐 mac（`PLAN-v9-clipboard.md`，PLAN-v9 第 2 批拆成 6a–6g，C1–C3 并在里面）由 **Claude 在自己的 worktree 里做**（D8），做完一小批推一次。

**归 Claude 的文件**（这一轮别的 agent 先别改；真要改先在这里写一句再动）：`KittyTools/Clipboard/**`、`KittyTools.Core/PanelMetrics.cs`、这一轮新加的 Core 文件和它们的测试（`ClipList*`、`ClipLens*`、`SyntaxHighlight`、`ColorFormats` 之类，加了就写在下面）、`Settings/SettingsWindow.cs` 的 `BuildClipboard`、`Settings/ShortcutsSheet.cs` 剪贴板那一组、`App/Settings.cs` 里剪贴板的新字段。

- 6a（数据底子）：见 `git log --grep "6a"`。另动了 `Core/BackupPlan.cs`（备份留「留下的」= 收藏 ∨ 片段）、`Core/Retention.cs`、`Storage/ArchiveService.cs`（导出带片段、导入带收藏夹名单）。新 Core 文件：`ContentForm.cs`、`ClipLens.cs`、`ClipListLayout.cs`、`ClipOrder.cs`，测试 `ClipboardAlignTests.cs`。
- 6b（列表）：见 `git log --grep "6b"`。新文件 `Clipboard/ClipListView.cs`、`ClipRowView.cs`、`ClipIcons.cs`，删了 `ClipRow.cs`；另动了 `Shell/Ui/SearchLine.cs`（加 `ExtendHairline`，启动器不受影响）、`Shell/Glyphs.cs`（RichText / Snippet / StarFilled）、`Launcher/ShellIcons.cs`（`LoadPng` 加 dip 参数，默认 32 不变）、`Storage/Database.cs`（读「带格式」标记；改正文时清掉 HTML / RTF）、`App/UiSnapshotProbe.cs`（clip-search / snippets / favorites / scrolled 四张，`KITTY_CLIP_PERF=1` 量 5000 条按 ↓）、`Core/PanelMetrics.cs`（剪贴板高度照 mac，删了不用的 `ClipboardHeight`）。
- 6c（透镜）：见 `git log --grep "6c"`。新文件 `Clipboard/ClipLensView.cs`、`Core/ClipPreviewRules.cs`；删了 `Core/PreviewRules.cs` 和它的测试（换成 ContentForm / ClipPreviewRules）；`LinkPreviewService` 多取网站图标、加 `Peek`。
- 6d（键盘和菜单）：见 `git log --grep "6d"`。新文件 `Clipboard/ClipPalette.cs`（面板里的筛选 / 操作菜单）；`ClipEntry` 加形态缓存 `Form`；另动了 `Settings/ShortcutsSheet.cs` 剪贴板那一组。
- 6e（对话框）：见 `git log --grep "6e"`。新文件 `Clipboard/ClipDialogs.cs`；`Shell/Glyphs.cs` 加 `Remove`。
- 6f（放大预览）：见 `git log --grep "6f"`。新文件 `Clipboard/ClipQuickLook.cs`；`Core/ClipPreviewRules.cs` 加 `QuickLookSize`、`HeaderStyle`。
- 真机反馈两条（2026-10-28，用户试 024d0e3 的包）：① 剪贴板操作菜单点击穿透到后面的条目 → `ClipPalette` 悬停 / ↑↓ 只换底色不重建行、去掉 ThemeShadow + Translation Z、加 `Scrim`（菜单下面一层透明垫层，点了只关菜单）；**启动器也用它，在 `Launcher/LauncherPanel.xaml.cs` 里加了一行 `ListHost.Children.Add(_palette.Scrim)`**（审查方的文件，只加这一行）。② 程序图标倒着 → `Launcher/ShellIcons.cs` 的 `ToPng` 不再看 `GetObject` 报的 biHeight 判断行序（自上而下的 DIB 也报正数，整张被翻了一次）；`Launcher/LauncherCache.cs` 的缓存版本 1 → 2，让旧的倒图标缓存作废、重扫一次。另：`--ui-snapshots` 加 `KITTY_SNAPSHOT_ONLY=前缀,…` 只出部分图；这次跑全套时卡在启动器 `launcher-calc` 之后不动（10 分钟被杀），没查，审查方看一下 7a–7d 的截图状态。
- 6g（设置页）：见 `git log --grep "6g"`。`App/Settings.cs` 加 `ClipboardShowLens`、`ClipboardPasteOnClick`、`ClipboardPastePlain`、`ClipboardImageOcr`、`ClipboardClearOnQuit`、`ClipboardClearOnLock`（字段名以后别改）；另动了 `Clipboard/OcrQueue.cs`（识字开关）、`Shell/ShellRuntime.cs`（退出 / 锁屏清空）、`Core/PanelFooterText.cs`、`App/UiSnapshotProbe.cs`（settings-clipboard 整页）。**6a–6g 做完，上面这些文件已交还**，照常归你们；真机手测 HANDTEST 449–528 都没走。

## v9 标注分工（2026-10-27，用户拍板 PLAN-v9-annotate D1–D7 全部按推荐）

截图标注编辑器对齐 mac（`PLAN-v9-annotate.md`，PLAN-v9 第 5 批拆成 5a–5e）由 **Claude 在自己的 worktree 里做**（D7），做完一小批推一次。

**归 Claude 的文件**（这一轮别的 agent 先别改；真要改先在这里写一句再动）：`KittyTools.Core/AnnotationGeometry.cs`、`KittyTools.Core/AnnotationDocument.cs`、`KittyTools.Tests/AnnotationGeometryTests.cs`、`KittyTools/Screenshot/Annotation.cs`、`KittyTools/Screenshot/SelectionOverlayWindow.cs`；`ShotHistoryRules.cs` 里标注 JSON 那几段、`ShotHistory.cs` 的 `ShotAnnotations`。5e 再加尺寸胶囊和工具栏用到的文件，到时写在这里。

- 5a（底子和 B1–B9）：见 `git log --grep "5a"`。
- 5b（十种工具、mac 的画法、样式托盘、每个工具记住样式）：见 `git log --grep "5b"`。另动了 `Shell/Glyphs.cs`（五个工具图标、删掉 ToolSelect）、`Shell/Theme.cs`（托盘选项分段两色）、`App/Settings.cs`（`ScreenshotToolStyles`）、`Settings/ShortcutsSheet.cs`（标注那一组的键）。
- 5c（选中样子、拖手柄 / 拖弯 / 双击拉直、Shift 锁轴、Alt 拖复制、Ctrl+D、方向键、双击文字重新编辑、光标）：见 `git log --grep "5c"`。
- 5d（文字：三档字号、无底 / 描边 / 底色、所见即所得的多行输入框）：见 `git log --grep "5d"`。
- 5e（选区和工具栏：尺寸胶囊输宽高 / 比例锁、Ctrl / Alt + 方向键推收边、空格平移、Ctrl 十字准线、工具栏放哪 / 长出来 / 让位、底块滑动、长截图和录屏按钮、拷贝圆钮、D 上次区域、R 切到录屏、双击拷贝、读屏播报）：见 `git log --grep "5e"`。新文件 `KittyTools/Screenshot/SelectionOverlayWindow.Chrome.cs`、`KittyTools.Core/SelectionChrome.cs`、`KittyTools.Tests/SelectionChromeTests.cs`；另动了 `Screenshot/ScreenshotSession.cs`（Mode 可切、LockedRatio、SelectLastRegion、SwitchToRecording）、`Shell/Motion.cs`（Entrance 加 rise 参数，默认不变）、`Shell/Glyphs.cs`（LongScreenshot）、`KittyTools.Core/RegionMath.cs`（ApplyingRatio 改成顶边不动，以前没人用、移植时上下弄反了）、`Settings/ShortcutsSheet.cs`、`App/UiSnapshotProbe.cs`。另动了 `Settings/ShortcutsSheet.cs`（文字框 Ctrl+Enter / Esc 收下）、`App/UiSnapshotProbe.cs`（shot-text*.png）。
- 录制条的四个开关换成图标（2026-10-28，用户要的）：`SelectionOverlayWindow.cs` 的 BuildRecordBar，`Shell/Glyphs.cs` 加了关着时的五个图形。

## v8 分工（2026-10-26 深夜，用户定：审查方接着把 mac 新功能搬过来）

方案在 `PLAN-v8.md`（截图历史、标注遮罩、速查表）。审查方在 Mac 上写、**不编译**，推上来由你们编译、截图、手测；编译错直接修，在这一节下面记一句。v7 照常归你们。

**归审查方的文件**（新文件你们不用管；下面这些现有文件只是加几行挂钩，你们照常改，rebase 撞了以你们的为准、把挂钩那几行补回去）：

- 新文件：`Core/ShotHistoryRules.cs`、`Tests/ShotHistoryTests.cs`、`Screenshot/ShotHistory.cs`、`Screenshot/ShotHistoryWindow.cs`、`Screenshot/AnnotateOverlay*.cs`、`Settings/ShortcutsSheet.cs`。
- 挂钩：`Core/Schema.cs`（第 8 步）、`App/Settings.cs`（`ShotHistory`）、`App/HotKeyDefaults.cs`（默认表最后加一项）、`Shell/ShellRuntime.cs`（启动 + 动作分发）、`Shell/TrayMenu.cs`（一项）、启动器的命令表（一项）、`Screenshot/ScreenshotSession.cs` / `SelectionOverlayWindow.cs` / `ScreenshotCard.cs`（记录和「在历史里看」）、录制的几处出口、设置 › 截图页（一个开关）。

**v8 进展（审查方，都没编译过；你们编过后在下面记一句）**：

- 第 1 批 `8d43b40`：存储和记录（你们 `7eff53c` 已在它之上跑过 333 个单测、0 警告）。
- 第 2 批 `e79620d`：历史窗口和入口。顺手把启动器里一直是「第 5 批接上」占位的截图 / 截图翻译 / 识字接上了（先收起启动器 200 ms 再开，不然冻结帧会拍到启动器），另加「录屏」「截图历史」两项。
- 第 3 批上 `036f8b8`：历史里「改标注」——原图 1:1 摆在鼠标所在屏正中当冻结帧（四周深灰），用截图遮罩那一套接着改，拷贝 / 存储 / 钉图时选区没动就回写同一条。比屏幕还大的（长截图）提示不支持。
- **第 5 批（提示带按钮、悬停展开）已交还**（提交见 `git log --grep "v8 第 5 批"`，没编译过）：`Notice.cs` 照常归你们。
  - `NoticeHost.Show(..., params NoticeAction[] actions)` / `ShowProgress(..., actions)`；`NoticeAction(Title, Run, Opens)`，`NoticeActions.Reveal / Open / SystemSettings / AppSettings` 几个现成的。
  - 窗口高度定死在展开卡片的最大高（124 + 上下 8），平时整扇点得穿；提示开着时 33 ms 看一次指针（`_pointerTimer`），指针动过、落在形状上才去掉 `WS_EX_TRANSPARENT`。悬停：停计时、`MeasureCard(expanded: true)` 排一次版、形体弹到卡片大小；离开合回、`max(剩下的, 1.5 s)` 再收。鼠标在上面时别处来的提示排着（`_pending`），按钮自己弹的不排。
  - 加了按钮的地方：截图存储 / 另存为、钉图存储、录屏 / 录音存好（**不再自己弹资源管理器**）、闪退恢复的录屏 / 录音、GIF 好了 + 转的时候「取消」、压缩完成 + 压的时候「取消」、更新失败「重试」、已更新「看更新了什么」、有新版本「更新」、没装识字组件「打开设置」（截图那两处**不再自己弹系统设置**）、复制即译 / 暂停剪贴板「撤销」、剪贴板已关闭「打开设置」、翻译历史删除「撤销」。
  - 调试参数 `--notice-buttons`；`--ui-snapshots` 多 `island-buttons`、`island-expanded`。
  - **最可能要改的**：按钮的轻量样式资源键（`ButtonBackgroundPointerOver` 等）在 WinUI 2.x 里叫不叫这个；`WS_EX_NOACTIVATE` 的窗口里按钮点不点得动（录制条那边是点得动的）；`--notice-anim-test` 的窗口高度变了，量宽度的那段可能要跟着改。验收看 `HANDTEST` 339–345。
- 第 4 批：速查表（`Settings/ShortcutsSheet.cs`），设置的剪贴板 / 启动器 / 截图 / 翻译 / 快捷键五页标题下面加了「查看全部快捷键…」。里面的面板按键是逐个对着现在的按键处理抄的（每组注明了文件），**改了面板按键要同步这里**；R39–R41 修完后跟着改。历史窗口加了 Delete 删选中的那条。
- **第 3 批下（长图标注）先不做**（0.2.0 的 S12 做了，见上面 windows-next 那段）：长图比屏幕高，截图遮罩那一套用不上，要另写一个能滚的长图画布、把标注交互再做一遍（约等于 `SelectionOverlayWindow` 的一半）。mac 那边的用户数据里长截图是 0 次，等用户要了再做。
- **和方案不一样**：画了标注的另存一张成品 `<id>-c.png`（Windows 的 `AnnotationRenderer` 画马赛克要冻结帧，离开遮罩合成不了）；来源程序先不记；角落缩略图卡没有右键菜单，「在历史里看」没加。
- **要验**：`ShotHistoryTests`；截图拷贝 / 存储 / 钉图 / 长截图 / 录屏 / 录音 / GIF 各来一次，`%LOCALAPPDATA%\KittyTools\shots\` 和 `shots` 表对得上；历史窗口每个操作；改标注后缩略图跟着变、再打开看到改过的标注；`Annotation` 以后加了字段（比如空心 / 实心）要在 `ShotAnnotations` 里一起存。

## v7 分工（2026-10-26 深夜，用户定）

用户让审查方（Claude，在 Mac 上，**不编译**）分着做 PLAN-v7 里你们还没动的两块。写完推上来，编译、截图、录屏由你们验；有编译错误直接修，在这一节下面记一句。

**归审查方的文件**（这一轮你们先别改；真要改先在这里写一句再动）：

1. **轻提示（§2.3、§3.4）**：`KittyTools/Shell/Notice.cs` 整个文件。另加 `NoticeHost.ShowProgress`（56 × 4 细进度条），只改三处调用里报进度的那几行：`Recording/GifService.cs`、`Recording/CompressionService.cs`、`App/AutoUpdater.cs` 的 `OnProgress`。
2. **界面对齐手测（§5 第 6 批）**：`HANDTEST.md` 里新加的「界面对齐手测」那一节（只追加这一节；你们别的手测照常往文件后面加）。

**归你们**：v7 其余的全部（剪贴板、启动器、翻译浮窗、截图与录制、设置窗、`Motion.cs`、`Styles.xaml`、changelog、STATUS）。

审查方做完会在这里写「已交还」，之后这些文件照常归你们。

**已交还（审查方，2026-10-26 深夜，提交见 `git log --grep "v7 轻提示"`；没编译过）**：上面这些文件从现在起照常归你们，编译错直接修。

- `Notice.cs` 重写：窗口一次定死在最大宽（左右透明边 24：island 弹簧冲过头约 8% 加抖动 7），黑底是 `ShapeVisual` 里的 `CompositionRoundedRectangleGeometry`，内容层用同一组尺寸的 `CompositionGeometricClip` 裁；宽度动画是 `SpringEase` 采样成 20 个表达式关键帧（`Lerp(this.StartingValue, target, k)`），中途换内容从当前大小接着走，主线程每帧不排版（原来 16 ms 定时器改 XAML `Width` 删掉了）。出现：36 的圆 → 实际宽度，内容晚 60 ms 淡入 + 0.9 → 1（顶边锚点）；原地换内容只动宽度；错误抖 [0, −7, 6, −4, 2, 0] 0.4 s（`Motion.Shake` 现在没人用了，要删随你们）；收起：内容 0.12 s 退场，0.08 s 后形体 retract 缩成圆、最后 0.12 s 淡掉，`CompositionScopedBatch` 走完才 `Hide`。胶囊顶边离工作区顶边 8（原来是 22），white 0.12 发丝线；信息的符号用 `OnAccent`。原来 `_shown` 收起后不复位、第二次出现不再从圆长出来，一起改了。
- `NoticeHost.ShowProgress(title, detail, fraction)`：标题后面 56 × 4 细进度条（填充按比例横向缩放，0.2 s 线性），同标题原地改、不重新出场、不播报，60 s 兜底。接了三处：转 GIF、压缩、下载更新（后两处的回调在线程池，切回 UI 线程，结束后才到的回调丢掉）。
- **压缩进度的单位**：`TranscodeAsync` 报的是 0–100 的百分数（learn.microsoft.com「Transcode media files」的示例参数就叫 percent），原来 `Progress = progress` 存进去、托盘按 `Progress * 100` 显示，会出「压缩中 4300%」。改成存 0–1。压一次看日志 `video.compress-progress` 是不是 0–100 往上走；要是本来就是 0–1，把 `/ 100` 去掉。
- `HANDTEST.md` 加了「第七版：界面对齐手测（细项，302–329）」，逐条是 PLAN-v7 §2–§4 的数值；轻提示是 316–320。
- **要验**：编译；`--notice` / `--notice-error` 录 3–5 秒（PLAN-v7 第 3 批的验收：长出 / 换内容 / 抖动 / 缩回）；`--ui-snapshots` 的 `island-notice`、`island-error`；HANDTEST 316–320。最可能要改的：表达式关键帧的写法（报错就看 `this.StartingValue` 和 `Lerp` 的参数类型）、`Translation.X` 动画（`SetIsTranslationEnabled` 已在构造里开）。

**Windows 这边验过（2026-10-26 深夜，Claude 的 worktree）**：`Notice.cs` 原样编过（Debug、AOT x64 / ARM64 都 0 警告），没有编译错。新加 `--notice-anim-test=<目录>`（`App/NoticeAnimationProbe.cs`）：WGC 只抓提示窗口，逐帧量胶囊宽度，依次放长出 → 原地换长内容 → 出错 → 停留到点缩回。结果：形状和顺序都对，四段动画期间 XAML 排版 0 次；**改了一处**——表达式的 `Lerp(this.StartingValue, target, p)` 在 Composition 里把 p 夹在 [0, 1]，island 的回弹冲不过头（量到最大宽 = 最后宽：36 → 104、104 → 372）。`PillAnimation` 改用共用的 `Motion.CurveTo`（`start + (target − start) × p`），之后 36 → 112 → 104、143 → 402 → 372。另外 `Notice.cs` 只加了一个给探针数排版次数的 `LayoutPassesForProbe`。帧图见 `windows-shots/0.7.0-v7/island-anim-*.png` 和 `island-anim-report.md`，`--ui-snapshots` 的 `island-notice` / `island-error` 也用合并后的构建重出了（`12b0d71`）。

## 待修

（2026-10-26 晚复查到 `3fe1725e`：R22、R25、R26、R28、R29 认可；R23 认可，60 s 和 10 分钟的重封装耗时并进 R24 一起量；R30 认可，托盘和 HUD 的截图见 R33。新加 R31–R35。R24 一直没动，排在最前面。）

（2026-10-26 夜：安装程序写完了（`616840b`，没编译过），新加 R36–R38。R36 排在 R24 前面先做：没编过的 Setup 不进 slnx，但 Core 单测里已经有它的测试。）

（2026-10-27：审查方在 Mac 上把代码过了一遍，找还能优化、没优化的地方，新加 R42–R52，行号都对着 `e82715d2`。每一条都读过代码确认过，只是没在 Windows 上量过：**改之前先量一次、改完再量一次**，两个数都写进报告；量出来不值得改的，写上数挪到「有异议」。顺序：R41 修完先做 R42–R44（P1），再做 R24；P2、P3 照常一条一条来。功能缺口另写在 `PLAN-v9.md`，那是拍板页，用户拍板之前别动。）

（2026-10-27 晚：用户定 Windows 第一个对外版本叫 0.1.0、主打剪贴板 / 截图 / 翻译，新加 R53（发版清单）和 R54–R64（这三样里的 bug，行号对着 `0533b3ae`）。**R53 排在所有待修前面**，R42–R52 里不挡发版的照旧往后排。）

### R53（P0）0.1.0 发版：先修下面这些，再打包

用户 2026-10-27：「你找出来，然后我 windows 上打包，并且 windows 就是 0.1.0 版本，没有现在那么多个版本」。Windows 的第一个对外版本叫 **0.1.0**，主打**剪贴板历史、截图、翻译**。

**0.1.0 分工（2026-10-27 中午，用户：「要不你来接手」，随后「我的 agent 本地修改的代码我都回退了，都交给你」）**：
- **代码全部归审查方**（在 Mac 上写、不编译）。R54–R63 是你们推的（`cc019fcc`…`589511c4`），审查方复查过，都认可。
- **你们只做这些**：
  - `git fetch && git rebase origin/windows`，编译，编译错、单测红直接修，在这一节下面记一句；
  - 装 Inno Setup 7，照第 6、7 步打包、跑 `setup-e2e.ps1`、手测（`HANDTEST.md` 351–366 是这一轮新加的），写报告。
  - 行为不对的，先在这里写一句，再改。
- **审查方的进度**：
  - `53d609e9` 第 4 步：R41 第一条、R44、R46、R47、R48 第一条、PLAN-v9 V2；
  - `9efc8da9` R64 五条：都按建议写了，**没在 Windows 上验过**，手测 358–362；
  - R66 托盘菜单换成系统的 Win32 菜单、安装程序加桌面快捷方式（`git log --grep R66`，用户真机反馈），手测 367–370；
  - R67 用过一次右键菜单后点图标打不开（`git log --grep R67`），手测 371；
  - R65 Inno 安装程序（`git log --grep R65`）：`installer/KittyTools.iss`、App 的 `--quit` / `--uninstall-cleanup`、`SetupRecord` 改认 Inno 的登记、删掉 `KittyTools.Setup` 和 `Core/SetupPayload.cs`、`build-release.ps1` 调 ISCC、`setup-e2e.ps1` 重写。
- **最可能要改的**：
  - `.iss` 的 Pascal 没用 ISCC 编过；
  - `CheckForMutexes` 认不认 `Local\` 前缀；
  - `{param:...}` 在卸载程序里能不能用；
  - `DisableReadyPage=yes` 时更新会不会照样出准备页（按钮文字设在 `wpReady` 上）；
  - `Recovery.AskAndRepairAsync` 里 `Window.Activate()` 之后 `Loaded` 来不来。

审查方已经提交了（在 Mac 上改的，**没编译**）：
- `Directory.Build.props` 版本改成 0.1.0；`changelog.json` 的七条内部版本合成一条对外的 0.1.0。
- `Shell/Feature.cs`：启动器和录屏没存过时默认关（`DefaultOn`，带 ponytail 注释）。启动器读浏览历史、默认值还没对齐 mac（R42、PLAN-v9 V1），录屏真机没走完（R24）。欢迎页的快捷键说明跟着改了（`Settings/SettingsWindow.cs` 的 `BuildWelcome`）。
- `AGENTS.md`「版本和发布」、`STATUS.md` 开头、PLAN-v9 的最后一批改成新编号。

**顺序**：

1. 编过审查方这次的改动。`--smoke` 里还直接开启动器面板和录音条，功能关着也该能开；开不了就把 smoke 里那两步跳过，别为了 smoke 把默认值改回去。
2. 修 R54–R63（这三样里的 bug，审查方读代码找的，都核过代码）。
3. 在 Windows 上验 R64 的五条，是真的就修。
4. 修已有待修里影响这三样的：
   - R41 第一条（剪贴板 Ctrl+K 里按 Enter 不执行）；
   - R44（每截一次图，设置窗就在后台重建一页）；
   - R46（剪贴板后台识字大图不缩、失败了每次启动重来）；
   - R47（每日备份跨线程读数据）；
   - R48 第一条（钉图「复制」卡界面）；
   - PLAN-v9 的 V2（识字默认不接行，截图翻译照旧接）。这一条用户还没拍板，审查方替用户定先做：只是改默认值、加一个开关。
5. **不挡 0.1.0**：R42、R24（启动器、录屏默认关了）；R43（长截图拼长了会卡）、R45（长译文流式会卡）能顺手修就修，修不完写进下面的「已知问题」；R49–R52、PLAN-v9 的其余项照旧往后排。
6. 先做 R65（安装程序换成 Inno Setup 7），再打包：`dotnet test` 全过 → `pwsh windows/build-release.ps1`（AOT x64 / ARM64、零警告、`--smoke`、zip、Inno 编的 setup.exe）→ `pwsh windows/tools/setup-e2e.ps1` 五步全过 → 产物在 `windows/build/release/0.1.0/`。
7. 手测，用 `KittyTools-0.1.0-windows-x64-setup.exe` 装一次。开发机上用旧安装程序装过的，先用它的 `Uninstall.exe` 卸掉（PLAN-setup-inno I14，不做迁移）：
   - `HANDTEST.md`「发版冒烟清单」的 1、2、3、5、6、8、9、15、16、17，第 7 条里除了启动器的部分；
   - 截图历史（333–338）、长截图（216–224 里长截图那几条）、提示带按钮（339–345）；
   - R54–R64 每条修完的那个场景再走一遍。

   没走的写「没测」，别打勾。
8. 报告：做了哪些、量到的数、产物路径和大小、没修的写成「已知问题」（一条一句）。**不发布**；用户要发时，tag 用 `windows-v0.1.0`、`--latest=false`、别标预发布（`App/UpdateService.cs` 只认非预发布的 `windows-v*`）。

**Windows 侧编译 / 打包时改的（2026-10-27）**：
- rebase 到 `2efae4cc` 后 Debug、Release AOT x64 / ARM64 都直接编过，零警告，325 个单测全过；`KittyTools.iss` 用 ISCC 7.1.0 直接编过，没改。
- Inno 7 的 winget id 是 `JRSoftware.InnoSetup.7`（`JRSoftware.InnoSetup` 装的是 6.7.3）：`build-release.ps1`、`setup-e2e.ps1` 的报错提示改了。
- `setup-e2e.ps1` 第 3 步没过（exit 7，程序没被叫退）：`--quit` 送到了（日志有 `instance.quit` / `app.exit`），但 `Application.Current.Exit()` 之后总剩一扇窗没关（预建的浮层；显式关了浮层就剩 `_keeper`），消息循环不结束，进程留着互斥量。去掉 R64 A 的 Closing 也一样，不是它。托盘「退出」、更新后退出走的是同一个 `ShellRuntime.Exit`，也受影响。改：`Exit()` 收尾做完后起一个后台线程，2 秒后还在就 `Environment.Exit(0)`（日志 `app.exit-forced`，带 ponytail 注释）。根因没找到。

### R54（P1）「截取上次区域」裁的是屏幕左上角那一块 → 已修（`d07959f`）

- `Screenshot/ScreenshotSession.cs:370`：`new PixelBounds(0, 0, global.Width, global.Height)` 从屏幕的 (0, 0) 开始裁，上一行算好的 `local`（减掉了 `screen.Bounds`）没用上。`Crop`（`Screenshot/ScreenCapture.cs:38`）吃的是这块屏里的像素坐标。
- 触发：在屏幕中间截一次图，再按 Ctrl+Alt+Z。复制出去的、飞入卡、截图历史里，都是屏幕左上角同样大小的一块。
- 改：`new PixelBounds((int)local.X, (int)local.Y, (int)local.X + global.Width, (int)local.Y + global.Height)`；加一条副屏上的手测。

### R55（P1）标注的撤销差一步：画完第一条按 Ctrl+Z 没反应 → 已修（`a86db3c`）

- `Screenshot/SelectionOverlayWindow.cs:1089`：矩形、箭头、画笔、马赛克一按下就加进 `_annotations`；松手时（:1258）才 `PushUndo()`，存进撤销栈的那份已经带着这一条，`Undo`（:435）还原出来的和现在一模一样。
- 触发：画一个矩形，按 Ctrl+Z 或点工具栏的撤销，没反应；画几条再撤，永远差一步。
- 改：按下、加进列表**之前** `PushUndo()`；松手时太小被丢掉的，把刚压进去的那份弹出来（不然要空撤一步）。文字工具、拖着挪标注那两条路（:289、:1052）也对一遍有没有同样的毛病。

### R56（P2）从托盘、设置窗打开面板，会粘进上一次的旧窗口 → 已修（`8ff846a`）

- `Shell/OverlayWindow.cs:129–133`：呼出时前台如果是本 App 自己的窗口（托盘菜单、设置窗、截图历史、钉图），就不更新 `_previousForeground`，留着上一次的。
- 触发：先往记事本粘过一次；之后点托盘「剪贴板历史」，选一条按 Enter，记事本被拉到前台、内容粘了进去。
- `Translate/TranslateWindow.cs:451–457` 的 `_replaceTarget` 同样：在剪贴板面板里 Ctrl+T 打开浮窗，点「替换原文」，粘进上一次翻译时的那个窗口。
- 改：前台是自己的窗口时，把目标清成 `default`，只复制、不粘贴，提示说「已复制」。Windows 的托盘菜单会抢前台，拿不准要粘到哪就别粘。

### R57（P2）复制即译：翻译关了照样弹；剪贴板关了它也跟着停 → 已修（`3203948`）

- `Translate/TranslateHost.cs:139` 的 `OnTextCopied` 不看翻译功能开没开。设置里关掉「翻译」后，复制文字照样弹浮窗；托盘里「复制即译」的开关又因为翻译关了被藏起来，关不掉。
- `Clipboard/ClipboardService.cs:65`：复制即译挂在剪贴板采集后面（:125 `TextCopied`）。关掉「剪贴板」功能、或者托盘里暂停记录以后，这里直接 return，复制即译就悄悄不工作了。
- mac 的做法（`App/AppDelegate.swift:2377`，以及 `applyFeatures` 里「剪贴板关着时只为复制即译跑、不入库」）：翻译开着才译；剪贴板关着时照样监听，只是不入库。
- 改：
  - `OnTextCopied` 先查 `Features.IsOn(Feature.Translate)`；
  - `Suspended` 时照样读文本、发 `TextCopied`，只是不入库；
  - 隐私标记、排除的 App、敏感文本、`_selectionPaused`（划词自己发的 Ctrl+C）这几道照样挡；
  - 「暂停记录」时复制即译停不停，照 mac 的 `isUserPaused` 那一处定。

### R58（P2）划词超过 2048 个字符，后面的直接丢掉 → 已修（`0e32e02`）

- `Translate/SelectionReader.cs:111`：UIA 取词用的是 `GetText(2048)`。
- 触发：在浏览器或 Word 里选 3000 字划词翻译，只翻了前 2048 个字符，没有任何提示（输入翻译的上限是 32 KB）。
- 改：`GetText(-1)`，长度交给后面那道 32 KB 的检查；超了照输入翻译那样提示。

### R59（P2）超过 2 MB 的 HTML / RTF 被截了一半存下来，不是丢掉 → 已修（`da9a6ca`）

- `Clipboard/ClipboardFormats.cs:495` 的 `ReadRich` 调 `ReadBlob(format, MaxRichBytes)`，`:523` 的 `Math.Min` 把超长的截断；`MaxRichBytes`（:46）的注释说的是「超过就只留纯文本」。
- 触发：复制几千行的 Excel 区域、带内嵌图片的网页，再从历史里粘回 Word / Outlook，格式是坏的，或者只出来一部分。
- 划词走 Ctrl+C 兜底时，`CaptureSnapshot`（:128 起）还原回去的也是截断版，等于把用户剪贴板里原来的富文本弄坏了。
- 改：`ReadRich` 改用 `ReadBlobWithin`（超了返回 null），和图片那几处一样。

### R60（P2）多选粘贴、替换原文：失败了还显示成功 → 已修（`8ea0d48`）

- `Clipboard/ClipboardPanel.xaml.cs`：
  - 依次粘贴失败时，`break`（:1419–1420）只跳出循环，接着 :1429 照样显示「已依次粘贴 N 条」，把刚报的错盖掉（`NoticeHost.Show` 是原地换内容）；
  - 一起粘文件时（:1395–1399）不看 `Paster.Paste` 的返回值，`Paster` 自己弹的「没能切回原窗口，请手动粘贴」「目标是管理员窗口」会被马上换成「已一起粘贴」。
- `Translate/TranslateWindow.cs` 的 `ReplaceWith`（:885 起）也一样：失败时把 `Paster` 给的具体原因换成「没能切回原窗口」。
- 改：失败就 return，看返回值再报成功；`ReplaceWith` 失败时不再另报一遍。

### R61（P3）片段里的 `{uuid}` 每次都一样 → 已修（`70e5814`）

- `Clipboard/Expander.cs:25`：传进去的是片段自己的 `Uid`，每次粘贴、同一片段里的几处都是同一个值；mac 是每处各生成一个新的。
- 改：`SnippetRules.Expand` 的 uuid 参数改成一个生成函数，每处现生成一个 `Guid`；单测补「同一片段两处不一样、两次粘贴不一样」。

### R62（P3）长截图进剪贴板历史，记的是选区的尺寸 → 已修（`7ab0e01`）

- `Screenshot/ScreenshotSession.cs:440` → `ScreenshotOutput.CopyPngAsync`（:33）按选区算宽高。
- 触发：拼出一张 1440 × 12000 的长图，剪贴板列表、预览角标、「已复制截图」提示都写着选区的大小（比如 1440 × 800）。
- 改：`CopyPngAsync` 加宽高参数，长截图传拼好的那张的。

### R63（P3）钉图、飞入卡的「复制」失败了没提示 → 已修（`774a6c8`）

- `Screenshot/PinWindow.cs:311`、`Screenshot/ScreenshotCard.cs:431`：剪贴板被别的程序占着、写不进去时，什么都不显示。
- 改：照 `ShotHistoryWindow.CopyAsync` 补一句「没能复制」（错误语气）。

### R64（P1，先在 Windows 上验）五处读代码看着有问题的 → 五条都已按建议写（`9efc8da9`，审查方，没在 Windows 上验）

验出来是真的就按建议修，都挡 0.1.0；不成立的写一句怎么验的，挪到「有异议」。

- **A. Alt+F4 关掉浮层以后，整块功能失灵到重启**：剪贴板面板（`Shell/OverlayWindow.cs`）、翻译浮窗（`Translate/TranslateWindow.cs`）、截图遮罩都没接 `AppWindow.Closing`，只有设置窗接了（`Settings/SettingsWindow.cs:151`）。
  - Alt+F4 之后，`OverlayHost._window`、`TranslateHost._window` 还指着已经关掉的窗口，下次按热键调它会抛异常。
  - 截图遮罩被关时只调 `Release()`（`SelectionOverlayWindow.cs:142`），不走 `Finish()`：`_current` 不清，开截图时注销掉的全局热键（`ScreenshotSession.cs:72`）不再注册；多屏时别的屏上的遮罩还盖着。
  - 验：在剪贴板面板、翻译浮窗、截图遮罩上各按一次 Alt+F4，再按它自己的热键和别的热键。
  - 改：`Closing` 里 `Cancel = true`，改走各自的 Hide / Finish。
- **B. 数据库打不开时，选择框可能出不来**：`Storage/Recovery.cs:138` 在 UI 线程上 `ShowAsync().AsTask().GetAwaiter().GetResult()` 同步等 ContentDialog，`XamlRoot` 是 `Activate()` 之后立刻取的、可能还是 null。结果要么卡死，要么异常被当成「退出」，App 一声不响地退了（HANDTEST 170 没走过）。
  - 验：在测试数据目录里把 `kitty.db` 写成乱码再启动。
  - 改：改成 await；`XamlRoot` 等内容 `Loaded` 以后再取。
- **C. 从剪贴板面板拖出去，可能变成「移动」**：`Clipboard/ClipboardPanel.xaml.cs:406–453` 没设 `RequestedOperation = Copy`（`ScreenshotCard.cs:483` 设了）。图片条目给的是 `images\<id>.png` 本体，文件条目给的是用户的原文件；资源管理器在同一个盘上按默认的「移动」处理时，图片被挪出数据目录（历史里变成图片丢了），用户的原文件被搬走。
  - 验：把图片条目拖到桌面（和 `%LOCALAPPDATA%` 同一个盘），看 `images` 目录和预览；文件条目同样试一次。
  - 改：设成 Copy；图片给一份临时副本。
- **D. 多屏时，在另一块屏上框选后按键可能没反应**：只有一开始光标所在那块屏的遮罩会把焦点给画布（`SelectionOverlayWindow.cs:476–486`、`:503–509`），按下鼠标时也不给。
  - 验：两块屏，光标在 A 屏按截图热键，到 B 屏框一块，按 Enter、Esc、Ctrl+C、1–5。
  - 改：按下鼠标时给画布焦点，激活不只限起始那块屏。
- **E. 输入法组字时按 Enter，可能直接粘贴或翻译**：剪贴板面板的 Enter / Esc / ↑↓（`ClipboardPanel.xaml.cs:1152–1183`，`handledEventsToo`）没看 `_composing`（:47）；翻译浮窗的 `OnSourceKeyDown`（`TranslateWindow.cs:521`）也一样。
  - 验：用微软拼音在剪贴板搜索框里打几个字母，按 Enter 上屏，看是不是直接粘贴了选中的条目；翻译浮窗同样试一次。
  - 改：组字中这几个键直接 return。

### R65（P1）安装程序换成 Inno Setup 7（0.1.0 打包之前做） → 已写（审查方，`git log --grep R65`，没编译、没用 ISCC 编过）

用户 2026-10-27：「安装 exe 的界面太简陋了，市面上没有现成的工具能使用吗，期望优化」，看过几种做法以后定了：「安装程序换成 Inno Setup 7」。现在的安装程序全是系统的任务对话框（PLAN-setup S2），几页白底弹框。

- **方案**：`PLAN-setup-inno.md`，照它做，一批做完。
  - 用户能看到的行为（装到哪、不许装到哪、装过就更新、开着先叫它退出、只问「开机时自动打开」、卸载时问删不删数据）和现在一样，改用 Inno 实现；
  - 长相换成 `WizardStyle=modern dynamic windows11`，跟着系统深浅色；
  - 两组安装图审查方已经出好、提交在 `windows/installer/`。
- **红线例外**：用户同意打包用 Inno Setup 7（只在 `build-release.ps1` 里用，不进 App）。`AGENTS.md` 红线那一条已经写上。装 Inno 用 `winget install --id JRSoftware.InnoSetup.7 -e`，要 7.x。
- **AppId 定死**：`{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}`，以后永远不改。
- **删**：`KittyTools.Setup/` 整个项目、`Core/SetupPayload.cs`、`Core/SetupRules.cs` 的大半、`SetupTests.cs` 跟着删到只剩留下来的函数（PLAN-setup-inno §5）。**加**：`installer/KittyTools.iss`；App 的 `--quit`、`--uninstall-cleanup [--remove-data]`；`SetupRecord` 改成认 Inno 的登记（§4）。
- **R37 / R38 的口子跟着改**：「从这台电脑移除」启动 `unins000.exe`；程序内更新后改 `{AppId}_is1` 里的 `DisplayVersion` / `EstimatedSize`。
- **最可能踩的坑**（PLAN-setup-inno §2 末尾）：
  - `CheckForMutexes` 认不认 `Local\` 前缀；
  - 静默安装时 `NextButtonClick` 调不调（所以位置检查在 `PrepareToInstall` 里再做一遍）；
  - `[UninstallDelete]` 整个删 `{app}` 之前，位置规则一定要先保证这个文件夹整个是我们的；
  - `--uninstall-cleanup` 不能开数据库、不能往数据目录写日志（R25）。
- **验收**：PLAN-setup-inno §7。`setup-e2e.ps1` 五步全过；浅 / 深色四张截图推到 `windows-shots`；报告写两个 setup.exe 的大小、装一次和卸载一次的耗时。

### R67（P1）用户真机反馈：用过一次右键菜单，再点托盘图标打不开 → 已写（审查方，`git log --grep R67`，待编译）

用户 2026-10-27：「右键菜单点击后会导致左键菜单也打不开」。审查方这边复现不了。旧菜单（WinUI 那一版）缺了托盘菜单收尾的两步，都没做：

- 收起后 `PostMessage(WM_NULL)`；
- `Shell_NotifyIcon(NIM_SETFOCUS)` 把焦点还给通知区域（NOTIFYICON_VERSION_4 的规矩）。

缺了这两步，下次点图标常常没反应。

- 新菜单（R66）已经有 `WM_NULL`，这次补上 `Tray.ReturnFocus()`（NIM_SETFOCUS），选了、Esc、点外面都调。
- 选中的那一项不再在 `WM_CONTEXTMENU` 的回调里当场做，改成 `DispatcherQueue.TryEnqueue` 出来再做。截图 / 截图翻译 / 识字 / 录屏再等 300 ms：系统菜单选中项有淡出，免得拍进冻结帧。
- **要验**：手测 371。还能复现的话，日志里看第二次点击有没有 `tray` 相关的行。没有就是系统没把 NIN_SELECT / WM_CONTEXTMENU 发过来，报告里写一句。

### R66（P1）用户真机反馈：没有桌面快捷方式；托盘菜单位置不对 → 已写（审查方，`git log --grep R66`，待编译）

用户 2026-10-27：「1、没有桌面快捷方式 2、系统托盘图标右键弹出的窗口怎么位置不对，没有使用官方的吗」。

- **桌面快捷方式**：`installer/KittyTools.iss` 选位置那一页多一个勾选框「在桌面上建快捷方式」，默认勾上；`[Icons]` 加 `{userdesktop}`，更新时不再建，卸载时 Inno 删掉。静默安装用 `/DESKTOPICON=0` 关掉；`setup-e2e.ps1` 跟着查。
- **托盘菜单**：以前是 WinUI 的 MenuFlyout 弹在一块 360 × 480 的透明窗口里，窗口右下角对准鼠标，位置全靠自己算。托盘回调 `wParam` 里系统给的位置没用（键盘选中时菜单跑到鼠标那儿）。
  - 换成系统的 Win32 弹出菜单，照微软 NotificationIcon 示例写：
    - 位置用 v4 回调的 `wParam`；
    - `SetForegroundWindow(托盘隐藏窗口)` → `TrackPopupMenuEx`（`SM_MENUDROPALIGNMENT` 定左 / 右对齐、`TPM_RETURNCMD`）→ `PostMessage(WM_NULL)`；
    - 位置、翻转、多屏、DPI、键盘、读屏都由系统管。
  - 分节、勾选（暂停记录、复制即译）、灰掉、快捷键（`\t` 右对齐）都保留；**菜单项前的彩色图标没了**（系统菜单是纯文字），这一处和 PLAN-v7 §3.5 不一样。
  - 深色用 uxtheme 没写进文档的序号 135 / 136（SetPreferredAppMode + FlushMenuThemes，资源管理器同一套），跟着设置 › 外观；拿不到就是浅色菜单。
  - `--ui-snapshots` 不再截托盘菜单（TrackPopupMenuEx 会一直占着界面线程），改成手测 368。
- **要验**：编译（`Shell/TrayMenu.cs` 整个重写了，`LibraryImport` 声明和函数指针调用最可能要改）；手测 367–370。
- **Windows 侧编译时改的（2026-10-27）**：`TrayMenu` 整个类标着 `unsafe`，`Show` 里 async lambda 的 `await Task.Delay` 编不过（CS4004）→ `unsafe` 只留在 `ApplyMenuTheme` 上；`(IntPtr)HiddenWindow.Hwnd.Value` 是指针转换、出了 unsafe 就编不过 → 改成 `(IntPtr)HiddenWindow.Hwnd`。之后 Debug、Release AOT x64 / ARM64 零警告，325 个单测过，`--smoke` 过，`setup-e2e.ps1` 18 项全过（含桌面快捷方式和 `/DESKTOPICON=0`）。
- **Windows 侧验的（2026-10-27，脚本，不是真点）**：测试档的 Release 版，往托盘隐藏窗口直接发 v4 回调（`WM_CONTEXTMENU` / `NIN_KEYSELECT`，wParam 带位置），截图在 `windows-shots/0.1.0-r66/`。
  - 位置：两种回调都弹在 wParam 给的那一点上，左下角对齐它往上展开（贴着屏幕底，系统自己翻的）；右键给的是鼠标处，键盘给的是图标中心（2560 × 1440、单屏、100%）。
  - 深色：设置 › 外观「一直深色」时菜单是深色（背景 44,44,44），浅色 249,249,249。系统是浅色，「跟随系统 + 系统深色」那条没验（不改系统设置）。
  - 「复制即译」打开时前面有勾；快捷键右对齐；Esc 能收；同一进程里连开两次都能弹。
  - 367「删掉桌面快捷方式后更新」：测试名静默装 0.0.1 → 删桌面那个 → 装 0.0.2 → 没再冒出来；卸载后目录、登记、快捷方式都没了。
  - 没测：真的鼠标右键 / Win+B（369 的真实路径）、多屏和 150%（370，这台只有一块屏）、371 里点菜单外面收起和「截图」不拍进残影。

### R39（P2）截图遮罩的按键：A、T 和工具栏对不上，换工具不刷新 → 已修（`901d4e3`）

- `SelectionOverlayWindow.OnKeyDown`（L1338 起）里 `case A when !control` 排在 `case A when !control && HasSelection` 前面，**A 永远选箭头**：「A 向下、Shift+A 向上自动滚动长截图」走不到，长截图里「被鼠标打断后按 A 继续」也就没机会用。
- 工具栏悬停提示写「文字（T）」，但 T 是截图翻译；**文字工具没有键**。
- R / A / B / M / V 只改了 `_tool`，没调 `UpdateToolbarChrome()` / `Invalidate()`：按键换了工具，工具栏上高亮的还是原来那个（点按钮的那条路是对的）。
- `P` 不看修饰键，Ctrl+P 也会钉图；方向键不能挪选区（mac 有：1 点 / Shift 10 点）。
- **建议**：工具键照 mac 改成数字（1 矩形、2 箭头、3 画笔、4 文字、5 马赛克……），把 A 还给自动滚动、T 还给截图翻译；按键换工具和点按钮走同一个方法；P 只认不带修饰键的；方向键挪选区。改完同步 `Settings/ShortcutsSheet.cs` 的「截图 · 标注」「截图 · 出图」两组和 `HANDTEST`。

### R40（P3）翻译历史里的键 → 已由 PLAN-v9 翻译 8a–8e 修掉（Shift+Tab、Ctrl+Delete、Ctrl+H/W/P 走根按键；PLAN-v11 第 3 批核对过）

- `TranslateWindow`：Ctrl+H 只挂在原文框上，历史打开后焦点在历史的搜索框里，**按 Ctrl+H 回不去**（L596 的注释说「再按一次回来」）；Ctrl+W、Ctrl+P、Ctrl+1–9 在历史里也不响应。
- `RefreshHistory` 里读 `Shift + Tab` 来筛收藏（L633），但没有哪个按键处理会在 Shift+Tab 时调它，等于走不到（mac 是 ⇧Tab 在 全部 / 收藏 之间切）。
- 历史里的 Delete 只看光标在不在末尾，没看有没有选中文字（剪贴板那边两样都看）。

### R41（P3）几处按键和说明对不上 → 第一条已写（`53d609e9`）；其余三条 PLAN-v11 第 3 批（设置窗 Esc 不做，见那一节）

- 剪贴板的 Ctrl+K 操作面板里按 Enter 只是把焦点挪到第一个匹配的按钮，**不执行**（L1862）；mac 是直接执行第一项。
- 钉图文件头说「右键菜单同这些」，菜单里少了快速保存和恢复 100%。
- `OverlayWindow.cs` 文件头说浮层按 Esc、Ctrl+W 收起，启动器不认 Ctrl+W。
- 设置窗没有返回（mac 有 ⌘[），也不能 Esc 关；要不要做你们定，做了同步速查表的「设置窗」一组。

### R42（P1）启动器第一次搜索时，在 UI 线程上把浏览器的库整个拷一遍 → 已修（`41bb4286` 启动器 7a–7d：线程池里读、换快照、10 分钟看一次文件变没变）

- `Launcher/LauncherModel.cs:56,70`：每次搜索都调 `BookmarkIndex.Load()` / `HistoryIndex.Load()`。第一次是真读：`Launcher/LookupServices.cs:425` 起，每个浏览器的每个配置都 `CopyWithWal`（:379），把 `History` / `places.sqlite` 整个拷到临时目录，再开库查，全在 UI 线程上。用久了的 Chrome `History` 有几十到几百 MB，拷完之前启动器是卡住的。
- 读过一次 `_loaded` 就一直是 true：新加的书签、新的浏览记录要等重启才搜得到。
- `HistoryIndex` 和 `BookmarkIndex` 的浏览器表、`Search` 方法是一字不差的两份。
- **建议**：
  - 第一次打开启动器时（或者启动后空闲时）在线程池里读，读完换成一份不可变的快照，回 UI 线程刷新当前结果；没读完之前其它结果照常出。
  - 之后按文件的修改时间在后台重读（隔 10 分钟看一次就够）。
  - 两份浏览器表收成一份。PLAN-v9 的 V1 要给每家浏览器加开关、加 Firefox 书签，一份好改。
  - 默认读不读浏览历史、读哪几家是 V1 的事。这一条只管两件：别卡住，能刷新。
- **验收**：日志记读库的耗时和线程（`history.load ms= thread=`），本机 `History` 有多大写进报告；打开启动器后第一次输入到列表出来，前后各量一次。

### R43（P1）长截图：每 600 ms 在 UI 线程上抓所有屏，再把整张长图重新分配、重算一遍 → 拼接那一半已写（windows-next，审查方，待编译）：Core 的 `ScrollCanvas` 存条带，`ScrollCanvasTests` 和逐帧整张拼逐像素比；**只抓选区那块屏、找重叠挪进线程池归你们**（D5，抓屏）

- `Screenshot/ScrollingCapture.cs:141`：每一拍都 `ScreenCapture.CaptureAll()` 抓全部显示器的整屏，只用选区那一块。
- `KittyTools.Core/ScrollStitcher.cs:53` 的 `Append(_current, frame)`：`Skip`、`Combine`、`Prepend`（:189 起）各新分配一份**整张**长图，再 `new ScrollFrame`；构造函数（:11）把整张图每一行重新哈希一遍。
  - 长到 1440 × 30000 时一份 172 MB。有吸顶栏时一拍要分配三份、哈希三遍，全在 UI 线程上。
  - 拷贝量随长度平方涨，峰值是成品的 2–3 倍，还会反复撑大大对象堆。STATUS「长截图内存峰值没测」说的就是这里。
- **建议**：
  - 只抓选区所在的那块屏，或者只 BitBlt 选区那一块。
  - 拼接改成条带：已经拼好的部分存成一串条带，外加最后一帧（带行哈希）。每拍只拿最后一帧和新帧找重叠、追加一条；`Complete` 时合一次。吸顶栏照现在的规则，最后放回一次。
  - 找重叠放到线程池，结果回 UI 线程。
  - `Stitch`（:237）的接口和现有单测（`PlanV3Batch6Tests`）的期望值不变；加一个单测：条带拼出来的和现在逐帧拼的逐像素一样。
- **验收**：Core 单测里 200 帧、1440 宽的合成样本，新旧两种拼法结果一致，两种的分配量（`GC.GetAllocatedBytesForCurrentThread`）写进报告；真机拍一张 20000 px 的长图（测试窗口，别拍用户的内容），拍的过程中专用工作集的峰值、每拍 UI 线程的耗时，前后各量一次。

### R44（P1）每保存一次设置，设置窗就在后台整页重建一次 → 已写（`53d609e9`，审查方，待编译）

- `Shell/ShellRuntime.cs:1021` 的 `OnSettingsChanged`：热键比过签名，但后面 :1036–1039 不管改了什么，每次都 `Theme.ApplyAccent()`（新建强调色那一组资源），再 `_settingsWindow?.RefreshTheme()`。`Settings/SettingsWindow.cs:202` 的 `RefreshTheme` 无条件 `BuildPage(_currentPage)`。
- `SettingsService.Save()` 全仓 72 处调用，很多和设置窗无关：
  - 每次截图记上次区域（`Screenshot/ScreenshotSession.cs:513`）；
  - 翻译浮窗收起时记位置和宽（`Translate/TranslateWindow.cs` 里 7 处）；
  - 录音（`Recording/AudioHost.cs:121,177`）、录制条的开关、同步写网页搜索……
- 设置窗关掉只是隐藏（R34），所以打开过一次以后，后台每存一次设置就重建一整页。当前页是「关于」时，还要在 UI 线程上 `iconTask.Wait(500)`（:1973）。
- **建议**：
  - 照热键那样比签名：外观、强调色、功能开关真的变了，才 `ApplyAccent` / `RefreshTheme`。
  - 设置窗不可见时只记一个「脏」，下次显示再建。
  - `ApplyFeatures`、`TranslateHost.ApplyCopyTranslate` 也看一下：没比过的照这个办。
- **验收**：打开设置窗再关掉，截 10 次图，`BuildPage` 次数是 0（加一行 Debug 日志数）；在设置里换强调色、换外观、关一个功能，照样立刻生效。

### R45（P2）流式翻译：每来一段，UI 线程就把所有卡片和窗口高度重算一遍 → 已写（windows-next，审查方，待编译）：流式片段合并成 33 ms 刷一次，换状态照旧当场刷；读流还在 UI 线程（ponytail）

- `Translate/TranslateCoordinator.cs:206–213`：每个流式片段都 `card.Text = piece` → `Changed?.Invoke()`。全仓没有一处 `ConfigureAwait(false)`，读流、解析 JSON 的续延全回到 UI 线程。
- `Translate/TranslateWindow.cs:936` 的 `OnCoordinatorChanged`：**所有**卡片 `Update`、`RebuildFooter`、`RefreshTranslateButton`，再 `ResizeToContent` 两次（一次当场、一次排队）。
- `KittyTools.Core/StreamingText.cs:17` 的 `Visible`：每次都 `_raw.ToString()` 拼整段，再 `Trim`。
- 长译文是平方级的；同时开几个大模型服务时，每秒几百次。
- **建议**：读流、累积放线程池，UI 合并成 33 ms 刷一次，只刷变了的那张卡；高度只在这一拍里文字行数变了时才重量。
- **验收**：一个大模型服务译 2000 字，生成期间进程 CPU（% 单核）和 UI 线程每拍耗时，前后各量一次；PLAN-v7 第 4 批「生成中 < 3% 单核」的那个数一起报。

### R46（P2）剪贴板后台识字：大图不缩、失败不记、跨线程读列表 → 已写（`53d609e9`，审查方，待编译）

- `Clipboard/OcrQueue.cs:107`：`GetSoftwareBitmapAsync` 整张解码、不缩放，一张 1440 × 30000 的长截图约 172 MB。截图那边的 `Screenshot/OcrService.cs:55` 已经按 `OcrEngine.MaxImageDimension` 先 `Fit` 了，这里没有。
- 失败的只记在内存的 `Failed`（:15），下次启动又整张解一遍、又失败。
- `PumpAsync` 是 `Task.Run` 起的（:25、:29），在线程池上调 `store.PendingOcr()`（:50），遍历的是 UI 线程正在改的 `_items`。
- **建议**：解码时用 `BitmapTransform` 缩到上限以内（或者走 `OcrService` 那个 `Fit`）；失败的落库成空串，不再重识；待识的那一条回 UI 线程去取（`_dispatcher.TryEnqueue` + `TaskCompletionSource`）。
- **验收**：复制一张 1440 × 20000 的图，识字期间专用工作集的峰值前后各量一次；重启后日志里同一张不再出现 `ocr.image-failed`。

### R47（P2）每日备份在线程池上读 UI 线程的列表和数据库连接 → 已写（`53d609e9`，审查方，待编译）

- `Shell/ShellRuntime.cs:852` 的 `ScheduleBackup` 在 `Task.Run` 里调 `ArchiveService.BackupDaily()`。它在 `Storage/ArchiveService.cs:111` 读 `ClipboardStore.Items`（UI 线程在改的 `List`），又调 `TranslationHistory.Search`（:134），用的是只许 UI 线程用的 `Database.Connection`。
- 碰上那一刻在复制东西，枚举会抛「集合已修改」，当天那份就没备成；数据库连接跨线程用，是没定义的行为。
- **建议**：要备份的数据（收藏的片段、收藏夹、生词本、设置）在 UI 线程上取成快照，序列化、加密、写文件放线程池。
- **验收**：单测或者 `--backup-now` 调试参数：一边每 10 ms 往剪贴板库里加一条，一边备份 20 次，全部成功。

### R48（P2）UI 线程上几处同步的图片活 → 第一条已写（`53d609e9`）；另外两条 PLAN-v11 第 3 批已写（没编译）

- `Screenshot/PinWindow.cs:313`：钉图「复制」直接 `WriteImagePng(_png)`，没带转好的 DIB，于是走到 `Clipboard/ClipboardWriter.cs:121` 的 `Task.Run(...).GetAwaiter().GetResult()`，在 UI 线程上干等 PNG → DIB（那里的注释自己写了大图要几百毫秒）。别的入口都先 `await PrepareImageAsync`。
- `Clipboard/ClipboardStore.cs:389` 的 `RecordImage` 算一次 SHA-256，`:426` 的 `Images.Save` → `Clipboard/ImageStore.cs:22` 同步 `File.WriteAllBytes` 整张 PNG（单张上限 128 MB），再算一次 SHA-256（返回值没人用）。复制大图、截图、钉图、从历史复制都会走到。
- `Clipboard/ClipboardPanel.xaml.cs:247`：选中的还是同一条、同一个位置，也调 `ShowPreview` 整个重建（:737），图片重新从盘上解码。搜索时第一条不变的每一次按键都会这样，OCR、同步带来的 `Store.Changed` 也会。
- **建议**：钉图复制改成先 `await PrepareImageAsync`；`ImageStore.Save` 不再算哈希，哈希和写盘挪进 `ClipboardService.SaveImageAsync` 已有的那个 `Task.Run`；`ShowPreview` 记住上次显示的那一条和它的版本，一样就直接返回。
- **验收**：钉一张 4K 截图，按复制，UI 线程卡多久前后各量一次；复制一张 20 MB 的图，`RecordImage` 在 UI 线程上的耗时前后各量一次。

### R49（P2）同步每 20 秒全量跑一轮，什么都没变也照跑 → 已写（windows-next，审查方，待编译）：`SyncDisk.Fingerprint` + 本机改动计数，都没变就跳过这一轮；`SyncRows(retainedOnly)`

- `Storage/SyncFolder.cs:218` 的定时器每 20 秒 `RoundAsync`，`KittyTools.Core/Sync/SyncRunner.cs:64` 起：把文件夹里所有设备、所有类别的文件读进来，整份解码、合并，再编回去比较，没有「上一轮以来什么都没变」的短路。
- UI 线程上每轮还有两件事：
  - `Clipboard/ClipboardStore.cs:65` 的 `SyncRows()` 给全部文本条目各建一个 `SyncClipRow`，到 Core 里才按「留着的」过滤；
  - 账本先解码一次，再 `SyncLedgerText.Encode` 编回去比较一次。
- **建议**：记下每个文件的修改时间和大小，再给本机四类数据各记一个修订号（改一次加一）；都没变就跳过这一轮。`SyncRows` 先按 `IsRetained` 过滤。只改 Windows 的执行层，文件格式不动。
- **验收**：开着同步静置 10 分钟，进程 CPU 和每轮耗时前后各量一次；R26 的集成测试照样全过。

### R50（P3）日志：每写一行开关一次文件，跨天不换文件 → PLAN-v11 第 3 批已写（没编译）

- `App/Log.cs:58`：每行都 `File.AppendAllText`，在调用方的线程上开、写、关一次文件（大多是 UI 线程；装了杀毒软件的机器上每次几毫秒）。
- 文件名在 `Initialize`（:18）时就定死了，7 天清理也只在启动时跑：常驻托盘的进程几周不重启，就是一个越写越大的文件，清理也不跑。
- **建议**：一个后台队列 + 常驻的 `StreamWriter`（退出、崩溃记录时 flush）；写之前看一眼日期，变了就换文件，顺手清理。
- **验收**：单测或调试参数：把钟拨过午夜，新的一行进新文件；连写 1 万行的耗时前后各量一次。

### R51（P3）几处小的 → PLAN-v11 第 3 批已写（没编译；保留规则改 long 那条不做）

- `Shell/OverlayWindow.cs:96`：每固定一次面板，都给复用的 `_foregroundTimer` 再挂一个 `Tick`，从不摘。固定 N 次以后，每 400 ms 跑 N 遍。只在建计时器时挂一次。
- `Shell/Paster.cs:151` 的 `SendLeft`：片段里 `{cursor}` 往回挪时，每挪一格就一次 `SendInput` + `Thread.Sleep(8)`，上限 500 格，最多在 UI 线程上冻 4 秒（`Clipboard/ClipboardPanel.xaml.cs:1333` 调）。一次 `SendInput` 把 2 × N 个按键发完；真有程序吃不住，再分成 50 个一组。
- `Clipboard/LinkPreviewService.cs`：
  - 最多 12 条连同头图字节（单张上限 4 MB）一直留在内存里，文件头说空闲时会丢，其实没注册 `IdleReclaimer`；
  - 每取一个网页都新分配 512 KB（:46）；
  - 找 `</head` 时每读一块都从头扫（:57）。
  
  建议：注册空闲回收，缓冲用 `ArrayPool`，只扫新读进来的那一段（往回多看 5 个字节）。
- `Storage/TranslationHistory.cs:357` 的 `Find` 按 `source, target_lang` 查，但只有 `WHERE favorite = 1` 的部分唯一索引（`KittyTools.Core/Schema.cs:79`），非收藏的要全表扫。`Add`、`SetFavorite`、`AdoptFavorites` 都调它。Schema 加一步，建普通索引 `(source, target_lang)`。
- `Recording/RecordingHost.cs:247` 和 `Recording/AudioHost.cs:194` 的闪退恢复：跑在启动路径的 UI 线程上，`Mp4Remux.TryRemuxWithTimeout` 同步等重封装。挪到线程池，做完回 UI 线程弹提示。
- `Clipboard/ClipboardPanel.xaml.cs:1091`：文件条目的预览在 UI 线程上，对最多 50 个路径各调一次 `File.Exists`、两次 `Directory.Exists`；路径在断开的网络位置上时，每个都能卡好几秒。先画出来，存在性放后台查，查完回来改图标和透明度。
- `Clipboard/ClipboardStore.cs:697–705`：每复制一次，都给全部条目建 `RetentionItem`，每条一个 `Id.ToString()`，后面 `doomed.Contains(item.Id.ToString())` 又转一遍。保留规则直接用 long。
- `Clipboard/ClipboardStore.cs:752`：第一次搜索后每条都缓存一份 UTF-8 折叠副本 `Folded`，等于全部文本再存一遍；空闲回收（`ClipboardPanel.xaml.cs:109 ReleaseCaches`）不清它。空闲回收时一起置空（重建只是一次冷搜，0.5.0 量过 5.7 ms）。

### R52（P3）死代码和重复代码 → PLAN-v11 第 3 批已写（没编译；飞入卡按卡片大小解码留给你们量）

- 全仓（含测试）只剩声明、没有调用的：
  - `Shell/Motion.cs:156 HeightChange`；
  - `Screenshot/ScreenshotOutput.cs` 的 `PngAsync`、`CopyAsync`、`QuickSaveAsync`、`SaveAsAsync`（:19 / 26 / 53 / 91，都被带 Png 的版本取代了，只剩互相调）；
  - `Storage/Sqlite.cs` 的 `BindBlob`、`GetBlob`；
  - `Shell/Ui/ListHighlight.cs` 的 `GlideTo`、`HideHighlight`，`Shell/Ui/SearchLine.cs` 的 `FocusBox`；
  - `Translate/TranslateServices.cs IsBuiltin`、`Shell/Theme.cs KindTint`、`Storage/SyncDevice.cs NextCounter`、`App/HotKeyDefaults.cs ResetBinding`、`Shell/Paster.cs SendHotkey`、`Shell/Speech.cs TagFor`、`Storage/ArchiveService.cs BackupFiles`；
  - `KittyTools.Core/AudioRules.cs WritePcm16`、`KittyTools.Core/RegionMath.cs ApplyingRatio`；
  - 整个 `Shell/MicaBackdrop.cs`（`MicaThemeBackdrop` 没人用，设置窗是 `SystemBackdrop = null`）；
  - `KittyTools.Core/LauncherCommands.cs:133 NetstatOutput`：R18 之后只剩 `PlanV3Batch5Tests.cs:88–95` 在测它，连测试一起删。
  - `App/Settings.cs:81 TranslateReplaceHotKeySeen`：第三版 §3.2「划词翻译并替换」的热键动作一直没做，这个字段也没人读。PLAN-v9 的 F1 要是做了，就留着用。
- 重复：
  - 「`byte[]` → `BitmapImage`」写了 6 份：`PinWindow.cs:94`、`ScreenshotCard.cs:380`、`LauncherPanel.xaml.cs:845`、`SettingsWindow.cs:2458`、`ClipboardPanel.xaml.cs:1074` 和 `:1518`（这一份还在 UI 线程上 `GetResult()`，流也没 Dispose）。`Clipboard/ImageCodec.cs:193` 已经有一个私有的 `ToStreamAsync`，放开它，收成一个 `ImageCodec.ToBitmapAsync(bytes, decodeWidth)`。
  - 「留着的条目」的规则 `IsRetained` 写了三处：`ClipboardStore.cs:151`、`KittyTools.Core/Sync/ClipSync.cs:25` 和 `:159`，留 Core 那一份。
- 截图飞入卡（`Screenshot/ScreenshotCard.cs:380`）整张解码：卡片最后只有 200 × 140 DIP，一张 1440p 截图解出来约 14.7 MB，和 STATUS 里「截图后 +18 MB」量级接近。上面那个公用方法加了 `decodeWidth` 以后，先量一下按卡片大小解码能省多少、飞入开头几帧会不会发糊，再决定用不用。

### R24（P1）第 2 批的音画同步是对着一张不动的画面量的，要重做 → 探针已重写（`f07feaa`，审查方）；2026-11-03 Windows 重测：还没过；2026-11-04 逐帧解码查出录制的时间戳问题、修了（`989cd77`），验收卡在测试图案这把尺上（见本条末尾）

**复查（2026-10-26 晚）**：这一条还没动。重做的时候，顺手把 R23 的重封装耗时（60 s、10 分钟的文件各一次）一起量了，写进同一份报告。

- 报告里写了：「测试图案窗口在 HUD 起来后被这台机器限帧（WGC 只收到 1 帧），视频靠补帧」。60 s 的文件只有 1.6 MB，也说明画面没动。这样「提示音的起点和闪白那一帧差 < 50 ms」根本没法验。CPU 9.2% 也不能算数，因为编码器一直在编同一帧。
- **先查为什么只收到 1 帧**。日志里有 `_arrivedFrames`，对比 HUD 出来之前和之后。怀疑方向：
  - HUD `Activate()` 抢了焦点，测试窗口的动画停了（R22 修好后再看）；
  - 测试窗口被 HUD 盖住的部分 DWM 不更新。
  
  测试窗口要保证一直在画：用 `CompositionTarget.Rendering` 驱动，并在日志里记它自己画了多少帧。
- **录制时的内存**：第 1 批 142 MB、第 2 批 192 MB，用的是 `Process.WorkingSet64`（总工作集，包括映射进来的显存和共享页），不是 §0 规定的专用工作集。
  - 换成专用工作集重新量。
  - 还超过「比录之前多 40 MB」，就把帧池从 4 张改成 2 张（PLAN 写的是 2），再列出剩下的是谁占的。
- **重做第 2 批的验收**，画面要一直在动：
  - 第 1 s 和第 60 s 的音画差都 < 50 ms；
  - 中间静音 20 s 后照样同步；
  - 抽第 1、30、60 s 的帧，测试窗口上的帧号是连续的；
  - CPU 按 Release AOT 量。

**进展（--sync-probe）**：测试图案 10 秒带系统声音，第一次样本闪白 0.417 s / 提示音 0.430 s（差约 13 ms），但 10 秒重测时 AudioWavProbe 仍把系统声音里的其它声音当成提示音（0.333 s 对 0.180 s，差 153 ms），**还不能据此下 < 50 ms 的结论**；试过 Goertzel 1 kHz 频段能量，系统声音里的峰值只有 0.094，仍分不干净，实验代码已回退（不影响产品）。60 秒无音轨文件 1812 帧 / 13.1 MB / 重封装 78 ms，专用工作集约 192 MB。还没做第 60 秒的逐帧差、20 秒静音后同步、10 分钟重封装。

**审查方在 Mac 上改了探针（没编译过）**：13 ms 和 153 ms 两个数都不能用——测试图案的闪白按渲染计数走（`_frameCount % 60`，而且计数是 30 Hz 加一，实际两秒才闪一次），提示音是另一个 MediaPlayer 循环放的 7 秒文件，**两边没有共用的钟**，量出来的差只是两个钟碰巧差多少。改成：

- `TestPatternWindow`：闪白每一拍（60 Hz）看提示音的 `PlaybackSession.Position`，落在每秒前 100 ms 就亮，暂停时不亮；右上角加 16 格条码（更新计数，按画布宽高的比例摆，读的时候不用知道 DPI）；时钟文字改用 Stopwatch；日志 `test-pattern.second` 记 updates / renders 两个数。
- `--sync-silence`（配 `--record-test` ≥ 45）：第 20–40 秒暂停提示音，这 20 秒系统声音回环一个包都不出。
- 提示音只认 1 kHz：`Core/AvSync.ToneOnsets`（Goertzel，10 ms 窗、2.5 ms 一跳，起点误差几毫秒）。和你们回退掉的那版不一样的地方：不看绝对峰值（系统音量低时提示音只有 0.094），看「1 kHz 的能量占这个窗口总能量的比例」，超过 0.3 就算响，起点按比例除以后面 10 ms 里的平台值往回推，所以底下一直有别的声音也不偏。单测三条：很响的 440 Hz 不算；提示音峰值 0.094、底下一直有 rms 0.045 的几个音加噪声，三声都找到、误差 < 4 ms（同样的算法先在 Python 里对过，误差约 1 ms）；配对 / 静音段 / 条码。量的时候照样把别的放声音的程序关掉。`AudioWavProbe` 改用它，`Result.Onsets` 给出每一声的起点。
- `VideoFlashProbe` 换成 `SyncProbe`：扫整个文件的每一次闪白（1/15 s 粗扫、1/60 s 往回找起点），和每一声逐个配对（`AvSync.PairUp` / `Summarize`），日志 `sync.pair`、`sync.summary`（第一对 / 最后一对 / 静音后第一对 / 平均 / 最大）；再在第 1、30、最后一秒连着抽 10 帧读条码（`sync.frames … continuous=`）。视频按帧取样，单个差带着最多一帧的误差，所以**量的时候录 60 fps**。
- 录制中的内存改成专用工作集（`MemoryProbe.PrivateWorkingSetMb`，日志 `wgc.mem private=`、`wgc.stats privateDelta=`）；192 MB 已经是专用工作集、比录之前多一百多 MB，按本条的规矩帧池 4 → 2。
- `Mp4Remux.TryRemuxWithTimeout` 不给秒数时按文件大小放宽（5 s 起、每 100 MB 加 1 s、最多 60 s），10 分钟的文件不会因为固定 5 s 误判超时、退回分段 MP4。

**要做（Windows 上）**：先编译、跑 `AvSyncTests`；然后

```powershell
KittyTools.exe --record-test=65 --record-fps=60 --sync-silence     # Release AOT
KittyTools.exe --sync-probe=<上一步的 mp4>
KittyTools.exe --record-test=600 --record-fps=30                     # 看 record.remux 的耗时
```

报告写 `sync.summary` 整行（验收：第一对、最后一对、静音后第一对都 < 50 ms，`passed=True`）、三行 `sync.frames`（都 `continuous=True`）、`wgc.stats` 的 CPU 和 `privateDelta`（目标 ≤ 40 MB）、60 秒和 10 分钟两次的重封装耗时。`passed=False` 时把 `sync.pair` 贴出来，看是固定偏移还是越走越偏。

**Windows 重测（2026-11-03，PLAN-v11 第 4 批）→ 还没过，探针本身又查出一个问题，剩下的要逐帧解码才定得了**：

1. 第一次跑 `passed=False`，`flashes=4 beeps=2`：`%TEMP%\kitty-test-1khz.wav` 是 10 月 26 日旧版本留下的 **83 ms** 文件，`EnsureTone` 见文件在就不重写——循环放起来一直在响、`Position` 一直落在前 100 ms 里、闪白一直亮。**修了**：长度不对就重写（`TestPatternWindow.EnsureTone`）。
2. 修好后（Release AOT，`--record-test=68 --record-fps=60 --sync-silence`，再用 Debug `--sync-probe`）：
   ```
   sync.summary pairs=42 flashes=42 beeps=49 first=-7ms last=-177ms afterSilence=-94ms mean=-116ms maxAbs=227ms fps=57.6 passed=False
   sync.frames at=1.0s  numbers=233,233,233,233,235,237,239,241,243,245 continuous=False
   sync.frames at=30.0s numbers=3669,3671,3671,3673,3675,3677,3679,3681,3683,3685 continuous=True
   sync.frames at=67.0s numbers=8112,8114,8114,8116,8118,8120,8122,8124,8126,8128 continuous=True
   wgc.stats cpu=18.3%single privateDelta=29.1MB private=111.3MB wall=68.7s arrived=4091 accepted=4091
   ```
   `sync.pair` 不是固定偏移、也不是一路越走越偏，是**锯齿**：提示音在音轨里严格 1.000 s 一声（x.176、x.189 s，静音 20 s 前后各自整齐），闪白在视频里 1.03–1.07 s 一次，一圈越拖越晚（−7 → −35 → −85 → −152 → −185 ms），约 7 秒跳回来一次（14.2 s 处 −18 ms），刚好是提示音 WAV 循环的长度。
3. 先以为是 `PlaybackSession.Position` 更新得粗，试了两种闪白的钟（两次更新之间按 Stopwatch 往前推；只在开始播放那一刻对一次表、之后全按 Stopwatch）：**结果几乎一样**（第二种 `first=15ms last=-192ms maxAbs=225ms`），所以不是测试图案的钟，两处试验都撤了。
4. 剩下两个嫌疑，现有工具分不开：(a) 录下来的视频时间戳在一圈里被拉长、再跳回；(b) 探针用 `MediaComposition.GetThumbnailAsync(NearestFrame)` 按时间取帧，取到的不是那一刻的帧（帧号条码在第 1 秒连着 4 张一样、别处偶尔跳 4，像是取帧不准）。要定，得按顺序解码每一帧、拿每帧自己的时间戳去找闪白（Media Foundation `IMFSourceReader`，`Mp4Remux` 里已经有一半），这次没做。
5. 其余几项：CPU 18.3% 单核、`privateDelta` 29 MB（目标 ≤ 40 MB，过）；音频 `loop=4091` 包、没断。60 s 的重封装 219 ms。
6. **10 分钟那次查出一个 0.1.0 就有的大问题，修了**：`--record-test=640 --record-fps=30`（带系统声音）存下来的文件**只有 1 分 30 秒**。`Mp4Remux.TryRemux` 的防死循环上限是「时间戳超过 9 亿（100 ns 单位 = 90 秒）或 20 万个样本就停」，停了还照样 `ok=True`，调用方接着把整段分段临时文件删了——**超过一分半的录屏和录音（`AacAudioWriter` 也走它）都只存下前 90 秒**。改成 24 小时 / 两千万个样本，撞上了算失败（调用方保留整段分段 MP4）。修后再录：9 分 50 秒、103 MB，存下来 9:49；重封装 **1 203 ms**（45 302 个样本）；CPU 21.5% 单核，`privateDelta` 41.5 MB（比目标多 1.5 MB）。
7. **第 1 批「关机时的重封装」接着量**：上面那次是在第 590 秒发 `WM_ENDSESSION` 停的：整个处理 **1 282 ms**。按每分钟约 120 ms 推，录到四十分钟左右才会碰到约 5 秒的门槛；那时候系统会出「这个应用阻止关机」的界面、能点「仍要关机」（被结束的话临时文件还在，下次启动恢复）。**这一版不改**；要改的话录得长的时候关机先不重封装、留给下次启动的恢复，或者先 `ShutdownBlockReasonCreate` 写一句「正在保存录屏」。

**PLAN-v11 第 7 批接着查（2026-11-04，Windows）→ 录制的时间戳问题修了（`989cd77`）；验收还是没过，卡在测试图案这把尺上**：

1. `SyncProbe` 改成逐帧解码（`Recording/VideoFrames`，按顺序解每一帧、用它自己的时间戳），不再用 `GetThumbnailAsync` 按时间取帧。拿 11-03 那两段 68 秒的录像重量：锯齿一样（`first=10ms last=-160ms`、`first=-2ms last=-175ms`）——**不是取帧的问题**。
2. 查出**录制的问题**：`WgcRecorder` 文件头写着「时间戳用 SystemRelativeTime」，实际是 `nextWrite` 一格一格往后排、没用帧的抓取时间；帧来得比帧率慢（60 fps 实际 57 帧）时视频时间比真实时间走得慢、越拖越晚，落后 5 帧以上再整个跳到现在。音轨按 QPC 是准的。**修了**：`RecordingPipeline.FrameTime`——抓取时间（SystemRelativeTime − 开录时刻，和音频同一个 QPC 钟）往下对齐到帧率的格子、保证递增。单测：57 帧 / 秒连录 60 秒，最后一帧和真实时间差不到一格（以前落后约 3 秒）。
3. 修后再录（Release AOT，`--record-test=68 --record-fps=60 --sync-silence`）：锯齿还在（`first=-76 last=-169 afterSilence=-52 maxAbs=236 passed=False`）。闪白一次比一次晚约 50 ms、每 6–7 秒跳回来，和 WAV 循环的周期一样：每一拍读 `PlaybackSession.Position` 算闪白，这个位置比真实播放慢约 5%、每次循环才对齐。
4. 测试图案改了三处（都留着）：闪白改成开播 / 恢复后对一次表、之后按 Stopwatch；文字和计数按时间 30 fps 更新（以前每两拍一次，这块屏是高刷，`Rendering` 一秒约 235 次，一秒排版一百多次）；条码下面加一排「真钟」（Stopwatch 的百分之一秒），`SyncProbe` 报 `sync.clock`（时间戳减真钟）并把每一帧写成 `<录像>.frames.csv`。
5. 再录两遍：`sync.clock` 显示**测试图案自己的画面一段一段地滞后**——时间戳减真钟在 ±100–200 ms 的台阶之间跳（5%–95% 区间 −173…+150 ms），长期斜率 0.997（时间戳本身跟着真实时间走）；`sync.summary` 例：`first=42 last=-81 afterSilence=35 maxAbs=215 passed=False`。又试了闪白放到合成线程上跑 1 秒一圈的循环动画：按真钟量是 1.04 秒一圈（这台机器上 WinUI 合成器的动画钟也不准），更糟，撤了。
6. 结论：录制这一侧现在视频、音频都按 QPC 打时间戳；**这个 XAML 测试窗口当不了 50 ms 的准尺**（UI 线程画的东西会滞后两三百毫秒再追上，合成线程的动画钟又偏 4%）。要过验收得换一个不经过 XAML 的测试源：比如一扇 D3D 交换链窗口，按 QPC 在同一时刻 Present 白帧、用 WASAPI 直接放一段提示音（两边同一个钟，不经过 MediaPlayer），录它。这次没做。
7. 其余：68 s 1440p60 录制 CPU 10.9–40.9% 单核（几次不等，测试图案本身在抢）、`privateDelta` 33–41 MB、重封装 203–219 ms。

### R31（P1）0.7.0 的包是在「设置窗一打开就崩」修好之前打的，要重打；打包时加启动冒烟 → 已修（`5db1e8f`）

**进展（`b10cbce`）**：新增 `--smoke`（设置六页、剪贴板 / 启动器、翻译、截图遮罩、录音待录条），
`build-release.ps1` 解压 x64 zip 后跑，非 0 就失败；0.7.0 已重打（x64 `dd9652c0…` / arm64 `96af0e90…`），
x64 包冒烟通过。设置窗的 Mica 在 Release AOT 下会抛 `ArgumentException`，已改成不透明卡片底；
关于页卡住的原因是 `ShellIcons.LoadPng` 在 Release AOT 下不返回；改成后台线程 + 500 ms 超时后，**七页冒烟全过**。

- `cea27773` 16:21 打的 0.7.0。设置窗崩溃 16:22（`7ec18c5e`）、16:45（`d1c697c8`）才修好，`d1c697c8` 里也写了「0.7.0 包里……真机已复现」。所以 `windows/build/release/0.7.0/` 里的 zip 一打开设置就退出。之后没看到重打。
- 更要紧的是这个崩溃怎么漏过去的：从 `877cdf17` 到 `7ec18c5e`，中间八九个提交，每个都写着「测试全过、AOT 零警告」，可是设置窗根本打不开。单测和编译管不到「界面能不能打开」。

**修**：
1. 加一个 `--smoke` 参数：依次打开设置窗（七页都切一遍）、剪贴板面板、启动器、翻译浮窗、截图遮罩（打开后马上取消）、录音控制条（待录状态，不真录），每个停 1 s。全部没崩就退出码 0；有崩溃记录或者异常就非 0，并打印是哪一步。
   - 用 `KITTY_PROBE_PROFILE` 那一套独立数据，不碰真实数据、开始菜单和托盘名。
2. `build-release.ps1` 打完 zip 后，解压到临时目录，用 `--smoke` 跑解压出来的 exe。不是 0 就打包失败、删掉产物。
3. 每批的自查清单（`AGENTS.md` 第 2 条）加一句：Release 发布物跑一次 `--smoke`。
4. 用当前代码重打 0.7.0，`STATUS.md` 写新的 sha256。

**验收**：故意把 `Kitty.CardStyle` 改回同名，`build-release.ps1` 要失败，并指出是设置窗那一步；改回来再过。

### R32（P1）翻译服务同步：mac 会写 `"usesDeepLX": false`，Windows 读到会把整类停住 → 已修（`8ce539d`）

- `6ebe6041` 报告里的疑问：「mac TranslateService 的编码没有源码可对：usesDeepLX 只在 true 时写」。审查方查了 mac 源码：
  - 翻译服务同步的就是 `TranslateService` 这个结构本身，用的是合成的 `Codable`：可选字段是 nil 才不写，`false` 和 `""` 照写。
  - mac 设置页里 DeepL 的「接口」切换用的是 `Binding(service.usesDeepLX, default: false)`，写回去的是值本身。用户切到 DeepLX 再切回「官方 API」，存下来的就是 `usesDeepLX: false`，`baseURL` 可能是 `""`。
  - 新建的 AI 服务，`model` 和 `baseURL` 都是 `""`。
- 所以 Windows 落地时对每个可选字段都要分清三种情况：没写（nil）/ `false` 或 `""` / 有值，再编回去要一模一样，不然 decodeExact 不过，整类停在「读不懂」。
- **审查方补了**：
  - `reference/mac-sync/TranslateService.swift`（结构原文）；
  - `sync-golden.json` 里 8 个 `kind: "service"` 的样本（用 mac 真正的结构编出来核对过，逐字节一致）：智谱、Google、DeepL 官方（`usesDeepLX:false`）、DeepLX、DeepL 切回官方且地址为 `""`、微软带区域、新建的 AI 服务（`model:""`、`baseURL:""`）、Anthropic。另外加了一个服务顺序的 `order` 样本。
- **要做**：
  - `SyncSourceTests.GoldenSamplesRoundTripThroughTheWindowsEncoders` 加 `case "service"`：用 `ServiceSync` 落下去再编回来，和 `json` 一字不差；
  - Windows 的服务模型里，`usesDeepLX` 改成 `bool?`，`model` / `baseURL` / `region` / `aiProtocol` 都保留 null 和 `""` 的区别（PLAN-v3 §1.5 的互通约定里补一句）。
- 审查方还改了片段样本：之前有「在收藏夹里但没收藏」的组合，mac 的不变式是在收藏夹里的一定是收藏，所以已经不会出现了。`SyncSourceTests` 里为它写的那句特殊处理可以删掉。

**修（`8ce539d`）**：`SyncService.UsesDeepLX` 改 `bool?`，encode 三态（没写 / false / true），decode 用 `FlagOrNull`；App 的 `TranslateServiceConfig` 同步改 `bool?`，DeepLProvider / 设置页按 `== true`。golden 加 service case，8 个 mac 样本全过。

### R33（P2）第七版的截图一张都没推；透明窗口用 WGC 只抓自己的窗口 → 大部分已修（`f6af9bd` / `6918be7`）

- 第七版改的全是界面（剪贴板透镜、启动器 40、轻提示、翻译浮窗、截图工具栏两段、设置侧栏色块、外观缩略图、强调色圆点），`windows-shots` 上只有 R30 那 8 张设置窗。审查方没法看效果。
- 托盘菜单、录制条、轻提示这种透明宿主窗口，`PrintWindow` 拍不到。项目里已经有 WGC 了：`GraphicsCaptureItem.CreateForWindow(自己窗口的 HWND)` 只抓这一个窗口（带透明），不会拍到后面别的程序。抓一帧存成 PNG，透明的地方铺棋盘格或纯色。
- **要做**：把 `--ui-snapshots` 扩展到所有面板和这几个透明窗口，浅色 / 深色各一套，推到 `windows-shots` 的 `0.7.0-v7/`，`STATUS.md` 里列文件名。推之前照旧逐张看，不能有别的程序。
**进展（`e5100bd`）**：`--ui-snapshots` 的启动器 / 剪贴板 / 设置窗浅深 + 翻译输入态共 7 张已推到 `windows-shots/0.7.0-v7/`；`--clip-scroll-test` 5000 条实测中位 **0.8 ms**、p95 **1.3 ms**，远低于 16 ms，不做 ItemsRepeater。12 张已交：启动器 / 剪贴板 / 设置浅深、翻译、轻提示两态、录制 HUD / 录音待录 / 截图工具栏（WGC 只抓自己窗口）；托盘菜单两态截出来是空的，还没接。

**审查方在 Mac 上补了透明窗口和截图工具栏（没编译过）**：新文件 `App/WindowShot.cs`——WGC `CreateForWindow` 只抓一扇窗口，`SoftwareBitmap.CreateCopyFromSurfaceAsync` 拿像素，裁到不透明的部分、垫 10 px 棋盘格存 PNG。`--ui-snapshots` 在翻译窗之后多出 7 张：`island-notice`、`island-error`、`shot-record-hud`（进程里临时设 `KITTY_HUD_CAPTURE=1`）、`shot-audio-pending`、`tray-menu-light` / `-dark`、`shot-toolbar`。截图遮罩用 `ScreenshotSession.StartSynthetic()`：冻结帧是 `ScreenCapture.Synthetic()` 画的深灰底加三块色块，**不抓桌面、不列窗口**，选区固定在主屏中间，图裁到选区加下面的工具栏。各窗口加了只给自检用的 `HandleForProbe`。

**要做（Windows 上）**：编译、跑一遍 `--ui-snapshots`，逐张看（尤其 `shot-toolbar` 里只有合成的底），推到 `windows-shots/0.7.0-v7/`，`STATUS.md` 列文件名。拍不到的（日志 `ui-snapshots <名字> wgc-timeout / no-item / empty`）写原因。托盘菜单的浅 / 深两张要是一样，说明宿主窗口不跟设置里的外观，记下来，第 3 批一起看。高对比度要改系统设置，不在自检里切，手测时截。

- 第七版第 2 批没做 `ItemsRepeater` + 自定义虚拟化布局，现在是 `ListView` 加变高的行。照 PLAN-v7 量一次：5000 条剪贴板按住 ↓ 连发 3 s，每次按键到画面更新的耗时，取中位数和最慢的 5%。超过 16 ms 再做虚拟化布局。

### R34（P2）截图后 +18 MB、设置窗关掉后 +10 MB：先确认会不会越积越多 → 已修（`1f03f72`）

- 报告说剩下的是 WinUI 合成层和 XAML 模板缓存的原生内存，`GC` 回收不掉。只要是「第一次用了之后多出来一块、之后不再涨」，就可以当已知上限接受。
- **要做**：内存探针加两步——截图 5 次、设置窗开关 5 次，每次之后空闲 30 s 记一个数。
  - 平的：在 `STATUS.md`「已知风险」里写清上限，代码里留 `// ponytail:`，写明升级路径（遮罩常驻复用，或者放到单独进程）。
  - 每次都涨：是泄漏，按录屏那次 D3D 设备的查法找出来。

**修（`1f03f72`）**：设置窗全进程只建一次，关闭移到屏幕外、同一页不重建 XAML 树。5 次开关实测 93.2 / 93.2 / 89.9 / 89.8 / 89.6 MB（平）；截图 5 次 86.3 → 88.6 MB（+2.3，模板缓存一次，可接受）。

### R35（P3）别按进程名结束进程 → 已修（审查方复查 `ab78ce7`：`.ps1` 和代码里只剩按 PID 结束的，`setup-e2e.ps1` 用 `Stop-Process -Id`）

- `bcd3eb7f` 报告里写了：探针被「主工作区另一个 agent 重编时按进程名结束了」。按进程名结束，会把用户正在用的那份 Kitty Tools、或者别的 agent 正在跑的测试一起杀掉。
- `AGENTS.md` 红线里已经加了一条：只结束自己起的那个 PID。两个 agent 各自查一下脚本里的 `taskkill /im`、`Stop-Process -Name`，都改掉。

### R36（P1）安装程序真机验收 → 大部分已修（`2bb2186`；截图 / 真实安装未走）

**进展（`2bb2186`）**：`SetupTests` 320 个全过；Setup 编进 slnx、零警告；x64/ARM64 AOT 零 trim/AOT，本体 2.5 MB；`build-release.ps1` 出 setup.exe（x64 31.5 MB / arm64 30.7 MB）；`setup-e2e.ps1` 七步全过。**未走**：七张对话框截图、真实安装 / 自动更新 / 设置应用的卸载。

- PLAN-setup 的代码都写完了，但 Mac 上没装 .NET SDK（用户定的），Core 单测、Setup 编译、AOT 发布、端到端一个都没跑。`KittyTools.Setup` 还**没加进** `KittyTools.slnx`，免得没编过的代码让你们每批的 slnx 构建红掉。
- **要做**（按顺序）：
  1. `dotnet test windows/KittyTools.Tests`：新加的 `SetupTests.cs`（`SetupPayloadTests`、`SetupRulesTests`）全过。
  2. `dotnet build windows/KittyTools.Setup` 编过、零警告，再把它加进 `KittyTools.slnx`（和 Core 一样，`*|x64`、`*|ARM64` 都映射到 `Any CPU`）。
  3. `dotnet publish windows/KittyTools.Setup/KittyTools.Setup.csproj -c Release -r win-x64`，再来一遍 `-r win-arm64`：**零 trim / AOT 警告**，记下 exe 大小。
  4. `pwsh windows/build-release.ps1`：每个架构多出 `KittyTools-<版本>-windows-<x64|arm64>-setup.exe` 和 `.sha256`，发布说明先讲安装包。
  5. `pwsh windows/tools/setup-e2e.ps1 -Zip <上一步的 x64 zip>`：PLAN-setup §5 的七步全过（zip 要从 `616840b` 之后打，App 才认 `quit`）。ARM64 真机没有就写「没测」。
  6. 截图，只截对话框本身（按 HWND 裁），推 `windows-shots` 的 `setup/`：安装页、选文件夹框、进度、完成、「已经装了 / 重新安装」、程序开着时的「重试」、卸载确认、已卸载（文件夹里留了别的文件那种）。用测试名跑（`$env:KITTY_SETUP_TEST_KEY = "shots"`），默认位置会落到 `%TEMP%`，不碰真实的。
  7. 不用测试名手动走一遍真的：装 →「设置 › 应用」里图标、名字、版本、大小对 → 开始菜单能打开 → 程序里自动更新（R38 修完后）→ 从「设置 › 应用」卸载。做完把机器恢复原样。
- **没编译过、最可能要改的地方**：
  - `SetupUi.cs` 的 `TaskDialogConfig` 照 commctrl.h 手写（pack(1)，64 位下 160 字节）：`TaskDialogIndirect` 返回 `E_INVALIDARG`（日志 `ui.taskdialog 0x80070057`）就是布局错了，先对 `sizeof`。
  - CsWin32 生成的名字和重载：`IFileOpenDialog` 的 `SetOptions` / `SetTitle` / `SetOkButtonLabel` / `SetFolder` / `Show` / `GetResult`，`IShellItem.GetDisplayName`，`SHCreateItemFromParsingName` 的指针重载，`CoInitializeEx(null, COINIT)`。照编译器报的改，不要换成手数 vtable。
  - AOT 下清单有没有嵌进 exe：没嵌的话找不到 `TaskDialogIndirect`（日志 `ui.taskdialog missing`），文件名带 setup 还会被系统当成要管理员权限。
  - 回调里换页（`TDM_NAVIGATE_PAGE`）后返回 `S_FALSE`；要是一点按钮对话框就关了，看 `SetupUi.Callback`。
- **和方案不一样的地方**（审查方认可，验收按这个来）：
  - `.kitty-install` 多了 `files` 数组（这次装的文件并上次记的）。§5 第 6 步要求「安装目录里多一个别的文件就不整个删」，§2.3 那四条做不到，所以「没有不认得的文件」算第五条。
  - 测试名不只换注册表键：开机启动值、互斥量、管道、凭据前缀、数据目录都和 App 的 `KITTY_PROBE_PROFILE=<同一个名字>` 对齐（`.Probe.<名字>`），端到端才能真开一个 App 再叫它退出。注册表键照方案是 `KittyTools.Test.<名字>`，快捷方式是 `Kitty Tools.Test.<名字>.lnk`；测试名下默认安装位置在 `%TEMP%`。
  - `MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)` 只有管理员能登记，普通权限下必失败：照样调（只记日志），%TEMP% 里那份卸载程序留到下次安装 / 卸载时清（`Uninstaller.CleanStaleCopies`）。
  - 静默卸载：安装目录里那份复制到 %TEMP% 就退出（退出码 0），真正的结果写进日志 `uninstall.exit <退出码>`；`setup-e2e.ps1` 等的是这一行。
  - 不整个删的时候 `Uninstall.exe` 也删掉（那时它已经退了）。开机启动值和登记只在指向这个安装目录时才删，另一份解压版的不动。
  - 已经装过（更新）时不显示「开机时自动打开」，也不动开机启动值：用户可能在程序里关掉了。
  - 任务对话框的结构体手写、没用 CsWin32（它不是 COM；在 Mac 上没法确认 CsWin32 生成的联合体和回调签名）。选文件夹、快捷方式照旧用 CsWin32。
- 日志在 `%TEMP%\KittyTools-setup.log`（测试名下是 `KittyTools-setup.Test.<名字>.log`）。修完挪到「已修」，写提交号、两个架构的安装包大小、七步结果。

### R37（P2）设置里「从这台电脑移除」交给 Uninstall.exe（PLAN-setup §4.2 / S10）→ 审查方写了，待编译验证


- `Settings/SettingsWindow.cs` 的 `UninstallAsync` 现在自己删快捷方式、开机启动和凭据，程序文件让用户自己删。安装程序装的（exe 旁边有 `.kitty-install`）改成：
  - `SetupRules.ReadMarker(<exe 所在目录>)` 不是 null，且同目录有 `SetupRules.UninstallerName`：启动它（不带参数，它会自己弹确认，含「同时删除我的数据」），然后走 `ShellRuntime.Exit`，不再弹自己的 ContentDialog。卸载程序会先通过管道发 `quit`，程序没退也会等。
  - 没有标记（zip 解压的）：照现在的做法。
- 顺带：第一次运行的欢迎页里「登录时自动打开」取的是设置的默认值（true），点「开始使用」会把安装时没勾的开机启动又写回去。有标记时改成取 `Autostart.IsEnabled()`，并同步到 `SettingsService.Current.StartWithWindows`。
- 设置窗第七版还在改，所以这条交给你们。

### R38（P2）程序内更新之后改「设置 › 应用」里的登记（PLAN-setup §4.3 / S11）→ 已编译 / 补测，真机更新待走

**进展（`76f94b4`）**：`SetupRules.WithInstalledFiles` 抽成纯函数（旧文件保留原大小写、新文件大小写不敏感去重、版本更新），`SetupRecord.AfterUpdate` 改用它；新增单测，325 个全过。登记写入仍要真机更新验一次。

- 在 `App/AutoUpdater.cs` 的 `update.installed` 之后（这时有 `result.Installed` 和 `version`），安装目录有 `.kitty-install` 就：
  - 改 `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<UninstallKey>` 的 `DisplayVersion`（新版本）和 `EstimatedSize`（`SetupRules.DirectorySizeKb(安装目录)`）。登记的 `InstallLocation` 不是这个目录就不动。
  - `.kitty-install` 的 `version` 改成新版本，`files` 并上这次装进去的文件（相对路径，`SetupRules.WriteMarker`）。不然更新带进来的新文件，卸载时会被当成「不认得的」，安装目录就不会整个删。
- 名字用 `SetupRules.NamesFor(null)`；Release 探针档（`KITTY_PROBE_PROFILE=<名字>`）下用 `SetupRules.NamesFor(<名字>)`，和安装程序的测试名是同一套。

**R37 / R38 的代码（审查方在 Mac 上写的，没编译过）**：新文件 `App/SetupRecord.cs`。
- R37：`UninstallAsync` 开头先看 `SetupRecord.Uninstaller()`，有就启动 Uninstall.exe、走 `ShellRuntime.Exit`；启动失败才退回原来的对话框。欢迎页有标记时取 `Autostart.IsEnabled()` 写回 `StartWithWindows`。
- R38：`AutoUpdater` 在 `update.installed` 后调 `SetupRecord.AfterUpdate`（标记的 version / files，登记的 DisplayVersion / EstimatedSize）；`HandleUpdatedLaunch` 删掉 `*.old` 后调 `RefreshSize` 再量一次大小（刚装完时旧文件还在，大小会翻倍）。登记的 InstallLocation 不是这个目录就只改标记。
- **验收**并进 R36 第 7 步：装 → 程序里更新 →「设置 › 应用」版本号变了、大小没翻倍 → 从设置里「从这台电脑移除」弹的是 Uninstall.exe 的确认 → 卸完安装目录整个没了。


## 转入 PLAN-v6

### R14（P1）录屏换成 H.264 MP4，补系统声音 → 转入 PLAN-v6 第 1–3 批

现在是 GDI 抓屏 → CPU 编 JPEG → 自己写 AVI：

- 大：`0.4.0-batch-1` 那段 12.5 MB 才几秒，约 2.5 MB/s，10 分钟 1.5 GB；
- 坏：`AviWriter` 的大小字段是 32 位，过 4 GB 就写坏；没有 OpenDML，很多播放器打不开 1 GB 以上的 AVI 1.0；
- 占内存：`AviReader` 压缩、转 GIF 时 `File.ReadAllBytes` 把整个文件读进来；
- 费 CPU：1440p 30 fps 的 JPEG 编码全在 CPU 上；
- 没有系统声音。

**做法（全走 WinRT，项目里已经在用 WinRT 投影，AOT 能用，不用手写 Media Foundation 的 COM）**，参考 robmikh/SimpleRecorder（MIT）：

1. **抓屏**：`GraphicsCaptureItem`（整屏用 `IGraphicsCaptureItemInterop.CreateForMonitor`、选区先抓整屏再裁，这一个接口用 CsWin32 / 函数指针）+ `Direct3D11CaptureFramePool.CreateFreeThreaded` + `GraphicsCaptureSession`（`IsCursorCaptureEnabled` 按设置；Win11 上能关就把 `IsBorderRequired` 关掉）。
2. **编码**：`MediaStreamSource`（`VideoStreamDescriptor`，BGRA8，选区尺寸取偶数），`SampleRequested` 里交 `MediaStreamSample.CreateFromDirect3D11Surface(frame.Surface, 时间戳)`；`MediaTranscoder.PrepareMediaStreamSourceTranscodeAsync(source, 输出流, MediaEncodingProfile.CreateMp4(...))` → `TranscodeAsync()`。码率按像素数算（1080p30 约 8 Mbps）。没有硬件编码器的机器系统会自己换软件编码，不用管。
3. **系统声音**：WASAPI 回环。CsWin32 在 `allowMarshaling=false` 下生成的 `IAudioClient` / `IAudioCaptureClient` 是带函数指针的结构体，AOT 能用。用**轮询**（每 10 ms `GetNextPacketSize`），**不要用事件模式**（回环 + 事件模式在没有声音播放时不来事件）；包上带 `AUDCLNT_BUFFERFLAGS_SILENT`、或中间断了，按时间戳补静音，不然音画会越录越不同步。PCM 作为同一个 `MediaStreamSource` 的 `AudioStreamDescriptor` 交进去，输出 AAC。
4. **麦克风**：一样走 WASAPI 采集，和回环在 PCM 层混（相加 + 限幅），重采样到同一个采样率。录音功能（现在是 `MediaCapture` 出 M4A）可以留着，也可以换成同一套，自己定。
5. **点按圈、按键胶囊**：改成画在 D3D 纹理上（Win2D：`CanvasDevice.CreateFromDirect3D11Device` + 在拷出来的纹理上画）。
6. **压缩**：同一个 `MediaTranscoder` 降码率再转一遍。**转 GIF**：`MediaComposition` / `MediaPlayer` 的帧服务器逐帧取。不用自己解 AVI 了，`AviWriter / AviReader / JpegEncoder / JpegDecoder` 删掉。

**在换完之前**：AVI 录到 1 GB 自动停止并提示（`// ponytail:` 写上 R14），免得写出打不开的文件。

**验收**：1440p 30 fps 录 60 s，文件 < 60 MB、录制期间本进程 CPU < 15%、内存不随时长涨；放系统声音 + 对着麦克风拍手，音画同步；资源管理器能出缩略图、「媒体播放器」能放；录满 10 分钟一次。

**进展（`50ecd87`、`7edbd92`）**：
- 已改成**直接录 H.264 MP4**：`Mp4Recorder` 用 Media Foundation SinkWriter（GDI 抓屏 → RGB32 → H.264，
  硬件编码），默认开，设置里可退回 AVI；点按圈 / 按键胶囊仍画进画面。
- 实测 2560×1440@30 录 10 秒：**2.75 MB**、MediaPlayer 认 10.0 秒、H.264；录制期间本进程 CPU **2.4%**。
- 停止后另存 MP4 / 托盘手动转 MP4 仍在（AVI 文件可用）。
- **还没做**：系统声音 / 麦克风混音（MP4 目前只有画面）、真实 60 秒 / 10 分钟长录制的内存曲线、
  压缩 / GIF 对 MP4 的支持（现在只对 AVI 显示）。

**审查（`1bdfde8`）**：MP4 能录了，但还是 GDI 抓屏，SinkWriter 没开 `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`，所以用不上硬件编码器。系统声音没做成，原因是用了事件模式：回环流在没有声音播放时根本不出包。这些连同删 AVI、录音补齐，都写进了 PLAN-v6 第 1–3 批。

### R12（P2）第 4、5 批欠的验证 → 剩下的转入 PLAN-v6 第 6 批

报告里写了，这里列出来免得漏。系统自带的截图工具就能录屏（Win+Shift+R），不需要额外装工具。

- **剪贴板面板、启动器的高度动画**：窗口每 16 ms 改一次尺寸，Windows 上这样做常见的问题是边缘闪黑或闪白。录一段 3–5 秒的视频看；有闪就改成不做动画，直接设到新高度。
- **截图**：选区贴着屏幕下边时，工具栏要放到上方或选区里面，不能出屏；中文输入法下的原位文字；飞入卡片拖到资源管理器。
- **数字**：翻译等待动画期间的 CPU、截一次图之后的内存（按 D8）。
- **截图**：截图翻译的浮窗贴着选区出现；飞入卡片的深色版。

**进展（2026-10-25，`4b7e0c1` 之后）**：

- 已验：选区贴着屏幕下边时工具栏在屏内（`windows\build\shots\r4\shot-bottom-toolbar.png`）；
  飞入卡片的深色版正常（`shot-card-dark2-crop.png`，顺手修了深色下卡片黑底黑字和白边）；
  截图翻译贴选区有纯函数单测（`ScreenshotLayoutTests` 的四个用例），真机 OCR + 翻译链路没走。
- 没做：高度动画的录屏（要人工开录屏工具、再逐帧看，自动化里没法可靠完成）、中文输入法的原位文字、
  把卡片拖到资源管理器、等待动画期间的 CPU（手上没有可用的 key / 服务能停在「思考中」）、
  第二次截图的内存（内存探针只截一次，下一轮看要不要给探针加第二步）。
  这些按 `AGENTS.md` 记「没测」，继续做 `PLAN-v3.md`；`HANDTEST.md` §144–161 里已经标了「待走」。

## 已修

### R22（P1）录屏 HUD 没按 DPI 算尺寸，还写死了屏幕高 1440 → 已修（`82a5a07`）

- HUD 尺寸按目标显示器 `Displays.AtPoint(...).Scale` 换算成物理像素；位置由 Core `HudPlacement.Compute` 限在工作区，下方放不下放上方、再放不下贴选区里面下边。
- `AppWindow.Show(false)` + `WS_EX_NOACTIVATE`，不再 `Activate()` 抢焦点。
- 单测 `HudPlacementTests` 4 条：150%、贴底、整屏、负坐标副屏。
- 还没做：`--fake-dpi=150` 真机截图和“开录后焦点还在原程序”的手测（见 HANDTEST）。

### R23（P1）去掉分段 MP4 以后，闪退会丢掉整段录屏 → 已修（`266a485`；长文件的重封装耗时并进 R24）

**进展（`266a485` / `d4b0c10`）**：
- 录制重新写 FMPEG4（`MFTranscodeContainerType_FMPEG4`），moov 及时落盘。
- 新增 `Mp4Remux`：SourceReader + SinkWriter 按原生压缩样本逐个搬，不重编码；每路时间戳从 0 开始；
  没有音频流按只有画面处理；失败退回「分段 MP4 原样改名」。
- 正常停止和 `RecoverOnStartup` 都走重封装；实测 2 秒 / 3 秒 / 5 秒文件重封装 16–47 ms，
  最终文件 `ftyp=mp42`、`moov` 在尾部、Shell 读出 2 秒 / 3 秒 / 5 秒；崩溃恢复的 5 秒文件也能读时长。
- 10 秒带音轨改成单个 SourceReader + ReadSample(ANY_STREAM) 后不再卡：31 ms / 789 样本，成品 10 秒。仍然差验收里的 **60 秒 / 10 分钟两种重封装耗时**，以及真实系统声音 / 麦克风两路设备
  （开发机只验了无声和系统回环空数据）。

- 第 3 批改回了普通 MP4（`MFTranscodeContainerType_MPEG4`）。普通 MP4 的索引（moov）要到 `Finalize` 才写，闪退、断电、被任务管理器结束时，临时文件里一个字节都放不出来。「启动时找回」挪过去的是一个打不开的文件。
- PLAN-v6 第 1 批第 6 条写的是：录分段 MP4，停止时如果缩略图、拖动有问题，就**无损重封装**成普通 MP4，不是改回普通 MP4。你遇到的「MediaComposition 在分段 MP4 上 seek 不准」，正好是重封装要解决的问题。

**修**：
1. 录制写分段 MP4（`MFTranscodeContainerType_FMPEG4`）。
2. 正常停止时重封装：`MFCreateSourceReaderFromURL` 读临时文件，两路都**不设输出类型**（默认就是原生的压缩样本）。第二个 SinkWriter 每一路用 `GetNativeMediaType` 拿到的类型 `AddStream`，`SetInputMediaType` 也传**同一个类型**（输入输出一样就不会插编码器，等于直接搬），逐个 `ReadSample` → `WriteSample`（时间戳减去第一个样本的，从 0 开始），最后 `Finalize`。不重编码，60 s 的录屏应该在一秒以内。
3. 启动时找到临时的分段 MP4，同样重封装后挪进保存目录。重封装失败就原样挪过去，分段 MP4 也能放。
4. 压缩、转 GIF、抽缩略图都只对重封装之后的普通 MP4 做。

**验收**：
- 录 30 s 时用任务管理器结束进程，下次启动找回的文件能放、时长约 30 s；
- 正常停止的文件，资源管理器缩略图、「媒体播放器」拖进度条都正常；
- 报告写 60 s 和 10 分钟两种文件的重封装耗时。

### R25（P1）卸载并删除数据时，数据库和日志还开着 → 已修（`61152c0`）

- 删除前 `ShellRuntime.PrepareForUninstall()`：提交剪贴板删除 → `ClipboardService.Stop()` 关 SQLite →
  停同步定时器 / 更新检查 / 热键 / 托盘 → `Log.Shutdown()`。
- 回收站改用内置 `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(..., SendToRecycleBin)`，
  删完检查目录是否真的不在；失败弹「数据目录没删干净」并可打开文件夹。
- 和审查要求的 `IFileOperation` 不同：CsWin32 的 `IFileOperation` 在当前 NativeMethods 里生成不出来，
  先用 VisualBasic 的内置实现；行为一致（回收站 + 失败提示 + 不静默）。
- 验收还差：`.Dev` 数据目录真机点一次、故意占用一个文件看提示。

### R26（P1）同步执行层的 8 处修复没有任何自动化测试 → 已修（`6ebe604`）

**修了什么（`6ebe604`）**：
- 四类的编出去 / 落回来在 Core：`ClipSync`、`VocabularySync`、`EngineSync`、`ServiceSync`（一类一个文件，照 mac 的 SyncSource / applySync，按合出来的改动落）；一整轮在 Core 的 `SyncRunner`（+ `SyncDisk`、`SyncLedgerText`、`ISyncSource` / `ISyncDevice`）。App 的 `SyncFolder.cs` 只剩定时器、状态和四个薄适配（规划落进库，和账本同一个事务）。
- 单测 `SyncSourceTests` 19 个，§2 每一条都有；集成测试 `SyncIntegrationTests` 走真的 `SyncRunner`：两台 Windows + 假 Mac（golden 样本），3 个种子 × 24 步，最后三边一样、再合一轮谁都不写；坏文件、换回旧备份照旧验。`SyncGoldenTests` 照过。全量 306 个。
- 「两个临时数据库」没用真 SQLite（测试工程只引 Core）：仓库在内存里，落规划的几步和 `ClipboardStore.ApplySyncPlan` / `TranslationHistory.ApplySyncOps` 一一对应；SQL 那几行用真 App 冒烟验了（两份临时 `.Dev` 数据 + 临时同步文件夹，片段落进另一台的库，之后安静的轮次不重写文件）。
- 顺手照 mac 改的（提交正文里有全单）：刹车的「至少 5 条」按要删的条数算（之前按总数，删 5 条里的 2 条也刹），「照样同步」只放行不超过当时那么多条；没东西要写就不重写文件、epoch 只在写了东西时 +1 且先记库；账本读不出来这一类停下；每一类跟着功能开关；面板里有能撤销的删除时先不合。
- 没连真 Mac（用户要求 R26 做完前不连）。

- `275ea952` 修的都是「会删到每一台」级别的问题，而且全在 App 项目的 `SyncFolder.cs` 里：仓库没起来时交空表、收藏夹没落地、`group` 的写法、只交收藏、落地失败照存账本、再编不稳定、抢别人的 uid、刹车。
- 报告里也写了：「这次的改动没有自动化测试覆盖」。`PlanV5IntegrationTests` 测的是 Core 的引擎加手写的值，没经过这些代码。

**修**：
1. 把四类数据各自的「编出去」和「落回来」，从 `SyncFolder.cs` 抽成 Core 里的纯函数：输入本机的记录列表，输出 value 字典；输入合出来的改动，输出要落的改动和失败原因。照 mac 各个 `SyncSource` 的写法，一类一个文件。`SyncFolder` 只管读写文件夹、事务和状态。
2. 单测，每一条对应 `275ea952` 修的一处：
   - 仓库没起来 → 这一类不合；
   - 收藏夹同名 → 编号小的留下、条目归过去；
   - 只是片段的条目要交出去；
   - 有一条解不开 → 整类不落、不存账本；
   - 编 → 落 → 再编，字节一样（备注空白、生词前后有空格、服务缺协议，各一条）；
   - 正文撞上已经留着的条目时不抢它的 uid；
   - 本机删一大批（erasing）也要刹车，等确认的状态不被盖掉。
3. 集成测试改成走真的执行层：两个临时数据库加一个临时同步文件夹，再加一台假 Mac（值用 `sync-golden.json` 里的样本），跑几轮，最后三边一样。
4. `sync-golden.json` 审查方已经改过：之前片段的 `group` 写成了带 `group:` 前缀的，是审查方的错。mac 条目里只写收藏夹的编号，前缀只在收藏夹那条记录自己的编号上，你在 `275ea952` 里改对了。样本已经按 mac 重新生成，跑一遍单测确认还都过。

### R27（P2）第 5 批的内存回落没做 → 已修（`bacd1a6`、`bcd3eb7`；剩下的转 R34）

**补完（`bcd3eb7`，Release AOT 全量探针，专用工作集，探针用独立数据 `KITTY_PROBE_PROFILE`）**：

| 步骤 | 之前（`bacd1a6` 的探针） | 之后 |
|---|---|---|
| 截图后 / 第二次 / 空闲两分钟 | 65.4 / 68.2 / 68.2 | 66.8 / 69.6 / 69.6 |
| 设置窗关掉 30 秒 / 两分钟 | 79.8 / 79.7 | 80.9 / 80.7 |
| 录屏 5 秒，停止后两分钟 | 103.3（+23.5） | 83.9（+3.2） |
| 再录一次，两分钟后 | 每次再 +24 | 84.2（+0.3） |

- **录屏修好了**：每录一次留下一整个 D3D 设备（约 24 MB）。WinRT 的 `IDirect3DDevice` 和每帧的 `frame.Surface` 包装都拿着设备、要等 GC 终结才放；关掉 / `using` 之后设备真的销毁（`d3d.still-referenced` 会记还有人拿着的情况）。NVENC 第一次加载多 20–30 MB 是驱动，之后每次 < 1 MB。
- **冷启动**：10 次中位数 0.5.0 79 ms、第六版第 5 批 76 ms、修之前 107 ms、之后 77 ms。之前报的 64 / 90 是单次读数（这台机器单次 61–118 ms）；真正变慢的是第 7 批把开始菜单快捷方式放在启动路径上（每次 COM 解析 .lnk），挪到启动 3 秒后。
- 设置窗点 × 关掉时放掉引用；截图、录屏、录音结束和设置窗关掉之后都排空闲回收。`GCConserveMemory=5` A/B 各步差不到 0.5 MB（`d1c697c` 已开，没撤）。发布目录前 20 个看过：删 WebView2 两个 DLL（0.91 MB），`Microsoft.UI.Xaml.Phone.dll` 设置窗要用不能删，`.winmd` 先留着。
- **没做成**：截图后 +18 MB、设置窗关掉后 +10 MB，两分钟后都不降。托管堆只剩 2.5–4 MB、GDI 位图已删，剩下的是 WinUI 合成层 / XAML 模板缓存的原生内存；给截图遮罩单独建 Win2D 设备再放掉也省不下（撤了）。再往下要换做法（遮罩常驻复用或单独进程）。录音的回落没量。

`9a836e49` 的数字：

| 场景 | 内存 |
|---|---|
| 启动器 | 57.8 MB |
| 截图 | 74.0 MB（+16） |
| 设置窗打开 | 83.6 MB |
| 设置窗关掉之后稳定 | 83.5 MB（没降） |

- PLAN-v6 第 5 批第 1–3 条（截图、设置窗、录屏之后回落）和第 4 条里的 `System.GC.ConserveMemory` 都没做；「发布目录前 20 个文件逐个看」也没做。照 PLAN 做完，报告列「之前 / 之后」。
- 冷启动从 64 ms 变成了 90 ms，查一下是哪一批加的、为什么。

**复查（`3fe1725e`）**：录屏每次漏一个 D3D 设备的问题找出来修了（+23.5 MB → +3.2 MB），冷启动 107 → 77 ms，发布目录看过、去掉了 WebView2。剩下截图后 +18 MB、设置窗关掉后 +10 MB 不降，转到 R34。

### R28（P2）录音控制条 / 直接写 AAC / 断开提示 → 已修（`3df5058`）

**进展（AudioHud，`0fc69bd`、`a64a8af`）**：新增录音控制条：屏幕上方的深色胶囊，红点 / 计时 / 电平条 / 暂停继续 / 停止，
显示不抢焦点；`--audio-rec-ui=3` 实测 3.2 秒 / 79.7 KB 的 m4a。待录模式已接：设置里关掉
「按快捷键后立即开始录音」后先出条、点 ● 才开始，托盘 / 快捷键再按一次取消。麦克风 / 系统声音断开的
橙字也接了（`132b806`，录音条和录屏 HUD 都读 `LiveNote`）。直接写 AAC 也接了（`c7c4ce4`）：
PCM16 进 SinkWriter 编 AAC，容器先写分段 MP4，停止时无损重封装成 .m4a；实测 3.16 秒 / 64.9 KB。
闪退恢复也接了（`3df5058`）：录到一半强杀，临时 121.8 KB，下次启动重封装 32 ms，恢复出 5 秒 .m4a。
还没测：1 小时长录的真机稳定性和内存曲线。

- PLAN-v6 第 3 批第 4 条没接界面：待录（按快捷键先出控制条、点 ● 才开始）、电平条、「没听到声音」的提示、「按快捷键后立即开始录音」的设置。照 mac `AudioRecorder.swift` 文件头做，界面按 PLAN-v7 的轻提示 / HUD 样式。
- 第 2 批：HUD 计时后面的橙字「麦克风断开了」还没接。
- 录音现在先写临时 WAV、停止后再转 M4A：1 小时就是 690 MB 的临时文件，转码还要等。改成录的时候直接用 SinkWriter 写 AAC。闪退恢复照 R23 的办法：写分段 MP4 容器，停止时重封装成 `.m4a`。

### R29（P2）窗口录制：窗口一改大小，录制就停了 → 已修（WgcScaler）

**修（WgcScaler）**：录单个窗口时 ContentSize 变化不再停止，输出尺寸不变；WgcScaler 用 Win2D 把新画面等比缩放、居中画进输出纹理，四周补黑。同尺寸仍走 CopySubresourceRegion，缩放器起不来退回居中裁。自检 --record-resize：录 900x600 → 回全屏，日志 wgc.scaled 900x600->2560x1440，5 秒 156 帧 / 1.4 MB。还没走：真机手拖窗口边、最小化恢复。

- `OnFrameArrived` 里 `ContentSize` 一变就 `_stop.Set()`，提示「屏幕尺寸变了」。录整屏时这样处理可以；录单个窗口时，用户拖一下窗口边就停了。
- **修**：录窗口时 `ContentSize` 变了就 `Recreate` 帧池，输出尺寸不变，把新的画面按比例缩放、居中画进输出纹理（已经有 Win2D 的画布，`DrawImage` 带缩放就行），四周补黑。窗口最小化时补上一帧，窗口关掉时停止并保存。
- **验收**：录测试窗口，录的过程中拖大、拖小、最小化再恢复，文件能放、画面不变形。

### R30（P3）几处小问题

**进展（`82a5a07`、`356bb30`）**：文件搜索的 LIKE 已把 `%` / `_` / `[` 用字符类转义；`System.ItemUrl` 实测不按百分号编码（空格就是空格），不再 `Uri.UnescapeDataString`，补了 `%20` 保持原样的单测；根目录过滤改成 `SCOPE='file:C:/…'`，`--file-search=jpg` 100 条从 62 ms 降到 31 ms。第六版截图补了（`97c8e7e`，`windows-shots` 的 `0.7.0-review-r30/` 8 张：设置窗 4 处浅深各一；顺手修了深色下对话框是浅色的问题，11 处 ContentDialog 跟着设置的深浅色走）；托盘菜单和录制条是透明宿主窗口，PrintWindow / BitBlt 都截不到，没交。提交格式、各用各的 worktree 照做了。另外 `7ec18c5` 修了 `877cdf1` 起设置窗一打开就崩（`Kitty.Card` 样式键和主题画刷同名）。

- **文件搜索的 SQL**（`Core/FileSearchSql.cs`）：
  - 只转义了 `'`。`%`、`_`、`[` 在 LIKE 里是通配符，搜「[草稿]」会搜不到。改成放进方括号转义：`[%]`、`[_]`、`[[]`。
  - `LocalPathFromItemUrl` 对路径做了 `Uri.UnescapeDataString`，文件名里本来就有「%20」的会被改成空格。先确认 `System.ItemUrl` 到底是不是百分号编码的，不是就别解码，补一个单测。
  - 根目录过滤改用 `SCOPE='file:…'`，比 `System.ItemUrl LIKE` 更能用上索引（Command Palette 也这么写）。
- **提交格式**：第六版有十几个提交的标题没有 `<type>(win):`，比如「PLAN-v6 第 6 批（续）：…」。旧提交不改，以后照格式写。
- **截图**：第六版改了托盘分节、录制条开关、卸载对话框、设置里的新选项，`windows-shots` 上一张都没有。补一套：只截窗口，浅色、深色各一张。
- **几个 agent 别共用同一个检出**：`275ea952` 的报告里说「另一个 agent 在主工作区 stash 了一份」。几个 agent 同时在一个目录里改，会互相覆盖、互相 pop 错 stash。每个 agent 用自己的 `git worktree`，做完 rebase 到 `origin/windows-wip` 再推。

### R13（P0）同步的合并规则和 mac 不一样 → 已修（`f29f437`、`2728574`、`a381cbe`）

**先说审查方的错**：PLAN-v5 让你照搬的 `SyncRecords.swift` 等文件，写方案时只在 Mac 本地、没推到 `origin`，你那边拿不到，只能按文字重写。现在原样拷在 `windows/reference/mac-sync/`（README 里有对照表）。

- **差在哪**：你写的是「`modified` 大的赢，一样再看钟」；mac 是**先比钟**——一版的钟每一格都不小于另一版（盖过它）就直接赢，跟改于无关；只有两版谁也盖不住谁（真的并发改）才比改于，再一样比内容哈希（`SyncRecords.swift` 文件头「合（C1）」）。
- **会出什么事**：Windows 的系统时间比 Mac 快 5 分钟。Windows 改了一条 → Mac 读到、在它上面又改了一次（Mac 这版的钟盖过 Windows 那版，但改于比 Windows 的小）→ Windows 这一轮按改于判自己赢、把 Mac 的改动丢掉，再把钟并起来写出去 → Mac 下一轮看到的钟盖过自己的，跟着退回旧值。两台的时钟差几分钟很常见，这个不是小概率。
- 别的没对上的（都在文件头里写着）：改于不晚于现在、取 changed 时刻；账本被退回去时只追自己那一格（你现在是换编号，那是 device.json epoch 的规矩，两件事都要有）；第一次合的规则（同一编号的不算改动、内容一样的只留文件夹那条、丢的不留墓碑不进刹车）；墓碑不过期。
- **要做**：
  1. 照 `SyncRecords.swift` **逐行**搬成 `KittyTools.Core` 里的纯函数：`round`、`Join.union`、`orderID`、`arranged`、`decodeExact`、`buried`、`standing`，文件头那几段原样保留成注释。你现在的 `SyncClock`、`SyncJson`、`SyncFile` 能对上 golden 的部分留着用。
  2. `SyncRecordsTests.swift` 的 17 个用例全部移植、期望值原样；`SyncRecordsFuzzTests.swift` 照着移植（三台随机加改删合、读到旧文件、钟快慢、退回、丢账本，查三台最后一样），默认 20 个种子随全量跑，`KITTY_SYNC_FUZZ=2000` 跑 2000 个。
  3. PLAN-v5 第 3 批的集成测试：临时文件夹里两台 Windows（两个数据目录）+ 一台用 golden 样本手写的假 Mac，随机改几轮，最后三份一样。
  4. 执行层挪出 UI 线程：同步文件夹多半在云盘里，读一个还没下载的文件会卡几秒。照 `NoteSyncer.swift`：后台读写、合，回 UI 线程落地（落地和账本同一个事务）。
- **修好之前**：设置 › 通用 ›「同步」这一节先藏起来（`// ponytail:` 写上 R13），0.5.0 的产物不能给用户装来同步。
- **验收**：上面 2、3 全过；报告里写 fuzz 2000 个种子的耗时。

**进展（2026-10-25，`2728574` / `a381cbe`）：**
- 引擎已接执行层：`SyncKind` 用 `SyncEngine.Round`，旧账本 `clock|hash` 迁成新格式；设置里的「同步」重新打开。
- 17 个移植用例 + 20 个种子的 fuzz 随全量跑；`KITTY_SYNC_RECORDS_FUZZ=2000` 实测 2000 个种子 34.9 秒；
  两台 Windows + 假 Mac 的临时目录集成测试（8 轮，三份一样）也过了。
- 文件读 / 解码 / 合并已放到线程池（`Task.Run`），回 UI 线程落地和写账本。
- 还差：旧账本迁移只把 modified 记 0；真机 / 真 Mac 的长期同步没测。

**审查（2026-10-25，`1bdfde8`）**：`SyncEngine.Round` 逐段对过 `SyncRecords.round`，账本、墓碑、退回只追自己那一格、第一次合的 union / adopt、`standing`、改于取 `min(changed, now)`、赢家按（改于，哈希）都对得上。旧的 `SyncMerge` 和它的测试还在，PLAN-v6 第 0 批删掉。

### R16（P1）截图拍到了用户的隐私 → 已修（审查方：`windows-shots` 已改写并强推，`d2d38b6`；规矩在 `AGENTS.md`）

- `0.4.0-batch-1/record-saved.png`、`0.4.0-batch-2/record-select.png`、`0.4.0-batch-3/hud.png` 都是 2560×1440 的整个桌面，拍进了用户别的窗口：代理配置、局域网和代理服务器的 IP、别的对话的内容。`0.4.0-batch-4/effects-frame.jpg`、`0.4.0-batch-5/gif-frame.png` 这两张录屏帧里也有。
- **以后的规矩**（已写进 `AGENTS.md`）：
  - 截图只截我们自己的窗口：按窗口矩形裁，或者只抓我们的 HWND。
  - 录屏的验证先开一个自己的测试窗口（满屏测试图案），只录它的范围。
  - 整屏的图一律不推。推之前自己看一遍，不能有别的 App 的内容。
- 已经推上去的那几张怎么处理，由用户定（要改写 `windows-shots` 的历史），agent **不要动**。

### R17（P1）启动器文件搜索是自己扫目录 → 已修（`ed4428d`）

- 改成 `StorageFolder.CreateFileQueryWithOptions` + `IndexerOption.OnlyUseIndexer` + `System.FileName:*词*`；
  失败才退回扫目录，退路 6 层 / 2000 候选 / 300 ms。
- 怎么验的：`--file-search=jpg` 索引 **880 ms / 20 条**，`KITTY_FS_FORCE_FALLBACK=1` 退路 **33 ms / 20 条**
  （退路被 300 ms 截断；这台机器 Downloads 只有 500 多个文件，索引本身约 0.9 s）。

**审查**：改成走索引了，但 WinRT 的查询一次要 880 ms，打字时等不起。转入 PLAN-v6 第 4 批，换成 OLE DB 查索引。

### R18（P2）端口靠解析 `netstat` 的输出 → 已修（`a381cbe`）

- `Launcher/PortTable.cs` 改用 `GetExtendedTcpTable` / `GetExtendedUdpTable`（IPv4 + IPv6，TCP 只要 LISTEN，
  UDP 全部）；纯函数 `PortMath.PortOf/FormatV4` 在 Core；`PortSearch` 不再起进程。
- 怎么验的：`--ports` 实测 129 行（TCP/UDP、IPv4/IPv6、pid 都对）；`PortMath` 2 个单测（字节序、格式）。

### R21（P3）几处小问题 → 已修（`a381cbe`）

- 剪贴板预览时间改 `HH:mm` + 最小宽度，来源名超长省略；
- HUD 加 `TransparentBackdrop`，胶囊外不再有浅色方框（本地截图确认）；
- 按键胶囊加小写字形，显示 `Ctrl + Shift + S`；
- 灰格子确认是测试图本身透明（`0.3.0-batch-4/ocr-search.png` 里预览就是透明棋盘格），不是没画出来。

### R20（P2）第三版报告里记的「没做成」→ 已修（`3e978d9`、`fb0aa36`）

- 浏览器历史：`HistoryIndex` 拷 `History` + `-wal`/`-shm` 到临时文件；本机 Chrome 等载入 217 条，
  Edge 的库拷出来 malformed（正在写），跳过并记日志。
- Firefox 书签：`places.sqlite` 的 `moz_bookmarks`（type=1）并入，书签 404 条。
- Ctrl+K：自建 Flyout（过滤框 + 按钮列表，Enter / Esc），条目和右键菜单同名同顺序。
- 长截图：`S` 向下、`Shift+S` 向上、`A` 自动向下、`Shift+A` 自动向上；自动每 600 ms `SendInput` 滚一格。
- 链接头图 `DecodePixelWidth=1200`；有道 / 火山 / 腾讯签名换成 mac 固定向量（3 个全过）。
- 没测：自动滚动的真机效果（会滚当前窗口，没自动化）；Edge 历史（库正在写时拷不出来）。

### R15（P1）R4 没修好：深色下设置卡还是浅底白字 → 已修（`2728574`）

- `Theme.CardBackground/SecondaryText` 不再从 XamlControlsResources 的主题字典取（实测 Default/Light
  解出来都是 `#B3FFFFFF`，深色用错），改成跟 `EffectiveTheme` 给具体颜色；`ThemeKey` 深色先找
  `Default`，`FindTheme` 只认里面真有这个 key 的字典；启动自检日志 `theme.check` 记实际颜色。
- 怎么验的：系统浅色 + 设置深色，只截设置窗口（`0.5.0-review-r15/settings-dark-system-light.png`，
  卡片深底白字、功能卡有图标）。系统深色 + 设置浅色的组合没测（要改系统主题）；
  XAML 里能写 `ThemeResource` 的地方还没全换，留给 R4 的后续。

### R19（P2）编码：一个文件的注释是乱码、提交信息带 BOM → 已修（`2728574`）

- `Shell/OverlayWindow.cs` 文件头 4 行和第 146 行按原意重写；DeepL / Google / Microsoft 三个
  Provider 去掉 BOM；新增 `windows/.editorconfig`（`charset = utf-8`）；
  本地设了 `git config i18n.commitEncoding utf-8`，提交信息用 Python / write 工具写不带 BOM 的 UTF-8。
- 怎么验的：读文件头是正常中文；`python` 检查 Providers 下没有 BOM；本次提交标题无 U+FEFF。

### R4（P1）设置里选的外观和系统不一样时，代码里设的颜色全是错的那一套 → 已修（`4b7e0c1`）

- `Theme.Brush` 改成按设置里选的那套深浅色去 `XamlControlsResources.ThemeDictionaries[Dark / Light /
  HighContrast]` 取；`SecondaryText / CardBackground / CardColor` 用 `EffectiveTheme`；
  设置窗标题栏用 `AppWindow.TitleBar.PreferredTheme`。
- 怎么验的：系统浅色 + 设置里深色，设置窗卡片深底浅字、翻译卡深底、计算结果说明可见
  （`windows\build\shots\r4\`）；运行中切换外观时设置页会重建、取到新的那一套。

### R5（P1）轻提示和托盘菜单的宿主窗口不是透明的 → 已修（`4b7e0c1`）

- 新增 `Shell/TransparentBackdrop.cs`，轻提示和托盘菜单的宿主窗口都用它；`OnTargetConnected` 里给
  `connectedTarget.SystemBackdrop` 设一个全透明的 `Windows.UI.Composition` 颜色画刷。
- 怎么验的：整屏截图里胶囊外面没有白框；托盘菜单打开时 360×480 的宿主窗口看不见。

### R6（P1）剪贴板列表的标题被挤成三个字，来源显示成 WebView2 → 已修（`4b7e0c1`）

- 行右栏只放短时间（刚刚 / N 分钟前 / N 小时前 / 昨天 / MM-dd / yyyy-MM-dd），来源只在预览卡卡头显示；
  `Core/ProcessTree.cs` 顺着 `th32ParentProcessID` 跳过 `msedgewebview2.exe` 这类宿主，
  `ClipboardFormats.Source` 用 Toolhelp 快照查表。
- 怎么验的：截图里标题能显示到六成以上；`ProcessTreeTests` 覆盖三层 WebView2、普通进程、环、大小写。

### R7（P1）启动器的计算结果那一行溢出了 → 已修（`4b7e0c1`）

- 结果行 64 DIP、普通行 48；`PanelMetrics.LauncherHeightFor` 按实际行高算，选中高亮用容器高度。
- 怎么验的：`PanelMetricsMixedRowsTests`；深色截图里结果和说明都在行内。

### R8（P1）翻译浮窗的高度没算对，最后一张卡被底栏盖住 → 已修（`4b7e0c1`）

- `NeededHeightDip` 改成 Measure + DesiredSize；设置类错误只给「打开设置」，网络 / 服务类给「重试」。
- 怎么验的：截图里错误卡完整显示（`translate-dark2.png`），按钮只有「打开设置」。

### R9（P2）界面文字里不该出现给开发者看的话 → 已修（`4b7e0c1`）

- 通用页和关于页的文案、0.1.0 更新日志只留功能；全项目查过没有「...」占位。

### R10（P2）设置窗的几处细节 → 已修（`4b7e0c1`）

- 每项一个图标、数据目录改成卡片、关于页加应用图标、导航 / 菜单项不画焦点框（焦点给内容区）。
- 怎么验的：截图（`settings-dark-system-light.png`）里图标各不相同、数据目录是卡片；
  托盘菜单第一项没有焦点框。

### R11（P3）截图卡片和更新下载的小问题 → 已修（`4b7e0c1`）

- 拖出用 deferral + await；启动时清空 `%TEMP%\kitty-shots`；下载把 `Content-Length` 当 `knownTotal` 传进去。
- 怎么验的：`UpdateDownloadTotalTests`（不可 seek 的流也能报总大小）。

### R1（第二版第 2 批，`da8cc1a9`）自动更新只认 GitHub 的 https 地址 → 已修（`58e62c2`）

- `Core/UpdateTrust.cs`：发布列表 / 下载地址的白名单纯函数；`App/UpdateHttp.cs` 自己逐跳处理跳转、
  每一跳都过白名单。`KITTY_UPDATE_FEED`、`file://`、本地路径、`http://` 只在 Debug 或 `--update-test` 下认。
- 怎么验的：`UpdateTrustTests` 8 种地址（含大小写、端口、账号密码、`github.com.evil.com`、别的仓库）全过；
  Release AOT 正常启动设 `KITTY_UPDATE_FEED` → 日志 `update.feed-ignored` + `localFeed=False`；
  带 `--update-test` → `newer=True localFeed=True` 并下载成功。

### R2（同上）更新完退出要走正常的退出流程 → 已修（`58e62c2`）

- `AutoUpdater.ExitApplication()` 调 `ShellRuntime.Instance.Exit()`（提交剪贴板删除、注销热键、删托盘图标），
  没有壳时才退回 `Application.Exit()`。
- 怎么验的：自动更新成功路径（同 `HANDTEST.md` §135）看托盘只剩一个图标；`ShellRuntime.Exit` 的
  `clipboard.ready` / `tray.added` / 热键注册在更新前后一致。

### R3（同上）下载直接写文件，不整个读进内存 → 已修（`58e62c2`）

- `Core/UpdateDownload.cs`：80 KB 一块流式写 `updates\<文件名>.partial`，写完才改名；失败 / 取消删半成品。
  托盘那一项在下载中显示「正在下载 37%」。
- 怎么验的：`UpdateDownloadTests`（成功改名、失败不留半成品、取消不留半成品、旧 .partial 被替换）；
  400 MB 假 zip 实测私有提交 91.9 → 100.6 MB（+8.7 MB，不随文件大小涨），校验失败后 `updates\` 里没有残留。

### R68（P1）0.1.0 用户真机反馈的四条 → 已修

- 截图工具栏没有保存、没有打勾：右边那段改成和 mac 一样的 识字 · 翻译 · 钉图 ｜ 保存 ▾（快速保存 / 另存为…）｜ ✕ ✓（✓ = 复制，Enter）。
- 截图瞬间整屏闪白：遮罩每次新建，Win2D 第一帧之前 WinUI 先合成一帧白底。`ShowOverlay` 先 DWM cloak，冻结帧画完再过两次合成才露出来，最多藏 300 ms。
- 截图翻译的浮窗从别处飘到选区旁：以前先在上次收起的位置 `Show()` 再挪。`TranslateWindow.ShowCore` 多一个 `place`，所有入口都先挪好再显示。
- 剪贴板透镜带滚动条：短文字的正文高 36，卡头（来源 + 三个按钮）就占满了，正文溢出。滚动条改成 Hidden（滚轮照样滚），一行放得下的普通文字不在透镜里再画一遍（同 mac `Lens.bodyHeight`）。
- 怎么验的：Debug 零警告；`--ui-snapshots` 的 shot-toolbar 和 clip 两张图；`--screenshot` 实机：cloak 之后遮罩正常露出、Esc 能关。闪白、浮窗位置没逐帧录，要真机再看一眼。

## 有异议

（还没有）
