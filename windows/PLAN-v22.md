# Kitty Tools Windows 版：第二十二版方案（折叠的翻译服务不自动翻译）

2026-11-15。有用户问：加了几个 AI 翻译服务、折叠了其中几个，折叠的是不是还在翻、在耗 token，看着还会闪一下。读代码确认：
mac 和 Windows 都会给**所有启用的服务**发请求（Windows `TranslateCoordinator.cs` 开会话时 `store.Enabled` 全部建卡、全部 `RunAsync`），
折叠只藏正文；「闪一下」是折叠着也在画的彗星光和完成时的闪光。拍板页 https://claude.ai/artifact/DFEx7K9FX9TXnW7kCuy42c
（D1–D7，用户「全部按推荐」；对标 Easydict：点箭头折叠 = 这个服务不查，点开才查）。

**这一版由 Windows 的 agent 自己写、自己编译、自己验**（同 PLAN-v16 / v17）。行为、默认值、文案照 mac（`AGENTS.md`「跟 mac 走」）。一批，
照 `AGENTS.md`「每一批的流程」和自查清单走；交接写在 `REVIEW.md`「PLAN-v22」，手测接着 `HANDTEST.md` 末尾往下编。排在手头那一版之后做。

**mac 那一半**：分支 `collapse-wip`（检出 `kitty-tools-macos-collapse`，从 macos `58f15ee3`），一个提交，写这份文档时**还没推**，看不到源码就照本文做；
推了以后看 `macos/KittyTools/Translate/TranslateCoordinator.swift`（`CardState.idle`、`Card.opened`、`collapsed`、`expand`、`primary(of:)`、
`ordered` / `orderedServices`、`resumeInput`）、`TranslatePanelView.swift`（`onChange(of: collapsedServices)`、折叠着点重新翻译）、
`ProviderCardView.swift`（折叠着不画彗星和完成闪光）、`App/AppDelegate.swift` 的 `translateSegments`；规矩在 `.claude/skills/mac-translate/rule.md` §2
「折叠着的服务不自动翻译」，单测 `collapsedServicesTranslateOnExpand`、`orderedServicesPutCollapsedLast`，手测 mac `HANDTEST.md`「折叠的服务不自动翻译」1–11。

## 1. 拍板（照 mac）

| # | 定了的 |
|---|---|
| D1 | 折叠 = 这个服务不自动翻译，**不加开关**。折叠状态还是 `TranslateCollapsedServices`（按服务 id 记住、跨重启）。收起按钮的提示改成「收起：以后不自动翻译，点开再翻」，折叠着时「展开：以后自动翻译」。 |
| D2 | 点开一张没翻的折叠卡：现在才翻**当前**原文（骨架 / 思考中 → 流式出字，和平时一样）。同一段原文翻过的，再折叠、再点开不重复请求。 |
| D3 | 正在翻时被折叠：让它翻完，结果留着。 |
| D4 | 新会话（换原文、换语言、重新翻译）时折叠的卡回到「没翻」，不发请求。再打开输入翻译（`ResumeInput`）时，被中断的卡里**折叠着的回到没翻、不重跑**，没折叠的照常重跑。 |
| D5 | 主结果（写历史、自动复制、收藏、替换原文）**不认没翻的卡**（也不挡着等：不然前面有一张折叠卡，主结果永远是 -1），**也不认点开后才翻的卡**（点开一张卡不换剪贴板、不再写一条历史）。全部服务都折叠时一次翻译什么都不发、没有主结果。 |
| D6 | 开浮窗的入口都走同一个开会话的地方，改一处就全改了。不开浮窗的两条路——静默替换 `TranslateOnceAsync`、截图翻译盖回 `ScreenshotTranslator.TranslateSegmentsAsync`——按「**没折叠的在前、折叠的垫底**、各自保持列表顺序」试服务。 |
| D7 | 折叠着的卡**不画彗星光、不闪完成的那一圈**（看不到正文，闪了像在偷偷翻）；失败的底色、自动复制的闪照旧。 |

## 2. 要做的

