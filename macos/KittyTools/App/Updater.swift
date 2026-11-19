// 应用内更新（PLAN D8，2026-09-27 改为做）：先读本仓库（github.com/YyAdnBug/kitty-tools，不碰 Tauri 版的仓库）latest 那个
// release 上的更新清单 macos-update.json（build-dmg.sh 生成，一个静态文件：不走 API，不受没登录时每个 IP 每小时 60 次的限制——
// 公司、学校共用出口时一下就用完、报 403，issue #12）；读不到（老 release 没有它、Windows 版被误标成 latest、网络问题）再读
// API 的 release 列表，取版本号最大的 macos-v*（跳过草稿和预发布；第四轮体检 E13：同一个仓库里还发 Windows 版，windows-v* 标成
// latest 时读 releases/latest 就找不到 mac 的新版）；API 也限流时说清是限流（apiFailure）。有更新的版本：刘海岛提示一次（每个版本一次；只停 2 秒、不接点击，错过就没了），
// 所以另有常驻到更新为止的入口（2026-10-06，对标 Alfred 窗口底部的小提示 / Raycast 根搜索顶上那一行 / Sparkle 给后台 App 的
// 「温和提醒」）：菜单栏图标右上角的小圆点（StatusItem.updateVersion）+ 菜单顶上「更新到 x…」、剪贴板面板和启动器底栏的
// 「更新到 x」（UpdateBarHint）、关于页的「更新并重新打开」。更新 = 下载 release 里这台架构的包（*_arm64.zip；Intel 上自己编的是 *_x86_64.zip，PR #21）→ ditto 解到 App 所在卷的临时目录 →
// 校验 bundle id、版本号和签名（Apple 签发、本团队 HTX9F4KG39 的证书）→ 原子地换掉正在运行的 .app →
// 等本进程退出后重新打开。下载是最久的一步，下了多少实时报出来（progress：关于页的进度条、刘海岛上的细条和百分比，
// 2026-10-13 用户要求「不是一直 loading」），下载中能取消（岛和关于页的「取消」，第四轮体检 E23：回到「有新版本」，
// 下了一半的临时文件由系统的下载任务删掉）；之后解包、验签、替换只有一两秒，写「正在安装」、不能取消。不用 Sparkle（禁止第三方依赖）；解包、验签交给系统的 ditto / codesign，在进程外跑。
// App 自己用 URLSession 下载的文件不带隔离标记（实测），换上的新版不会再被 Gatekeeper 拦；证书不变，授权不丢。
// 第四轮体检 X11（2026-11-17）：
// - 「跳过这个版本」（岛上、关于页）：角标、菜单和底栏的「更新到 x」（nudge）、后台检查的岛都不再提它，更新的版本出来照常提；
//   关于页照样写着、能取消跳过（Prefs.updateSkippedVersion，这台电脑自己的）。
// - 后台下载、退出时安装（设置 › 关于，默认开）：查到新版本（没跳过）就在后台把包下到缓存目录（prepare），退出时
//   （AppDelegate.applicationShouldTerminate）装上——校验一条不少，走同一个 replace；装好不重新打开（用户是要退出），
//   装不成照常退出、下次打开再查再下。下好之前点了「更新」照旧从头下；下好之后点「更新」直接用下好的那份。
// 第五轮体检 E10（2026-11-18）：
// - 查到新版本时就看这份 App 能不能原地换（obstacle：在 DMG 里、没拖进「应用程序」被系统挪到临时位置、只读卷、所在文件夹
//   写不进去）；换不了时四个入口（岛、菜单「更新到 x…」、面板底栏、关于页）都改成「到发布页下载」并写明原因，不再让人点
//   一个注定失败的「更新」。
// - 装失败按原因分（failureKind）：网络（下载断了、服务器不是 200、校验值对不上）才给「重试」；磁盘满单独说、不给重试
//   （腾出空间再点「更新」）；签名没过、解不开、包不对这类重试也不会好的给「打开发布页」。关于页把原因写全（多行）。
// 只有正式版（bundle id com.yy.kitty-tools.native）更新：Debug 版的 bundle id 不同，装过去会把 Dev 换成正式版。

