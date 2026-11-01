# 0.1.0 深色开关 / 输入框、翻译卡彗星（REVIEW 最上面一节，HANDTEST 805–811）

2026-11-01，worktree `kitty-win-rel010`，Windows 11，一块 100% 的屏。系统是浅色；「系统深色」那一套用自检档的
`KITTY_APP_THEME=dark` 把 App 的主题定死成深色来模拟（没去改系统设置）。

## 设置窗（Release x64，`--ui-snapshots`，WGC 抓真窗口，带毛玻璃底）

- `sys-light-*` / `sys-dark-*`：系统浅色 / 深色；文件名里的 `-dark` / `-light` 是 设置 › 外观。
- `settings-clipboard-*`：剪贴板页的开关；`settings-translate-service-*`：DeepSeek 服务详情的输入框。
- 取色（外观深色，两种系统一样）：关着的圆点 #D0D0D0、开着的圆点 #FFFFFF；「搜索设置」占位字 #CFCFCF；
  输入框里的字 #FFFFFF、占位字「本机模型可留空」#D4D4D4。
- `sys-light-clip-dark.png`、`sys-light-shortcuts-dark.png`：807 里底栏键帽、空状态说明、速查表「全局」（RenderTargetBitmap）。

## 彗星

- `comet-before-fix-*`：75d6f86 原样。逐帧量光头：长边中间最快（约 2000 px/s）、短边和角上最慢（约 110 px/s），和 mac 反过来；
  一圈里还冒出一个半彗星。原因：合成层的 `StrokeDashArray` 是 DIP，代码按描边粗细（1.5）除了周长，图样一圈只有周长的 2/3。
- `comet-after-fix-*`：修好后（`--ui-snapshots` 的生成中那张，4 秒，60 fps）。上、下长边正中约 90–110 px/s，绕两头约 1300–1500 px/s。
- `comet-streaming.*`：本机假 OpenAI 流式服务、`--translate-text`，卡片一行行长高，光接着走；出完淡掉。
- `comet-reduced-motion-frames.png`：`KITTY_REDUCED_MOTION=1`，光停在同一个方向不动，出完淡掉。
- `translate-done-bottom-clipped.png`：另外发现的问题——出完以后窗口比生成中矮 20 px，最后一行贴着窗口底边，卡片下边框没了（没修）。
