// 应用内更新（PLAN D8，2026-09-27 改为做）：先读本仓库（github.com/YyAdnBug/kitty-tools，不碰 Tauri 版的仓库）latest 那个
// release 上的更新清单 macos-update.json（build-dmg.sh 生成，一个静态文件：不走 API，不受没登录时每个 IP 每小时 60 次的限制——
// 公司、学校共用出口时一下就用完、报 403，issue #12）；读不到（老 release 没有它、Windows 版被误标成 latest、网络问题）再读
// API 的 release 列表，取版本号最大的 macos-v*（跳过草稿和预发布；第四轮体检 E13：同一个仓库里还发 Windows 版，windows-v* 标成
// latest 时读 releases/latest 就找不到 mac 的新版）；API 也限流时说清是限流（apiFailure）。有更新的版本：刘海岛提示一次（每个版本一次；只停 2 秒、不接点击，错过就没了），
// 所以另有常驻到更新为止的入口（2026-10-06，对标 Alfred 窗口底部的小提示 / Raycast 根搜索顶上那一行 / Sparkle 给后台 App 的
// 「温和提醒」）：菜单栏图标右上角的小圆点（StatusItem.updateVersion）+ 菜单顶上「更新到 x…」、剪贴板面板和启动器底栏的
// 「更新到 x」（UpdateBarHint）、关于页的「更新并重新打开」。更新 = 下载 release 里的 *_arm64.zip → ditto 解到 App 所在卷的临时目录 →
// 校验 bundle id、版本号和签名（Apple 签发、本团队 HTX9F4KG39 的证书）→ 原子地换掉正在运行的 .app →
// 等本进程退出后重新打开。下载是最久的一步，下了多少实时报出来（progress：关于页的进度条、刘海岛上的细条和百分比，
// 2026-10-13 用户要求「不是一直 loading」），下载中能取消（岛和关于页的「取消」，第四轮体检 E23：回到「有新版本」，
// 下了一半的临时文件由系统的下载任务删掉）；之后解包、验签、替换只有一两秒，写「正在安装」、不能取消。不用 Sparkle（禁止第三方依赖）；解包、验签交给系统的 ditto / codesign，在进程外跑。
// App 自己用 URLSession 下载的文件不带隔离标记（实测），换上的新版不会再被 Gatekeeper 拦；证书不变，授权不丢。
// 只有正式版（bundle id com.yy.kitty-tools.native）更新：Debug 版的 bundle id 不同，装过去会把 Dev 换成正式版。

import AppKit

