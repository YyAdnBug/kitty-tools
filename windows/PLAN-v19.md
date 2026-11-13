# Kitty Tools Windows 版：第十九版方案（同步直接连 WebDAV 服务器）——拍板页

2026-11-13。外部 issue #18：作者的 Mac 和 Windows 不在一个网络里，想不装网盘客户端，直接用 NAS / 网盘的 WebDAV 同步。
用户定：**直接加进 设置 › 通用「同步」，不做成插件**（「本身就是同步的功能，在这里加个 WebDAV 就行」）。mac 版已经做完，
在分支 `webdav-wip` 的提交 `a84887c0`，进 mac 0.9.0。写这份文档时那个分支**还没推**，看不到源码就照本文做。这一版让 Windows 跟上：
作者两台都要用，只有 mac 一边做好了对他没用。

**状态：拍板页，等用户拍板。拍之前 Windows 别动这一份。** 拍了以后照 §4 D5 的分工、§5 做；交接写在 `REVIEW.md`「PLAN-v19」，
手测接着 `HANDTEST.md` 末尾往下编。

- **Windows 支持之前的过渡办法**：用网盘客户端把同一个文件夹同步到本机，在「选择文件夹…」里选它，就能和连服务器的 Mac 互通
  （服务器上的写法和同步文件夹一模一样，§1）。
- **不做**（同 mac）：端到端加密（两边要一起改格式，密码丢了就打不开，以后单独定）、普通剪贴板历史、两台之间实时互传剪贴板、
  信任自签证书。
- 对照的 Windows：`origin/windows` `7214f94f`，行号按它，路径相对 `windows/`。审查方在 Mac 上读两边的代码写的，没编译。
- **怎么读**：§1 是 mac 的做法，照做；§2 是要改的文件；§3 是 Windows 上和 mac 不一样、不照着改会出错的几处，照做；
  §4 是要拍的，每题带推荐答案。

## 1. mac 的做法（照做）

- **只换传输层**：服务器上那个文件夹和同步文件夹的写法一字不差，都是标记 `kitty-notes-sync.json`、每台只写自己的
  `devices/<编号>/`、共用一个 `images/`。所以一台连服务器、一台用同步盘指到同一个文件夹，也能合到一起。文件夹格式不升。
- **镜像**：数据目录里放一份 `sync-server/<UUID>/`，是服务器上那个文件夹在本机的拷贝，`SyncFolder` 指着它。一轮分三步：
  1. **pull**：把服务器上变了的拿进镜像。
  2. 照原来的文件夹同步合一轮：`SyncRunner`、`NoteSyncPart`、`SyncDisk` 读写的就是镜像，合并、刹车、退回、图片清理都不用改。
  3. **push**：把本机写进镜像的送上去。

  每连一次服务器换一个新的镜像目录，停止同步时整个删掉。
- **pull**：
  - 用 Depth 1 的 PROPFIND 一层一层列：根、`devices/`、每台的子文件夹和它的 `notes/`、`images/`。有的服务只认 Depth 1。
  - 按 ETag 认变没变（没给 ETag 的看改动时间 + 大小），只 GET 变了的，没变的不碰。
  - 服务器上没了的：别人的文件和标记直接删；自己的和 `images/` 里账上记过（传上去过）的也删；账上没有的是还没传上去的，留着。
  - 镜像里文件的改动时间设成服务器上的。
  - 服务器上有、本机图片目录里也有的同名图，从本机拷进镜像、不下载（同名就是同一张）。
  - 只认同步格式里的文件（§3 W3），别的不拿、不删。
- **这一轮没拿下来的**（超了请求数）：
  - 镜像里有旧的一版就留着。同步盘慢了也是这样，合并本来就经得起旧的。
  - 镜像里没有的放一个占位。读的那层当它「还没下载」：那一版这一轮不算，状态行说还有几个没拿下来。
  - 有没拿下来的，这一轮整个算「没合完」：下一轮不跳过，也不清共用图片。
