// 启动器系统命令的执行（SystemCommands 是目录）：只在启动器收起之后由 AppDelegate 调；单测从不调
// （LauncherModel.perform 默认什么都不做）。看不见结果的和所有错误走刘海岛（mac-whisker S2）。
// - 锁屏：系统私有函数 `SACLockScreenImmediate`（用户 2026-09-27 拍板；Raycast、Hammerspoon 同做法，
//   15.7 / 26 上都还在），找不到就模拟 ⌃⌘Q（Alfred 做法，要辅助功能）。
// - 睡眠 / 关闭显示器：`pmset sleepnow` / `displaysleepnow`；屏幕保护程序：打开 ScreenSaverEngine。
// - 清倒废纸篓：让访达清倒；退出登录 / 重新启动 / 关机：给 loginwindow 发 Apple Event（弹 macOS 自己的确认框）；
//   音量：AppleScript 的 set volume（不控制别的 App，不要授权）。都用 osascript 跑在进程外：第一次控制访达 /
//   loginwindow 时系统弹「允许控制」框，要等用户点，主线程不能跟着等。需要 apple-events entitlement。
// - App：NSRunningApplication 的 terminate / forceTerminate / hide；推出：FileManager.unmountVolume。
// - kill / port 列的后台进程（体检 D12）：kill(2) 发 SIGTERM（↩）/ SIGKILL（⌘↩，启动器里已上膛确认过）；
//   port 列的程序坞 App 走上一条的 terminate / forceTerminate。

import AppKit
import Carbon.HIToolbox

enum SystemControl {
  enum Action: Equatable {
    case command(SystemCommand)
    // 下面四个的对象是 App 的路径（bundleURL）或宗卷的路径
    case quit(String)
    case forceQuit(String)
    case hide(String)
    case eject(String)
    /// 后台进程：SIGTERM，force 时 SIGKILL
    case signal(pid: Int32, name: String, force: Bool)
  }

  static func perform(_ action: Action, island: Island?) {
    switch action {
    case .command(let command): run(command, island: island)
    case .quit(let path): control(path, island: island, failure: "没能退出") { $0.terminate() }
    case .forceQuit(let path):
      control(path, island: island, failure: "没能强制退出") { $0.forceTerminate() }
    case .hide(let path): control(path, island: island, failure: "没能隐藏") { $0.hide() }
    case .eject(let path): Task { await eject([URL(filePath: path)], island: island) }
    case .signal(let pid, let name, let force):
      signal(pid, name: name, force: force, island: island)
    }
  }

  // MARK: 进程

  /// 结果和错误都走岛：结束了 / 已经不在了 / 权限不够（别的用户的，ps 只列自己的，这里防 PID 被重用）。
  /// ponytail: 列出来到按下之间 PID 被别的进程重用时会结束错的那个（要几秒内正好轮到同一个号，概率极低）；
  /// 真要防就在发信号前用 proc_pidpath 比一下可执行文件
  private static func signal(_ pid: Int32, name: String, force: Bool, island: Island?) {
    guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else {
      switch errno {
      case ESRCH: island?.show("「\(name)」已经不在运行了", tone: .info)
      case EPERM: island?.show("没能结束「\(name)」", detail: "它属于别的用户", tone: .error)
      default:
        island?.show("没能结束「\(name)」", detail: String(cString: strerror(errno)), tone: .error)
      }
      return
    }
    island?.show(
      "已\(force ? "强制" : "")结束 \(name)（PID \(pid)）", symbol: force ? "xmark.octagon" : "stop.circle"
    )
  }