import AppKit
import OSLog
import Synchronization

@Observable final class Updater {
  struct Release: Equatable, Sendable {
    let version: String
    /// 更新包（*_arm64.zip / *_x86_64.zip，archiveSuffix）
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

  /// 这份 App 为什么原地换不了（E10）：入口都改成「到发布页下载」，写上 reason
  enum Obstacle: Equatable {
    /// 在 DMG 里、只读卷上，或没拖进「应用程序」就打开（被系统挪到了临时位置）
    case notInstalled
    /// 所在的文件夹写不进去（标准账户装在「应用程序」里）
    case noPermission

    /// 一句话：岛上的详情、关于页、底栏和菜单的悬停提示
    var reason: String {
      switch self {
      case .notInstalled:
        String(localized: "Kitty Tools 不是从「应用程序」里打开的，没法原地更新：到发布页下载新版，拖进「应用程序」后从那里打开")
      case .noPermission:
        String(localized: "没有权限替换这个 App：到发布页下载新版，用管理员账户替换")
      }
    }

    /// 短的，菜单那一项下面的小字
    var summary: String {
      switch self {
      case .notInstalled: String(localized: "没从「应用程序」里打开，没法原地更新")
      case .noPermission: String(localized: "没有权限替换这个 App")
      }
    }
  }

  /// 装没成的那一次（E10）：关于页写在「有新版本」下面；再点「更新」、查到别的版本时清掉
  struct Failure: Equatable {
    let message: String
    let kind: UpdateError.Kind
  }

  private(set) var state: State {
    didSet { available = Self.available(available, after: state) }
  }
  /// 发现的新版本（菜单栏图标的角标和菜单顶上那一项、面板底栏的「更新到 x」）：复查期间、没查成时留着，见 available(_:after:)
  private(set) var available: Release? {
    didSet { if available != oldValue { onAvailableChange(nudge) } }
  }
  /// 「跳过这个版本」跳过的版本号（X11）
  private(set) var skipped: String? {
    didSet { if skipped != oldValue { onAvailableChange(nudge) } }
  }
  /// 该提示的新版本：available 里去掉跳过的那个（菜单栏图标的角标、菜单顶上那一项、面板底栏的「更新到 x」）
  var nudge: Release? { Self.nudge(available, skipped: skipped) }
  /// nudge 可能变了（AppDelegate 接菜单栏图标的角标；面板底栏是 SwiftUI，自己跟着变）
  @ObservationIgnored var onAvailableChange: (Release?) -> Void = { _ in }
  /// 后台下好、等退出时装的那一版（X11；关于页写「已下载好」）和包
  private(set) var ready: Release?
  @ObservationIgnored private var readyZip: URL?
  /// 后台下载那个任务（跳过、关掉开关、点「更新」时掐掉）
  @ObservationIgnored private var prepareTask: Task<Void, Never>?
  /// 更新包下了多少（0…1，整百分点；下完到重新打开之前一直是 1）。nil = 没在下载，或服务器没给大小（那就还是转着等）
  private(set) var progress: Double?
  /// 这份 App 原地换不了（E10）：查到新版本时判断；nil = 能换
  private(set) var obstacle: Obstacle?
  /// 上一次装没成（E10，关于页写原因）
  private(set) var failure: Failure?
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
  /// 更新包的后缀跟着这份 App 的架构走（PR #21：Intel 能自己编）。Intel 上找 _x86_64.zip，release 里没有就当没有更新——
  /// 把 _arm64.zip 换上去，Intel 上就打不开了；清单（只写 arm64 那个包）的网址后缀对不上也不认，退回 API 按后缀挑
  #if arch(x86_64)
    static let archiveSuffix = "_x86_64.zip"
    private static let architecture = NSBundleExecutableArchitectureX86_64
  #else
    static let archiveSuffix = "_arm64.zip"
    private static let architecture = NSBundleExecutableArchitectureARM64
  #endif
  /// 新包必须满足的签名要求：同一个 bundle id、Apple 签发、本团队的证书（只认团队，换证书也能更新）
  static let requirement =
    "=identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"HTX9F4KG39\""