- **push**：
  - 只写自己的子文件夹和共用的 `images/`。
  - 本机改过的（和账上记的样子不一样）PUT；账上有、镜像里没了的 DELETE。
  - `images/` 里镜像有、账上没有的图要上传：先 PUT 成点开头的临时名，再 MOVE 成正式名、不覆盖。正式名已经有了就是同一张，删掉临时的。
    服务器不支持 MOVE（405 / 501）时直接 PUT 正式名，带 `If-None-Match: *`。
  - 先后和写文件夹时一样：便签、墓碑、图片、一类一类的，**device.json 最后传**，前面的都传完了才传它。
  - 服务器上没有的文件夹先 MKCOL。
  - 传完把写过的文件夹重新列一下，记下服务器给的 ETag，下一轮就不会把自己传的再拿回来。
- **账**：每个文件记两样：
  - 服务器上的 ETag、改动时间、大小；
  - 拿下来或传上去时镜像里那份的样子。

  Windows 上账存在哪见 §3 W2。账上记着服务器和用户名，换了任何一个就从头记。
- **请求数**：
  - 每轮 GET / PUT / DELETE / MKCOL / MOVE 合起来最多 **40** 个。列目录不算在里面，一轮是 3 + 2 × 电脑数个 PROPFIND。
  - 先拿标记、device.json、墓碑和一类一类的文件，再拿便签和图片；同一档按路径排，剩下的下一轮再拿。
  - 连服务器时**一分钟一轮**，同步文件夹照旧 20 秒一轮。
  - 服务器说请求太多（**429 / 503**）就立刻停，**退避 5、10、20、30 分钟**；`Retry-After` 给得更长就按它。退避期间的一轮直接停在「请求太多」。
  - 连不上、密码不对：停在那一轮，下一轮再试。
  - 坚果云的限额不公开，网上的说法是每半小时 600–1500 次；两台都空闲时每半小时约 210 次 PROPFIND。
  - ponytail：按轮限，不按时间窗算。
- **认证**：
  - 每个请求都先带 Basic。等 401 再补的话，在按次数限流的服务器上请求数会翻一倍。
  - 服务器要 Digest 时补同一组用户名密码，错了不重试。
  - http 地址照连（局域网 NAS），表单上用橙字说明是明文。证书照系统的判断。
- **连接（开同步）**：先看服务器上那个文件夹（`inspect`）。
  - 不在就连同没有的上级一起建：MKCOL 回 409 说明上级没有，往上找。
  - 这几种都不开，提示的话和选文件夹时一样：标记读不出来、标记的格式比这一版新、没有标记却有别人的子文件夹、没有标记而且文件夹不空（点开头的文件不算）。
  - 没有标记就写一个，带 `If-None-Match: *`。回 412 说明别的电脑刚写了一个，提示「这个文件夹里刚有别的电脑开始同步，再连接一次」。
  - 已经有别的电脑在同步，先问合不合在一起。
- **测试连接**：列一下根；文件夹在的话 PUT 一个 `.kitty-test-<UUID>`，再 DELETE 掉。
- **停止同步**：设置里的服务器地址和用户名清掉，密码删掉，镜像在后台删掉。服务器上的东西都留着。

## 2. 要做的

