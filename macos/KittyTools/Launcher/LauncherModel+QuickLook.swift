// 启动器的快速查看、打开方式、废纸篓（体检 C7；第五轮体检 H1 从 LauncherModel.swift 拆出）。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension LauncherModel {
  // MARK: 快速查看、打开方式、废纸篓（体检 C7）

  /// ⌘Y：打开 / 缩回快速查看（选中的不是文件时只有提示音）
  func toggleQuickLook() {
    if isQuickLooking {
      isQuickLooking = false
      closeQuickLook(true)
    } else if let item = selectedItem, isFile(item) || Self.resultFile(item) != nil {
      isQuickLooking = true
      showsQuickLookContent = true
      openQuickLook()
    } else {
      NSSound.beep()
    }
  }

  /// 预览浮层收走了（缩回放完、点了外面、跟着启动器收起）：同步状态、拆掉预览
  func quickLookDidHide() {
    isQuickLooking = false
    showsQuickLookContent = false
  }

  /// 预览的文件：选中的不是文件时 nil（浮层里写「没有可预览的文件」）
  var quickLookURL: URL? {
    guard let item = selectedItem else { return nil }
    if let path = Self.resultFile(item) { return URL(filePath: path) }
    guard isFile(item) else { return nil }
    return URL(filePath: item.target)
  }

  /// 列表脚本给的文件结果（第三轮 B1）：⌘Y 快速查看它；不能选的（payload 是 nil）不算
  static func resultFile(_ item: LauncherItem) -> String? {
    guard item.kind == .scriptResult, item.payload != nil, case .file(let path) = item.opens else {
      return nil
    }
    return path
  }

  /// 右键菜单里的「快速查看」：先选中被点的那一行
  func quickLook(_ item: LauncherItem) {
    if let index = results.firstIndex(of: item) { selection = index }
    if !isQuickLooking { toggleQuickLook() }
  }

  /// 移到废纸篓（能放回，按 D2「只确认不可撤销的」不二次确认）：刘海岛说一声、带「撤销」（第五轮体检 U5①），
  /// 结果行原地删掉（settle）
  func moveToTrash(_ item: LauncherItem) {
    let original = URL(filePath: item.target)
    Task {
      let trashed: URL?
      do {
        trashed = try await recycle(original)
      } catch {
        island?.show("没能移到废纸篓", detail: "\(error.localizedDescription)", tone: .error)
        return
      }
      island?.show(
        "已移到废纸篓「\(item.title)」", symbol: "trash.circle.fill",
        actions: trashed.map { trashed in
          [
            Self.putBack(trashed, to: original, island: island) { [self] in
              // 收起着就不搜（同「关掉这条命令」的撤销）；下次呼出自己会搜
              if isShown { search() }
            }
          ]
        } ?? [])
      let index = selection
      withAnimation(Style.Motion.settle.animation(reduced: Style.reduceMotion)) {
        if isShowingRecent {
          search()
        } else {
          results.removeAll { $0.id == item.id }
        }
      }
      selection = min(index, max(results.count - 1, 0))
    }
  }

  /// 「已移到废纸篓」上的「撤销」（启动器、设置里脚本的「移到废纸篓」共用，第五轮体检 U5①）：从废纸篓挪回原处。
  /// 原处又有了同名的就报错、不覆盖（RENAME_EXCL，同 mac-native §2 动用户文件的规矩）；done：放回去之后（重搜、重读脚本库）
  static func putBack(
    _ trashed: URL, to original: URL, island: Island?, done: @escaping () -> Void
  ) -> Island.Action {
    Island.Action("撤销") {
      let name = original.lastPathComponent
      let error = FileMoves.rename(trashed, to: original)
      guard error != 0 else {
        island?.show("已放回「\(name)」", symbol: "arrow.uturn.backward.circle.fill")
        return done()
      }
      // 可选参数里的三目只有第一个分支抽得进目录：先放进不是可选的 let
      let detail: LocalizedStringResource =
        if error == EEXIST || error == ENOTEMPTY {
          "原处已经有同名的了，没有覆盖"
        } else if !FileMoves.occupied(trashed) {
          "废纸篓里已经没有它了"
        } else {
          "原来的文件夹不在了，或者那里写不了"
        }
      island?.show("没能放回「\(name)」", detail: detail, tone: .warning)
    }
  }

  /// 默认浏览器以外能开网页的 App（按 https 问 LaunchServices，不读网页）。
  /// ponytail: 登记了 https 的非浏览器 App 也会列出来，真碰到再按 bundle id 滤
  static func otherBrowsers() -> [URL] {
    guard let https = URL(string: "https:") else { return [] }
    let workspace = NSWorkspace.shared
    let resolved = { (url: URL) in url.resolvingSymlinksInPath().path }
    var seen = Set([workspace.urlForApplication(toOpen: https).map(resolved)].compactMap { $0 })
    return workspace.urlsForApplications(toOpen: https).filter {
      seen.insert(resolved($0)).inserted
    }
  }

  /// 能打开这种类型的 App：默认的排第一（标「默认」），最多 5 个；按类型问，不读文件本身
  static func applications(toOpen type: UTType) -> [(url: URL, isDefault: Bool)] {
    let workspace = NSWorkspace.shared
    let preferred = workspace.urlForApplication(toOpen: type)
    var seen = Set<String>()
    return ([preferred].compactMap { $0 } + workspace.urlsForApplications(toOpen: type))
      .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
      .prefix(5)
      .map { ($0, $0 == preferred) }
  }

  /// App 在访达里的名字（跟系统的语言）
  static func appName(_ url: URL) -> String { AppCatalog.systemName(path: url.path) }

  var otherBrowsers: [URL] {
    if let browserCache { return browserCache }
    let found = browsers()
    browserCache = found
    return found
  }

  /// 「用 X 打开」的 App：网址是默认浏览器以外的浏览器，文件是能开这种类型的 App
  func openers(for item: LauncherItem) -> [(url: URL, isDefault: Bool)] {
    if isWebLink(item) { return otherBrowsers.map { ($0, false) } }
    guard isFile(item), let type = item.contentType else { return [] }
    if let cached = applicationCache[type.identifier] { return cached }
    let found = applications(type)
    applicationCache[type.identifier] = found
    return found
  }
}
