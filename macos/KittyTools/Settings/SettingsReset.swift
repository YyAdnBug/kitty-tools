// 子页和「高级…」表单底部的「恢复默认」（设置改版 S9，2026-11-18，规格 SPEC §1.5）：把这一处登记的偏好键（SettingsIndex）
// 里改过的那几个删掉、回到注册的默认值，刘海岛上给「撤销」（原样写回）。只动持久域里真有的键：没改过的不碰，免得同步把它
// 当成刚改的发出去（同步那边「改回默认 = 删掉这一条」，别的 Mac 也回到默认，Storage/SettingsSync.swift 文件头）。
// 不管的：没注册默认值的（这台电脑自己的：面板大小、文件夹、授权跟着走的几个），功能开关，和改回默认可能当场删掉历史的
// 上限（保留天数、图片占用、截图历史的保留和占用、翻译历史条数：它们改小时自己会先问，撤销也回不来）。

import SwiftUI

enum SettingsReset {
  /// 恢复默认不碰的上限：改回默认可能当场删掉历史
  static let limits: Set<String> = [
    Prefs.clipboardRetentionDays, Prefs.clipboardImageBudgetMB, Prefs.shotHistoryDays,
    Prefs.shotHistoryMegabytes, Prefs.translateHistoryLimit,
  ]

  /// 注册的默认值（一次运行里不变；Prefs.defaults 每次现算一份）
  static let registered = Prefs.defaults

  /// 这几行的「恢复默认」管哪些键：注册了默认值的、不是功能开关、不是上限（按登记的先后、去重）
  static func keys(of items: [SettingsItem]) -> [String] {
    let features = Set(Feature.allCases.map(\.prefsKey))
    var seen = Set<String>()
    return items.flatMap(\.info.keys).filter {
      registered[$0] != nil && !features.contains($0) && !limits.contains($0)
        && seen.insert($0).inserted
    }
  }

  /// 这些键里有没有和注册的默认值不一样的（按钮亮不亮）：逐键读，不整份拷偏好域（每改一次偏好都要查一遍）
  static func differs(_ keys: [String], in defaults: UserDefaults) -> Bool {
    keys.contains { key in
      guard let value = defaults.object(forKey: key) else { return false }
      return !(value as AnyObject).isEqual(registered[key])
    }
  }

  /// 这些键里改过的（持久域里有的）此刻的值
  static func changed(
    _ keys: [String], in defaults: UserDefaults, domain: String?
  ) -> [String: Any] {
    let stored = domain.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    return stored.filter { keys.contains($0.key) }
  }

  /// 恢复默认：删掉改过的那几个键，交回它们原来的值（撤销用）
  static func reset(
    _ keys: [String], in defaults: UserDefaults, domain: String?
  ) -> [String: Any] {
    let before = changed(keys, in: defaults, domain: domain)
    for key in before.keys { defaults.removeObject(forKey: key) }
    return before
  }

  /// 撤销：原样写回
  static func restore(_ values: [String: Any], in defaults: UserDefaults) {
    for (key, value) in values { defaults.set(value, forKey: key) }
  }
}

/// 「恢复默认」按钮：一个都没改过时置灰；点了不先问，刘海岛上给「撤销」
struct ResetDefaultsButton: View {
  let keys: [String]
  /// 岛上那一句里说的是哪里（「截图 · 高级」「通用 › 权限」）
  let place: String
  @Environment(Island.self) private var island: Island?
  @State private var canReset = false

  var body: some View {
    // 显式 key：英文是复数（一组设置），「快速保存到」那一行的「恢复默认」是单数
    Button(LocalizedStringResource("settings.restoreDefaults", defaultValue: "恢复默认")) {
      // 没有岛就给不了「撤销」：不删
      guard let island else { return }
      let domain = Bundle.main.bundleIdentifier
      let before = SettingsReset.reset(keys, in: .standard, domain: domain)
      guard !before.isEmpty else { return }
      island.show(
        "已恢复默认", detail: "\(place)改回了 \(before.count) 项",
        symbol: "arrow.counterclockwise.circle.fill",
        actions: [.init("撤销") { SettingsReset.restore(before, in: .standard) }])
    }
    .disabled(!canReset)
    .onAppear(perform: recheck)
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      recheck()
    }
  }

  private func recheck() {
    let now = SettingsReset.differs(keys, in: .standard)
    if now != canReset { canReset = now }
  }
}
