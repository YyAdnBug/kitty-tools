# Kitty Tools Windows 版：第二十一版方案（设置、快捷键、功能开关和启动器收藏的同步）——拍板页

2026-11-15。用户：「为设置、快捷键、功能开关和启动器收藏同 mac 的同步单独写一版方案：先出一张两边键名的对照表」。

**状态：D1–D8 用户 2026-11-15「照推荐」，一批一批在做（`git log --grep "PLAN-v21"`；结果在 `REVIEW.md`「PLAN-v21」）。** 照 `AGENTS.md`「每一批的流程」一批一批做，交接写在 `REVIEW.md`「PLAN-v21」，
手测接着 `HANDTEST.md` 末尾往下编（从 1357 起），截图推到 `windows-shots` 的 `0.3.0-v21-<批>/`。不改版本号、不发布。

- **对照的 mac**：`origin/macos` `58f15ee3`（0.9.0 发布后）。规则在 `Storage/SettingsSync.swift`（文件头就是规格）、`Storage/SyncRecords.swift`、
  `Storage/SyncLedger.swift`、`Storage/Prefs.swift`（`defaults` 那张表 = 同步哪些键）、`Storage/SettingsArchive.swift`（`kinds`、`Value`）、
  `Launcher/LauncherUsage.swift`（启动器收藏那一类）、`Shell/HotKeyCenter.swift`、`Screenshot/ShotKeys.swift`、`Shell/Feature.swift`。
- **对照的 Windows**：`origin/windows` `7561487a`（PLAN-v20 第 6 批）。路径相对 `windows/`。

## 0. 先说的几件事

- **Windows 已经有的**：合并引擎（`Core/Sync/SyncEngine.cs`，mac 17 个用例和随机测试都移植了）、执行层（`Storage/SyncFolder.cs`、
  `Core/Sync/SyncRunner.cs`）、文件夹和 WebDAV 两种方式、六类数据（片段与收藏、生词本、网页搜索、翻译服务、状态屏的状态、提醒）和便签。
  这一版**不动引擎**，只是多接几类 `ISyncSource`，加上设置页里的开关。
- **mac 的这两类是什么样**：
  - `settings.json`（`SyncRecords.Kind.settings`）：一项设置一条记录，编号 `pref:<mac 偏好键>`，内容是 `SettingsArchive.Value` 编出来的 JSON
    （`true`、`7`、`"top"`、`["a","b"]`）。快捷键的编号是 `hotkey:<动作>`，截图工具栏的键是 `shotkey:<键>`，内容都是 `{"keyCode":…,"modifiers":…}`
    （mac 的虚拟键码 + Carbon 修饰键）。
  - **只同步改过的**：mac 偏好里存过的才有记录，改回默认 = 删掉这一条。
  - **第一次合跟着已有的**（`adopt`）：别的电脑已经有这一类时，这台整个跟过去，本机改过、别人没有的那几项回到默认。
  - **透传**：不认识的编号、留在本机的键、落不下的值，原样存进 `syncPassthrough.settings`，下一轮原样交回去，不落进设置、不留墓碑。
  - **后改的赢**：每项改的时刻记在 `syncChangedAt.settings`。
  - **这一类先不合**：正在录屏 / 录音、正在录快捷键、状态屏开着的时候。
  - `launcher.json`（`Kind.launcher`）：一个收藏一条，编号 = `hash(kind + "\0" + target)`，内容是 `{"kind","target","title"}`，顺序单独一条 `~order`。
    第一次合是并在一起（union）。**收到不认识的 `kind` 时整类停下、说「先更新」（`.newer`）**——这一点决定了 D5。
- **最大的坑：mac 的 `adopt` 会把 Mac 独有的设置清回默认**。一台 Mac 第一次加入一个文件夹时，只要「别的电脑已经有 `settings.json`」，
  它就整个跟过去：本机存过、对面文件里没有的那几项全回到默认。如果对面只有 Windows，而 Windows 不认识刘海岛、程序坞预览、
  访达右键这些键，也不写 mac 的 `hotkey:`，这台 Mac 的这些设置和**全部自定义快捷键**就都被清掉了。D3 专门解决这个。
