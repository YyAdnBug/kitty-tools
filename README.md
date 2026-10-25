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

- record-saved.png：录 4 秒后轻提示「录屏已保存」，资源管理器里选中 `录屏 2026-10-25 18.15.46.avi`（12.5 MB）
## 0.4.0-batch-2（录屏选区与倒数）

- record-select.png：Alt+R 打开的录屏选区遮罩（提示「拖动选区，单击窗口取整窗 · Esc 取消」）
## 0.4.0-batch-3（录屏 HUD）

- hud.png：录制中的控制条（红点、0:02 计时、✕ 放弃、■ 停止）；用 KITTY_HUD_CAPTURE=1 关掉排除捕获才截得到，正常录制时它不会进画面
