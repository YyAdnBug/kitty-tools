# windows/REVIEW.md：审查意见

审查方（Claude，在 Mac 上）看完代码或报告后，把要改的写在这里。agent **每一批开始前先看这里**：

- 「待修」的条目先修完，再做那一批；
- 修完把条目挪到「已修」，写上提交号和一句怎么验的；
- 不同意的，在条目下面写理由，挪到「有异议」，照常做下一批，审查方回头再看。

条目编号不复用。行号按条目里写的那个提交。

## 待修

### R1（第二版第 2 批，`da8cc1a9`）自动更新只认 GitHub 的 https 地址

- **现状**：`App/AutoUpdater.cs` 的 `ReadBytesAsync` 认 `http://`、`file://` 和本地路径；`App/UpdateService.cs:77` 不论什么构建都读 `KITTY_UPDATE_FEED`。正常运行的 Release 版里，这些本来只该是测试入口。
- **改成**：
  - 正常启动的 Release 版：发布列表只认 `https://api.github.com/repos/YyAdnBug/kitty-tools/releases`；zip 和 `.sha256` 的下载地址只认 `https`，主机只认 `github.com`（路径以 `/YyAdnBug/kitty-tools/releases/download/` 开头）、`objects.githubusercontent.com`、`release-assets.githubusercontent.com`（GitHub 下载会跳转到这两个），**跳转之后的每一跳也按这张表查**（自己处理跳转，或者在 `HttpClientHandler` 里关掉自动跳转、逐跳检查）。
  - `KITTY_UPDATE_FEED`、`file://`、本地路径、`http://`：只在 Debug 构建，或者带 `--update-test` 命令行参数启动时才认。这样手测仍然能在 Release AOT 下走完整条链路。
  - 判断「这个地址认不认」写成 Core 里的纯函数，单测覆盖：上面每一种地址、大小写、带端口、`github.com.evil.com` 这类伪装的主机。
- **验收**：单测；Release 正常启动时设了 `KITTY_UPDATE_FEED` 也不生效（日志里写一行「忽略测试用的发布列表」）。

### R2（同上）更新完退出要走正常的退出流程

- **现状**：`AutoUpdater.cs` 在拉起新进程之后直接 `Application.Current.Exit()`，不经过 `ShellRuntime.Exit()`。结果：托盘图标残留（鼠标移过去才消失）、剪贴板里还没提交的删除丢掉、热键没注销。
- **改成**：拉起新进程之后调 `ShellRuntime.Instance.Exit()`（它会提交删除、注销热键、删托盘图标、再退出）。
- **验收**：自动更新的成功路径走一遍，更新后托盘里只有一个图标；更新前在剪贴板面板里删掉的条目，更新后不会再出现。

### R3（同上）下载直接写文件，不整个读进内存

- **现状**：`ReadAsByteArrayAsync` 把整个 zip（30–40 MB）读进内存再写盘；下载到一半失败时也没清理。
- **改成**：流式写到 `updates\<文件名>.partial`，下载完再改名；失败、取消、校验不过都删掉半成品。下载中更新托盘菜单那一项的文字（「正在下载 37%」），不另外弹窗。
- **验收**：断网中途失败时 `updates\` 里没有残留；下载过程中专用工作集不涨 30 MB。

## 已修

（还没有）

## 有异议

（还没有）
