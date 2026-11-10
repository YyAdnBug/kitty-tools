// 在哪些 App 里停用快捷键（2026-11-10 拍板「全部按推荐」，设置 › 快捷键「在这些 App 里停用」+ 菜单栏一项）。
// 全局热键（Carbon）会把键吞掉、前台 App 收不到，所以名单里的 App 在前台时 HotKeyCenter 干脆不注册对应的键，按键原样到那个 App；
// 离开时再注册回来（HotKeyCenter.frontChanged）。这里只放名单的存法和「此刻停哪些」的纯函数（单测喂字符串，不读偏好）。
// 偏好里是一组字符串（Prefs.hotKeyBlockedApps，注册了默认值 []：跟着设置导出、每日备份、全局同步走，同剪贴板「不记录」的 App）：
// 一条一个 App，「bundle id」= 全部快捷键（含启动器命令的快捷键和连按两下），「bundle id|动作,动作」= 只停这几个全局动作；
// 不认识的动作名（更新版本加的）原样留着、交回去。bundle id 精确匹配；同一个 App 出现两次只认第一条。
// ponytail: 整张名单在同步里算一项，两台同时各加一个 App 会丢一个（同剪贴板那张）；要细就改成一个 App 一条记录

import Foundation

struct HotKeyBlock: Equatable {
  var bundleID: String
  /// nil = 全部快捷键；否则只停这几个动作（HotKeyAction 的 rawValue，按 allCases 的顺序存）
  var actions: [String]?

  /// 此刻对前台 App 生效的停用规则
  enum Rule: Equatable {
    /// 全部：各动作、启动器命令、连按两下都不注册
    case all
    /// 只停这几个动作（不会是空的：空的当没停）
    case only(Set<HotKeyAction>)

    func blocks(_ action: HotKeyAction) -> Bool {
      switch self {
      case .all: true
      case .only(let actions): actions.contains(action)
      }
    }

    /// 启动器命令的快捷键只跟着「全部」
    var blocksCommands: Bool { self == .all }
  }

  init(bundleID: String, actions: [String]? = nil) {
    self.bundleID = bundleID
    self.actions = actions
  }

  /// 偏好里的一条；空的、id 里带空白的不认
  init?(entry: String) {
    let parts = entry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    let id = String(parts[0])
    guard !id.isEmpty, id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
    bundleID = id
    actions = parts.count == 2 ? parts[1].split(separator: ",").map(String.init) : nil
  }

  var entry: String {
    actions.map { bundleID + "|" + $0.joined(separator: ",") } ?? bundleID
  }

  /// 认得的那几个动作（只停几个时）
  var knownActions: Set<HotKeyAction> {
    Set((actions ?? []).compactMap(HotKeyAction.init(rawValue:)))
  }

  /// 这个 App 停不停这个动作（设置页里那一行的勾）
  func blocks(_ action: HotKeyAction) -> Bool {
    actions == nil || knownActions.contains(action)
  }

  /// 勾上 / 取消一个动作：从「全部」取消一个 = 只停 shown 里除它以外的那些；不认识的动作名留着
  func setting(_ action: HotKeyAction, blocked: Bool, shown: [HotKeyAction]) -> HotKeyBlock {
    var known = actions == nil ? Set(shown) : knownActions
    if blocked { known.insert(action) } else { known.remove(action) }
    let unknown = (actions ?? []).filter { HotKeyAction(rawValue: $0) == nil }
    let ordered = HotKeyAction.allCases.filter(known.contains).map(\.rawValue)
    return HotKeyBlock(bundleID: bundleID, actions: ordered + unknown)
  }

  /// 整张名单（读不出来的条目扔掉、同一个 App 只留第一条）
  static func list(_ entries: [String]) -> [HotKeyBlock] {
    var seen = Set<String>()
    return entries.compactMap(HotKeyBlock.init(entry:)).filter { seen.insert($0.bundleID).inserted }
  }

  /// 前台是这个 App 时停哪些；nil = 不停
  static func rule(for bundleID: String?, in entries: [String]) -> Rule? {
    guard let bundleID, let block = list(entries).first(where: { $0.bundleID == bundleID })
    else { return nil }
    guard block.actions != nil else { return .all }
    let known = block.knownActions
    return known.isEmpty ? nil : .only(known)
  }

  // MARK: 偏好

  static var stored: [String] {
    UserDefaults.standard.stringArray(forKey: Prefs.hotKeyBlockedApps) ?? []
  }

  /// 改名单：从偏好现读再改、写回（同剪贴板「不记录」的 App，E19：页面上那份可能还没跟上同步刚落下的）
  static func change(_ edit: (inout [HotKeyBlock]) -> Void) {
    var blocks = list(stored)
    edit(&blocks)
    UserDefaults.standard.set(blocks.map(\.entry), forKey: Prefs.hotKeyBlockedApps)
  }
}