  private static func run(_ command: SystemCommand, island: Island?) {
    switch command {
    case .lock: lock(island: island)
    case .sleep:
      Task { await tool("/usr/bin/pmset", ["sleepnow"], failure: "没能让电脑睡眠", island: island) }
    case .sleepdisplays:
      Task {
        await tool("/usr/bin/pmset", ["displaysleepnow"], failure: "没能关闭显示器", island: island)
      }
    case .screensaver:
      let engine = URL(filePath: "/System/Library/CoreServices/ScreenSaverEngine.app")
      if !NSWorkspace.shared.open(engine) { island?.show("没能启动屏幕保护程序", tone: .error) }
    case .trash:
      let trash =
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? URL(filePath: NSHomeDirectory() + "/.Trash")
      if !NSWorkspace.shared.open(trash) { island?.show("没能打开废纸篓", tone: .error) }
    case .emptytrash: Task { await emptyTrash(island: island) }
    case .logout: Task { await loginWindow("logo", failure: "没能退出登录", island: island) }
    case .restart: Task { await loginWindow("rrst", failure: "没能重新启动", island: island) }
    case .shutdown: Task { await loginWindow("rsdn", failure: "没能关机", island: island) }
    case .quitall: quitAll(island: island)
    case .ejectall:
      let volumes = SystemCommands.volumes()
      guard !volumes.isEmpty else {
        island?.show("没有可推出的磁盘", tone: .info, symbol: "eject")
        return
      }
      Task { await eject(volumes, island: island) }
    case .volup, .voldown, .mute: Task { await volume(command, island: island) }
    }
  }

  // MARK: 锁屏

