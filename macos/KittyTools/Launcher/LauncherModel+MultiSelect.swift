// 启动器的多选（2026-11-24 拍板 3A：同一次搜索要打开好几个文件）。只有文件、文件夹的行能勾（isPathRow）。
// 键位和剪贴板面板一样：⇧↑ ⇧↓ 从锚点扩选、⌘ 点按加减、⇧ 点按选一段，不按 ⇧ 地移动取消；↩ 按勾的先后一起打开
// （find 模式一起在访达中选中），⌘↩ 反过来；⌘C 复制路径、⇧⌘C 拷贝文件；⌘K 勾着时只给批量动作；Esc 先取消多选；
// 结果换了，看不见的勾去掉（results 的 didSet）。执行完照常收起，回到原来的搜索按拍板 1A（didHide 看 lastRun）。

import AppKit
import SwiftUI

extension LauncherModel {
  /// 能不能勾：文件、文件夹的行（宗卷、带对象模式里的不算）
  func isCheckable(_ item: LauncherItem) -> Bool { isPathRow(item) }

  /// 勾着的、现在看得见的，按勾的先后
  var checkedItems: [LauncherItem] {
    guard !checked.isEmpty else { return [] }
    var byID: [String: LauncherItem] = [:]
    for item in results where byID[item.id] == nil { byID[item.id] = item }
    return checked.compactMap { byID[$0] }
  }

  /// ⇧↑ / ⇧↓：选中挪一行，从锚点到新位置中间能勾的都勾上（和系统列表一致）；一个都勾不上响提示音
  func extendChecks(by offset: Int) {
    guard !results.isEmpty else { return }
    let current = results.indices.contains(selection) ? selection : 0
    let next = min(max(current + offset, 0), results.count - 1)
    if checkAnchor == nil || checked.isEmpty { checkAnchor = results[current].id }
    let anchor = results.firstIndex { $0.id == checkAnchor } ?? current
    checked = results[min(anchor, next)...max(anchor, next)].filter(isCheckable).map(\.id)
    if checked.isEmpty { NSSound.beep() }
    armed = nil
    forgotten = nil
    selectionMotion = Style.isKeyRepeat ? .instant : .snap
    selection = next
    userMovedSelection = true
    resumedSelection = nil
    // 焦点一直在搜索框：说出勾了几个、选中了什么（同 move 的 A1）
    let count = checked.count
    let title = results[next].title
    Island.announceSettled(String(localized: "已选 \(count) 个"), title)
  }

  /// ⌘ 点按：勾上 / 去掉这一行（还没在多选时先把选中的那行也勾上，同剪贴板）；range（⇧ 点按）：从锚点到这里能勾的都勾上
  func check(_ item: LauncherItem, range: Bool) {
    guard let index = results.firstIndex(of: item) else { return }
    if range {
      // 锚点：还没在多选时（刚呼出、打过字）从选中行起，之后 ⇧↑↓ 接着从它扩
      let anchorID = (checked.isEmpty ? nil : checkAnchor) ?? selectedItem?.id
      checkAnchor = anchorID
      let anchor = results.firstIndex { $0.id == anchorID } ?? selection
      checked = results[min(anchor, index)...max(anchor, index)].filter(isCheckable).map(\.id)
    } else {
      if checked.isEmpty, let current = selectedItem, isCheckable(current), current != item {
        checked = [current.id]
      }
      if let at = checked.firstIndex(of: item.id) {
        checked.remove(at: at)
      } else {
        checked.append(item.id)
      }
      checkAnchor = item.id
    }
    armed = nil
    forgotten = nil
    selectionMotion = .glide
    selection = index
    userMovedSelection = true
    resumedSelection = nil
  }

