// 启动器命令的快捷键（第三轮 D1；第五轮体检 H1 从 LauncherModel.swift 拆出）：偏好里那段 JSON 的读写、按快捷键直接跑一条命令、脚本的别名。

import AppKit
import SwiftUI

extension LauncherModel {
  // MARK: 命令的快捷键（第三轮 D1）

  /// 最多这么多条（文件、同步来的再多也不读）
  static let maxCommandHotKeys = 200

  /// 偏好里那段 JSON → 编号 → 组合：读不出来的、过不了录制框规矩的（缺修饰键、通用编辑键）、连按两下的（命令的快捷键
  /// 只认组合）都丢掉。纯函数，配单测
  static func commandHotKeys(fromText text: String) -> [String: HotKey] {
    guard let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String: HotKey].self, from: data)
    else { return [:] }
    let usable = decoded.filter {
      !$0.key.isEmpty && $0.value.isUsable && $0.value.doubleTap == nil
    }
    return Dictionary(
      uniqueKeysWithValues: usable.sorted { $0.key < $1.key }.prefix(maxCommandHotKeys).map {
        ($0.key, $0.value)
      })
  }

  static func text(of hotKeys: [String: HotKey]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard !hotKeys.isEmpty, let data = try? encoder.encode(hotKeys) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// 一条命令给人看的名字（查重的提示里）：关键词命令、系统命令的名字，脚本的文件名
  static func commandTitle(_ id: String) -> String {
    if let builtIn = LauncherCommands.builtIns.first(where: { $0.id == id }) {
      return builtIn.title
    }
    let system = LauncherCommands.systemID("")
    if id.hasPrefix(system),
      let command = SystemCommand(rawValue: String(id.dropFirst(system.count)))
    {
      return command.title
    }
    return (id as NSString).lastPathComponent
  }

  /// 偏好里存着的（录制框、热键中心读）
  static func savedCommandHotKeys(_ defaults: UserDefaults = .standard) -> [String: HotKey] {
    commandHotKeys(fromText: defaults.string(forKey: Prefs.launcherCommandHotKeys) ?? "")
  }

  /// 改一条（nil = 清除）
  static func setCommandHotKey(
    _ hotKey: HotKey?, for id: String, _ defaults: UserDefaults = .standard
  ) {
    var all = savedCommandHotKeys(defaults)
    all[id] = hotKey
    defaults.set(text(of: all), forKey: Prefs.launcherCommandHotKeys)
  }

  /// 这条命令在这台 Mac 上有（关着的也算；录制框查重只算有的）
  func hasCommand(_ id: String) -> Bool {
    let system = LauncherCommands.systemID("")
    return LauncherCommands.builtIns.contains { $0.id == id }
      || (id.hasPrefix(system)
        && SystemCommand(rawValue: String(id.dropFirst(system.count))) != nil)
      || scripts().contains { LauncherCommands.scriptID($0) == id }
  }

  /// 这条命令此刻按快捷键能不能做事：开着；脚本在（这台 Mac 上有、脚本命令开着）；关键词命令的功能开着、还有别名（别名清空了
  /// 打不出它）；系统命令都在。热键中心只注册这些
  func canRunHotKey(_ id: String) -> Bool {
    let settings = commandSettings()
    guard settings.isOn(id) else { return false }
    if activeScripts.contains(where: { LauncherCommands.scriptID($0) == id }) { return true }
    if let builtIn = LauncherCommands.builtIns.first(where: { $0.id == id }) {
      let needs: Feature? =
        switch builtIn.keyword {
        case "cb": .clipboard
        case "fy": .translate
        case "remind": .reminders
        default: nil
        }
      return needs.map(features.contains) != false
        && settings.alias(id, default: builtIn.keyword) != nil
    }
    return id.hasPrefix(LauncherCommands.systemID(""))
      && SystemCommand(rawValue: String(id.dropFirst(LauncherCommands.systemID("").count))) != nil
  }

  /// 「命令和别名」里给一条命令设的快捷键按下了（第三轮 D1）。脚本：从网上下载没看过的、要参数的（含列表）、写了 confirm 的
  /// 打开启动器，做在启动器里按 ↩ 的那一步（先看全文 / 填好「关键词 空格」/ 选中并上膛）；全文输出的打开启动器看输出；
  /// 别的直接跑（粘贴的粘进眼前的 App）。关键词命令打开启动器、填好「关键词 空格」。系统命令要确认的同脚本，别的直接做。
  /// 使用只记总数，不记在当时搜索框里的字上
  func runHotKey(_ id: String) {
    guard canRunHotKey(id) else { return }
    let settings = commandSettings()
    if let script = activeScripts.first(where: { LauncherCommands.scriptID($0) == id }) {
      let item = LauncherItem.script(script, alias: scriptAlias(script))
      let unreviewed = script.isDownloaded && !approvedScripts.contains(script.path)
      if unreviewed || script.takesInput || script.confirmation != nil {
        return showAndExecute(item, word: scriptAlias(script) ?? script.title)
      }
      if script.mode == .full {
        guard showPanel() else { return }
        showsActions = false
        // 它自己还在跑：start 会在岛上说「还在运行」，不动眼前那一页（清空搜索框会停掉它）
        if runningScripts[script.path] == nil {
          // 别的全文脚本的那一页还在跑：交给岛（跑完说一声带「看输出」），不停掉它（第 4 批评审）
          if let current = output, current.isRunning {
            output = nil
            detach(current.script)
          }
          query = ""
        }
      }
      usage.record(item, query: "")
      runWithoutPanel { start(script, arguments: []) }
      return
    }
    if let builtIn = LauncherCommands.builtIns.first(where: { $0.id == id }),
      let alias = settings.alias(id, default: builtIn.keyword)
    {
      guard showPanel() else { return }
      showsActions = false
      query = alias + " "
      return
    }
    let keyword = String(id.dropFirst(LauncherCommands.systemID("").count))
    guard let command = SystemCommand(rawValue: keyword),
      let item = systemItems.first(where: { $0.target == keyword })
    else { return }
    if command.confirmation != nil {
      return showAndExecute(item, word: settings.alias(id, default: keyword) ?? command.title)
    }
    usage.record(item, query: "")
    runWithoutPanel {
      close()
      perform(.command(command))
    }
  }

  /// 打开启动器、打 word、选中那一行按一下 ↩（上膛、补关键词、先看全文都在 execute 里）
  private func showAndExecute(_ item: LauncherItem, word: String) {
    guard showPanel() else { return }
    // ⌘K 菜单开着时收起：不然上了膛的那句压在菜单下面，菜单第一项（执行）再按一下 ↩ 就跑了（第 4 批评审）
    showsActions = false
    query = word
    guard let index = results.firstIndex(where: { $0.id == item.id }) else { return }
    selection = index
    execute(results[index])
  }

  /// 启动器没开着时直接做：close() 会记「执行过」（下次收起清掉查询），没开着就不该记
  private func runWithoutPanel(_ work: () -> Void) {
    let wasShown = isShown
    work()
    if !wasShown { executed = false }
  }

  /// 一条脚本此刻的别名：「命令」表里改过的用改过的，没改过的是头部写的 keyword
  func scriptAlias(_ script: ScriptCommand) -> String? {
    commandSettings().alias(LauncherCommands.scriptID(script), default: script.keyword)
  }
}
