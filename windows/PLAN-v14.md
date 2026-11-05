# Kitty Tools Windows 版：第十四版方案（翻译反馈四条）

2026-11-05。用户转来四条 mac 翻译窗口的反馈：系统词典卡没排版、想要更多免费词典、两个喇叭一个读原文一个把整张卡都念了、
想改启动器 / 剪贴板 / 翻译窗口的大小。mac 的拍板页（D1–D5 / S1–S6 / R1–R6 / W1–W4 / X1）用户「全部按推荐」，其中 **X1 定的是先做 mac、
Windows 下一轮写进 PLAN**——就是这一份。

**这一版不是新的拍板页**：行为、默认值、文案照 mac 已经拍板的（`AGENTS.md`「跟 mac 走」那张单子）；Windows 自己要定的写成 §3 的
V1–V12，每条带推荐答案，**照推荐做**，用户不同意的直接说，改起来都小。分工照 PLAN-v11 D10：Core / 服务 / 设置页 / 文案审查方在 Mac 写
（不编译）推上来，拖边这种要在屏幕上看手感的交 Windows 的 agent 边写边验；每批交接写在 `REVIEW.md`「PLAN-v14」。

对照的 mac：本机分支 `translate-wip`（检出 `kitty-tools-macos-translate`，**没 push、没并进 `macos`**），四个提交
`13b67633`（词典排版）、`8d581e5f`（朗读）、`318a5282`（免费服务）、`3e94388d`（面板大小），做法记在那边 `macos/PLAN.md` §10「翻译反馈四条」、
`.claude/skills/mac-translate/rule.md`（服务、朗读两段）、`mac-overlay-panel/rule.md` 第 9 行（拖边）、`macos/HANDTEST.md`「翻译反馈手测」1–14。
Windows 的 agent 读不到那个分支，**照本文做**；审查方写代码时对着 mac 源码。

## 1. 四条在 Windows 上怎么落

| # | mac 做了什么 | Windows |
|---|---|---|
| 1 词典 | 「词典」App 的牛津英汉汉英格式（A. B. 分词性、①② 义项、▸ 例句、去拼音）排进系统词典卡（D1–D5） | **不搬**：Windows 没有系统词典（PLAN-v3 §3.4）。替代是第 3 条的有道词典卡（V1） |
| 2 朗读 | 卡片喇叭只读译文、单词卡读第一行释义（R1）；单词卡第一行「美 /…/ 英 /…/」换成带小喇叭的一行（R2）；英文单词放有道真人录音、3 秒取不到退回系统声音，设置「朗读」两行（R3）；句子不接要冒充 Edge 的在线语音（R4 没做） | 照搬（V5–V8） |
| 3 免费服务 | 加有道词典（`youdaoDict`，只查单词和短语、不当主结果、不进静默替换，S2）；加系统翻译（`apple`，Translation 框架，S1）；Google 免费接口不做（429 反机器人，S3） | 有道词典照搬（V4）；系统翻译**不搬**，但要认得它（V2、V3） |
| 4 面板大小 | 启动器、剪贴板拖左右边改宽（560–1200）、拖下边改最多几行（6.5–14.5 按半行吸附）；翻译浮窗拖下边改最高多高；设置三页「面板大小」→「恢复默认大小」；六个键是这台电脑的（W1–W4） | 照搬，拖边用系统的（V9–V12） |

**不做**（mac 也不做的照旧）：选声线、朗读速度、DeepL / 必应 / 火山的免费网页接口、Google 留空走免费接口、微软 Edge「大声朗读」的在线语音
（要伪造扩展来源和浏览器标识，违反「只如实标明自己、不冒充别的客户端」）、快速记一条和主界面改大小。

## 2. 分批

