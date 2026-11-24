// 启动器的 ⌘K 动作菜单 / 右键菜单（第五轮体检 H1 从 LauncherModel.swift 拆出）：一行有哪些动作、过滤、选中执行。

import AppKit
import SwiftUI

extension LauncherModel {
  // MARK: ⌘K 动作菜单 / 右键菜单

  /// 选中项的动作（⌘K）。勾着时只给批量动作（只勾一个也是：菜单上的键位 ↩ ⌘↩ ⌘C ⇧⌘C 都对着勾的，和按键一致）
  var actions: [ActionMenu.Item] {
    let checked = checkedItems
    if !checked.isEmpty { return checkedActions(checked) }
    return selectedItem.map(actions(for:)) ?? []
  }

  /// 行上右键：点的是勾着的行给批量动作，否则对着被点的那一行
  func contextActions(for item: LauncherItem) -> [ActionMenu.Item] {
    let checked = checkedItems
    return checked.contains(item) ? checkedActions(checked) : actions(for: item)
  }

  /// 一项能做的全部动作（N8；右键菜单同一份，体检 C8）：主动作 ↩ 在最前，每行写上键位，执行的和按键是同一段代码。
  /// 分节：打开 ｜ 用别的 App 打开（脚本是编辑、改别名、关掉）｜ 复制 ｜ 搜索框（补全、⌥↩、⌃↩）｜ 收藏、移除、废纸篓
  func actions(for item: LauncherItem) -> [ActionMenu.Item] {
    var actions: [ActionMenu.Item] = []
    func add(
      _ title: LocalizedStringResource, _ symbol: String?, _ shortcut: String? = nil,
      image: NSImage? = nil, detail: LocalizedStringResource? = nil, section: Int,
      destructive: Bool = false, _ run: @escaping () -> Void
    ) {
      actions.append(
        ActionMenu.Item(
          title: title, symbol: symbol, image: image, detail: detail, shortcut: shortcut,
          id: "\(actions.count)", section: section, isDestructive: destructive, run: run))
    }
    // 0 打开
    let primary = primaryAction(for: item)
    add(
      primary.title, primary.symbol, "↩", section: 0,
      destructive: isDangerous(item, commandKey: false)
    ) { [unowned self] in execute(item) }
    // 网址的 ⌘↩ 就是下面浏览器里的第一个
    if !isWebLink(item), let secondary = commandReturnAction(for: item) {
      add(
        secondary.title, secondary.symbol, "⌘↩", section: 0,
        destructive: isDangerous(item, commandKey: true)
      ) { [unowned self] in commandReturn(item) }
    }
    if isFile(item) || Self.resultFile(item) != nil {
      add("快速查看", "eye", "⌘Y", section: 0) { [unowned self] in quickLook(item) }
    }
    if isPathRow(item) {
      add("在终端中打开", "terminal", "⌘T", section: 0) { [unowned self] in openInTerminal(item) }
    }
    // 1 脚本（第二轮 D1）：发现一条不对劲，就地改它、换个词、关掉；自带的复制一份成自己的。
    // 脚本没有「用别的 App 打开」，接在打开后面，不用滚就看得到
    if let script = script(of: item) {
      // 自带的在 App 包里（改了会被更新盖掉、坏签名）：⌘E 是复制一份成自己的再改
      if script.isBundled {
        add("复制一份到我的脚本", "plus.square.on.square", "⌘E", section: 1) { [unowned self] in
          edit(script)
        }
      } else {
        add("编辑脚本", "pencil", "⌘E", section: 1) { [unowned self] in edit(script) }
      }
      add("改别名…", "keyboard", section: 1) { [unowned self] in
        close()
        openCommandSettings(LauncherCommands.scriptID(script))
      }
      add("关掉这条命令", "nosign", section: 1) { [unowned self] in disable(script) }
    }
    // 1 用别的 App 打开：网址是默认浏览器以外的浏览器（第一个是 ⌘↩），文件是能开这种类型的 App（默认的排第一）
    let web = isWebLink(item)
    for (index, app) in openers(for: item).enumerated() {
      add(
        "用「\(Self.appName(app.url))」打开", nil, web && index == 0 ? "⌘↩" : nil,
        image: LauncherIcons.icon(for: app.url.path), detail: app.isDefault ? "默认" : nil,
        section: 1
      ) { [unowned self] in
        if web {
          if let url = URL(string: item.target) {
            open(url, item.kind == .url ? item : nil, with: app.url)
          }
        } else {
          open(URL(filePath: item.target), item, with: app.url)
        }
      }
    }
    // 2 复制（计算结果、ip 的 ⌘C 和 ⌘↩ 一样，不重复列）；复制路径和剪贴板 ⌘K 的「复制路径」同一个符号 link（mac-whisker §3）
    // 列表结果的 ⌘↩ 是在访达中显示（文件）、或者另给了 ⌘C 复制的（text.copy）：⌘C 另列
    let copiesOnCommandReturn =
      [.calculation, .ip].contains(item.kind)
      || (item.kind == .scriptResult && Self.resultFile(item) == nil && item.copyText == nil)
    if !copiesOnCommandReturn, let title = copyTitle(for: item) {
      let symbol =
        [.app, .path, .script].contains(item.kind) || Self.resultFile(item) != nil
        ? "link" : "doc.on.doc"
      add(title, symbol, "⌘C", section: 2) { [unowned self] in copy(item) }
    }
    if isPathRow(item) {
      add("拷贝文件", "doc.on.doc", "⇧⌘C", section: 2) { [unowned self] in copyFile(item) }
      add("复制终端写法的路径", "apple.terminal", "⌥⌘C", section: 2) { [unowned self] in
        copyShellPath(item)
      }
    }
    if web {
      add("复制为 Markdown 链接", "text.badge.plus", "⇧⌘C", section: 2) { [unowned self] in
        copy(item, .markdown)
      }
      add("复制标题", "text.quote", section: 2) { [unowned self] in copy(item, .title) }
    }
    // 计算结果：原始数字（不分组、不带单位）、别的进制（体检 D11）
    if item.kind == .calculation {
      for extra in Calculator.result(for: item.target, rates: rates)?.copies ?? [] {
        add(extra.title, "doc.on.doc", detail: "\(extra.text)", section: 2) { [unowned self] in
          copy(item, .calculation(extra))
        }
      }
    }
    // 3 搜索框：提示行、要参数的脚本那一行的主动作就是补全
    let completesOnReturn =
      item.kind == .prompt
      || (item.kind == .script && item.arguments == nil && item.completion != nil)
    if !completesOnReturn, Self.completion(for: item) != nil {
      add("补全到搜索框", "arrow.right.to.line", "⇥", section: 3) { [unowned self] in
        complete(item)
      }
    }
    if let title = finderSearchTitle {
      add("\(title)", "doc.text.magnifyingglass", "⌥↩", section: 3) { [unowned self] in
        searchInFinder()
      }
    }
    if let title = webSearchTitle {
      add("\(title)", "globe", "⌃↩", section: 3) { [unowned self] in searchWeb() }
    }
    // 4 收藏、移除、废纸篓
    if canFavorite(item) {
      let favorite = isFavorite(item)
      add(favorite ? "取消收藏" : "加入收藏", favorite ? "star.slash" : "star", "⌘D", section: 4) {
        [unowned self] in toggleFavorite(item)
      }
    }
    if isCommon(item) {
      add("从常用中移除", "clock.badge.xmark", "⌘⌫", section: 4) { [unowned self] in forget(item) }
    }
    if isFile(item), Self.canTrash(item.target) {
      add("移到废纸篓", "trash", section: 4, destructive: true) { [unowned self] in
        moveToTrash(item)
      }
    }
    return actions
  }

