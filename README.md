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