| 批 | 内容 | 谁写 | 主要文件 |
|---|---|---|---|
| 1 | **服务**：认得 mac 新加的两种（`youdaoDict`、`apple`）和以后不认识的种类（V2、V3）；有道词典服务（V4）：Core 的 `YoudaoDict.Entry`、`WordLookup.IsPhrase`，Provider，主结果 / 静默替换跳过它，设置里的状态和测试连接 | 审查方（Mac） | `KittyTools.Core/YoudaoDict.cs`、`WordLookup.cs`、`TranslateSession.cs`，`Translate/Providers/YoudaoDictProvider.cs`、`TranslateServices.cs`、`TranslateCoordinator.cs`、`Settings/SettingsWindow.Translate.cs` |
| 2 | **朗读**：Core 的读哪段字 / 读音行 / 录音地址（V5、V6、V7），`Speech.ToggleWord`（下载、缓存、退回系统声音），卡片喇叭、读音行小喇叭、原文框喇叭，设置 › 翻译「朗读」一组（V8），导出清单加两个键 | 审查方（Mac），读音行的样子 Windows 截图核验 | `KittyTools.Core/SpeechText.cs`、`Shell/Speech.cs`、`Translate/TranslateCardView.cs`、`TranslateWindow.cs`、`Storage/ArchiveService.cs`、`App/Settings.cs` |
| 3 | **面板大小**：Core 的行数换算 / 吸附 / 翻译高度上限（审查方写）；三扇窗口的拖边、记宽度和行数、拖的时候不按内容改高度、设置三页「面板大小」（Windows 边写边验） | Core 审查方，窗口 Windows | `KittyTools.Core/LauncherListLayout.cs`、`ClipListLayout.cs`、`TranslateSession.cs`，`Shell/OverlayWindow.cs`、`Translate/TranslateWindow.cs`、`Clipboard/ClipPalette.cs`、`Launcher/LauncherPanel.xaml.cs`、设置三页 |

- **版本（推荐）**：第 1 批里「认得 `youdaoDict` / `apple`」那一小块（V2、V3）**进 0.2.0**——mac 带着这两种服务发版之后，同步、导入过来的
  有道词典今天会落到 `TranslateServiceStore.Translate` 的 `_ =>` 分支被当成 AI 服务跑、每次都报错卡。其余随 0.2.0 之后那一版，版本号、
  更新日志等核验时和别的一起定，**不发布、不打 tag**。
- 手测：`HANDTEST.md` 末尾另起一节「PLAN-v14 翻译反馈」，编号接着当时最后一条往下排（便签 PLAN-v13 正从 1043 起占号），照 mac「翻译反馈手测」
  2、4–8、10–14 改写（1–3、9 是系统词典 / 系统翻译，不搬）。`MAC-DIFF.md` 记三条：没有系统词典卡、没有系统翻译、拖边多两个下角（V9）。

## 3. Windows 自己要定的（推荐答案，照推荐做）

### 服务（第 1 批）

- **V1 系统词典卡不搬，有道词典当替代。** 推荐：不搬（Windows 没有系统词典，也没有可调用的本机英汉词典）；单词模式照旧只认 `WordLookup.IsWord`
  （2–3 个词不算单词，第四轮体检 U2），**不拿有道的结果反过来定「是不是单词」**（那样要等网络回来才知道走哪个提示词）。
- **V2 系统翻译（`apple`）不搬，但认得它。** 推荐：不进设置「+」；从 mac 同步、导入来的**留在列表里**（同步、导出原样带回去，不然 Windows 一合
  就把 mac 上的删了），翻译时**不开它的卡**，设置列表那一行灰字「只在 Mac 上能用」，开关照常能关。替用户定的：mac 15 上是开卡报「要 macOS 26」，
  Windows 永远用不了，每次翻译都多一张错误卡没意义。
- **V3 不认识的种类同样处理。** 推荐：`TranslateServiceStore.Translate` 的分发改成 `TranslateKinds.Ai => AiServiceProvider`、不认识的种类不开卡
  （今天 `_ =>` 一律当 AI 服务）；设置里灰字「这一版不认识这个服务，更新后可用」。mac 以后再加种类、Windows 没跟上时不会出错卡，也不会把它删掉。
  同步（`ServiceSync`）和导入（`SettingsArchive.Read` 只查长度）本来就原样收下，不用改。