  /// 选中的是一条脚本命令（不是列表脚本给的结果行）
  func script(of item: LauncherItem) -> ScriptCommand? {
    guard item.kind == .script else { return nil }
    return activeScripts.first { $0.path == item.target }
  }

  /// ⌘E / ⌘K「编辑脚本」：收起，用编辑器打开；自带的复制一份到我的脚本再打开（同时关掉自带那条）
  func edit(_ script: ScriptCommand) {
    close()
    if script.isBundled { copyBundledScript(script) } else { editScript(script) }
  }

  /// ⌘K「关掉这条命令」：从搜索里拿掉（就是 设置 › 启动器「命令和别名」里那个开关），启动器留着、重搜；岛上带「撤销」
  func disable(_ script: ScriptCommand) {
    let id = LauncherCommands.scriptID(script)
    setCommandOn(id, false)
    search()
    island?.show(
      "已关掉「\(script.title)」", detail: "设置 › 启动器「命令和别名」里能再打开",
      actions: [
        Island.Action("撤销") { [weak self] in
          guard let self else { return }
          setCommandOn(id, true)
          // 收起着就不搜（留着的查询可能正好会跑一个列表脚本）；下次呼出自己会搜
          if isShown { search() }
        }
      ])
  }

  /// 按 actionQuery 过滤（和剪贴板的两个菜单同一个 ActionMenu.filter：子串 + 中文标题的拼音前缀）
  var filteredActions: [ActionMenu.Item] { ActionMenu.filter(actions, query: actionQuery) }

  /// ⌘K / 底栏「动作」：没有选中项时不打开。⌘Y 预览开着时先缩回它：菜单画在被预览盖住的启动器里，
  /// 不然搜索框悄悄变成过滤动作、↑↓ 改的是看不见的菜单
  func toggleActions() {
    guard showsActions || selectedItem != nil, review == nil, output == nil else { return }
    if isQuickLooking { toggleQuickLook() }
    showsActions.toggle()
  }

  func moveAction(by offset: Int) {
    let actions = filteredActions
    let count = actions.count
    guard count > 0 else { return }
    actionSelection = (actionSelection + offset + count) % count
    ActionMenu.announce(actions[actionSelection])
  }

  func runSelectedAction() {
    let actions = filteredActions
    guard actions.indices.contains(actionSelection) else { return NSSound.beep() }
    run(actions[actionSelection])
  }

  /// 先关菜单再执行：执行里要改查询（补全）、收起面板
  func run(_ action: ActionMenu.Item) {
    showsActions = false
    action.run()
  }
}
