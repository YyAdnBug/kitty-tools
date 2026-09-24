// 启动器状态与操作：查询 → 结果（App 目录 + 内置动作 + 用过的网址 / 文件），空查询显示「最近使用」。
// 键盘：↑↓ 循环、↩ 执行、⌘↩ 在访达中显示、⌘C 复制路径 / 网址、⌘1–9 执行第 N 项、Esc 先清空再关闭；
// 单击选中、双击执行（和剪贴板面板一致）。执行成功才收起并记使用（修旧版先收起、失败提示看不见，§11 #33）。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class LauncherModel {
  var query = "" { didSet { search() } }
  private(set) var results: [LauncherItem] = []
  var selection = 0
  /// 执行失败的提示（面板不收起）
  private(set) var error: String?

  @ObservationIgnored let usage: LauncherUsage
  @ObservationIgnored private var apps: [LauncherItem] = []
  @ObservationIgnored private var appsScannedAt: Date?
  /// 单测 / 截图自检传入固定的 App 列表，不扫本机
  @ObservationIgnored private let fixedApps: Bool
  // 以下由 AppDelegate 接上
  @ObservationIgnored var hidePanel: () -> Void = {}
  @ObservationIgnored var runAction: (String) -> Void = { _ in }
  /// 面板按内容伸缩高度（顶边不动）
  @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }

  static let recentLimit = 8
  static let rescanInterval: TimeInterval = 300

  init(usage: LauncherUsage, apps: [LauncherItem]? = nil) {
    self.usage = usage
    fixedApps = apps != nil
    if let apps {
      self.apps = apps
      appsScannedAt = .now
    }
  }

  var isShowingRecent: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

  /// 启动时和第一次呼出前扫 App 目录
  func rescanApps() {
    guard !fixedApps else { return }
    apps = AppCatalog.scan()
    appsScannedAt = .now
  }

  func prepareForShow() {
    if appsScannedAt == nil { rescanApps() }
    search()
  }

  /// 收起后清空查询；App 目录超过 5 分钟就趁没人看时重扫。
  /// ponytail: 刚装的 App 最迟在下一次收起面板后出现；嫌慢再改成监听应用程序目录
  func didHide() {
    query = ""
    error = nil
    if let scannedAt = appsScannedAt, Date.now.timeIntervalSince(scannedAt) > Self.rescanInterval {
      rescanApps()
    }
  }

  private func search() {
    error = nil
    selection = 0
    if isShowingRecent {
      results = recent()
    } else {
      let query = query
      results = LauncherMatch.rank(apps + LauncherItem.actions + usedLocations, query: query) {
        usage.boost(for: $0, query: query)
      }
    }
  }

  /// 用过的网址 / 文件：不在任何目录里，靠使用记录找回来（书签接上后同一网址去重）
  private var usedLocations: [LauncherItem] {
    usage.entries.values
      .filter { $0.query.isEmpty && ($0.kind == .url || $0.kind == .path) }
      .map(Self.item(for:))
  }

  static func item(for entry: LauncherUsage.Entry) -> LauncherItem {
    LauncherItem(
      kind: entry.kind, target: entry.target, title: entry.title,
      subtitle: entry.kind == .url
        ? entry.target : (entry.target as NSString).abbreviatingWithTildeInPath,
      names: [entry.title, entry.target].map(LauncherMatch.fold))
  }

  /// 按全局使用分取前几条，只留还能还原的（App 还在、文件还在）
  private func recent() -> [LauncherItem] {
    var items: [LauncherItem] = []
    // 全部按分排好再往下找：前面几条失效（App 已卸载、文件已删）时后面的补上
    for entry in usage.top(Int.max) where items.count < Self.recentLimit {
      switch entry.kind {
      case .app:
        if let app = apps.first(where: { $0.target == entry.target }) {
          items.append(app)
        } else if FileManager.default.fileExists(atPath: entry.target) {
          items.append(AppCatalog.item(path: entry.target))  // 应用程序目录以外的 App
        }
      case .action:
        if let action = LauncherItem.actions.first(where: { $0.target == entry.target }) {
          items.append(action)
        }
      case .url:
        items.append(Self.item(for: entry))
      case .path:
        if FileManager.default.fileExists(atPath: entry.target) {
          items.append(Self.item(for: entry))
        }
      }
    }
    return items
  }

  // MARK: 执行

  func execute(_ item: LauncherItem) {
    switch item.kind {
    case .action:
      usage.record(item, query: query)
      hidePanel()
      runAction(item.target)
    case .app, .path:
      open(URL(filePath: item.target), item)
    case .url:
      guard let url = URL(string: item.target) else {
        error = "打不开「\(item.title)」"
        return
      }
      open(url, item)
    }
  }

  private func open(_ url: URL, _ item: LauncherItem) {
    guard NSWorkspace.shared.open(url) else {
      error = "打不开「\(item.title)」"
      return
    }
    usage.record(item, query: query)
    hidePanel()
  }

  func click(_ item: LauncherItem) {
    if NSApp.currentEvent?.clickCount == 2 {
      execute(item)
    } else if let index = results.firstIndex(of: item) {
      selection = index
    }
  }

  private var selectedItem: LauncherItem? {
    results.indices.contains(selection) ? results[selection] : nil
  }

  // MARK: 键盘

  func handleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)): move(by: -1)
    case #selector(NSResponder.moveDown(_:)): move(by: 1)
    case #selector(NSResponder.insertNewline(_:)):
      if let selectedItem { execute(selectedItem) }
    case #selector(NSResponder.cancelOperation(_:)):
      guard !query.isEmpty else { return false }  // 没有查询：交给窗口关闭
      query = ""
    default: return false
    }
    return true
  }

  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
      return false
    }
    let fieldHasSelection =
      ((event.window?.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
    switch Int(event.keyCode) {
    case kVK_Return:
      guard let item = selectedItem, item.kind == .app || item.kind == .path else { return true }
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
      hidePanel()
    case kVK_ANSI_C where !fieldHasSelection:
      guard let item = selectedItem, item.kind != .action else { return false }
      Paster.write(string: item.target)
      hidePanel()
    case kVK_ANSI_Comma:
      hidePanel()
      runAction("settings")
    default:
      guard let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      if digit < results.count { execute(results[digit]) }
    }
    return true
  }

  private func move(by offset: Int) {
    guard !results.isEmpty else { return }
    selection = (selection + offset + results.count) % results.count
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]
}
