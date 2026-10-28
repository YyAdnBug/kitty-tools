# Kitty Tools Windows 截图（孤儿分支，不并进 main）

每批一个目录，浅色 / 深色各一套。目录里的图是当批提交时的样子，文件名见主仓提交正文。

## batch-1（第二版第 1 批：修第一版）

- clipboard-panel-dark.png / clipboard-panel-light.png：剪贴板面板（列表 + 预览），深 / 浅
- launcher-dark.png / launcher-light.png：启动器，深 / 浅
- translate-card-dark.png：翻译卡，长译文的卡片内滚动（停在末尾）
- tray-menu-light.png：托盘菜单（Win32 浅色菜单，右边是快捷键）
- notice-light.png：轻提示胶囊（布局分层窗口后仍然正常画）

## batch-2（第二版第 2 批：系统底座）

- about-update-dark.png / about-update-light.png：设置 › 关于，更新日志和「更新到 0.1.1」按钮（浅 / 深）
- navigationview-aot.png：AOT 发布物里 NavigationView 能正常画出来的证据（诊断用，KITTY_XAML_PROBE=1）

## 0.2.0-batch-3（第二版第 3 批：外观（一）壳和设置窗）

- settings-general-light.png / settings-general-dark.png：设置 › 通用（NavigationView + 设置卡），浅 / 深
- settings-hotkeys-light.png / settings-hotkeys-dark.png：设置 › 快捷键（一个键一个键帽），浅 / 深
- settings-about-light.png / settings-about-dark.png：设置 › 关于（更新卡、按版本分组的更新日志、类型标签），浅 / 深
- settings-aot-release.png：Release AOT 发布物里同一个设置窗（验证 PRI 修好之后 NavigationView 能用）
- tray-menu-light.png / tray-menu-dark.png：托盘换成 WinUI MenuFlyout（图标、快捷键右对齐、勾选项），浅 / 深
- notice-light.png / notice-dark.png：轻提示胶囊（宽度生长的终态；窗口四圈真透明）
- notice-error-light.png：错误语气的胶囊（红底 + 抖动后的终态）

高对比度主题没截：要改用户的系统主题，留给用户手测（`HANDTEST.md` 第 142 条）。

## 0.2.0-batch-4-5（第二版第 4–5 批：三块面板和截图）

- clipboard-dark.png / clipboard-light.png：剪贴板面板——高度随内容（八条）、左列表右预览、选中高亮、
  行右「来源 · 多久前」、底栏和齿轮，浅 / 深
- launcher-calc-dark.png：启动器里输入 `1+2*3`，计算结果单独一行（28 号半粗）
- launcher-keys-dark.png：按住 Ctrl 后右下角浮现的数字键帽
- launcher-query-light.png：浅色启动器搜 `chrome`（行高 48、图标 32、副标题次要色）
- translate-dark.png / translate-light.png：翻译浮窗——服务徽标、两行原文（会重新排版）、
  设置类错误是橙字、带「打开设置 / 重试」，浅 / 深
- shot-toolbar.png：截图遮罩 + XAML 工具栏（工具 / 颜色·线宽·撤销 / 复制·保存·钉图·识字·翻译·关闭）、
  尺寸胶囊、放大镜
- shot-annotation.png：画好的矩形标注被选中（四角手柄）、工具栏当前工具是品牌粉实心底
- shot-card.png：复制之后的飞入缩略图卡片（复制 / 保存 / 钉图 / 关闭）

这些图是在开发机解锁后补的；用户当时在用同一台电脑，所以背景里能看到别的工作窗口（不涉及隐私内容）。
高对比度、150%（这台是 100%）、动效短视频仍然没测/没录，见 `HANDTEST.md` §144–161。


## 0.3.0-batch-1（第三版第 1 批：数据安全、导出导入、功能开关）

- settings-features.png：设置 › 通用 › 功能（四项开关）+「导出与导入」两张卡
- settings-feature-off.png：关掉剪贴板后，设置 › 剪贴板 只留一张「已关闭」的卡
- 每日数据库备份和自动备份 JSON 在数据目录的 backups\ 里（文件名见 HANDTEST §168、§174，不是界面）
## 0.3.0-batch-2（第三版第 2 批：翻译历史）
- translate-history.png：翻译浮窗的 Ctrl+H 历史列表（搜索框、空列表提示、底栏快捷键）

## 0.3.0-batch-3（第三版第 3 批：片段、收藏夹、备注）
- clipboard-snippets.png：三枚范围胶囊（全部 / 收藏 / 片段）、片段标签与备注、右侧预览和底栏

## 0.3.0-batch-4（第三版第 4 批：识字后可搜）
- ocr-search.png：搜索「OCR」命中一张图片条目（靠后台识字的结果）；多选、链接预览在 HANDTEST 待走

## 0.3.0-batch-5（第三版第 5 批：启动器补齐）
- launcher-port.png：`port 135` 列出监听的端口、PID 和进程名

## 0.3.0-batch-6（第三版第 6 批：截取上次区域）
- screenshot-last-card.png：Ctrl+Alt+Z 直接截上次区域后的飞入卡片
## 0.4.0-batch-1（第四版基础录屏）

- record-saved.png：拍到了整个桌面，已删（windows/REVIEW.md R16）。要重拍的话只截我们自己的窗口。
## 0.4.0-batch-2（录屏选区与倒数）