  /// state / progress / downloading：截图自检直接摆出各种状态；正常使用就是 `Updater()`
  init(
    state: State = .idle, progress: Double? = nil, downloading: Bool = false,
    skipped: String? = UserDefaults.standard.string(forKey: Prefs.updateSkippedVersion),
    ready: Release? = nil, obstacle: Obstacle? = nil, failure: Failure? = nil
  ) {
    self.state = state
    self.progress = progress
    isDownloading = downloading
    available = Self.available(nil, after: state)
    self.skipped = skipped
    self.ready = ready
    self.obstacle = obstacle
    self.failure = failure
  }

  /// 正式版才更新（Debug 版 bundle id 不同）
  var isSupported: Bool { Bundle.main.bundleIdentifier == Self.bundleID }

  /// 启动后 10 s 查一次，之后每天一次；没查成（多半是刚开机网络还没好）半小时后再试。设置里关了就跳过
  func start() {
    guard isSupported else { return }
    // 上次后台下好、没装上的包（退出时没装成、开关关了）：这次查到再下。换上之后还没核完就退出了（退出时最多等 30 秒）
    // 留下的那份旧 App 也删掉
    try? FileManager.default.removeItem(at: Self.preparedFolder)
    try? FileManager.default.removeItem(at: Self.backupURL(of: Bundle.main.bundleURL))
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
      state = .failed(String(localized: "开发版不自动更新"))
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
        // 上次没装上的原因只留到下一次查到（同一版也清：可能是几天前的事，磁盘早腾出来了）
        failure = nil
        // 能不能原地换，现在就看（E10）：换不了的话入口都改成「到发布页下载」
        obstacle = Self.obstacle(Bundle.main.bundleURL)
        state = .available(release)
        let notified = UserDefaults.standard.string(forKey: Prefs.updateNotifiedVersion)
        let skipping = release.version == skipped
        if toMenu || (trigger == .schedule && notified != release.version && !skipping) {
          UserDefaults.standard.set(release.version, forKey: Prefs.updateNotifiedVersion)
          // 菜单栏图标隐藏了（设置 › 通用）就指到关于页的按钮；跳过了的（菜单里点「检查更新…」才说）指到取消跳过
          let hint: LocalizedStringResource =
            skipping
            ? "已跳过这个版本，到 设置 › 关于 里能取消跳过"
            : UserDefaults.standard.bool(forKey: Prefs.statusItemVisible)
              ? "点菜单栏图标，选「更新到 \(release.version)」" : "到 设置 › 关于 里点「更新并重新打开」"
          // 换不了（E10）：详情写原因，按钮是「打开发布页」
          var detail = hint
          if let obstacle { detail = "\(obstacle.reason)" }
          let update = obstacle == nil ? installAction("更新") : pageAction(release)
          island?.show(
            "有新版本 \(release.version)", detail: detail, tone: .info,
            symbol: "arrow.down.circle.fill",
            actions: skipping ? [update] : [update, skipAction()])
        }
        prepare(release)
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
        state = .failed(String(localized: "检查更新失败：\(error.localizedDescription)"))
      }
      if toMenu {
        island?.show(
          "检查更新失败", detail: "\(error.localizedDescription)", tone: .error,
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
    // 原地换不了（E10）：入口已经是「到发布页下载」，走到这里也只开发布页
    if obstacle != nil { return openPage(release) }
    if let blocker {
      island?.show("\(blocker)", tone: .warning)
      return
    }
    failure = nil
    // 后台已经下好这一版：直接装它（replace 照样全部校验）；还在下的掐掉、从头下（ponytail: 不接着它的进度，
    // 后台那次没有进度可接；要省这一截再把后台下载改成带进度的同一个任务）
    stopPreparing()
    // 校验用下这个包时的那一版（清单那条路带 sha256；这次检查可能落在 API 那条路上、没有 sha256）
    let downloadedFor = Self.same(ready, release) ? ready : nil
    let prepared = downloadedFor == nil ? nil : readyZip
    if prepared == nil { discardReady() }
    ready = nil
    readyZip = nil
    state = .installing(release)
    progress = prepared == nil ? nil : 1
    do {
      let app = Bundle.main.bundleURL
      try Self.checkReplaceable(app)
      let zip: URL
      var response: URLResponse?
      if let prepared {
        zip = prepared
      } else {
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
        (zip, response) = try result.get()
      }
      // 下完了：岛上的「取消」去掉（解包、验签、替换不能停）
      if trigger != .page { showInstalling(release) }
      try await Self.replace(app, with: downloadedFor ?? release, zip: zip, response: response)
      try Self.relaunch(app)
      NSApp.terminate(nil)
      // 还走得到这里 = 退出被取消了（B5：原来一直显示「正在安装」）。等着本进程退出再重开的 sh 留着
      quitCancelled(release, trigger: trigger)
    } catch {
      downloadTask = nil
      isDownloading = false
      // 换不了 App 时（checkReplaceable）后台下好的包还没交给 replace：一并删掉
      if let prepared { try? FileManager.default.removeItem(at: prepared) }
      // 装的时候才发现换不了（查到新版本之后挪了地方、改了权限）：入口跟着改成「到发布页下载」
      if let found = Self.obstacle(Bundle.main.bundleURL) { obstacle = found }
      let kind = Self.failureKind(error, lowOnSpace: Self.isLowOnSpace(Bundle.main.bundleURL))
      let message = kind == .diskFull ? Self.diskFullMessage : error.localizedDescription
      failure = Failure(message: message, kind: kind)
      state = .available(release)
      progress = nil
      // 「重试」只给网络问题；磁盘满腾出空间后再点「更新」；别的重试也不会好，给发布页
      let actions: [Island.Action] =
        switch kind {
        case .network: [installAction("重试")]
        case .diskFull: []
        case .unpack, .other: [pageAction(release)]
        }
      island?.show(
        kind == .diskFull ? "磁盘空间不够，没装上新版本" : "更新失败", detail: "\(message)", tone: .error,
        actions: actions)
    }
  }

  /// 打开这一版的发布页（换不了 App、装不上时的出路，E10）
  func openPage(_ release: Release) {
    NSWorkspace.shared.open(release.page)
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

  /// 「跳过这个版本」（岛上、关于页）：角标、菜单和底栏的「更新到 x」收起，后台下的包不要了
  func skip() {
    guard let release = available else { return }
    UserDefaults.standard.set(release.version, forKey: Prefs.updateSkippedVersion)
    skipped = release.version
    stopPreparing()
    discardReady()
    island?.dismiss(ifShowing: "有新版本 \(release.version)")
  }

  /// 关于页的「取消跳过」
  func unskip() {
    UserDefaults.standard.removeObject(forKey: Prefs.updateSkippedVersion)
    skipped = nil
    if let available { prepare(available) }
  }

  /// 设置 › 关于「在后台下载新版本，退出时安装」拨了：关掉就不下了、下好的删掉；打开就把已经发现的那一版下起来
  func installOnQuitChanged() {
    if UserDefaults.standard.bool(forKey: Prefs.updateInstallOnQuit) {
      if let available { prepare(available) }
    } else {
      stopPreparing()
      discardReady()
    }
  }

  /// 退出时有没有下好的新版本要装（AppDelegate.applicationShouldTerminate）
  var hasPrepared: Bool {
    guard let ready, readyZip != nil, isSupported, Self.same(available, ready) else { return false }
    return UserDefaults.standard.bool(forKey: Prefs.updateInstallOnQuit) && ready.version != skipped
  }

  /// 退出时装上后台下好的新版本：校验和点「更新」走同一个 replace；装好不重新打开，装不成就算了（只记日志，照常退出）。
  /// 开着的这段时间里用户自己换上了一样新或更新的版本（从 DMG 拖进去的）：不装，免得装回旧的
  func installPrepared() async {
    guard hasPrepared, let release = ready, let zip = readyZip else { return }
    ready = nil
    readyZip = nil
    let target = Bundle.main.bundleURL
    let onDisk =
      NSDictionary(contentsOf: target.appending(path: "Contents/Info.plist"))?[
        "CFBundleShortVersionString"] as? String ?? AboutTab.version
    guard Self.isNewer(release.version, than: onDisk) else {
      try? FileManager.default.removeItem(at: zip)
      return
    }
    state = .installing(release)
    progress = 1
    island?.show(
      "正在装上新版本 \(release.version)", detail: "装好就退出", tone: .progress,
      symbol: "arrow.down.circle.fill")
    do {
      try await Self.replace(target, with: release, zip: zip, response: nil)
      state = .installed(release)
    } catch {
      Log.storage.error("退出时没装上新版本：\(error.localizedDescription, privacy: .public)")
      state = .available(release)
    }
    progress = nil
  }

  /// 后台把这一版下到缓存目录、等退出时装（X11）：开关关着、跳过了、已经下好 / 正在下、换不了 App（没拖进「应用程序」、
  /// 没权限：下了也装不上）时不下；没下成就算了，下次检查再来
  private func prepare(_ release: Release) {
    guard isSupported, UserDefaults.standard.bool(forKey: Prefs.updateInstallOnQuit),
      release.version != skipped, !Self.same(ready, release), prepareTask == nil,
      (try? Self.checkReplaceable(Bundle.main.bundleURL)) != nil
    else { return }
    prepareTask = Task { [weak self] in
      let result = try? await Self.download(release.archive, progress: { _ in })
      // 掐掉了（stopPreparing 已经把 prepareTask 清了）、中途跳过了 / 关掉了 / 开始装了：下好的不要
      guard let self, !Task.isCancelled else {
        if let result { try? FileManager.default.removeItem(at: result.0) }
        return
      }
      prepareTask = nil
      guard let (zip, response) = result else { return }
      guard (response as? HTTPURLResponse)?.statusCode == 200, Self.same(available, release),
        release.version != skipped, UserDefaults.standard.bool(forKey: Prefs.updateInstallOnQuit),
        let kept = try? Self.keep(zip)
      else {
        try? FileManager.default.removeItem(at: zip)
        // 下载这一阵又查到了更新的一版（那时这边正在下，没起它）：接着下那一版
        if let available, !Self.same(available, release) { prepare(available) }
        return
      }
      ready = release
      readyZip = kept
    }
  }

  private func stopPreparing() {
    prepareTask?.cancel()
    prepareTask = nil
  }

  private func discardReady() {
    if let readyZip { try? FileManager.default.removeItem(at: readyZip) }
    ready = nil
    readyZip = nil
  }

  /// 后台下好的包放这里（系统临时目录里放久了会被清掉）；启动时清空
  static var preparedFolder: URL { URL.cachesDirectory.appending(path: "\(bundleID)/Updates") }

  /// 挪进 preparedFolder（固定的名字：版本号来自网上，不拿它拼路径）
  private static func keep(_ zip: URL) throws -> URL {
    let target = preparedFolder.appending(path: "ready.zip")
    try FileManager.default.createDirectory(at: preparedFolder, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.moveItem(at: zip, to: target)
    return target
  }

  private func pageAction(_ release: Release) -> Island.Action {
    .init("打开发布页") { [weak self] in self?.openPage(release) }
  }

  private func skipAction() -> Island.Action {
    .init("跳过这个版本") { [weak self] in self?.skip() }
  }

  /// 岛上的「更新」「重试」：同菜单栏的「更新到 x」
  private func installAction(_ title: LocalizedStringResource) -> Island.Action {
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
    island?.show("新版本 \(release.version) 已装好", detail: "\(Self.installedDetail)")
  }

  /// 下载中带「取消」，下完（在装）就不带
  private func showInstalling(_ release: Release) {
    island?.show(
      Self.installingTitle(release.version), detail: "\(Self.installingDetail(progress))",
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
      Self.installingTitle(release.version), detail: "\(Self.installingDetail(percent))",
      fraction: percent)
  }

  // MARK: 纯逻辑（单测）

  /// 磁盘满时怎么说（E10）
  static var diskFullMessage: String {
    String(localized: "磁盘空间不够：腾出一些空间后再点「更新并重新打开」")
  }

  /// 装没成的原因归哪一类（E10）：明说没空间的（POSIX ENOSPC、写文件时空间不够，错误链上哪一层都算）是磁盘满；下载写不了临时文件、
  /// 解不开包时磁盘快满了（lowOnSpace）也算磁盘满；别的网络错误、下载回的不是 200、校验值对不上是网络；剩下的（签名没过、包不对、
  /// 换不了 App）是别的
  static func failureKind(_ error: Error, lowOnSpace: Bool) -> UpdateError.Kind {
    var chain: [NSError] = []
    var next: NSError? = error as NSError
    while let current = next, chain.count < 8 {
      chain.append(current)
      next = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    let outOfSpace = chain.contains {
      ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC))
        || ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
    }
    if outOfSpace { return .diskFull }
    if let update = error as? UpdateError {
      return update.kind == .unpack ? (lowOnSpace ? .diskFull : .other) : update.kind
    }
    if let url = error as? URLError {
      let writing: [URLError.Code] = [.cannotCreateFile, .cannotWriteToFile]
      return writing.contains(url.code) && lowOnSpace ? .diskFull : .network
    }
    return .other
  }

  /// App 所在的卷和临时目录那个卷，有一个剩得不到 300 MB（E10：解包、下载失败时拿它判断是不是磁盘满）。
  /// ponytail: 定死 300 MB（更新包解开约 100 MB，下载、暂存、换上各一份）；包变大了再按包的大小算
  static func isLowOnSpace(_ app: URL) -> Bool {
    [app.deletingLastPathComponent(), FileManager.default.temporaryDirectory].contains { folder in
      guard
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
          .volumeAvailableCapacity
      else { return false }
      return free < 300_000_000
    }
  }

  /// 刘海岛上更新那一条的标题（进度按标题认这一条，两处要同一句）
  static func installingTitle(_ version: String) -> LocalizedStringResource {
    "正在更新到 \(version)…"
  }

  /// 岛上的后半句：还不知道下了多少 / 下载中的百分比 / 下完了在装
  static func installingDetail(_ progress: Double?) -> String {
    switch progress {
    case nil: String(localized: "装好会自动重新打开")
    case let value? where value < 1: String(localized: "已下载 \(Int((value * 100).rounded()))%")
    default: String(localized: "正在安装，装好会自动重新打开")
    }
  }

  /// 装好了、还没退出：岛上的后半句，关于页那句话的后半句
  static var installedDetail: String { String(localized: "退出后重新打开即生效") }

  /// 关于页上的那句话（进度条在它前面）
  static func installingLine(_ version: String, progress: Double?) -> String {
    switch progress {
    case nil: String(localized: installingTitle(version))
    case let value? where value < 1:
      String(localized: "正在下载 \(version) · \(Int((value * 100).rounded()))%")
    default: String(localized: "正在安装 \(version)…")
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

  /// 是不是同一个包（版本号 + 下载地址）：清单和 API 两条路查到的同一版，sha256、发布页可能一个有一个没有
  static func same(_ lhs: Release?, _ rhs: Release?) -> Bool {
    guard let lhs, let rhs else { return false }
    return lhs.version == rhs.version && lhs.archive == rhs.archive
  }

  /// 该不该提示这一版：跳过的那个版本不提（更新的版本出来照常提）
  static func nudge(_ available: Release?, skipped: String?) -> Release? {
    available?.version == skipped ? nil : available
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
      throw UpdateError("\(apiFailure(reply.status))")
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
      ? String(localized: "GitHub 限流了（这个网络查得太频繁），稍后再试或到发布页下载")
      : String(localized: "GitHub 返回 \(status)")
  }

  /// 更新清单（build-dmg.sh 生成）→ 那一版。认 version（只有数字和点）、url 和 page（https）、sha256（64 位十六进制），
  /// 缺一样、不对就 nil（退回 API）；别的键不管（size 现在没用上）。**格式发布后别改**（已装的老版本会读 latest 上的它）：
  /// 只加新键；要改已有键的意思就换一个文件名，旧名字的照发
  static func release(fromManifest data: Data, suffix: String = archiveSuffix) -> Release? {
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
      manifest.url.lastPathComponent.hasSuffix(suffix),
      sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil
    else { return nil }
    return Release(
      version: manifest.version, archive: manifest.url, page: manifest.page, sha256: sha256)
  }

  /// GitHub release 列表的 JSON → 版本号最大的那个 mac 版（版本、更新包、发布页）。只认 macos-v* 的 tag、带 https 的
  /// 这台架构的更新包（suffix）的；草稿、预发布跳过（E13：windows-v* 可能是 latest、也可能排在最前）。一个都没有时 nil
  static func release(from data: Data, suffix: String = archiveSuffix) throws -> Release? {
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
        let asset = payload.assets.first(where: { $0.name.hasSuffix(suffix) }),
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
    if let obstacle = obstacle(target) { throw UpdateError("\(obstacle.reason)") }
  }

  /// target 原地换不了的原因（E10；查到新版本时、装之前都看）：DMG（/Volumes 下的只读卷）、App Translocation 的临时位置
  /// （同 LaunchAtLogin.isInstalled 的判断，另看卷是不是只读）、所在文件夹写不进去。nil = 能换
  static func obstacle(_ target: URL) -> Obstacle? {
    let folderURL = target.deletingLastPathComponent()
    let folder = folderURL.path
    let readOnly = (try? folderURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
      .volumeIsReadOnly
    if folder.contains("/AppTranslocation/") || readOnly == true { return .notInstalled }
    return FileManager.default.isWritableFile(atPath: folder) ? nil : .noPermission
  }

  /// 下好的更新包（zip，这里用完就删）：解到 target 所在卷的临时目录、校验、原子地换掉 target。
  /// response：下载给的回复（看状态码）；nil = 后台下载时已经看过是 200（X11）
  static func replace(
    _ target: URL, with release: Release, zip: URL, response: URLResponse?
  ) async throws {
    defer { try? FileManager.default.removeItem(at: zip) }
    if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
      throw UpdateError("下载失败（\(status)）", kind: .network)
    }
    // 清单里给了校验值（#12）：下得不全、被换过的包在这里就拦下，不等解包
    if let sha256 = release.sha256, await FileHash.digest(of: zip, kind: .sha256) != sha256 {
      throw UpdateError("更新包下载得不完整（校验值对不上），请重试", kind: .network)
    }
    let staging = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    // 不要包里带的 ACL、扩展属性（签名在包内，用不着；也挡掉带进来的隔离标记）
    try await run(
      "/usr/bin/ditto", ["-x", "-k", "--noacl", "--noextattr", zip.path, staging.path],
      failure: "更新包解不开", kind: .unpack)
    guard
      let app = try FileManager.default.contentsOfDirectory(
        at: staging, includingPropertiesForKeys: nil
      ).first(where: { $0.pathExtension == "app" }),
      isGenuine(app, version: release.version)
    else { throw UpdateError("更新包不对（App 或版本号对不上）") }
    // 名字对了也再看一眼里面的可执行文件：传错了包（Intel 上拿到只有 arm64 的），换上去就打不开了
    guard
      Bundle(url: app)?.executableArchitectures?.contains(NSNumber(value: architecture)) == true
    else { throw UpdateError("更新包不支持这台 Mac 的芯片，请到发布页下载") }
    // 文件权限不在签名里：去掉组 / 其他人的写权限和 setuid / setgid / sticky，免得装进「应用程序」后别的账户能改它
    try await run("/bin/chmod", ["-R", "go-w,a-st", app.path], failure: "更新包的文件权限处理失败")
    try await run(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, app.path],
      failure: "更新包的签名校验没通过")
    // 换上之后对装好的那一份再核一遍：暂存目录、后台下好的包本机别的进程也写得进去（X11 评审：包放上几天、退出时才装），
    // 验签之后、替换之前被换掉的在这里拦下；不过就换回原来的那份
    let backupURL = backupURL(of: target)
    let installed =
      try FileManager.default.replaceItemAt(
        target, withItemAt: app, backupItemName: backupURL.lastPathComponent,
        options: .withoutDeletingBackupItem)
      ?? target
    do {
      guard isGenuine(installed, version: release.version) else {
        throw UpdateError("更新包不对（App 或版本号对不上）")
      }
      try await run(
        "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, installed.path],
        failure: "更新包的签名校验没通过")
    } catch {
      if (try? FileManager.default.replaceItemAt(installed, withItemAt: backupURL)) == nil {
        Log.storage.error("更新没核过、也没换回原来的那份")
      }
      throw error
    }
    try? FileManager.default.removeItem(at: backupURL)
  }

  /// 换上新版时原来那份暂放的地方（同一个文件夹里的隐藏项，核过就删）
  static func backupURL(of target: URL) -> URL {
    target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).before-update")
  }

  /// 是不是我们的那个 App、是不是这一版：不是符号链接（链接那头的东西验签时和换上之后可以不一样）、bundle id、版本号
  private static func isGenuine(_ app: URL, version: String) -> Bool {
    guard (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
      let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
    else { return false }
    return info["CFBundleIdentifier"] as? String == bundleID
      && info["CFBundleShortVersionString"] as? String == version
  }

  /// 下载到临时文件（调用方删），一路报下了多少（0…1，见 DownloadWatcher）
  static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    -> (URL, URLResponse)
  {
    try await URLSession.shared.download(from: url, delegate: DownloadWatcher(report: progress))
  }

  /// 等本进程退出后重新打开：先开的话新实例会看到还没退的旧实例，按单实例规则自己退出（设置 › 通用换语言后也用它）
  static func relaunch(_ app: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [
      "-c",
      "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
      app.path,
    ]
    try process.run()
  }

  /// 跑系统命令（ditto / codesign）：在进程外，等它结束，非 0 退出就抛 failure。最多等 2 分钟（退出时装更新也走这里，
  /// 不能让退出一直卡着；到点停掉 = 非 0，当没通过）
  private static func run(
    _ tool: String, _ arguments: [String], failure: LocalizedStringResource,
    kind: UpdateError.Kind = .other
  ) async throws {
    guard try await Subprocess.run(tool, arguments, timeout: .seconds(120)).status == 0 else {
      throw UpdateError(failure, kind: kind)
    }
  }
}

/// 看着一次下载下了多少。async 的 download(from:) 不报进度：这一个任务的委托收不到 didWriteData（实测 0 次），只有
/// didCreateTask 把任务交过来，之后看它的 progress（一变就按任务上的字节数算，progress 自己的比例开头有 5% 的虚头）。
/// 服务器没给大小就不报。回调都在会话自己的线程上
private final class DownloadWatcher: NSObject, URLSessionTaskDelegate {
  private let report: @Sendable (Double) -> Void
  /// 只在 didCreateTask 里写一次，之后只是拿着（放掉就不再观察）。委托的回调在会话的线程上，所以放在 Mutex 里
  private let observation = Mutex<NSKeyValueObservation?>(nil)

  init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

  nonisolated func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    observation.withLock {
      $0 = task.progress.observe(\.fractionCompleted) { [report] _, _ in
        let expected = task.countOfBytesExpectedToReceive
        if expected > 0 { report(Double(task.countOfBytesReceived) / Double(expected)) }
      }
    }
  }
}

struct UpdateError: LocalizedError {
  /// 哪一类（E10，Updater.failureKind 按它分出口）：network 给「重试」；diskFull 单独说；unpack 是解不开包（磁盘快满了算磁盘满，
  /// 不然同 other）；other 重试也不会好，给发布页
  enum Kind: Equatable, Sendable {
    case network, diskFull, unpack, other
  }

  let errorDescription: String?
  let kind: Kind
  /// 能本地化的字（调用处的字面量会被抽进目录）
  init(_ message: LocalizedStringResource, kind: Kind = .other) {
    errorDescription = String(localized: message)
    self.kind = kind
  }
}