@Observable final class Updater {
  struct Release: Equatable, Sendable {
    let version: String
    /// 更新包（*_arm64.zip）
    let archive: URL
    /// 发布页（看更新内容）
    let page: URL
    /// 更新包的 SHA-256（小写十六进制）：清单里有，下完先核一遍；API 那条路没有
    var sha256: String? = nil
  }

  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(Release)
    case installing(Release)
    /// 新版本已经换上、退出却被取消了（便签没存上时点了「取消」，AppDelegate.applicationShouldTerminate）：
    /// 下次退出时等着的那个 sh 会把新版打开
    case installed(Release)
    case failed(String)
  }

  /// 谁发起的检查：定时的只在发现新版本时提示（每个版本一次）；菜单里点的结果都用刘海说（菜单一关就看不见）；
  /// 关于页点的结果就写在页上
  enum Trigger {
    case schedule, menu, page
  }

  private(set) var state: State {
    didSet { available = Self.available(available, after: state) }
  }
  /// 发现的新版本（菜单栏图标的角标和菜单顶上那一项、面板底栏的「更新到 x」）：复查期间、没查成时留着，见 available(_:after:)
  private(set) var available: Release? {
    didSet { if available != oldValue { onAvailableChange(available) } }
  }
  /// available 变了（AppDelegate 接菜单栏图标的角标；面板底栏是 SwiftUI，自己跟着变）
  @ObservationIgnored var onAvailableChange: (Release?) -> Void = { _ in }
  /// 更新包下了多少（0…1，整百分点；下完到重新打开之前一直是 1）。nil = 没在下载，或服务器没给大小（那就还是转着等）
  private(set) var progress: Double?
  /// 此刻不能更新的原因（录屏中「录制结束后再更新」，AppDelegate 写）：关于页的「更新并重新打开」置灰、旁边写它；
  /// 菜单里点了「更新到 x…」用刘海说
  var blocker: String?
  /// 正在下载更新包（关于页和岛上这时有「取消」；下完进入解包、验签、替换就是 false，那几步不能停）
  private(set) var isDownloading = false
  /// 刘海岛（AppDelegate 给，单测里是 nil）
  @ObservationIgnored var island: Island?
  /// 正在下载的那个任务（「取消」掐它，E23）
  @ObservationIgnored private var downloadTask: Task<(URL, URLResponse), Error>?
  @ObservationIgnored private var schedule: Task<Void, Never>?
  /// 检查进行中时菜单里又点了「检查更新…」：这次的结果也用刘海说
  @ObservationIgnored private var menuWaiting = false

  static let bundleID = "com.yy.kitty-tools.native"
  static let releasesPage = URL(string: "https://github.com/YyAdnBug/kitty-tools/releases")!
  /// 更新清单的文件名（build-dmg.sh 写同一个名字，UpdaterTests 比对）
  static let manifestName = "macos-update.json"
  /// latest 那个 release 上的清单：github.com 的下载地址，302 到附件，不算 API 的次数
  private static let manifest = URL(
    string: "https://github.com/YyAdnBug/kitty-tools/releases/latest/download/\(manifestName)")!
  /// 最近 20 个 release（mac 和 Windows 混在一起，按发布时间倒序）：从里面挑 macos-v*
  private static let releases = URL(
    string: "https://api.github.com/repos/YyAdnBug/kitty-tools/releases?per_page=20")!
  /// 新包必须满足的签名要求：同一个 bundle id、Apple 签发、本团队的证书（只认团队，换证书也能更新）
  static let requirement =
    "=identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"HTX9F4KG39\""

  /// state / progress / downloading：截图自检直接摆出各种状态；正常使用就是 `Updater()`
  init(state: State = .idle, progress: Double? = nil, downloading: Bool = false) {
    self.state = state
    self.progress = progress
    isDownloading = downloading
    available = Self.available(nil, after: state)
  }

  /// 正式版才更新（Debug 版 bundle id 不同）
  var isSupported: Bool { Bundle.main.bundleIdentifier == Self.bundleID }

  /// 启动后 10 s 查一次，之后每天一次；没查成（多半是刚开机网络还没好）半小时后再试。设置里关了就跳过
  func start() {
    guard isSupported else { return }
    schedule?.cancel()
    schedule = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      while !Task.isCancelled {
        var succeeded = true
        if UserDefaults.standard.bool(forKey: Prefs.updateAutoCheck) {
          succeeded = await self?.check(.schedule) ?? true
        }
        try? await Task.sleep(for: .seconds(succeeded ? 86_400 : 1_800))
      }
    }
  }

  /// 返回这次有没有查成（定时检查没查成时早点重试）
  @discardableResult
  func check(_ trigger: Trigger) async -> Bool {
    switch state {
    case .checking:
      if trigger == .menu { menuWaiting = true }
      return true
    case .installing(let release):
      if trigger == .menu { showInstalling(release) }
      return true
    case .installed(let release):
      if trigger == .menu { showInstalled(release) }
      return true
    default: break
    }
    guard isSupported else {
      state = .failed("开发版不自动更新")
      return true
    }
    let previous = state
    state = .checking
    do {
      let latest = try await Self.latest()
      let toMenu = trigger == .menu || menuWaiting
      menuWaiting = false
      // 检查还在路上时点了「更新到 x」（入口在复查期间留着）：已经在装了，这次的结果不要
      guard case .checking = state else { return true }
      if let release = latest, Self.isNewer(release.version, than: AboutTab.version) {
        state = .available(release)
        let notified = UserDefaults.standard.string(forKey: Prefs.updateNotifiedVersion)
        if toMenu || (trigger == .schedule && notified != release.version) {
          UserDefaults.standard.set(release.version, forKey: Prefs.updateNotifiedVersion)
          // 菜单栏图标隐藏了（设置 › 通用）就指到关于页的按钮
          let hint =
            UserDefaults.standard.bool(forKey: Prefs.statusItemVisible)
            ? "点菜单栏图标，选「更新到 \(release.version)」" : "到 设置 › 关于 里点「更新并重新打开」"
          island?.show(
            "有新版本 \(release.version)", detail: hint, tone: .info,
            symbol: "arrow.down.circle.fill", actions: [installAction("更新")])
        }
      } else {
        state = .upToDate
        if toMenu { island?.show("已是最新版本", detail: "当前 \(AboutTab.version)") }
      }
      return true
    } catch {
      let toMenu = trigger == .menu || menuWaiting
      menuWaiting = false
      guard case .checking = state else { return false }
      // 已经发现的新版本不因为这次没查成就丢掉；定时检查没查成不在关于页报错（用户没点过）
      if case .available = previous {
        state = previous
      } else if trigger == .schedule {
        if case .failed = previous { state = .idle } else { state = previous }
      } else {
        state = .failed("检查更新失败：\(error.localizedDescription)")
      }
      if toMenu {
        island?.show(
          "检查更新失败", detail: error.localizedDescription, tone: .error,
          actions: [
            .init("重试") { [weak self] in
              guard let self else { return }
              Task { await self.check(.menu) }
            }
          ])
      }
      return false
    }
  }

  /// 下载、校验、换掉正在运行的 App，再重新打开。关于页点的：页上有转圈，不再弹岛（Whisker S2 分工）；
  /// 失败时回到「有新版本」，刘海岛说原因
  func install(_ trigger: Trigger = .menu) async {
    guard let release = available, isSupported else { return }
    if let blocker {
      island?.show(blocker, tone: .warning)
      return
    }
    state = .installing(release)
    progress = nil
    do {
      let app = Bundle.main.bundleURL
      try Self.checkReplaceable(app)
      // 下载单独一个任务：「取消」只掐它（E23）。进度是下载的线程报的，回到主线程再动界面
      let report: @Sendable (Double) -> Void = { [weak self] fraction in
        Task { @MainActor in self?.downloaded(fraction, of: release) }
      }
      let task = Task { try await Self.download(release.archive, progress: report) }
      downloadTask = task
      isDownloading = true
      if trigger != .page { showInstalling(release) }
      let result = await task.result
      downloadTask = nil
      isDownloading = false
      // 点了「取消」（哪怕刚好下完）：回到「有新版本」，下好的包删掉；没下完的临时文件系统的下载任务自己删
      if task.isCancelled {
        if case .success(let downloaded) = result {
          try? FileManager.default.removeItem(at: downloaded.0)
        }
        return downloadCancelled(release)
      }
      let (zip, response) = try result.get()
      // 下完了：岛上的「取消」去掉（解包、验签、替换不能停）
      if trigger != .page { showInstalling(release) }
      try await Self.replace(app, with: release, zip: zip, response: response)
      try Self.relaunch(app)
      NSApp.terminate(nil)
      // 还走得到这里 = 退出被取消了（B5：原来一直显示「正在安装」）。等着本进程退出再重开的 sh 留着
      quitCancelled(release, trigger: trigger)
    } catch {
      downloadTask = nil
      isDownloading = false
      state = .available(release)
      progress = nil
      island?.show(
        "更新失败", detail: error.localizedDescription, tone: .error,
        actions: [installAction("重试")])
    }
  }

  /// 关于页、岛上的「取消」（只在下载中有用；同转 GIF 的取消：不出结果岛）
  func cancelDownload() {
    downloadTask?.cancel()
  }

  private func downloadCancelled(_ release: Release) {
    state = .available(release)
    progress = nil
    island?.dismiss(ifShowing: Self.installingTitle(release.version))
  }

  /// 岛上的「更新」「重试」：同菜单栏的「更新到 x」
  private func installAction(_ title: String) -> Island.Action {
    .init(title) { [weak self] in
      guard let self else { return }
      Task { await self.install(.menu) }
    }
  }

  /// 新版本换上了、退出却被取消了：改说「已装好，退出后重新打开即生效」，进度清掉；岛上那条「正在更新」原地换成它
  /// （从关于页点的没有岛，页上自己换）
  func quitCancelled(_ release: Release, trigger: Trigger) {
    state = .installed(release)
    progress = nil
    if trigger != .page { showInstalled(release) }
  }

  private func showInstalled(_ release: Release) {
    island?.show("新版本 \(release.version) 已装好", detail: Self.installedDetail)
  }

  /// 下载中带「取消」，下完（在装）就不带
  private func showInstalling(_ release: Release) {
    island?.show(
      Self.installingTitle(release.version), detail: Self.installingDetail(progress),
      tone: .progress, symbol: "arrow.down.circle.fill", fraction: progress,
      actions: isDownloading ? [.init("取消") { [weak self] in self?.cancelDownload() }] : [])
  }

  /// 下载又进了一截：整百分点才动一次界面（一次下载报几百回），只往前走（回主线程的顺序不保证）；岛上那一条跟着改
  /// （从关于页点的没有岛，改不到就算了）
  private func downloaded(_ fraction: Double, of release: Release) {
    let percent = (min(max(fraction, 0), 1) * 100).rounded(.down) / 100
    guard state == .installing(release), percent > progress ?? -1 else { return }
    progress = percent
    island?.progress(
      Self.installingTitle(release.version), detail: Self.installingDetail(percent),
      fraction: percent)
  }

  // MARK: 纯逻辑（单测）

  /// 刘海岛上更新那一条的标题（进度按标题认这一条，两处要同一句）
  static func installingTitle(_ version: String) -> String { "正在更新到 \(version)…" }

  /// 岛上的后半句：还不知道下了多少 / 下载中的百分比 / 下完了在装
  static func installingDetail(_ progress: Double?) -> String {
    switch progress {
    case nil: "装好会自动重新打开"
    case let value? where value < 1: "已下载 \(Int((value * 100).rounded()))%"
    default: "正在安装，装好会自动重新打开"
    }
  }

  /// 装好了、还没退出：岛上的后半句，关于页那句话的后半句
  static let installedDetail = "退出后重新打开即生效"

  /// 关于页上的那句话（进度条在它前面）
  static func installingLine(_ version: String, progress: Double?) -> String {
    switch progress {
    case nil: installingTitle(version)
    case let value? where value < 1: "正在下载 \(version) · \(Int((value * 100).rounded()))%"
    default: "正在安装 \(version)…"
    }
  }

  /// 状态变了之后，已经发现的新版本还算不算：复查中、没查成时留着——不然菜单栏的角标、面板底栏的「更新到 x」每天复查
  /// 那一下都要闪（连不上 GitHub 时一闪就是到超时为止，半小时重试一次）；查到已是最新、开始安装才清
  static func available(_ known: Release?, after state: State) -> Release? {
    switch state {
    case .available(let release): release
    case .upToDate, .installing, .installed: nil
    case .idle, .checking, .failed: known
    }
  }

  /// 最新的 mac 版（没有 = nil）：先读清单，没读到 200、解不出来就读 API 的 release 列表；API 不是 200 / 404 时抛出说给人听的原因。
  /// fetch：取一个网址，给回正文和状态码（单测换成假的，不联网）
  static func latest(
    fetch: (URL) async throws -> (data: Data, status: Int) = Updater.fetch
  ) async throws -> Release? {
    if let reply = try? await fetch(manifest), reply.status == 200,
      let release = Self.release(fromManifest: reply.data)
    {
      return release
    }
    let reply = try await fetch(releases)
    // 仓库还没有 release 时列表是空的（200）；404 当成没有
    guard reply.status == 200 || reply.status == 404 else {
      throw UpdateError(apiFailure(reply.status))
    }
    return reply.status == 200 ? try release(from: reply.data) : nil
  }

  /// 不读缓存（一天才查一次；清单在同一个网址上换内容）；API 要带它的 Accept
  private static func fetch(_ url: URL) async throws -> (data: Data, status: Int) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  /// API 没给 200 / 404 时怎么说：403 / 429 是限流——没登录的 API 每个 IP 每小时 60 次，公司、学校共用一个出口时
  /// 别人就替你用完了（#12；关于页那一行只有一行宽，话要短，下面就是「打开发布页」）
  static func apiFailure(_ status: Int) -> String {
    status == 403 || status == 429
      ? "GitHub 限流了（这个网络查得太频繁），稍后再试或到发布页下载" : "GitHub 返回 \(status)"
  }

  /// 更新清单（build-dmg.sh 生成）→ 那一版。认 version（只有数字和点）、url 和 page（https）、sha256（64 位十六进制），
  /// 缺一样、不对就 nil（退回 API）；别的键不管（size 现在没用上）。**格式发布后别改**（已装的老版本会读 latest 上的它）：
  /// 只加新键；要改已有键的意思就换一个文件名，旧名字的照发
  static func release(fromManifest data: Data) -> Release? {
    struct Manifest: Decodable {
      let version: String
      let url: URL
      let sha256: String
      let page: URL
    }
    guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
    let sha256 = manifest.sha256.lowercased()
    guard manifest.version.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil,
      manifest.url.scheme == "https", manifest.page.scheme == "https",
      sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil
    else { return nil }
    return Release(
      version: manifest.version, archive: manifest.url, page: manifest.page, sha256: sha256)
  }

  /// GitHub release 列表的 JSON → 版本号最大的那个 mac 版（版本、更新包、发布页）。只认 macos-v* 的 tag、带 https 的
  /// *_arm64.zip 的；草稿、预发布跳过（E13：windows-v* 可能是 latest、也可能排在最前）。一个都没有时 nil
  static func release(from data: Data) throws -> Release? {
    struct Payload: Decodable {
      struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
      }
      let tagName: String
      let htmlUrl: URL
      let draft: Bool?
      let prerelease: Bool?
      let assets: [Asset]
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let prefix = "macos-v"
    let candidates = try decoder.decode([Payload].self, from: data).compactMap {
      payload -> Release? in
      guard payload.draft != true, payload.prerelease != true, payload.tagName.hasPrefix(prefix),
        let asset = payload.assets.first(where: { $0.name.hasSuffix("_arm64.zip") }),
        asset.browserDownloadUrl.scheme == "https"
      else { return nil }
      return Release(
        version: String(payload.tagName.dropFirst(prefix.count)),
        archive: asset.browserDownloadUrl, page: payload.htmlUrl)
    }
    return candidates.max { isNewer($1.version, than: $0.version) }
  }

  /// 按数字逐段比（0.1.10 比 0.1.9 新）
  static func isNewer(_ version: String, than current: String) -> Bool {
    version.compare(current, options: .numeric) == .orderedDescending
  }

  // MARK: 安装

  /// 下载更新包，解到 target 所在卷的临时目录，校验 bundle id、版本号和签名，再原子地换掉 target。
  /// 从 DMG 里、或没拖进「应用程序」就打开（系统把它挪到只读的随机路径）时换不了；标准（非管理员）账户写不了「应用程序」。
  /// progress：下载了多少（0…1），在下载的线程上调
  static func replace(
    _ target: URL, with release: Release, progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    try checkReplaceable(target)
    let (zip, response) = try await download(release.archive, progress: progress)
    try await replace(target, with: release, zip: zip, response: response)
  }

  /// 换得了 target 吗（下载之前先看，免得白下）
  static func checkReplaceable(_ target: URL) throws {
    let folderURL = target.deletingLastPathComponent()
    let folder = folderURL.path
    let readOnly = (try? folderURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
      .volumeIsReadOnly
    if folder.contains("/AppTranslocation/") || readOnly == true {
      throw UpdateError("请先把 Kitty Tools 拖进「应用程序」，从那里打开后再更新")
    }
    guard FileManager.default.isWritableFile(atPath: folder) else {
      throw UpdateError("没有权限替换「\(folder)」里的 App：请用管理员账户更新，或到发布页下载后手动替换")
    }
  }

  /// 下好的更新包（zip，这里用完就删）：解到 target 所在卷的临时目录、校验、原子地换掉 target
  static func replace(
    _ target: URL, with release: Release, zip: URL, response: URLResponse
  ) async throws {
    defer { try? FileManager.default.removeItem(at: zip) }
    if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
      throw UpdateError("下载失败（\(status)）")
    }
    // 清单里给了校验值（#12）：下得不全、被换过的包在这里就拦下，不等解包
    if let sha256 = release.sha256, await FileHash.digest(of: zip, kind: .sha256) != sha256 {
      throw UpdateError("更新包下载得不完整（校验值对不上），请重试")
    }
    let staging = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    // 不要包里带的 ACL、扩展属性（签名在包内，用不着；也挡掉带进来的隔离标记）
    try await run(
      "/usr/bin/ditto", ["-x", "-k", "--noacl", "--noextattr", zip.path, staging.path],
      failure: "更新包解不开")
    guard
      let app = try FileManager.default.contentsOfDirectory(
        at: staging, includingPropertiesForKeys: nil
      ).first(where: { $0.pathExtension == "app" }),
      let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
      info["CFBundleIdentifier"] as? String == bundleID,
      info["CFBundleShortVersionString"] as? String == release.version
    else { throw UpdateError("更新包不对（App 或版本号对不上）") }
    // 文件权限不在签名里：去掉组 / 其他人的写权限和 setuid / setgid / sticky，免得装进「应用程序」后别的账户能改它
    try await run("/bin/chmod", ["-R", "go-w,a-st", app.path], failure: "更新包的文件权限处理失败")
    try await run(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, app.path],
      failure: "更新包的签名校验没通过")
    _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
  }

  /// 下载到临时文件（调用方删），一路报下了多少（0…1，见 DownloadWatcher）
  static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    -> (URL, URLResponse)
  {
    try await URLSession.shared.download(from: url, delegate: DownloadWatcher(report: progress))
  }

  /// 等本进程退出后重新打开：先开的话新实例会看到还没退的旧实例，按单实例规则自己退出
  private static func relaunch(_ app: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [
      "-c",
      "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
      app.path,
    ]
    try process.run()
  }

  /// 跑系统命令（ditto / codesign）：在进程外，等它结束，非 0 退出就抛 failure
  private static func run(_ tool: String, _ arguments: [String], failure: String) async throws {
    guard try await Subprocess.run(tool, arguments).status == 0 else { throw UpdateError(failure) }
  }
}

/// 看着一次下载下了多少。async 的 download(from:) 不报进度：这一个任务的委托收不到 didWriteData（实测 0 次），只有
/// didCreateTask 把任务交过来，之后看它的 progress（一变就按任务上的字节数算，progress 自己的比例开头有 5% 的虚头）。
/// 服务器没给大小就不报。回调都在会话自己的线程上
private final class DownloadWatcher: NSObject, URLSessionTaskDelegate {
  private let report: @Sendable (Double) -> Void
  /// 只在 didCreateTask 里写一次，之后只是拿着（放掉就不再观察）
  nonisolated(unsafe) private var observation: NSKeyValueObservation?

  init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

  nonisolated func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    observation = task.progress.observe(\.fractionCompleted) { [report] _, _ in
      let expected = task.countOfBytesExpectedToReceive
      if expected > 0 { report(Double(task.countOfBytesReceived) / Double(expected)) }
    }
  }
}

struct UpdateError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