- **V4 有道词典（mac S2）。** 照 mac：
  - 种类字符串 `youdaoDict`、默认名「有道词典」（**和 mac 一字不差**：同步、导出靠它认），加进 `TranslateKinds.All` 和 `IsBuiltin`（「+」里能加），
    logo 用有道的那张（同「有道翻译」），标识色照 mac `#E1251B`。
  - 请求：`GET https://dict.youdao.com/jsonapi?q=<词>&dicts={"count":99,"dicts":[["ec","ce","blng_sents_part"]]}`（只要英汉、汉英、双语例句三节，
    整份 130 KB 这样约 5 KB），不签名、不带冒充别的客户端的请求头，超时同别的服务（30 s，`TranslateHttp.Shared`）。
  - 写成单词卡的样子（Core `YoudaoDict.Entry(JsonElement)`，纯函数，单测照 mac `FreeServicesTests` 的两组、样本 JSON 照抄）：英汉 =
    「美 /…/  英 /…/」+ 每个词性一行（`trs[].tr[0].l.i` 第一个字符串）+「变形：…；…」+「例：英文 中文」；汉英 = 拼音一行 + 每条「pos 文字」
    （`i` 是字符串和 `{"#text": …}` 混着的数组）；只有读音、没有释义的算没查到，报「有道词典里没有这个词」。
  - 只查单词和短语：`IsWord || IsPhrase` 才开它的卡（`WordLookup.IsPhrase` = 2–3 个词、每个词字母开头、只含字母 / 连字符 / 撇号、一行 ≤ 40 字，照 mac）；
    `TranslateSession.Primary` 跳过它（给的是释义，不是译文：写历史、自动复制、收藏、替换原文都认后面那张翻译卡），「划词翻译并替换」的静默替换也跳过。
  - 设置：没有「密钥」一节，状态「免费 · 只查单词」，测试连接查 hello。**坑**：`TranslateKinds.SecretField(kind)` 是 `SecretFields(kind)[0]`，
    有道词典没有密钥字段，返回空数组会越界——`SecretFields` 给它空数组，所有取 `[0]` 和「字段都填了才算能用」的地方先判空（状态行、`HasAnyUsableService`、
    同步搬密钥的循环）。
  - 不是流式的服务：没有彗星边框、不按 Markdown 显示（同 Google、DeepL 那几家）。

### 朗读（第 2 批）

- **V5 卡片喇叭只读译文（mac R1）。** 照 mac `Speaker.speechText`，搬成 Core `SpeechText.ForCard(text, wordStyle)`：单词卡（大模型单词模式
  = `request.IsWord` 且是流式服务，或有道词典）读第一行释义——跳过读音行、拼音行、「例 / Example / e.g.」开头的行，去掉行首 `n.` `v.` `adj. & adv.`
  这类词性记号；别的卡先去掉 Markdown 记号再读整段（先看 `InlineMarkdown.Parse` 拼出纯文字够不够用，够就不另写，单测照 mac `SpeakerTests` 四组）。
  **坑**：`TranslateCardView` 现在拿 `Speech.Speaking == card.Text` 判断「正在读这张」，改了读的字以后要拿读的那段比，不然按钮不亮、再点不停。
- **V6 读音行带小喇叭（mac R2）。** 单词卡第一行整行只是「美 /…/」「英 /…/」时（`SpeechText.PhoneticLine`，粗体记号去掉再看；流式中第一行没出完不换），
  换成一行「美 /rʌn/ 🔊  英 /rʌn/ 🔊」：音标正文字号、次级颜色，小喇叭用 Segoe Fluent 的 Volume 字形、12 号、点了读那个口音，正在读的那个填实变强调色；
  读屏名「美音朗读 run」「英音朗读 run」。正文从第二行开始照旧显示。
- **V7 英文单词真人发音（mac R3）。**
  - 地址 `https://dict.youdao.com/dictvoice?audio=<词>&type=1|2`（1 英、2 美），只给像英文词的（ASCII 字母、空格、连字符、撇号，1–3 个词、≤ 40 字，
    照 mac `recordingURL`，Core 纯函数配单测）；别的一律系统声音。
  - 取：**3 秒超时**（单独一个短超时的请求，别用 30 s 的 `Shared`）、要 200 + `audio/*`、非空、≤ 1 MB；按「词 + 口音」在内存里记最近 32 个
    （`// ponytail:` 满了整个清掉，同 mac）。播：现有的 `MediaPlayer`，`MediaSource.CreateFromStream(InMemoryRandomAccessStream, "audio/mpeg")`。
  - 取不到（没网、超时、不是音频）退回系统声音，**不报错**：美音挑 en-US、英音挑 en-GB 的系统声音；**替用户定的**：中文版 Windows 常常没装英式声音，
    en-GB 没有就用 en-US，再没有用系统默认，都不提示。
  - 谁走它：原文框喇叭（原文是英文单词时）、读音行的小喇叭。卡片喇叭读的是释义（中文），照旧系统声音。
  - 日志只记 `speech.recording-failed reason=timeout|status|type`，**不记词、不记地址**（AGENTS 红线）。