- **保持唤醒在 mac 0.9.0 里被拿掉了**（`07da6ad3`，2026-11-13 用户「拿掉」，代码留在 mac 分支 `plugins-wip`）。PLAN-v20 K1 照的是拿掉之前的
  `f48c5d2e`，所以 Windows 现在有、mac 发布版没有。这一版把 `keepAwakeSchedule`、`keepAwakeDisplay`、`feature.keepAwake`、`hotkey:keepAwake`
  都当 Windows 独有处理；等 mac 把它放回来，再按那时的键名并过去。`MAC-DIFF.md` 里两处「同 mac 0.9.0」顺手改掉了。
- **mac 0.9.0 把便签、提醒、状态屏改成了插件**（`5cac0095`）。偏好键不变（还是 `feature.notes` 这些、默认值也不变），所以开关照样能一一对上。
  Windows 不跟「改插件」这件事（PLAN-v20 §0）。

## 1. 对照表

**怎么读**：

- 「mac 键」是 `pref:` 后面那一段（mac `Prefs` 里的字符串，不是 Swift 常量名）。
- 「Windows」是 `App/Settings.cs` 里的属性名。
- 默认值不一样的，「mac 默认」那一格写出来。
- 「待核」= 我读代码对不出意思或值域一不一样，第 1 批写换算前先对一遍两边的代码；对不上的归到 C 组。

### A 组：同一个意思、同样的值，直接同步（`pref:<mac 键>`）

| mac 键 | Windows | 类型 | 备注 |
|---|---|---|---|
| `clipboardBlockSensitive` | `ClipboardBlockSensitive` | 布尔 | |
| `clipboardClearOnLock` | `ClipboardClearOnLock` | 布尔 | |
| `clipboardPasteOnClick` | `ClipboardPasteOnClick` | 布尔 | |
| `clipboardImageOcr` | `ClipboardImageOcr` | 布尔 | |
| `clipboardPanelPosition` | `ClipboardPanelPosition` | top / mouse / last | |
| `launcherPanelPosition` | `LauncherPanelPosition` | top / mouse / last | |
| `launcherShowsFrequent` | `LauncherShowsFrequent` | 布尔 | |
| `launcherFallbackAlways` | `LauncherFallbackAlways` | 布尔 | |
| `launcherRomanInput` | `LauncherRomanInput` | 布尔 | |
| `launcherScripts` | `LauncherScripts` | 布尔 | |
| `panelSqueezeEntrance` | `PanelSqueezeEntrance` | 布尔 | |
| `translateCopyRecognized` | `TranslateCopyRecognized` | 布尔 | |
| `translateScreenshotOverlay` | `TranslateScreenshotOverlay` | 布尔 | |
| `translateHistoryEnabled` | `TranslateHistoryEnabled` | 布尔 | |
| `translateHistoryLimit` | `TranslateHistoryLimit` | 整数 | 范围按 mac 设置页的档位核 |
| `translateFontScale` | `TranslateFontScale` | 小数 | mac 写 1.0 时编出来是 `1`，读回当整数，收下时再转小数（`Value` 的注释） |
| `translateCollapsedServices` | `TranslateCollapsedServices` | 文字 | **待核**：mac 是一段文字，Windows 可能是列表；服务编号两边同步过，意思一样 |
| `translateWordRecording` | `TranslateWordRecording` | 布尔 | |
| `translateWordAccent` | `TranslateWordAccent` | us / uk | |
| `ocrJoinLines` | `OcrJoinLines` | 布尔 | |
| `screenshotShutterSound` | `ScreenshotShutterSound` | 布尔 | |
| `screenshotToolbarAlign` | `ScreenshotToolbarAlign` | right / center | |
| `screenshotCopyAs` | `ScreenshotCopyAs` | image / file | |
| `scrollCaptureSpeed` | `ScrollCaptureSpeed` | slow / normal / fast | |
| `screenshotKeepsColors` | `ScreenshotKeepsColors` | 布尔 | |
| `screenshotFindsElements` | `ScreenshotFindsElements` | 布尔 | |
| `shotHistory` / `shotHistoryDays` / `shotHistoryMegabytes` | `ShotHistory` / `ShotHistoryDays` / `ShotHistoryMegabytes` | 布尔 / 整数 / 整数 | 天数、大小的档位第 1 批对一遍 |
| `statusScreenExitHint` / `statusScreenHotKeyEntersFirst` / `statusScreenAnimations` | 同名 | 布尔 | |
| `remindersSnoozeMinutes` | `RemindersSnoozeMinutes` | 整数 | |
| `notesFontSize` / `notesMarkdown` / `notesLineSpacing` | 同名 | 整数 / 布尔 / compact·standard·relaxed | |
| `notesDeckEnabled` `notesDeckEdge` `notesDeckStyle` `notesDeckSize` `notesDeckSense` `notesDeckAlwaysFanned` `notesDeckHidesPill` `notesDeckPreview` `notesDeckOpensOnHover` `notesDeckOverFullScreen` `notesDeckNoteSize` | 同名 | 照 mac | Windows 照 mac 抄的值域；`notesDeckDisplay` 留在本机（E 组） |