  /// ↩（commandKey：⌘↩）：勾着的一起打开，find 模式一起在访达中选中（和单个的 ↩ / ⌘↩ 同一个分法，revealsOnReturn）
  func runChecked(commandKey: Bool = false) {
    let items = checkedItems
    guard let first = items.first else { return NSSound.beep() }
    if pathPending { return NSSound.beep() }
    lastRun = first
    let query = query
    close()
    if revealsOnReturn(first) != commandKey {
      // 同单个：find 模式的 ↩（主动作）记使用，⌘↩ 在访达中显示不记
      if !commandKey { for item in items { usage.record(item, query: query) } }
      NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(filePath: $0.target) })
    } else {
      for item in items { launch(URL(filePath: item.target), item, query: query) }
    }
  }

  /// ⌘C：勾着的路径，一行一个（同剪贴板「复制路径」：记进历史）
  func copyCheckedPaths() {
    let items = checkedItems
    guard !items.isEmpty else { return NSSound.beep() }
    lastRun = items[0]
    Paster.write(string: items.map(\.target).joined(separator: "\n"), record: true)
    close()
    island?.show(Self.copied("复制路径"), detail: "\(items.count) 个文件和文件夹")
  }

  /// ⇧⌘C：勾着的文件本身（能一起粘进访达、聊天窗口）
  func copyCheckedFiles() {
    let items = checkedItems
    guard !items.isEmpty else { return NSSound.beep() }
    lastRun = items[0]
    Paster.write(files: items.map { URL(filePath: $0.target) })
    close()
    island?.show("已拷贝 \(items.count) 个文件")
  }

  /// 勾着的一起移到废纸篓（能放回、不二次确认，同单个）：一个岛、一个「撤销」全部放回；挪不了的说一声，挪成了的照样留在废纸篓
  func trashChecked() {
    let items = checkedItems
    guard !items.isEmpty else { return NSSound.beep() }
    // 先取消多选：一个个挪的时候再按 ↩、再移一次都不会对着它们
    checked = []
    Task {
      var moved: [(trashed: URL, original: URL)] = []
      var gone = Set<String>()
      var failed = 0
      for item in items {
        let original = URL(filePath: item.target)
        do {
          if let trashed = try await recycle(original) { moved.append((trashed, original)) }
          gone.insert(item.id)
        } catch {
          failed += 1
        }
      }
      pathListings = [:]
      let done = items.count - failed
      if done == 0 {
        island?.show("没能移到废纸篓", tone: .error)
        return
      }
      // 可选参数里的三目只有第一个分支抽得进目录：先放进 let
      var detail: LocalizedStringResource?
      if failed > 0 { detail = "另有 \(failed) 项没能移走" }
      island?.show(
        "已移到废纸篓 \(done) 项", detail: detail, symbol: "trash.circle.fill",
        actions: moved.isEmpty
          ? []
          : [
            Island.Action("撤销") { [weak self] in
              let back = moved.filter { FileMoves.rename($0.trashed, to: $0.original) == 0 }.count
              if back == moved.count {
                self?.island?.show("已放回 \(back) 项", symbol: "arrow.uturn.backward.circle.fill")
              } else {
                self?.island?.show(
                  "放回了 \(back) 项", detail: "有的原处已经有同名的了、或者原来的文件夹不在了",
                  tone: .warning)
              }
              guard let self else { return }
              pathListings = [:]
              if isShown { search() }
            }
          ])
      let index = selection
      withAnimation(Style.Motion.settle.animation(reduced: Style.reduceMotion)) {
        // 空搜索框的常用：重搜补齐（同单个的移到废纸篓）
        if isShowingRecent {
          search()
        } else {
          // 只删挪成了的：没挪走的还在原处
          results.removeAll { gone.contains($0.id) }
        }
      }
      selection = min(index, max(results.count - 1, 0))
    }
  }

  /// 勾了两个以上时 ⌘K 的批量动作：打开、在访达中显示、复制路径、拷贝文件、移到废纸篓
  func checkedActions(_ items: [LauncherItem]) -> [ActionMenu.Item] {
    var actions: [ActionMenu.Item] = []
    func add(
      _ title: LocalizedStringResource, _ symbol: String, _ shortcut: String?, section: Int,
      destructive: Bool = false, _ run: @escaping () -> Void
    ) {
      actions.append(
        ActionMenu.Item(
          title: title, symbol: symbol, image: nil, detail: nil, shortcut: shortcut,
          id: "\(actions.count)", section: section, isDestructive: destructive, run: run))
    }
    let count = items.count
    let opens: (LocalizedStringResource, String) = ("打开 \(count) 个", "arrow.up.forward.app")
    let reveals: (LocalizedStringResource, String) = ("在访达中显示 \(count) 个", "folder")
    let (primary, secondary) =
      revealsOnReturn(items[0]) ? (reveals, opens) : (opens, reveals)
    add(primary.0, primary.1, "↩", section: 0) { [unowned self] in runChecked() }
    add(secondary.0, secondary.1, "⌘↩", section: 0) { [unowned self] in
      runChecked(commandKey: true)
    }
    add("复制路径", "link", "⌘C", section: 1) { [unowned self] in copyCheckedPaths() }
    add("拷贝文件", "doc.on.doc", "⇧⌘C", section: 1) { [unowned self] in copyCheckedFiles() }
    if items.allSatisfy({ isFile($0) && Self.canTrash($0.target) }) {
      add("移到废纸篓", "trash", nil, section: 2, destructive: true) { [unowned self] in
        trashChecked()
      }
    }
    return actions
  }

  /// 底栏和 ⌘K 第一项：勾着时 ↩ 做什么
  var checkedPrimaryTitle: LocalizedStringResource {
    let items = checkedItems
    guard let first = items.first else { return "打开" }
    return revealsOnReturn(first) ? "在访达中显示 \(items.count) 个" : "打开 \(items.count) 个"
  }
}