- **V8 设置 › 翻译「朗读」一组（mac R3、R4），放在「查词」后面。** 两行：「英文单词用真人发音」开关（默认开），说明「单词会发给有道词典取录音；取不到时用系统声音」；
  「英文单词发音」美音（默认）/ 英音。组末一句次级小字：「句子用系统声音：在 Windows 设置 › 时间和语言 › 语音 里添加语音，可以换更自然的声音」。
  两个键**名字和值同 mac**：`translateWordRecording`（bool，默认 true）、`translateWordAccent`（`us` / `uk`，默认 `us`），加进 `ArchiveService.PreferencesOf`
  的白名单跟着导出导入（mac 注册了默认值，会导出）。

### 面板大小（第 3 批）

- **V9 用系统的拖边，不自己画拖边条。** 推荐：剪贴板、启动器的 `OverlayWindow` 改成 `IsResizable = true`（翻译浮窗已经是），窗口子类化处理三条消息：
  `WM_NCHITTEST` 把顶边和两个上角改回 `HTCLIENT`（顶边不动，同 mac；也免得和「按住空白处拖动挪面板」抢）；`WM_SIZING` 按拖的那条边（`WMSZ_*`）
  把宽、高夹进范围；`WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` 包住「用户正在拖」——这期间内容变化不改高度（同 mac `isDraggingHeight`），松手才记、
  再按新上限改一次高度。**替用户定的**：下面两个角也能拖（Windows 用户习惯拖角，一次改宽和行数），mac 没有角。
  风险（写进核验指令）：`SetBorderAndTitleBar(true, false)` + `ExtendsContentIntoTitleBar` 时系统拖边是窗口外那圈看不见的边，要实测鼠标移上去
  出不出箭头、亚克力会不会在拖的时候闪；不行的退路是在内容里铺三条 6 DIP 的透明条自己发 `WM_NCLBUTTONDOWN`（`HTLEFT` / `HTRIGHT` / `HTBOTTOM`）。
- **V10 范围和吸附（照 mac）。** 剪贴板、启动器宽 560–1200 DIP（默认 720，也不超过那块屏工作区的宽），最多几行 6.5–14.5、按半行吸附（默认 8.5，
  就是现在的 `LauncherListLayout.VisibleRows`、`ClipPalette.MaxListHeight`）；启动器分组标题、计算器那种高行照旧按实际高度算，「行」= 普通行高。
  翻译浮窗宽照旧 420 起、上限是工作区宽；拖下边定「最高多高」：`TranslateSession.PanelHeight` 加一个 `cap` 参数——拖过就照它（前三张卡也不例外、
  在卡片区里滚），内容少时照样变矮，夹在 220 和工作区高减 24 之间（单测照 mac `PanelSizeTests.translateCapWins` 六条）。行数换算、吸附都是 Core 纯函数配单测。
- **V11 记在哪、跟不跟导出。** 这台电脑自己的状态（同 mac 不注册默认值），`ArchiveService` 的导出清单是白名单、本来就不带，不用另外排除：
  `ClipboardPanelWidth`、`LauncherPanelWidth`、`ClipboardPanelRows`、`LauncherPanelRows`、`TranslateWindowMaxHeight`（都可空，null = 默认），
  翻译浮窗的宽照旧 `TranslateWindowWidth`。都存 DIP，换了缩放的屏照样对。拖左边会挪左边：「面板位置」是上次位置时同时更新 `ClipboardPanelLeft` / `LauncherPanelLeft`。
- **V12 设置三页「面板大小」一行（mac W3）。** 设置 › 剪贴板「面板」、设置 › 启动器第一组（都在「面板位置」下面）、设置 › 翻译「行为」（「浮窗位置」下面）各一行「面板大小」：说明「拖面板的左右边改宽、
  拖下边改高」，右边按钮「恢复默认大小」——宽写回默认（720 / 420）、行数和最高多高清成 null，没拖过时是灰的。下次呼出生效（开着的那块不跟着动）。设置页的搜索关键词（`SettingsWindow.cs` 开头那张表）补上「面板大小」「恢复默认大小」「朗读」「真人发音」「有道词典」。
  剪贴板、启动器里按 720 宽算的东西（标题能不能整条显示、透镜的宽）要改成读实际宽；改不动的写 `// ponytail:`（mac 同样留了剪贴板标题那一处）。
