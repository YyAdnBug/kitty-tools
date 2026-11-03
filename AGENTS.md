# AGENTS.md

`main` 分支只放介绍：`README.md`、`docs/images/` 里的截图，以及官网（`docs/`，2026-11-03 起）。**不在这里写 App 的代码**（2026-10-30 起）：

- macOS 版：`macos` 分支，指引在那边的 `AGENTS.md`（Claude Code 经 `CLAUDE.md` 导入）。
- Windows 版：`windows` 分支，指引在 `windows/AGENTS.md`。

要改介绍或截图就在这里改；功能有了变化，README 里对应的那段和官网的功能页跟着改。用中文写。

## 官网

GitHub Pages 从 main 分支的 `docs/` 发布，地址 https://yyadnbug.github.io/kitty-tools/ 。拍板记录：https://claude.ai/artifact/KNNma2uaaJyA8e8JEGeSYW （24 项全部按推荐）。

- **纯静态、零依赖**：手写 HTML，一份 `docs/assets/site.css`、一份 `docs/assets/site.js`，不用框架、不用构建、不引第三方（字体用系统字体）。`docs/.nojekyll` 让 Pages 不跑 Jekyll。
- **页面**：首页 `docs/index.html`，功能 `features/`、下载 `download/`、更新日志 `changelog/`、常见问题 `faq/`（隐私是其中 `#privacy` 一节），`404.html`。页头页脚每页各有一份，改导航要改六处。404 页在任意深的地址上出现，靠开头一段脚本把 `<base>` 定到站点根。
- **发版后官网不用改**：下载按钮和版本号在浏览器里读 GitHub 的 release 列表（Mac 取版本号最大的 `macos-v*` 里的 `_arm64.dmg`，Windows 取最大的 `windows-v*`，不用 `releases/latest`，Windows 的 release 不标 latest）；更新日志读两个分支上的 `changelog.json`（Mac：`macos/KittyTools/Resources/changelog.json@macos`，Windows：`windows/KittyTools/Resources/changelog.json@windows`）。读不到时按钮仍链到 GitHub 发布页。所以发布资源的命名（`_arm64.dmg`、`-windows-x64-setup.exe`、`-windows-arm64-setup.exe`、`.zip`）和两份 changelog.json 的位置、格式不能随便改，改了要同步改 `site.js`。
- **截图**：`docs/assets/shots/`，由 macos 分支的 `WebsiteShotsTests`（屏上截带毛玻璃的面板、屏外渲染全屏类）出 PNG，再用 `swift tools/site-shots.swift <出图目录>` 转成 AVIF（面板，浅深各一张，另有 @1x PNG 兜底）和 JPEG（全屏类）。面板背后的底 `docs/assets/wallpaper-*.avif` 是同一个探针画的，换图时一起换。
- **其他素材**：「探头」是照 `macos/brand-icons.swift` 的几何手抄的内联 SVG（首页两处、404 一处）；功能图标是两个平台共用的 `icons/feature/*.svg`（macos 分支）拷过来的，当 CSS 遮罩用；`dmg-window.jpg` 是 DMG 背景加图标合成的；`og.png` 是 1200 × 630 的分享卡片。
- **换域名**：在 `docs/` 加 `CNAME`、域名商加解析；页面都是相对路径，只有 `og:image` 和 `sitemap.xml` 里写着完整地址，要一起改。
- **本地预览**：`python3 -m http.server 8765 --directory docs`，打开 http://localhost:8765/ 。桌面宽度和手机宽度（375）、浅色深色都看一遍；界面和文案不提其他产品，说法以两个平台的 changelog.json 为准。
