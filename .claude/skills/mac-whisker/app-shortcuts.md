# mac-whisker · App 快捷键

App 快捷键（插件，2026-11-17，PLAN §10「App 快捷键」）：单独按住 ⌘ 弹出前台 App 菜单栏里的全部快捷键。先读核心 `mac-whisker`
（原则、皮肤、刻度、动效、无障碍、验收）再读本文件。行为（什么时候弹、收）在 `AppShortcuts/AppShortcuts.swift` 文件头。

## 1. 面板
- **Panel 皮肤**（§2）：就是 `OverlayPanel`（`firstMouse: true`：不是 key 时第一下点击也交给内容），15 上毛玻璃 16 pt、26 起液态玻璃；
  面板里只用填充、不叠玻璃。放在鼠标所在屏的正中（OverlayPanel 不带 frameName、不 topAnchored 时就是居中），宽高随内容，
  最大可见区的 90% × 80%。**出来时不当 key**：按着 ⌘ 再按的键要照常到前台 App。
- 入场、退场照 OverlayPanel（淡入 + 内容下落 6 pt；收起是替身淡出），减弱动态效果时没有。不用家族色、不用强调色。
- 四周内边距 14；顶上一行（高 24，下面留到 40）：20 pt App 图标、App 名（15 semibold，一行截断）、「N 个快捷键」（13 secondary）；
  没读完时右边一句橙字「没读完：这个 App 没响应」（12，一行截断）。

## 2. 卡片和列
- 一个顶层菜单一张卡（`.cardSurface()`，内边距左右 10、上下 8）：组名 12 semibold secondary（高 18）+ 一行行快捷键（行高 22）。
- 列宽 248、列间距 10、卡片间距 10。卡片按菜单的先后一列列往下排；列底放不下的卡拆到下一列接着排，前一段至少留 3 行，
  下一段的组名写「X（续）」。列数取「一屏放得下」的最少列，都放不下就用最多的列、整块竖着滚（不翻页）。
  排版是纯函数 `AppShortcutsLayout`，列宽、行高定死，不量 SwiftUI。
- 一行：子菜单的路径灰字在前（「排序方式 › 」，13 secondary）、标题（13，primary），放不下先截路径、再截标题；右边 Whisker 键帽
  `KeyCombo`（修饰键逐个拆开，🌐 也算修饰键）；两段式的（⌘K ⌘S）两组键帽间距 4。**灰着的不画灰**（`AXEnabled` 靠不住）。

## 3. 读不到时
- 整块换成 `EmptyState`（380 × 210）：一条都没有 →「这个 App 的菜单里没有快捷键」/「有的 App 只在窗口里响应快捷键，菜单里看不到」
  （`keyboard`）；App 没响应 →「这个 App 没响应」/「过一会儿再按住 ⌘ 试试」（`hourglass`）；读不到菜单栏 →「读不到这个 App 的菜单」/
  「有的 App 没有菜单栏」（`menubar.rectangle`）。说明 12 secondary。

## 4. 读屏
- 弹出时播报「App 名，N 个快捷键」（`Island.announce`）；组名是标题（`isHeader`），一行合起来读「标题、组合」。

## 5. 验收
- 截图自检 `SnapshotProbeTests/appShortcuts()`（图以 app-shortcuts- 开头）：访达那样几张卡（浅 / 深）、少的、Xcode 那样要滚的、
  没读完、三种读不到；设置 › App 快捷键（没授权 / 已授权、关了按住 ⌘，浅 / 深）。