| # | 内容 | Windows 怎么做 |
|---|---|---|
| V1 | **WebDAV 客户端**，新文件 `KittyTools.Core/Sync/WebDav.cs`。<br>请求：<br>• PROPFIND（Depth 1）<br>• GET<br>• PUT（可选 `If-None-Match: *`）<br>• DELETE（404 也算删了）<br>• MKCOL（405 = 已经有了）<br>• 一路建到同步文件夹（409 往上找）<br>• MOVE（`Overwrite: F`，412 = 已经有了）<br>地址 + 文件夹拼成同步用的网址：只认 http / https、要有主机；扔掉地址里的用户名密码和查询串；结尾补 `/`；文件夹一段一段编码。<br>还有 multistatus 解析，和出错分类。 | `HttpMessageInvoker` 从外面传进来：App 传 D2 的那个 `HttpClient`，单测传假服务器。<br>• PROPFIND / MKCOL / MOVE 用 `new HttpMethod("…")`。<br>• 解析用 `XmlReader`：`DtdProcessing.Prohibit`、`XmlResolver = null`；按命名空间 `DAV:` 认，不按前缀；只认状态 200 的那组 `propstat`。<br>• `href` 有的是整个网址、有的是绝对路径，解码后按路径认出「自己」那一项；前面隔着改路径的反向代理时，第一项是同名文件夹也算自己。<br>• HTTP 日期用 `DateTimeOffset.TryParseExact(…, "r", …)`；`Retry-After` 读 `response.Headers.RetryAfter`，秒数和日期两种都认。<br>• 连不上的原因：从 `HttpRequestException.HttpRequestError` 分出找不到主机、连不上、证书不受信任；`TaskCanceledException` 是服务器很久没回应。<br>• 3xx 当错，提示「服务器让改用别的地址，检查地址是不是写全了」，不自动跳转（D2）。<br>• 界面上的话照 mac 原文：连不上服务器：…；用户名或密码不对（有的服务要在网页上另外生成给第三方应用用的密码）；服务器不让读写这个文件夹；服务器上没有这个文件夹；服务器上已经有同名的了；服务器说请求太多，过一会儿再试；服务器上的空间满了；服务器出错（HTTP n）；服务器回的东西看不懂，可能不是 WebDAV 地址。 |
| V2 | **镜像**，新文件 `Core/Sync/SyncServer.cs`，对应 mac 的 `NoteSyncServer`。<br>包括：pull、push、inspect、建文件夹、写标记、测试连接、删不用的镜像、读写账、认得的文件（`Known`：路径 → 大小上限 + 拿的先后）、退避时长。 | 网络和文件读写都在线程池上，只收发值。<br>账用源生成的 `JsonSerializerContext`（同 `SettingsArchive.cs`）。<br>退避时长写成纯函数 `Backoff(retryAfter, 第几回)`，给单测用。<br>§3 的几处照做。 |
| V3 | **一轮怎么接**：`SyncServer.RoundAsync`，加上 `SyncRunner` 一处小改。 | 先后顺序放在 Core，单测能跑整轮。<br>`RoundAsync(account, http, mirror, ledger, device, images, merge)` 的步骤：<br>1. pull；出错或者文件夹不在了就停（「服务器上找不到同步的那个文件夹：被挪走或删了，找到了自己接着同步」）。<br>2. **镜像里没有标记就停**（§3 W4）。<br>3. `await merge()`：App 传进来的，就是现在 `Syncer.RunOnceAsync`（`Storage/SyncFolder.cs:167`）里算指纹、跳过、`SyncRunner.RunAsync` 那一段。<br>4. merge 走过了「认清文件夹」这一步就 push。`SyncRoundResult` 加一个 `FolderOk`，认完文件夹、`SetLibrary`（`SyncRunner.cs:125`）之后设成真。Windows 一类出错时照样写别的几类，刹车时也照写别的几类；这些写进了镜像的都送上去，同 mac「写镜像出了错也照送」。<br>5. 返回 pull / push 的结果：还有几个没拿下来、几个没传上去、出了什么错。<br>pull 有没拿下来的、或 push 有没传完的：`Unsettled = true`，`Syncer` 的 `_quiet` 不记，下一轮不跳过。 |
| V4 | **Syncer**：`Storage/SyncFolder.cs`。 | • 连服务器时定时器 60 秒（`:33` 现在写死 20 秒）；换模式时重建定时器。<br>• 退避：记两样，一是「这个时刻之前不合」，二是连着第几回。退避期间的一轮（定时器、唤醒、立即同步都算）直接停在新状态 `busy`；pull 成了就清零。<br>• 密码第一次用时从凭据管理器取（D1）。取不到就停，提示「凭据管理器里没有服务器的密码，停止同步后重新连接」。<br>• 新加 `EnableServerAsync(account)`，照 mac `enable(server:)`：inspect → 没有就建 → 拒绝的那几种 → 写标记 → 新镜像目录 → 存密码、地址、用户名 → `SyncFolder` 指向镜像、`SyncEnabled = true` → 后台删旧镜像。<br>• 新加 `ForgetServer()`：「停止同步」时调，清设置、删密码、后台删镜像。<br>• `SyncStatus` 加三项：`Downloading`（没拿下来的）、`Uploading`（没传上去的）、`PausedUntil`。<br>• 日志只记请求数、没拿下来 / 没传上去几个、状态码、耗时，**不记地址、用户名**。 |
| V5 | **设置**：`App/Settings.cs`、`Settings/SettingsWindow.cs`（`BuildSyncSection`，`:1306`），新文件 `Settings/SyncServerDialog.cs`。 | **设置项**：`Settings` 加 `SyncServer`（同步的那个网址，以 `/` 结尾）和 `SyncServerUser`。**不进导出**：`ArchiveService` 是一个键一个键手写的，不加就不带；Windows 也不同步设置。<br>**没开同步时那张卡**：说明改成「选一个几台电脑都看得到的空文件夹（比如在 OneDrive 里新建一个），或者连一个 WebDAV 服务器；每台选同一个」；右边两个按钮「连接服务器…」「选择文件夹…」。<br>**开着同步时**：<br>• 卡片标题「同步服务器」；左边服务器图标（Segoe Fluent Icons 的服务器）+ 文件夹名（地址就是根时写主机名）；悬停看整个网址和用户名。<br>• 状态行加「；还有 N 个文件没从服务器拿下来」「；还有 N 个等着传上去」。<br>• `busy` 时橙字「服务器说请求太多，HH:mm 后接着同步」。<br>• 其他电脑一台都没有时写「还没有——在另一台电脑的 设置 › 通用 里连同一个服务器上的同一个文件夹」。<br>• 页脚改成 mac 那段：「同步文件夹（连服务器时是服务器上那个文件夹）里放的是不加密的…」「看同步盘多快；连服务器时大约一分钟一轮」。<br>**表单**用 `ContentDialog`：<br>• 四个输入框：服务器地址（占位 `https://dav.example.com/dav/`）、文件夹（默认「Kitty Tools 同步」）、用户名、密码（`PasswordBox`，最多 256 个字）。<br>• 地址是 http:// 开头时，下面橙字「这个地址没加密（http），密码和同步的内容在网上都是明文的」。<br>• 主按钮「连接」；次按钮「测试连接」，点了不关对话框（`args.Cancel = true` + deferral），结果写在对话框里；关闭按钮「取消」。<br>• 没填全时两个按钮都是灰的；正在测试或连接时，输入框和按钮都停用，旁边转圈。<br>• `ContentDialog` 不能再叠一个，所以有别的电脑在同步时**在同一个对话框里换成问句**：标题「和服务器上这个文件夹里已经在同步的电脑合在一起？」，正文「这个文件夹里已经有 N 台电脑在同步，有 M 条便签（含「最近删除」里的）。」+ `JoinNote`（`:1428`），主按钮换成「合在一起」。<br>• 没出结果时的说明：「文件夹没有的话连接时新建，每台电脑填同一个。密码存在这台电脑的凭据管理器里；有的服务要在网页上另外生成给第三方应用用的密码。」 |
| V6 | **文档** | • `MAC-DIFF.md` 同步那几条：§3 的 W1、W5、W7 记成长期的不同。<br>• `STATUS.md`。<br>• `HANDTEST.md` 加一节（§5）。<br>• `REVIEW.md` 加「PLAN-v19」交接。<br>• 0.3.0 的「新」标记、版本号、更新日志在那一版最后一批定；「新」的候选是 设置 › 通用「同步」。 |