- record-select.png：拍到了整个桌面，已删（windows/REVIEW.md R16）。要重拍的话只截我们自己的窗口。
## 0.4.0-batch-3（录屏 HUD）

- hud.png：拍到了整个桌面，已删（windows/REVIEW.md R16）。要重拍的话只截我们自己的窗口。
## 0.4.0-batch-4（点按圈与按键胶囊）

- effects-frame.jpg：拍到了整个桌面，已删（windows/REVIEW.md R16）。要重拍的话只截我们自己的窗口。
## 0.4.0-batch-5（录屏转 GIF）

- gif-frame.png：拍到了整个桌面，已删（windows/REVIEW.md R16）。要重拍的话只截我们自己的窗口。
## 0.5.0-review-r15（R15 深色设置卡）

- settings-dark-system-light.png：系统浅色 + 设置深色，只截设置窗口；卡片深底白字
## 0.1.0-launcher（PLAN-v9-launcher 7a–7d 启动器对齐 mac，Windows 编译修过之后）

`--ui-snapshots` 屏外渲染（只画启动器面板，不截屏幕），浅 / 深各一套；高对比度要改系统设置，没截。
数值对过 PLAN-v9-launcher §3：搜索线 56、发丝线、四周内缩 6、行 40、分组标题 28、计算卡 64、底栏 36。

- launcher-*.png：搜「a」（系统设置页用「设置」的齿轮图标，第一行在最上面、带高亮）
- launcher-home-*.png：空查询、空数据——只有搜索线和底栏（V3「第一次用什么都没有」）
- launcher-calc-*.png：`10 km to mi` 计算卡一行「算式 → 结果」
- launcher-kill-*.png / launcher-port-*.png：「后台进程」「在监听的端口」分组和行（本机当时在跑的进程）
- launcher-prompt-*.png：`g` 第一行「用 Google 搜索…」补全提示
- launcher-empty-*.png：匹配不到时只剩 Bing 兜底一行
- launcher-actions-*.png：Ctrl+K 菜单（占位「搜索操作」、命令符号）
- launcher-keys-*.png：按住 Ctrl 的「Ctrl+1…9」键帽

## 0.1.0-translate（PLAN-v9-translate 8a–8e 翻译对齐 mac，Windows 编译修过之后）

`--ui-snapshots`（Debug、自检档 `KITTY_DEV_SUFFIX`、空数据）浅 / 深各一套，只截自己的窗口。
翻译浮窗那几张是 WGC 只抓浮窗这一扇窗口（不激活、放在左上角，亚克力是失焦时的回落色）：
彗星边框、骨架扫光是合成层的，RenderTargetBitmap 画不出来。卡片是自检摆出来的，不发请求。

- translate-empty-*.png：刚打开、没翻过——「划词、截图或输入后开始翻译」+ 三个入口和快捷键键帽
- translate-running-*.png：两张卡生成中——智谱「思考中」+ 骨架两根带扫光；DeepSeek 出字到一半、末尾光标；两张都有彗星（边框上一段粉光）
- translate-comet-frames-light.png：生成中每 0.3 s 一帧、一圈 8 帧（`KITTY_COMET_FRAMES=1`），粉光顺时针绕边框走
- translate-done-*.png：智谱完成（行内 Markdown：加粗、`代码`）+ DeepSeek 配置错误（整卡染橙、钥匙、「打开设置」）
- translate-truncated-*.png：截断的长结果——卡里 8 行封顶、底部渐隐（「只翻了前一部分」那行在滚动区最下面，同 mac）
- translate-history-*.png：Ctrl+H 历史——搜索框 + 全部 / 收藏胶囊、今天 / 昨天 / 10月24日 分组、选中第二条、收藏星标
- translate-history-menu-*.png：历史里的 Ctrl+K 菜单（重新翻译 / 复制译文 / 复制原文 / 收藏 / 删除 ｜ 导出 › / 清空历史…）
- settings-translate-*.png：设置 › 翻译上半页（语言、译文字号的滑块和预览卡、查词、行为）
- settings-translate-services-*.png：滚到底的「翻译服务」——logo、名字、状态行（智谱没有内置 key 时橙字「未填密钥」、微软「免费 Edge 接口」、DeepSeek「OpenAI 兼容 · deepseek-chat」、Kimi 橙字「未填模型」、百度关着时灰字）、开关、›、「＋ 添加服务」
- settings-translate-service-*.png：DeepSeek 详情子页（「‹ 翻译」、启用、名称 / 协议 / 服务地址 / 模型 ↻、API Key、测试连接、删除…）。模型下拉要联网取 /models、下拉是弹出层，没截
- settings-general-*.png / settings-general-end-*.png：设置 › 通用整页和滚到底——「功能」每行 20 的家族色块、单独的「数据」一节，卡上没有灰色单色图标；页头图标是这一页自己的（d8770e5）
- settings-hotkeys-*.png：快捷键页，每行家族色块，最后一行「划词翻译并替换」（未设置）。多数行写「被占用」是因为装着的正式版占着这些键（Dev 自检档和正式版同时开）
- launcher-home-*.png：启动器空首页（空数据）——只有搜索线，没有底栏、没有下面那一截
