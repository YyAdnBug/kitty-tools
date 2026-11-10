# Kitty Tools Windows 版：第十七版方案（按 App 停用快捷键）

2026-11-10。用户转来的反馈：全局快捷键和某些软件自己的快捷键撞了，希望能设成「在这些软件里 Kitty 不响应，把按键让给它」，
mac 和 Windows 都要。拍板页 https://claude.ai/artifact/FKGz6fNopMTW97NsqeFMqS（7 题，用户「全部按推荐」）。

**这一版由 Windows 的 agent 自己写、自己编译、自己验**（同 PLAN-v16）。行为、默认值、文案照 mac（`AGENTS.md`「跟 mac 走」），
Windows 自己要定的写在 §3，带推荐答案，**照推荐做**。一批，照 `AGENTS.md`「每一批的流程」和自查清单走；交接写在 `REVIEW.md`
「PLAN-v17」，手测接着 `HANDTEST.md` 末尾往下编。**PLAN-v16 做完再做这一版。**

**mac 那一半**：分支 `hotkey-block-wip`（检出 `kitty-tools-macos-hotkeyblock`，从 macos `80e01660`），一个提交，2026-11-10 写这份文档时
**还没推**，看不到源码就照本文做；推了以后看 `macos/KittyTools/Shell/HotKeyBlock.swift`（纯函数）、`Shell/HotKeyCenter.swift`
（`frontChanged` / `reload`）、`Settings/HotKeyBlockSection.swift`、`App/AppDelegate.swift` 的 `addHotKeyBlockItem`。

## 1. 为什么要注销，而不是触发时「不做事」

`RegisterHotKey` 注册的组合，按下时系统把 `WM_HOTKEY` 投给我们，**前台窗口收不到这一下**（mac 的 Carbon 热键一样，mac 那边实测过）。
所以光在 `HotKeyManager.OnHotKey` 里判断前台、不做事不够，键还是没了。要让键真的到那个软件，只能在它成为前台之前把组合注销。

否掉的做法：
- **触发时判断，再用 `SendInput` 把键补发回去**：发出去的键又会撞上自己注册的热键，只能先注销、发、再注册，时序很脆；以管理员身份运行的窗口
  还收不到我们发的键（UIPI）。
- **改用低级键盘钩子（`WH_KEYBOARD_LL`）自己判断放不放行**：每个按键都过一遍本进程，回调慢了系统会摘掉钩子；不提权时管理员窗口在前台
  收不到（PowerToys Command Palette 的设置页写明开了低级钩子后管理员软件在前台时快捷键不灵）；杀毒软件也敏感。

## 2. 要做的