| # | 内容 |
|---|---|
| C1 | **Core**（`KittyTools.Core/TranslateSession.cs`）：`CardState` 加 `Idle`（没翻）；`Primary` 把 `Idle` 当跳过（`continue`），另加「点开后才翻的」也跳过（`Skip` 那一位并上它就行）；加纯函数 `Ordered(services, collapsed)`（没折叠的在前、折叠的垫底、稳定）。单测照 mac 的两条：`Primary` 遇到 `Idle` / 点开后才翻的；`Ordered` 的顺序。 |
| C2 | **会话**（`Translate/TranslateCoordinator.cs`）：开会话建卡时读 `SettingsService.Current.TranslateCollapsedServices`，折叠的建成 `Idle`、不 `RunAsync`；卡上加一个「点开后才翻的」标记；新增 `Expand(id)`：卡是 `Idle` 才标记 + 照重试那条路跑（用设置里现在的那份配置），别的状态不动；`ResumeInput` 照 D4；`IsRunning` 不算 `Idle`。查词那条先查系统词典再开跑的路径里，也只跑不是 `Idle` 的。 |
| C3 | **浮窗**（`Translate/TranslateWindow.cs`）：`ToggleCollapse` 展开时（从折叠变成展开）调 `_coordinator.Expand(id)`；折叠着点「重新翻译」= 展开并翻译（没翻的由 `Expand` 跑，翻过的再 `Retry`）；展开着却是 `Idle` 的卡（偏好从别处改了）点「重新翻译」也走 `Expand`。 |
| C4 | **卡片**（`Translate/TranslateCardView.cs`）：折叠着不开彗星、不闪完成那一圈；`Idle` 且展开着（只在偏好被别处改了时出现）正文写一行 11 号次要色「折叠着时没有翻译，点右上角的重新翻译」，不画骨架。折叠按钮的提示照 D1。 |
| C5 | **不开浮窗的两条路**：`TranslateOnceAsync`、`ScreenshotTranslator.TranslateSegmentsAsync` 的服务列表过一遍 C1 的 `Ordered`。 |
| C6 | **截图自检**（`App/UiSnapshotProbe.cs`）：加一张「两张折叠、一张没翻、一张翻过」的浮窗，浅色 / 深色 / 高对比度；mac 的样子见 mac 截图自检 `translate-collapsed`（没翻的那张只剩标题行，右边只有「重新翻译」和展开两个按钮）。 |
| C7 | **文档**：`MAC-DIFF.md` 没有要记的（行为一样）；`STATUS.md` 翻译那一行补一句「折叠着的服务不自动翻译，点开才翻」。 |

## 2½. 同一批：免费的服务标出来（2026-11-15 用户追加）

mac 同日另一个提交（`collapse-wip` 上，`feat: 设置里标出免费的翻译服务`）：用户要「让用户知道哪些是免费的」，拍板「只排『+』菜单和新装，
已经排好的列表不动」（列表顺序 = 卡片顺序、决定主结果）。

| # | 内容 |
|---|---|
| F1 | 免费的种类：智谱（内置的免费模型）、微软（没填 Key 时走 Edge 接口）、系统翻译、有道词典。Core 一个纯函数（mac `Kind.isFree`）。 |
| F2 | 设置 › 翻译「+」菜单：没加的内置服务分两节「免费」「要填密钥」，免费的在前；菜单里智谱的名字不带默认名里的「（免费）」。 |
| F3 | 服务行：名字后面一枚「免费」小标签（同浮窗「自动」标签的样子：强调色 0.16 底、强调色字、10 号半粗）；微软填了自己的 Key 不标。标签出来时名字里的「（免费）」去掉，副标题不再写「免费」（微软写「Edge 接口」、有道词典写「只查单词」）。读屏读得到「免费」。 |
| F4 | 不改用户已有列表的顺序；新装默认列表照旧（只有智谱）。 |

## 3. 验收

- 单测：C1 两条；再照 mac `collapsedServicesTranslateOnExpand` 写一条会话级的（假的翻译流记下请求了哪些服务）：开会话只请求没折叠的、`Expand` 才请求折叠的、
  点开后才翻的不当主结果、再点开不重复请求、换原文回到 `Idle`、取消后 `ResumeInput` 折叠的回到 `Idle`。
- 截图：C6。
- 手测（接着 `HANDTEST.md` 末尾编号，照 mac 那 11 条换成 Windows 的键）：折叠的不请求、点开才翻、再点开不重复；折叠卡排第一时自动复制 / 历史用的是没折叠的那个；
  改原文后折叠卡回到没翻；生成中折叠照样翻完；折叠着点重新翻译会展开并翻；全部折叠时一个请求都不发；划词翻译并替换、截图翻译盖回先用没折叠的；
  复制即译 / 截图翻译 / 历史重译 / 便签里的翻译都一样；Esc 收起再 Alt+T 打开，没折叠的中断卡重跑、折叠的回到没翻；折叠按钮的提示；
  F2 F3 的「+」菜单两节、服务行的「免费」标签（填了微软 Key 后消失），已有列表顺序没变。
