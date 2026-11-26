# PLAN-gitcode：国内用户经 GitCode 更新（2026-11-25）

用户：国内打不开 GitHub，代码已经由 GitCode 镜像 https://gitcode.com/yyandbug/kitty-tools 自动同步，要让国内用户也能下载、App 内更新。
拍板页 https://claude.ai/artifact/FHmjtbwYMqFtW6dpoj5Whh（A–E），用户「按照推荐的来」。mac 那边的做法和查到的事实在 macos 分支
`macos/PLAN.md` §10「GitCode 国内分发」；这一份只管 Windows（拍板 W1：**先给清单签名，再接 GitCode**）。

和 PLAN-v26 不冲突：这一批只动 `Update*`、`build-release.ps1` 头部注释和本文件，不碰 PLAN-v26 / REVIEW / AGENTS / STATUS。

## 为什么要签名

Windows 包没有代码签名，App 内更新原来信的是「只认 GitHub 的地址白名单 + 同一个站给的 sha256」。GitCode 镜像只同步代码和标签，
release 由 mac 的 `macos/publish-gitcode.sh` 原样搬过去；如果直接把 GitCode 加进白名单，GitCode 的账号、令牌或平台出事，就能给走
GitCode 的用户推任意程序。所以 GitCode 那份清单必须带签名：

- 私钥：用户在 Mac 上跑 `swift macos/sign-manifest.swift new-key` 生成，只存在他的登录钥匙串（`kitty-tools-update-signing`），脚本不打印；
  丢了就只能发一个手动下载的版本换公钥，所以用户自己备份一份。
- 签名：ECDSA P-256 / SHA-256，DER 编码再 base64，放在清单旁边（`windows-update.json.sig`）。`publish-gitcode.sh` 改写完地址后签。
- 公钥：SubjectPublicKeyInfo DER 的 base64，写死在 `UpdateManifest.SigningKey`。**现在是空的**：空的时候 GitCode 那份一律不认，
  行为和以前一样（只走 GitHub）。用户生成钥匙后把公钥填进去，单独一个提交。

签名覆盖整个清单文件，所以里面的 sha256 也可信；zip 从哪个站下都只核这个 sha256。GitCode 上的 `.sha256` 没签名，不用它。

## 改了什么

| 文件 | 改动 |
|---|---|
| `KittyTools.Core/UpdateManifest.cs` | `GitCodeUrl`（固定标签 windows-update 上的清单；GitCode 没有 `releases/latest/download`）、`SignatureSuffix`、`SigningKey`、`GitCodeReleasesPage`、`VerifySignature`（`ECDsa.ImportSubjectPublicKeyInfo` + `VerifyData(..., DSASignatureFormat.Rfc3279DerSequence)`） |
| `KittyTools.Core/UpdateTrust.cs` | 白名单加 `gitcode.com` / `atomgit.com`（只认 `/yyandbug/kitty-tools/releases/download/`）和跳转目标 `file-cdn.gitcode.com`；`Mirror(url)`：GitHub ↔ GitCode 同一个附件的地址（只换前缀） |
| `KittyTools.Core/UpdateFlow.cs` | `UpdatePlan.Sha256`：有就只核它、不取 `.sha256`；没有（API 那条路）照旧取 `.sha256` |
| `KittyTools/App/UpdateHttp.cs` | `GetBytesAsync`（按原始字节验签名）、`DownloadWithMirrorAsync`（zip 没下成换另一个站，取消除外） |
| `KittyTools/App/UpdateService.cs` | `FirstManifestAsync`：GitHub 和 GitCode 的清单一起问，先回来、认得出的为准（GitCode 那份要先验签）；`AvailableSha256`；「打开发布页」跟着先回来的那个站 |
| `KittyTools/App/AutoUpdater.cs` | 两处 `UpdatePlan` 带上 `AvailableSha256`，下载换成 `DownloadWithMirrorAsync` |
| `build-release.ps1` | 头部注释：GitHub 发完后在 Mac 上跑 `publish-gitcode.sh windows-v<版本>` |
| 单测 | `UpdateManifestTests.VerifySignature_OnlyTheSignedBytes`（CryptoKit 签的测试向量，Mac 上已用 openssl 交叉核过）、`Parse_GitCodeManifest`；`UpdateTrustTests.GitCodeMirror` 和坏地址几条；`UpdateFlowTests.ManifestSha256IsTheOnlyHashChecked` |

没做：Windows 的动画表情包（`emoji-pack-1-win` 还没发；发的时候 `publish-gitcode.sh emoji-pack-1-win` 一起搬，`EmojiPackRemote` 再加 GitCode 的地址）。
ponytail：先回的那个站要是还没传上最新一版（发版后、publish-gitcode.sh 跑完前那几分钟），这次查到的是旧的，第二天再查就对了。

## 给 Windows agent 的核验指令（这批代码是在 Mac 上写的，没编译过）

1. `git fetch origin && git checkout claude/gitcode-win`（或用户合并到 windows 之后在 windows 上），先 `git log --oneline -3` 确认有这一批的提交。
2. 编译和单测：
   ```
   dotnet build windows/KittyTools.slnx -c Debug -p:Platform=x64
   dotnet test windows/KittyTools.Tests --filter "FullyQualifiedName~Update"
   ```
   全过；**重点看 `VerifySignature_OnlyTheSignedBytes`**：它证明 .NET 的 `ECDsa` 认 Mac 上 CryptoKit 写的签名和公钥格式。失败就停下报告，别改测试向量。
3. AOT 发布零警告（`ECDsa` 在 AOT 下要能用）：`dotnet publish windows/KittyTools/KittyTools.csproj -c Release -r win-x64`。
4. 全量单测一遍（`dotnet test windows/KittyTools.Tests`）。
5. 真地址（等用户在 Mac 上跑过 `publish-gitcode.sh windows-v0.3.0`、GitCode 上有 0.3.0 和清单之后）：用新打的包跑
   `KittyTools.exe --update-live=0.3.0`，照旧退出码 0（GitHub 那条路没坏）。
6. 填了 `SigningKey`、GitCode 上有签过名的清单之后：装一个旧版本，在 `C:\Windows\System32\drivers\etc\hosts` 里把 `github.com`、
   `api.github.com` 指到 `127.0.0.1` 模拟打不开 GitHub，托盘「检查更新」→ 几秒内查到新版本，日志里是 `source=manifest gitcode=True`；
   点「更新」能从 GitCode 下完、校验、装上。改坏 GitCode 上的 `.sig`（或公钥）→ 日志 `update.manifest-bad-signature`、退回 GitHub（这时连不上，报检查失败）。测完把 hosts 改回去。
7. 结果写在报告里；编译错误就地修，改动小的照这里的设计修，设计要变先停下问。

## 上线顺序

1. 用户在 Mac 上 `swift macos/sign-manifest.swift new-key`，备份私钥，把打印的公钥给 agent 填进 `UpdateManifest.SigningKey`（一个提交）。
2. 用户在 Mac 上跑 `publish-gitcode.sh windows-v0.3.0`：搬 0.3.0，GitCode 的 windows-update.json 带上 `.sig`。
3. 这一批随下一个 Windows 版本发；已经装着的 0.3.0 及以前照旧只读 GitHub。
4. 以后要不要让 GitHub 那份也必须带签名（防 GitHub 账号被盗），另议。