| # | 内容 | 和 mac 一样的地方 / Windows 怎么做 |
|---|---|---|
| H1 | **名单**：设置里一个字符串列表 `HotKeyBlockedApps`（`Settings.cs`，默认空）。一条一个软件：`exe 名` = 全部快捷键；`exe 名\|动作,动作` = 只停这几个全局动作（动作 id 用 `HotKeyActions` 的那串）。exe 名按文件名、不分大小写匹配（同剪贴板「排除的应用」）；同一个 exe 出现两次只认第一条；不认识的动作 id（以后加的）原样留着、写回去。 | mac 是 bundle id，其余一样。纯函数放 Core（`HotKeyBlock`：解析 / 写回、「此刻停哪些」、勾选一个动作后的结果），单测照 mac 的 `HotKeyBlockTests`：往返、坏条目和重复、全部 / 只停几个 / 空的当没停、从「全部」取消一个 = 只停看得见的其余几个、不认识的动作 id 留着。 |
| H2 | **前台切换时注销 / 注册**：`SetWinEventHook(EVENT_SYSTEM_FOREGROUND, …, WINEVENT_OUTOFCONTEXT)`（`Notes/NoteDeck.cs` 有现成写法），回调里取前台窗口的进程路径（照 `Clipboard/ClipboardFormats.cs`：`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `QueryFullProcessImageName`，取不到当没匹配上）。算出这个前台的规则，**和上次注册时的规则一样就什么都不做**（大多数切换都是），不一样才动 `HotKeyManager`。 | 同 mac 的 `frontChanged`。`HotKeyManager` 加一个「停用规则」参数：`RegisterAll` 跳过被停的动作。只动变了的那几个 id 更好（整套重来会清掉失败原因、设置页那几行橙字闪一下）；嫌麻烦整套 `RegisterAll` 也行，但要保留失败原因。 |
| H3 | **「全部」连别的一起停**：Windows 现在只有全局动作的热键；以后有了启动器命令的快捷键、连按修饰键，也归「全部」管，「只停几个」只管勾的全局动作。录屏倒数的临时 Esc（`RecordingCountdown.cs`）不受名单管。 | 同 mac。 |
| H4 | **暂停期间不动**：截图框选、状态屏、录快捷键时 `UnregisterAll()` 停着热键（`ScreenshotSession.cs`、`ShellRuntime.cs`），这时前台变了不注册；停的那一方结束时 `RegisterAll` 按那时的前台算规则。**注意**：结束时是不是要重新注册，如果是看「有没有注册着的热键」，要把「因为停用才没注册」也算上，不然在名单软件里开的截图结束后热键就一直停着（mac 的 `isActive` 踩过这一下，见 mac `HotKeyCenter.blockedSomething`）。 | |
| H5 | **设置 › 快捷键 最下面一节「在这些应用里停用」**：照剪贴板「排除的应用」那一节（`SettingsWindow.cs` `BuildExcludedApps`：一行一个，图标 + 显示名 + 灰色的 exe 名 + 移除；「选择应用…」从正在运行的程序里选或浏览 exe）。每行右边一个下拉：「全部快捷键」（默认）或勾几个全局动作（分组同快捷键页那几节、只列开着的功能的），文字是「全部快捷键」/「N 个快捷键」/「没有停用的」。空着时写「没有停用快捷键的应用」。说明一句：「名单里的应用在前台时，上面的快捷键不响应，按键交给那个应用。也可以在那个应用里打开托盘菜单，从菜单里停用。」 | 文案同 mac（mac 写「App」，Windows 写「应用」，同剪贴板那一节的叫法）。 |
| H6 | **托盘菜单一项「在「某应用」中停用快捷键」**，已经在名单里时写「在「某应用」中恢复快捷键」；放在「设置…」上面。停用加的是「全部快捷键」，恢复把那一条整个删掉；点了胶囊（刘海岛的 Windows 版）说一声「「某应用」里不再响应快捷键」，副标题「按键交给它；设置 › 快捷键 里可以改」，恢复时「「某应用」里恢复了快捷键」。 | **点托盘时前台已经变成任务栏**：用 H2 那个钩子顺手记「最后一个不是我们、也不是任务栏 / 桌面的前台窗口」（窗口类 `Shell_TrayWnd`、`Shell_SecondaryTrayWnd`、`NotifyIconOverflowWindow`、`TopLevelWindowForOverflowXamlIsland`、`Progman`、`WorkerW` 这些跳过，实测补全），菜单用它；它是我们自己、资源管理器（`explorer.exe`）或已经关掉了就不出这一项。 |
| H7 | **全屏游戏时停用快捷键**（§3 W1）：快捷键那一节里一个开关，**默认开**，跟着导出导入。 | 见 §3。 |
| H8 | **导出导入**：`ArchiveService` 里和 `clipboardExcludedApps` 一样手写一段，键名用 **`hotKeyBlockedExes`**（和 mac 的 `hotKeyBlockedApps` 分开：mac 存 bundle id，导进对方那边只会多出几行认不出的）；上限 200 条、每条 512 字以内，导入时照 H1 的解析过一遍；`hotKeyBlockFullscreen`（W1 的开关）一起带。导入名单不算「会删数据 / 会关掉保护」，`ImportReview` 不用加。 | mac 的名单跟着设置同步走；Windows 没有设置同步，不做。 |

## 3. Windows 自己定的（照推荐做）

| # | 问题 | 推荐 |
|---|---|---|
| W1 | 「全屏游戏」怎么认 | `SHQueryUserNotificationState`（`Screenshot/ShotFeedback.cs` 已经在用）返回 **`QUNS_RUNNING_D3D_FULL_SCREEN`（3）或 `QUNS_PRESENTATION_MODE`（4）** 才算。**不认 `QUNS_BUSY`（2）**：全屏看视频、F11 的网页也是它，那时截图、识字是正当用法。无边框全屏的游戏系统认不出来，要的人加进名单（说明里写一句）。 |
| W2 | 全屏进出系统不发通知，什么时候查 | 前台一变（H2 的回调）查一次；**热键触发时再查一次**：是全屏就什么都不做，并且按「全部」注销到下次前台变化——第一下被吞掉、后面几下就放行了。不加定时轮询（空闲 CPU 要是 0）。 |
| W3 | 以管理员身份运行的软件 | 不特别处理。`PROCESS_QUERY_LIMITED_INFORMATION` 一般拿得到它的路径（受保护进程除外），名单照样生效。**要实测一条**：名单之外，`RegisterHotKey` 在管理员窗口前台时触不触发（微软没写，社区普遍说会），结果写进报告；粘贴、划词往管理员窗口发键本来就不成（UIPI），不是这一版的事。 |
| W4 | 远程桌面 `mstsc.exe` | 不预置（拍板：默认名单空着）。**实测一条**：mstsc 全屏、「应用 Windows 组合键」是默认的「仅全屏时」时，本机热键还触不触发（推断它自己的低级钩子先把键拿走了）；窗口模式下本机热键照常触发，把 `mstsc.exe` 加进名单后按键到远端。 |
| W5 | 切前台很频繁时的开销 | 规则一样不动（H2），注册 / 注销十来个组合不到 1 ms（mac 量的是 8 个约 0.27 ms，Windows 量一下写进报告）。 |

## 4. 验收

- 单测：H1 的纯函数（照 mac 的五条）+ W1 认哪几个值。
- 截图：快捷键页那一节空着、三行（全部 / 只停两个 / 本机没装的 exe）各一张，浅色、深色、高对比度；托盘菜单那一项（停用、恢复）。
- 手测（接着 `HANDTEST.md` 末尾编号）：
  1. 记事本加进名单，在记事本里按 Alt+C：剪贴板面板不出来，记事本照常收到（Alt+C 在记事本里没有菜单，就换 Alt+E / Alt+O 看记事本的菜单弹开）；切到别的软件 Alt+C 照常出面板。
  2. 那一行下拉取消「截图」：记事本里 Alt+X 照常截图，Alt+C 仍然到记事本；勾回「全部快捷键」后 Alt+X 也停了。
  3. 在浏览器里点托盘图标：「设置…」上面一项「在「浏览器名」中停用快捷键」，点了胶囊说一声、设置页多一行；再点托盘是「…恢复快捷键」，点了那一行没了。在桌面上、资源管理器里点托盘时没有这一项。
  4. 名单里的软件在前台时从托盘开始截图，截完切到别的软件：快捷键都回来了。
  5. 独占全屏的游戏（或任意 D3D 独占全屏的测试程序）里按 Alt+X：不弹截图、游戏不被切走；第二下起键到游戏。关掉开关后照旧弹。全屏放视频、F11 网页时 Alt+X 照常截图。
  6. 以管理员身份运行的记事本：加进名单后同第 1 条；不在名单里时 Alt+C 出不出面板，写进报告（W3）。
  7. 远程桌面：W4 那两条写进报告。
  8. 设置 › 通用 导出再导入：名单和全屏开关跟着回来；mac 导出的文件导进来不出现名单的行。
  9. 快速 Alt+Tab 几十次：空闲 CPU 仍为 0，没卡顿，最后停在哪边快捷键就按哪边的规则。
- 报告写：量到的注册 / 注销耗时、W3 W4 的实测结果、替用户定的、没测的。
