// 应用内更新（PLAN D8，2026-09-27 改为做）：读本仓库（github.com/YyAdnBug/kitty-tools，不碰 Tauri 版的仓库）的
// latest release（tag macos-v*）。有更新的版本：刘海岛提示一次（每个版本一次；只停 2 秒、不接点击，错过就没了），
// 所以另有常驻到更新为止的入口（2026-10-06，对标 Alfred 窗口底部的小提示 / Raycast 根搜索顶上那一行 / Sparkle 给后台 App 的
// 「温和提醒」）：菜单栏图标右上角的小圆点（StatusItem.updateVersion）+ 菜单顶上「更新到 x…」、剪贴板面板和启动器底栏的
// 「更新到 x」（UpdateBarHint）、关于页的「更新并重新打开」。更新 = 下载 release 里的 *_arm64.zip → ditto 解到 App 所在卷的临时目录 →
// 校验 bundle id、版本号和签名（Apple 签发、本团队 HTX9F4KG39 的证书）→ 原子地换掉正在运行的 .app →
// 等本进程退出后重新打开。不用 Sparkle（禁止第三方依赖）；解包、验签交给系统的 ditto / codesign，在进程外跑。
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
  }

  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(Release)
    case installing(Release)
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
  /// 此刻不能更新的原因（录屏中「录制结束后再更新」，AppDelegate 写）：关于页的「更新并重新打开」置灰、旁边写它；
  /// 菜单里点了「更新到 x…」用刘海说
  var blocker: String?
  /// 刘海岛（AppDelegate 给，单测里是 nil）
  @ObservationIgnored var island: Island?
  @ObservationIgnored private var schedule: Task<Void, Never>?
  /// 检查进行中时菜单里又点了「检查更新…」：这次的结果也用刘海说
  @ObservationIgnored private var menuWaiting = false

  static let bundleID = "com.yy.kitty-tools.native"
  static let releasesPage = URL(string: "https://github.com/YyAdnBug/kitty-tools/releases")!
  private static let latest = URL(
    string: "https://api.github.com/repos/YyAdnBug/kitty-tools/releases/latest")!
  /// 新包必须满足的签名要求：同一个 bundle id、Apple 签发、本团队的证书（只认团队，换证书也能更新）
  static let requirement =
    "=identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"HTX9F4KG39\""

  init(state: State = .idle) {
    self.state = state
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
    default: break
    }
    guard isSupported else {
      state = .failed("开发版不自动更新")
      return true
    }
    let previous = state
    state = .checking
    do {
      var request = URLRequest(url: Self.latest)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      // 还没发过正式版时 latest 是 404
      guard status == 200 || status == 404 else { throw UpdateError("GitHub 返回 \(status)") }
      let toMenu = trigger == .menu || menuWaiting
      menuWaiting = false
      // 检查还在路上时点了「更新到 x」（入口在复查期间留着）：已经在装了，这次的结果不要
      guard case .checking = state else { return true }
      if status == 200, let release = try Self.release(from: data),
        Self.isNewer(release.version, than: AboutTab.version)
      {
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
            symbol: "arrow.down.circle.fill")
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
      if toMenu { island?.show("检查更新失败", detail: error.localizedDescription, tone: .error) }
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
    if trigger != .page { showInstalling(release) }
    do {
      let app = Bundle.main.bundleURL
      try await Self.replace(app, with: release)
      try Self.relaunch(app)
      NSApp.terminate(nil)
    } catch {
      state = .available(release)
      island?.show("更新失败", detail: error.localizedDescription, tone: .error)
    }
  }

  private func showInstalling(_ release: Release) {
    island?.show(
      "正在更新到 \(release.version)…", detail: "装好会自动重新打开", tone: .progress,
      symbol: "arrow.down.circle.fill")
  }

  // MARK: 纯逻辑（单测）

  /// 状态变了之后，已经发现的新版本还算不算：复查中、没查成时留着——不然菜单栏的角标、面板底栏的「更新到 x」每天复查
  /// 那一下都要闪（连不上 GitHub 时一闪就是到超时为止，半小时重试一次）；查到已是最新、开始安装才清
  static func available(_ known: Release?, after state: State) -> Release? {
    switch state {
    case .available(let release): release
    case .upToDate, .installing: nil
    case .idle, .checking, .failed: known
    }
  }

  /// GitHub「latest release」的 JSON → 版本、更新包、发布页。不是 macos-v* 的 tag、没有 https 的 *_arm64.zip 时 nil
  static func release(from data: Data) throws -> Release? {
    struct Payload: Decodable {
      struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
      }
      let tagName: String
      let htmlUrl: URL
      let assets: [Asset]
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let payload = try decoder.decode(Payload.self, from: data)
    let prefix = "macos-v"
    guard payload.tagName.hasPrefix(prefix),
      let asset = payload.assets.first(where: { $0.name.hasSuffix("_arm64.zip") }),
      asset.browserDownloadUrl.scheme == "https"
    else { return nil }
    return Release(
      version: String(payload.tagName.dropFirst(prefix.count)), archive: asset.browserDownloadUrl,
      page: payload.htmlUrl)
  }

  /// 按数字逐段比（0.1.10 比 0.1.9 新）
  static func isNewer(_ version: String, than current: String) -> Bool {
    version.compare(current, options: .numeric) == .orderedDescending
  }

  // MARK: 安装

  /// 下载更新包，解到 target 所在卷的临时目录，校验 bundle id、版本号和签名，再原子地换掉 target。
  /// 从 DMG 里、或没拖进「应用程序」就打开（系统把它挪到只读的随机路径）时换不了；标准（非管理员）账户写不了「应用程序」
  static func replace(_ target: URL, with release: Release) async throws {
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
    let (zip, response) = try await URLSession.shared.download(from: release.archive)
    defer { try? FileManager.default.removeItem(at: zip) }
    if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
      throw UpdateError("下载失败（\(status)）")
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

struct UpdateError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