### B 组：意思一样，键名或取值要换算

| mac 键 | Windows | 换算 |
|---|---|---|
| `appearance` | `Theme` | system / light / dark，值一样 |
| `accent` | `Accent` | **mac 默认 `system`，Windows 默认 `brand`**。`brand` 发成 `pink`（Windows 的品牌粉就是调色板里的 pink），收到 `system` 时 Windows 跟随系统强调色。其余颜色名**待核**：两边的调色板对一遍，Windows 没有的颜色进透传 |
| `updateAutoCheck` | `AutoCheckUpdates` | 布尔 |
| `clipboardHistoryRetentionDays` | `ClipboardRetentionDays` | 整数，档位一样。**会删数据**：收到更短的天数，到期的历史就删了，和 mac 一样在「合在一起？」里写明（mac 评审 H1） |
| `clipboardImageCacheMaxMb` | `ClipboardImageBudgetMB` | 整数 |
| `clipboardPastePlainByDefault` | `ClipboardPastePlain` | 布尔 |
| `clipboardClearOnExit` | `ClipboardClearOnQuit` | 布尔 |
| `clipboardLinkPreview` | `LinkPreviews` | 布尔 |
| `clipboardShowPreview` | `ClipboardShowLens` | **待核**：mac 是「显示预览」，Windows 是「透镜」那一栏，意思不一样就归 C 组 |
| `autoCopy` | `TranslateAutoCopy` | 布尔 |
| `translateClipboardMonitor` | `CopyTranslate` | 布尔（复制即译）。**会关掉**：要连同剪贴板的开关一起同步（mac H1） |
| `translateNativeLang` / `translateForeignLang` | `TranslateFirstLanguage` / `TranslateSecondLanguage` | 语言代码，两边是同一张表；Windows 没有的语言进透传 |
| `translateSourceLang` / `translateTargetLang` | `TranslateSource` / `TranslateTarget` | 同上（mac 没注册默认值：存过才同步） |
| `translateDeleteNewline` | `TranslateJoinLines` | **待核**：是不是同一个「去掉换行」 |
| `translateWordMode` | `TranslateWordLookup` | **待核**：mac 还有一个 `translateSystemDictionary`，两个开关对的是 Windows 的哪一个 |
| `translatePanelPosition` | `TranslateWindowPosition` | top / mouse / last |
| `screenshotPlacement` | `ShotPlacement` | **mac 默认 `corner`，Windows 默认 `card`**：card ↔ corner，none ↔ none；收到 `clothesline`（晾衣绳，Windows 没有）时进透传，本机不变 |
| `screenRecordFrameRate` | `RecordFps` | 整数，档位核一遍 |
| `screenRecordCountdown` | `RecordCountdown` | 整数 |
| `screenRecordShowsCursor` | `RecordCursor` | 布尔 |
| `screenRecordSharpness` | `RecordSharpness` | original / standard / … 值一样 |
| `screenRecordKeysShortcutsOnly` | `RecordKeysShortcutsOnly` | 布尔 |
| `screenRecordSystemAudio` | `RecordSystemSound` | 布尔 |
| `screenRecordShowsClicks` | `RecordClicks` | 布尔 |
| `audioRecordStartsImmediately` | `RecordInstantStart` | 布尔 |
| `feature.clipboard` `feature.launcher` `feature.translate` `feature.screenshot` `feature.record` `feature.notes` `feature.reminders` `feature.statusScreen` | `Features["clipboard"]` 等 | 布尔。mac 「没存过 = defaultOn」（便签、提醒、状态屏也是开），Windows 新装明写四个开、其余关（HANDTEST 1190）。两边新装都会明写，存过的才同步，所以照常对得上。**关掉别的电脑正在用的功能**：`isBusy` 里那几样先不合 |

### C 组：Windows 独有，只在 Windows 之间同步（D1）