## 3. Windows 上和 mac 不一样的地方（照这个做）

| # | 哪里 | 怎么做 |
|---|---|---|
| W1 | 没拿下来的文件，占位怎么放 | mac 放旧式 iCloud 占位 `.名字.icloud`。Windows 的 `SyncDisk.IsPlaceholder`（`SyncDisk.cs:15`）认的是文件属性（`Offline` / `RecallOnDataAccess`）。<br>所以**放一个空文件，设上 `FileAttributes.Offline`**（`SetFileAttributes` 允许设这个属性）。`SyncDisk.ReadText` 和 `NoteSyncDisk` 现在就会把它当「还没下载」，一行不用改。<br>拿下来时，用临时文件 + `File.Move(overwrite)` 换掉它，属性跟着新文件走。<br>push 扫镜像时，带 `Offline` 的算占位：不传，也不当成「本机删了」去 DELETE。 |
| W2 | 账放哪 | **不放在镜像根上**。Windows 的 `SyncDisk.LooksForeign`（`:89`）只要根上有东西就当「里面有别的东西」，点开头的文件也算；mac 的 `NoteSyncDisk` 不认点开头的文件，Windows 认。<br>改放在镜像旁边：镜像是 `sync-server/<UUID>/`，账是 `sync-server/<UUID>.json`，删镜像时一起删。 |
| W3 | 服务器给的名字（信任边界） | 镜像在 NTFS 上：不分大小写，`\` 也是分隔符，还有保留名。<br>**服务器给的每个名字先过 `Known`，过了才拼本机路径**。`Known` 只认规范写法、一字不差：<br>• 便签文件：用 `NoteSyncFolder.NoteId(name)` 取出编号再拼回去，要和原名完全相同（也就是编号大写）；<br>• 图片：同理用 `NoteSyncFolder.ImageId`；<br>• 电脑编号：用 `SyncFolderRules.IsDeviceName`；<br>• 固定的几个文件名：按 `Ordinal` 比。<br>这样只差大小写的两个名字只认一个，`..\`、`a\b` 这类名字进不来。单测各放一个。<br>mac 有同样的口子：`noteID(ofFileNamed:)` 也认小写，APFS 默认也不分大小写。影响小，只有别的程序往服务器上写了小写名字才会碰到；另外报给 mac。 |
| W4 | 标记谁来写 | Windows 的 `SyncRunner` 读到没有标记、文件夹又不像别人的时，会**自己新建一个库**（`SyncRunner.cs:108`），因为选文件夹时不先写标记。<br>可是 push 不传标记，镜像里新建的这个永远到不了服务器，几台会各建各的库。<br>所以连服务器时：标记只在连接时写（V4）；**一轮里 pull 完镜像里没有标记就停**，不进 `SyncRunner`，提示「服务器上那个文件夹里的同步记录被换掉或删了：先停止同步，再连一个新的空文件夹（每台电脑都换过去）」。 |
| W5 | 图片拷进镜像（D4） | mac 在 APFS 上是克隆，不占地方；NTFS 没有克隆。<br>推荐照现在的写法拷：`NoteSyncDisk` 往文件夹里放图本来就是 `File.Copy`（`NoteSyncPart.cs:346`）。代价是镜像里的图和本机图片目录各占一份。<br>写 `ponytail:` 注释，量一下典型的占用写进报告。 |
| W6 | 怎么认本机改过没有 | mac 记文件号 + 改动时间 + 大小。Windows 记 `LastWriteTimeUtc.Ticks` + `Length` 就够：<br>• `SyncDisk.WriteText` 和 `NoteSyncDisk` 都是临时文件 + 改名，改过就是新的时刻；<br>• `SyncRunner` 字节一样就不重写，不会白传。<br>拿下来的文件用 `File.SetLastWriteTimeUtc` 设成服务器上的改动时间：R49 的指纹、「其他电脑上次有改动」都按它算。 |
| W7 | 比上限还大的文件 | mac 放一个同样大小的空洞文件：APFS 上不占地方，读的那层当它太大。<br>Windows 上不标稀疏的话 `SetLength` 会真的占盘；标稀疏又要多写一段 `DeviceIoControl`。<br>**改放一个长期的占位（W1）**，不算进「还有几个没拿下来」。效果是那一版一直当「还没下载」：那一版便签不算，共用图片也不清（宁可少删），和 mac「读不出来」差不多。写 ponytail。<br>只有写坏了的、或者别的程序写的文件才会这么大。 |
| W8 | 第一次用 System.Xml | 现在 App 里没有用到 `System.Xml`，AOT 发布会把 `System.Private.Xml` 里用到的部分带进来。<br>用 `XmlReader`，不用 `XDocument`（带进来的少一点）。发布体积涨多少写进报告；超过 3 MB 再议，退路是手写一个只认 multistatus 的小解析器。 |

## 4. 要拍的

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| D1 | 服务器的密码放哪 | A **凭据管理器**：用现成的 `Infrastructure/Credentials.cs`（CRED_TYPE_GENERIC，只留在这台电脑）。目标名 `KittyTools/sync-server.password`，Dev 版 `KittyTools.Dev/…`；设置里只存地址和用户名<br>B `PasswordVault`（WinRT 的 `Windows.Security.Credentials`）<br>C 用 DPAPI 加密后写进 settings.json | **A**。<br>• AGENTS 红线就是「密钥只进凭据管理器」；翻译服务的密钥已经这么存，卸载时 `Credentials.DeleteAll` 按前缀一起清掉。<br>• B 底下也是凭据管理器（「Web 凭据」那一栏），但要走 WinRT 激活，没装包的 AOT 程序多一层；条目也不带我们的前缀，卸载时清不到。<br>• C 加密后的内容跟着 settings.json 走，导出、备份时容易被带出去，也没有系统的管理界面。<br>凭据一条最多 2560 字节（1280 个字），所以表单的密码框限 256 个字。 |
| D2 | `HttpClient` 怎么写 | A **一个静态的 `HttpClient`**：<br>• handler：`SocketsHttpHandler { UseCookies = false, AllowAutoRedirect = false, MaxConnectionsPerServer = 2, PooledConnectionLifetime = 2 分钟, ConnectTimeout = 10 秒 }`；<br>• `Timeout = 30 秒`，`MaxResponseContentBufferSize` 取认得的文件里最大的上限（32 MB）再留点余量；<br>• **每个请求自己带 `Authorization: Basic`**；<br>• 回 401 而且 `WWW-Authenticate` 是 Digest 时，用这个账号专门的第二个 client 重发（它的 handler 的 `Credentials` 是一个只登记这个网址 Digest 的 `CredentialCache`），之后这个账号都走它，账号一换就扔掉。<br>B 每个账号一个 client，handler 的 `Credentials` 同时管 Basic 和 Digest（`PreAuthenticate = true`）<br>C 只做 Basic，碰到 Digest 的服务器就报「不支持」 | **A**。<br>• 和 mac 一样先带 Basic。B 的 handler 要先挨一个 401 才知道带什么，按次数限流的网盘上每个新地址都多一个请求，换账号还要换 handler。<br>• 不自动跳转：自动跳转可能把 PUT 的内容带到别的主机；而且 WebDAV 的跳转大多是地址少写了 `/`，说清楚让用户改地址更好。<br>• 代理照系统的（`SocketsHttpHandler` 默认读系统代理）。<br>• 证书照系统的判断，不加校验回调（不支持自签证书，同 mac）。<br>• Digest 那条走的是真的 `SocketsHttpHandler`，假服务器测不到，靠 D3 的真服务器测试：把 mac 那边的 Apache 换成 Digest 跑一次。<br>• C 能少写十几行，但会变成 mac 支持、Windows 不支持；NAS 上偶尔会碰到 Digest。 |
| D3 | 测试怎么做 | A **假服务器 = 测试里的一个 `HttpMessageHandler`**（叫 `FakeDav`）：<br>• 拿一个临时文件夹当服务器，真读真写：PROPFIND Depth 1 回 multistatus（带 ETag、改动时间、大小）；GET；PUT（`If-None-Match: *` 遇到已有的回 412）；DELETE；MKCOL（409 / 405）；MOVE（`Overwrite: F` 遇到已有的回 412）。<br>• 能按请求注入 401、429 / 503 + `Retry-After`、断网（抛 `HttpRequestException`）。<br>• 记下每个请求的方法和路径。<br>整轮测试用 Core 的 `SyncServer.RoundAsync` + `SyncRunner` + 现有测试里的内存仓库（`NoteSyncRunnerTests`、`PlanV5IntegrationTests` 那一套）。<br>**另一台直接拿 FakeDav 的那个临时文件夹当同步文件夹**，正好就是「一台连服务器、一台走同步盘」的混用；再放一台照 `sync-golden.json` 写的假 Mac。<br>另有一个真服务器测试：设了 `KITTY_WEBDAV="地址\|用户名\|密码"` 才跑，没设就 `Assert.Inconclusive`。<br>B 起一个本机 `HttpListener` 当假服务器，走真的 `SocketsHttpHandler`<br>C 只测真服务器 | **A**。<br>• 不开端口、不弹防火墙，几秒跑完；请求数能逐个核对，比如「空闲一轮只有 PROPFIND」「没变的不再 GET」。mac 那边也是拦请求 + 临时文件夹（URLProtocol）。<br>• B 能测超时、跳转、Digest，但 `HttpListener` 的 Digest 要用 Windows 账号，自己写一个 Digest 服务器不值得。这几条交给真服务器测试。<br>• 真服务器**用测试账号**（AGENTS：不用用户真实的账号）：mac 上那份 Apache mod_dav 开在局域网里（起法在 mac `webdav-wip` 的 HANDTEST「WebDAV 同步」开头，分支推了才看得到），或者用户另给一个 Nextcloud / 坚果云的测试账号。 |
| D4 | 镜像里的图片 | A **拷贝**：照现有写法，镜像里多占一份<br>B 硬链接：用 `CreateHardLinkW`，只在镜像里用，失败退回拷贝；要给 `NoteSyncDisk` 加一个「这是镜像」的开关 | **A**。<br>• 改动最小。便签里的图一般是几百 KB 的截图，几百张也就多占几十到一百多 MB；报告里量一下。<br>• B 省地方，但硬链接是两个名字指同一份内容，以后谁原地改了图，两边会一起变。嫌占地方了再换。 |
| D5 | 谁写、进哪一版 | A **审查方在 Mac 上写**：Core + App + 设置页 + 单测，没编译；Windows 的 agent 负责编译、跑单测、截图、手测、修编译错。<br>排在 **0.2.0 发出去之后，作为 0.3.0 最先做的一批**。它和 PLAN-v18 的各批不碰同样的文件，谁先谁后都行。<br>B Windows 的 agent 自己写、自己验（同 PLAN-v16、v17），排在同样的位置<br>C 塞进 0.2.0 收口 | **A**。<br>• mac 那份刚写完，细节都在审查方手上；逻辑大半在 Core，单测在 Mac 上也能对着代码写。<br>• 代价是**没编译**，所以单测要写全，Windows 那边先编译、跑单测，再上屏看。<br>• 不进 0.2.0：收口不加中等规模的新功能（理由同 PLAN-v18 D3）。<br>• 作者等着用：0.3.0 想先发的话，可以单拎这一批，先出一个 0.2.1。 |

## 5. 一批与验收

一批（PLAN-v19）：V1–V6。除了自查清单，还要过下面这些。

- **单测**（只测 Core，不碰真的凭据、设置、同步文件夹）：
  - `WebDavTests`：
    - 地址拼法：补 `/`；去掉用户名密码和查询串；文件夹一段段编码；不是 http(s) 时是 null。
    - multistatus：Apache 的写法；整个网址的 href（反向代理后面）；别的命名空间前缀；状态 404 的 propstat 不算；乱码；**带 DOCTYPE 的拒收**。
    - HTTP 日期。
    - 状态码 → 出错分类。
    - `Retry-After` 的秒数和日期两种写法。
  - `SyncServerTests`（用 FakeDav），照 mac 的十条：
    - 便签来回传；
    - 和同步文件夹混用；
    - 图片来回传，服务器上只有正式名、没有 `.kitty-…partial`；
    - 永久删除能传到对面；
    - 没变的不再 GET：第二轮空闲时只有 3 + 2N 个 PROPFIND；
    - 一轮 40 个，分几轮传完，中途对面不丢东西；
    - 429 / 503 退避：`Backoff` 的几档，退避期间不发请求；
    - 密码不对 / 断网时停在那一轮，好了之后下一轮接着来；
    - 不往放着别的东西的文件夹里撒子文件夹；
    - 测试连接不留下文件；
    - 停止同步清掉镜像和账。
  - Windows 另加：
    - W1：占位的那一版不算；push 不删占位。
    - W2：镜像根上只有同步的文件。
    - W3：只差大小写的两个名字只认一个；`..\` 这类名字被拒。
    - W4：服务器上标记没了就停，镜像里不新建标记。
    - W7：超过上限的文件放长期占位。
  - 混用测试里，六类（片段与收藏、生词、网页搜索、翻译服务、状态、提醒）各走一遍。
- **真服务器**：`KITTY_WEBDAV` 对着测试用的 WebDAV 跑一遍 Basic，有条件再跑一遍 Digest。报告里写：
  - 服务器是什么；
  - 访问日志核对的结果：空闲一轮几个 PROPFIND、只 GET 对方变了的、图片先 PUT 临时名再 MOVE、标记第二次 PUT 回 412。
- **截图**，浅色、深色、高对比度各一套：
  - 「同步」没开时（两个按钮）；
  - 表单：空的、填了 http 地址出橙字、测试连接成功 / 失败、问合不合在一起；
  - 开着连服务器：正常、还有几个没拿下来 / 没传上去、请求太多。
- **量**：
  - AOT 发布体积比上一批涨多少（W8）；
  - 内存探针：开着连服务器同步时多多少；
  - 一轮的耗时：空闲一轮、第一次连有几百条便签时；
  - 镜像占多大（W5）。
- **手测**（接着 `HANDTEST.md` 末尾编号）：
  1. 设置 › 通用「同步」没开时：一张卡「在几台电脑之间同步」，右边是「连接服务器…」「选择文件夹…」。
  2. 点「连接服务器…」：表单里有服务器地址、文件夹（默认「Kitty Tools 同步」）、用户名、密码。地址写 http:// 开头时下面出橙字说明是明文；没填全时「测试连接」「连接」是灰的。
  3. 点「测试连接」：
     - 文件夹已经有 →「连上了，能读能写」，服务器上没留下 `.kitty-test` 文件；
     - 文件夹还没有 →「连上了；服务器上还没有这个文件夹，连接时会新建」；
     - 密码错 →「用户名或密码不对…」；
     - 地址错 →「连不上服务器：找不到这个服务器」这类。
  4. 点「连接」：对话框关掉，那张卡变成「同步服务器」+ 服务器图标 + 文件夹名，悬停能看到网址和用户名。服务器上有了这个文件夹、标记和 `devices/<编号>/`。凭据管理器 › Windows 凭据里多了一条 `KittyTools/sync-server.password`（Dev 版 `KittyTools.Dev/…`）；settings.json 里没有密码。
  5. 一台 Mac（0.9.0 起，或 Dev 版）连同一个地址、同一个文件夹：先问合不合在一起；合了之后便签、片段、生词来回传。一边改一条，约一分钟后另一边跟上；「立即同步」马上合。
  6. 便签里贴一张图：另一台拿到这张图；服务器的 `images/` 里只有正式名字的图。
  7. 一台连服务器，另一台用网盘客户端把同一个文件夹同步到本机、在「选择文件夹…」里选它：两台照样合在一起。
  8. 有几百条便签时第一次连：状态行出现「还有 N 个文件没从服务器拿下来」「还有 N 个等着传上去」，几分钟内降到没有，中途不报错。
  9. 断网（关 Wi-Fi）：橙字「连不上服务器：…」。这期间改一条便签，联网后下一轮传上去，另一台收到。
  10. （按次数限流的网盘）连着点很多次「立即同步」，直到服务器拒绝：橙字「服务器说请求太多，HH:mm 后接着同步」；到点之前不再发请求（看服务器日志或抓包），之后自己恢复。
  11. 点「停止同步」：回到没开时的那张卡；凭据管理器里那条没了，数据目录下 `sync-server` 里空了，服务器上的东西都还在。再连回来：接着同一个库（先问合不合在一起）。
  12. 设置导出的文件里没有服务器地址、用户名、密码。
  13. 卸载时选删数据：凭据管理器里那条也没了。
- **报告**写：量到的数、真服务器测试的结果、替用户定的、没测的。