  private static func lock(island: Island?) {
    typealias LockScreen = @convention(c) () -> Int32
    if let login = dlopen(
      "/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY),
      let symbol = dlsym(login, "SACLockScreenImmediate")
    {
      _ = unsafeBitCast(symbol, to: LockScreen.self)()
      return
    }
    // 退路：系统的锁屏快捷键 ⌃⌘Q。远程桌面 / 虚拟机在前台时会被它们收走，改过这个快捷键也会失效
    guard Permissions.isAccessibilityTrusted else {
      island?.show("没能锁定屏幕", detail: "授权辅助功能后再试", tone: .warning)
      return Permissions.requestAccessibility()
    }
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: keyDown)
      event?.flags = [.maskCommand, .maskControl]
      event?.post(tap: .cgSessionEventTap)
    }
  }

  // MARK: App

  /// 按路径找正在运行的 App 再做（退出 / 强制退出 / 隐藏只是发出请求：有没存的文稿时 App 会先问）
  private static func control(
    _ path: String, island: Island?, failure: String, _ act: (NSRunningApplication) -> Bool
  ) {
    let current = ProcessInfo.processInfo.processIdentifier
    guard
      let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleURL?.path == path && $0.processIdentifier != current
      })
    else {
      let name = URL(filePath: path).deletingPathExtension().lastPathComponent  // 不读 App 包
      island?.show("「\(name)」已经不在运行了", tone: .info)
      return
    }
    if !act(app) { island?.show(failure + "「\(app.localizedName ?? "")」", tone: .error) }
  }

  private static func quitAll(island: Island?) {
    let apps = SystemCommands.runningApps(for: .quit)
    guard !apps.isEmpty else {
      island?.show("没有要退出的 App", tone: .info, symbol: "xmark.circle")
      return
    }
    for app in apps { app.terminate() }
    island?.show(
      "正在退出 \(apps.count) 个 App", detail: "有没存的内容时它们会先问你", tone: .info,
      symbol: "xmark.circle")
  }

  // MARK: 推出

  private static func eject(_ volumes: [URL], island: Island?) async {
    var ejected: [String] = []
    var failure: (name: String, blocker: String?)?
    for url in volumes {
      let name = SystemCommands.volumeName(url)  // 推出之后就读不到了
      do {
        try await FileManager.default.unmountVolume(
          at: url, options: [.allPartitionsAndEjectDisk, .withoutUI])
        ejected.append(name)
      } catch {
        // 同一块盘的别的分区已经跟着前一个一起推出了：不算失败
        if !FileManager.default.fileExists(atPath: url.path) {
          ejected.append(name)
          continue
        }
        let pid =
          ((error as NSError).userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey]
          as? NSNumber)?.int32Value
        failure =
          failure
          ?? (name, pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName })
      }
    }
    if let failure {
      island?.show(
        "没能推出「\(failure.name)」",
        detail: failure.blocker.map { "「\($0)」正在使用它" } ?? "有 App 正在使用它", tone: .error)
    } else if ejected.count == 1 {
      island?.show("已推出「\(ejected[0])」", symbol: "eject.fill")
    } else {
      island?.show("已推出 \(ejected.count) 个磁盘", symbol: "eject.fill")
    }
  }

  // MARK: 系统工具 / AppleScript（进程外）

  private static func tool(_ path: String, _ arguments: [String], failure: String, island: Island?)
    async
  {
    if (try? await Subprocess.run(path, arguments))?.status != 0 {
      island?.show(failure, tone: .error)
    }
  }

  /// 跑一段 AppleScript，成功返回输出。没被允许控制目标 App（-1743 / -1744）时刘海岛说明并打开系统设置的
  /// 「自动化」，用户在系统确认框里点了取消（-128）不算错
  private static func script(_ source: String, target: String, failure: String, island: Island?)
    async -> String?
  {
    guard
      let result = try? await Subprocess.run("/usr/bin/osascript", ["-e", source], captures: true)
    else {
      island?.show(failure, tone: .error)
      return nil
    }
    guard result.status != 0 else {
      return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if result.error.contains("-1743") || result.error.contains("-1744") {
      island?.show(
        "没有权限控制「\(target)」", detail: "在 系统设置 › 隐私与安全性 › 自动化 里打开", tone: .warning)
      Permissions.Kind.automation.openSettings()
    } else if !result.error.contains("-128") {
      island?.show(failure, detail: Island.excerpt(result.error), tone: .error)
    }
    return nil
  }

  /// 访达清倒（不弹访达自己的确认，启动器已经确认过）；先数一下，空的就不清、只说一声
  private static func emptyTrash(island: Island?) async {
    let source = """
      with timeout of 600 seconds
        tell application "Finder"
          set n to count items of trash
          if n > 0 then empty trash
          return n
        end tell
      end timeout
      """
    guard let output = await script(source, target: "访达", failure: "没能清倒废纸篓", island: island)
    else { return }
    let count = Int(output) ?? 0
    if count == 0 {
      island?.show("废纸篓是空的", tone: .info, symbol: "trash")
    } else {
      island?.show("已清倒废纸篓", detail: "\(count) 个项目", symbol: "trash")
    }
  }

  /// kAELogOut 'logo' / kAEShowRestartDialog 'rrst' / kAEShowShutdownDialog 'rsdn'：弹系统自己的确认框
  /// （60 秒倒计时、「重新打开窗口」），不等它的回复
  private static func loginWindow(_ event: String, failure: String, island: Island?) async {
    _ = await script(
      "ignoring application responses\ntell application \"loginwindow\" to «event aevt\(event)»\nend ignoring",
      target: "loginwindow", failure: failure, island: island)
  }

  /// 按 1/16 一档调（同键盘音量键）；调高顺便取消静音。输出设备没有音量（HDMI 这类）时 output volume 是 missing value
  private static func volume(_ command: SystemCommand, island: Island?) async {
    let change =
      switch command {
      case .volup:
        """
        set n to (round (v / 6.25)) + 1
        if n > 16 then set n to 16
        set volume without output muted
        set volume output volume (round (n * 6.25))
        """
      case .voldown:
        """
        set n to (round (v / 6.25)) - 1
        if n < 0 then set n to 0
        set volume output volume (round (n * 6.25))
        """
      default: "set volume output muted (not (output muted of s))"
      }
    let source = """
      set s to get volume settings
      set v to output volume of s
      if v is missing value then return "none"
      \(change)
      set s to get volume settings
      return ((output volume of s) as text) & "," & ((output muted of s) as text)
      """
    guard let output = await script(source, target: "音量", failure: "没能调音量", island: island)
    else { return }
    let parts = output.split(separator: ",")
    guard parts.count == 2, let level = Int(parts[0]) else {
      island?.show("这个输出设备不能调音量", tone: .warning, symbol: "speaker.slash")
      return
    }
    if parts[1] == "true" {
      island?.show("已静音", tone: .info, symbol: "speaker.slash.fill")
    } else {
      let symbol =
        level == 0
        ? "speaker.fill"
        : level < 34
          ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
      island?.show("音量 \(level)%", tone: .info, symbol: symbol)
    }
  }
}