| Windows | 为什么 mac 用不了 |
|---|---|
| `ClipboardExcludedApps`（exe 名） | mac 是 `clipboardExcludedBundleIDs`，存 bundle id，互相认不出 |
| `HotKeyBlockedApps`（exe 名）、`HotKeyBlockFullscreen` | mac 的 `hotKeyBlockedApps` 也是 bundle id（PLAN-v17 H8 已经分开了导出的键名） |
| `LauncherCommandAliases` `LauncherCommandsOff` `LauncherCommandHotKeys` `LauncherAppAliases` | 命令编号、App 的标识两边不是一套，快捷键写法也不一样（mac 这几项是一段 JSON 文字） |
| `LauncherRecentPrograms` `LauncherBookmarkBrowsers` `LauncherHistoryBrowsers` | 浏览器和「最近用过的程序」是 Windows 的来源（Edge、开始菜单） |
| `ScreenshotCursor` `CaptureHideDesktopIcons` | Windows 独有的截图选项 |
| `UpdateInstallOnQuit` | Windows 的更新方式 |
| `KeepAwakeSchedule` `KeepAwakeDisplay` `Features["keepAwake"]` | mac 0.9.0 拿掉了（§0）；同 mac B4，定时本来就不同步（PLAN-v20 D3），只同步「屏幕也不熄」和开关 |
| 全部全局快捷键 `HotKeys[*]`、截图工具栏的键 `ScreenshotKeys[*]` | D2 |

### D 组：mac 独有，Windows 不落、原样透传

`statusItemVisible` `statusItemStyle` `dockIconOnTahoe` `clipboardHideOnUnfocus` `floatingPinned`（这几项 mac 自己也留在本机）、
`clipboardExcludedBundleIDs` `hotKeyBlockedApps`、`launcherBrowserBookmarks` `launcherBrowserHistory`、`launchpad*` 全部、`dockPreview*`、`finder*`、
`island*` 全部、`screenRecordCodec`、`emojiPackDownloads`、`translateSystemDictionary`（待核）、`feature.launchpad` `feature.dockPreview` `feature.finderMenu` `feature.island`，
mac 的全部 `hotkey:*` 和 `shotkey:*`，以及以后 mac 新加、这一版不认识的编号。

透传的意思是：Windows 一项都不落进设置，下一轮原样交回去。Windows 本来也没有这些设置，所以「本机自己又改了它」这种情况不会发生。

### E 组：留在本机，两边都不同步

- 跟着 mac `localKeys` 的：录屏要不要录麦克风（`RecordMicrophone`、`RecordMicrophoneDevice`）、录音的来源（`AudioSource`）、
  录屏显示按键（`RecordKeys`）、便签放在哪块屏幕（`NotesDeckDisplay`、`NotesDeckChosenDisplay`），还有图钉（`TranslatePinned`）。
- 跟着电脑走的：开机启动（`StartWithWindows`）、窗口位置和大小（`*Left` `*Top` `*Width` `*Rows` `TranslateWindowX/Y/Width/MaxHeight` `ScreenshotLast*`
  `NotesFloat*` `NotesDeckPosition` `NotesWindowLayout`）、文件夹路径（`ScreenshotSaveFolder` `RecordDirectory` `LauncherScriptFolders`
  `LauncherAppFolders` `LauncherHiddenApps` `BackupCopyFolder` 和各个临时路径）、每日备份（`DailyBackup`）、
  同步本身（`Sync*`），还有状态和记号（`NotifiedUpdateVersion` `UpdateSkippedVersion` `LastRunVersion` `WhatsNew*` `NotesSampleAdded`
  `NotesDeckHintShown` `NotesRecentColors` `LauncherRecentCurrencies` `StatusScreenLastPreset` `RemindersState` `SettingsCollapsedGroups`
  `SettingsShowsOffFeatures`）。
- mac 也不同步的：`ScreenshotToolStyles`（mac 没注册默认值，不导出也不同步）。
- 已经各自成一类的：`TranslateServices`、`LauncherSearchEngines`、`StatusScreenPresets`、`Reminders`（mac 也是）。

### 快捷键：动作编号对照（D2 选 B 时才用得上）

| mac `HotKeyAction` | Windows `HotKeyActions` | 两边默认 |
|---|---|---|
| `clipboard` `launcher` `inputTranslate` `screenshotTranslate` `translateReplace` `audioRecord` `pinClipboard` `shotHistory` `home` `statusScreen` `reminderNew` `noteCapture` `noteNew` `noteAll` | 同名 | ⌥C / Alt+C、⌥Space / Alt+Space、⌥T、⌥S、⌥N 一样；其余两边都是不设 |
| `selectionTranslate` | `selectionTranslate` | **⌥D / Alt+E**（Alt+D 在浏览器里是地址栏） |
| `screenshot` | `screenshot` | **⌥A / Alt+X** |
| `screenshotLastRegion` | `screenshotLast` | 编号不一样 |
| `screenRecord` | `record` | 编号不一样 |
| `recognizeText` | `ocr` | 编号不一样 |
| `launchpad` `island` `clothesline` | — | mac 独有 |
| — | `keepAwake` | Windows 独有 |

mac 存的是虚拟键码（kVK）+ Carbon 修饰键（⌘ ⌥ ⌃ ⇧），Windows 存的是 `Alt+C` 这种文字（VK + Alt / Ctrl / Shift / Win）。⌘ 在 Windows 上没有对应的键（Win 键大多被系统占着），
两边的默认键也是刻意不一样的。

### 启动器收藏：类型对照（D5 选 B / C 时才用得上）

mac `LauncherItem.Kind`：`app` `action` `url` `path` `system` `script`……。Windows `LauncherKind` 存的是 `App` `Setting` `Command` `Action` `Url` `Path` `Script`（首字母大写）。
两边都能打开的只有 `url`（网址）。`app` / `path` / `script` 的目标是这台电脑上的路径；`Setting`、`Command` 是 Windows 自己的设置页和系统命令，mac 不认识这两种类型。

## 2. 要拍的

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| D1 | Windows 独有的设置（C 组）放哪 | **A** 新开一类 `windows-settings.json`：只有 Windows 读写，mac 不认识这个文件<br>**B** 和 mac 共用 `settings.json`，编号加 `win:` 前缀，mac 透传 | **A**。<br>• B 会让每台 Mac 的透传里存着一份 Windows 的设置、每轮原样交回去。<br>• 更麻烦的是 `adopt`：B 的话一台 Windows 第一次加入「只有 Mac」的文件夹时，会把自己的 C 组全清回默认（文件夹里没人有这些键）；A 的话，Windows 之间各自第一次合，互不牵连。<br>• mac 会不会删掉不认识的文件：mac 只写自己设备的子文件夹；服务器镜像里不认识的路径一律跳过（`NoteSyncServer.known` 返回 nil）。第 3 批照这两处再读一遍，再用本地临时文件夹实测 |
| D2 | 全局快捷键、截图工具栏的键跨不跨平台 | **A** 不跨：Windows 的键放进 `windows-settings`，只在 Windows 之间同步；mac 的 `hotkey:` `shotkey:` 原样透传<br>**B** 跨：kVK ↔ VK、⌥ ↔ Alt、⌃ ↔ Ctrl、⌘ ↔ Win（或 Ctrl），按上面那张动作对照表改编号 | **A**。<br>• 两边默认键刻意不一样（⌥D / Alt+E、⌥A / Alt+X），换算过去会把 Windows 的划词翻译改成 Alt+D，抢浏览器的地址栏。<br>• ⌘ 没有好的对应：换成 Ctrl 会撞上各个 App 的快捷键，换成 Win 又多半被系统占着。<br>• mac 收到不能当全局热键用的组合会拒收（`HotKey.isUsable`），Windows 也一样，换算出来很多键会两头落不下 |
| D3 | 怎么不把 Mac 独有的设置清掉（§0 的坑） | **A** Windows 先不写 `settings.json`，等文件夹里有了别的电脑的 `settings.json` 再写（那就一定有 Mac）。在那之前，A、B 组的设置在 Windows 之间先放在 `windows-settings` 里同步；有了 Mac 之后，Windows 第一次合 `settings` 这一类、跟着 Mac（adopt），`windows-settings` 里的 A、B 组从此只发不落（第 1 批定的细节：这一类里 A、B 组编号的删除一律不落——Windows 本机从不删一项设置，这一类里出现它的删除只会是切换那一刻留下的；所以照发也不会白来回）<br>**B** 照常写，请 mac 那边改 `adopt`：对面一条 `hotkey:` 都没有的时候不动本机的快捷键，对面那台不认识的键也不清（要 mac 改代码、发一版，不在 `windows/` 的范围）<br>**C** 照常写，接受这个坑，只在设置页写一句提示 | **A**。只在 `windows/` 里改，Mac 一个字都不用动。<br>• 一台 Mac 加入只有 Windows 的文件夹时，文件夹里没有 `settings.json`，它就是第一台，自己的设置原样留着。<br>• 一台 Windows 加入有 Mac 的文件夹时，跟着 Mac（同 mac C4）。<br>• 代价是一份规则：「`windows-settings` 里的 A、B 组编号在有了 Mac 之后只发不落，删除任何时候都不落」，每台 Windows 跑的是同一份代码，按同一个条件切换，不会打架。<br>• 第 2 批用三台假电脑（两台 Windows 测试档 + 一份照 mac 格式写的假 Mac 文件夹）把切换前后、谁先加入都测一遍 |
| D4 | 「只同步改过的」在 Windows 上怎么算（mac 看的是持久域里有没有这个键，Windows 的 `settings.json` 每项都写） | **A** 记一份「存过的键」：用户在设置里改过的、同步或导入落下来过的才算存过（同 mac 持久域）；改回默认值**还是**存过（mac 也是）<br>**B** 值和 mac 默认不一样就发 | **A**。<br>• B 会在收到 Mac 那条「值等于默认值」的记录、落下去之后，下一轮把它算成「本机删了」，写出去一块墓碑，Mac 那边跟着删掉这个键，白来回一次。<br>• 存过的键记在 `settings.json` 的新字段 `SyncStoredKeys`，和透传、改的时刻放一起（D6）。<br>• 「默认」按本机（Windows）的默认算：值和本机默认不一样的就算存过（升级上来的人第一次算也是这一条）；同步删掉一项 = 回到本机默认、不再算存过。所以 Windows 的强调色（品牌粉）、截完放「卡片」这种默认值本来就和 mac 不一样的，没动过就各自留着各自的默认（第 1 批定的细节） |
| D5 | 启动器收藏怎么同步 | **A** 新开一类 `windows-launcher.json`：只在 Windows 之间同步，mac 的 `launcher.json` 不读也不写<br>**B** 共用 `launcher.json`：Windows 的类型换成 mac 的小写名，Windows 独有的类型照发<br>**C** 共用，但只发网址（`url`），mac 的别的收藏在 Windows 上藏起来、不删 | **A**。<br>• B 的话，mac 收到 `setting` / `command` 这种不认识的类型时整类停下、说「先更新」（`LauncherUsage.applySync` 返回 `.newer`）；Windows 的 App 收藏在 mac 上也是打不开的一格，还占着 8 个位置之一。<br>• C 能用，但顺序（`~order`）只有一条：两边各自只看得见一部分，挪一下就把对面的顺序搅乱。<br>• A 只少了「两边同一个网址收藏」这一点；以后要的话，再单独给网址开一类 |
| D6 | 透传、改的时刻、存过的键存哪 | **A** `settings.json` 里的三个新字段（同 mac 存在偏好里），不导出、不进每日备份的「设置」一类<br>**B** `sync-ledger.json` 旁边另开一个文件 | **A**。和设置写在同一个文件、同一次「写临时文件 → 替换」里，不会出现设置写了、记号没写的情况（mac 也是因为偏好没有事务才这么放）。账本照 PLAN-v5，放在 `sync-ledger.json` |
| D7 | 升级上来、已经开着同步的人 | **A** 同 mac R1（`e910f432`）：新的三行（「设置与快捷键」「Windows 独有的设置」「启动器收藏」）先不勾；勾上「设置与快捷键」时先问「和已经在同步的电脑合在一起？」，写明保留天数、「不记录的应用」、功能开关会跟着换；在设置页的同步那一节写一行提示<br>**B** 默认勾上 | **A**。mac 0.7.0 就是因为默认勾上，先升级那台把后升级那台的设置整套换掉、还按对面的保留天数清了历史，才有了 R1。新装、第一次开同步的人三行照常默认勾上（同别的几类） |
| D8 | 「设置与快捷键」和「Windows 独有的设置」在设置页里分不分开 | **A** 一行「设置与快捷键」，同时管两个文件<br>**B** 两行 | **A**。用户分不清 A / B / C 组；mac 也只有一行。启动器收藏另一行 |

## 3. 分批

| 批 | 内容 | 验 |
|---|---|---|
| 1 | **Core 的对照表和编码**：`Core/Sync/SettingsSyncMap.cs`，A、B、C 组一项一行：mac 键或 Windows 键、怎么从 `AppSettings` 读和写、编成 mac `Value` 的 JSON（键排好序、不转义斜杠和非 ASCII，同 `SyncRecords.encoder`）、怎么核值域、mac 默认值是什么；`decodeExact` 的规矩（编回去不一字不差的当落不下，进透传）；透传、改的时刻、存过的键的算法（D4、D6），都写成纯函数。先把对照表里「待核」的几项对完、写进表头注释。 | 单测：每个 A、B 组的键编出来的那一行和 mac 一字不差（golden 行在 Mac 上用 mac 的 `SettingsSync` 编出来，做法同 `ReminderTests`；这一步要 Mac，交给 mac 那边的会话或用户），换算来回不变，超出范围的进透传，不认识的编号进透传、原样交回去，存过的键升级时只算一次 |
| 2 | **`settings` 和 `windows-settings` 两类接进执行层**：`SyncFolder.Sources()` 里加 `SettingsSource`（mac 格式）和 `WindowsSettingsSource`，账本在 `sync-ledger.json`；D3 的切换条件（文件夹里有别的电脑的 `settings.json`）；`isBusy`（录屏 / 录音、正在录快捷键、状态屏开着）；落下去之后走导入的那条收尾（主题、强调色、热键重新注册、功能起停、拦截名单刷新）；两个动作撞了同一个键，用轻提示说一声；`SettingsService` 存盘时比出哪几项变了，记下改的时刻（攒到这一轮空下来再比，同 mac `recordChanges`）。 | 三台假电脑的随机测试（两台 Windows `MemorySource` + 一份照 mac 格式写的假 Mac）：谁先加入、中途加入 Mac、Mac 的 `hotkey:` 原样留着、Mac 独有的键不被清、Windows 之间 C 组照常同步；两个 Release 测试档在本地临时文件夹里真跑一轮（改主题、改快捷键、关一个功能，另一台跟上）；本地临时 WebDAV 服务器跑一轮；内存、空闲 CPU；一轮没变化的时候整轮跳过（mac `03f47047`：783 → 6 ms） |
| 3 | **`windows-launcher` 一类**：`LauncherFavorites` 实现 `ISyncSource`，编号 = 类型 + 目标的哈希，顺序单独一条，union，和 `launcher_favorites` 同一个事务；还原不出来的照旧藏起来、不删；两台各加一个时不卡 8 个（同 mac）。再读一遍 mac 文件夹和服务器镜像对不认识的文件怎么处理，写进 REVIEW。 | 单测（mac `LauncherUsage` 那几条照搬）；两个测试档各收藏一个，挪一下顺序，另一台跟上；假 Mac 文件夹里的 `launcher.json` 一个字节都没变 |
| 4 | **设置页和升级**：同步那一节加「设置与快捷键」「启动器收藏」两行；D7 升级上来的不勾、勾上时先问「合在一起？」，问的时候写明会换掉什么；轻提示写「设置跟着 <电脑名> 换了」；导出导入不动（导入照旧跳过 Mac 文件里的设置和快捷键）。`MAC-DIFF.md`「还没对齐」那一条删掉，写进长期例外：快捷键不跨平台、Windows 独有的收藏不跨平台。 | `--ui-snapshots` 的 `settings-sync`（浅深、升级上来的那种、问的那一句）；新写的 `--sync-settings-probe`（测试档）走一遍勾上、合、提示；HANDTEST 加真机条目：一台 Mac + 一台 Windows 用同一个文件夹 |

每批都照常：Debug 和 Release AOT x64 / ARM64 0 警告，`dotnet test` 全过，内存探针、空闲 CPU，截图推 `windows-shots`，一批一个提交、报告写在正文，REVIEW 一行，rebase 再 push。
**所有自动化只用测试档、临时文件夹和本地临时服务器，不碰真的同步文件夹、真账户。**

## 4. 不做

| 项 | 为什么 |
|---|---|
| 快捷键跨平台（D2 B） | 见 D2 |
| 启动器收藏跨平台（D5 B / C） | 见 D5 |
| 改 mac 的 `adopt`（D3 B） | 不在 `windows/` 的范围；D3 A 不需要它 |
| 窗口位置、文件夹路径、开机启动 | 跟着电脑走，mac 也不同步 |
| 保持唤醒并进 mac 的键名 | mac 0.9.0 拿掉了；等它从 `plugins-wip` 回来再对 |
