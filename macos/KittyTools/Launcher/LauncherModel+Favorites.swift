// 启动器的收藏与常用（体检 A22 D13 B38；第五轮体检 H1 从 LauncherModel.swift 拆出）：加 / 去收藏、挪顺序、从常用里移除和撤销。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension LauncherModel {
  // MARK: 收藏与常用（体检 A22 D13 B38）

  /// 能收藏的：记使用的那几类（App、内置动作、网址、文件、系统命令），带对象模式里的 App / 宗卷不算，
  /// 只在有钉图时才有的两个内置动作也不算（没钉图时还原不出来，收藏会自己消失）
  func canFavorite(_ item: LauncherItem) -> Bool {
    item.kind.isRecorded && commandRequest == nil
      && item.contentType?.conforms(to: .volume) != true
      && !(item.kind == .action && item.target.hasPrefix("pins-"))
  }

  func isFavorite(_ item: LauncherItem) -> Bool { usage.isFavorite(item) }

  /// 空查询里「常用」那一组的（收藏的不算）：⌘⌫ 能移除
  func isCommon(_ item: LauncherItem) -> Bool {
    guard isShowingRecent, item.kind.isRecorded, let index = results.firstIndex(of: item) else {
      return false
    }
    return index >= favoriteCount
  }

  /// ⌘D：加入 / 取消收藏；满 8 个时提示音 + 底栏说一声。空查询时列表跟着变，选中留在这一项上
  func toggleFavorite(_ item: LauncherItem) {
    guard canFavorite(item) else { return NSSound.beep() }
    let adding = !usage.isFavorite(item)
    guard usage.toggleFavorite(item, visible: adding ? favorites(builtIns).count : nil) else {
      NSSound.beep()
      return show(.warning("收藏最多 \(LauncherUsage.favoriteLimit) 个，先取消一个"))
    }
    show(.message(adding ? "已加入收藏" : "已取消收藏"))
    if isShowingRecent { refresh(keeping: item.id) }
  }

  /// ⌥⌘↑↓：空查询里选中的收藏和上一个 / 下一个换位置（⌘1–N 跟着固定下来）；不是收藏时不接这个键
  /// 和**看得见的**上一个 / 下一个换（藏着的收藏——这台还原不出来的——不挡着，换了看得出变化）
  func moveFavorite(by offset: Int) -> Bool {
    guard isShowingRecent, let item = selectedItem, selection < favoriteCount else { return false }
    let neighbor = selection + offset
    if (0..<favoriteCount).contains(neighbor), usage.swapFavorites(item, results[neighbor]) {
      refresh(keeping: item.id)
    } else {
      NSSound.beep()
    }
    return true
  }

  /// 「常用」里 ⌘⌫：忘掉这一项的使用记录，底栏「已从常用中移除 · 撤销 ⌘Z」，⌘Z 原样放回（体检 B38）
  func forget(_ item: LauncherItem) {
    let entries = usage.forget(item)
    refresh(keeping: nil)
    forgotten = (item, entries)
    show(.undo("已从常用中移除"), spoken: String(localized: "已从常用中移除，按 Command-Z 撤销"))
  }

  func undoForget() {
    guard let forgotten else { return }
    usage.restore(forgotten.entries)
    self.forgotten = nil
    refresh(keeping: forgotten.item.id)
    Island.announce("已撤销移除")
  }

  /// 底栏就地提示（剪贴板底栏同一种，BarNotice），同时播报。⌘Y 预览开着时底栏被它盖住：另走刘海岛
  /// （岛自己会播报，同剪贴板；底栏照样设上，缩回预览后还看得到）
  private func show(_ notice: BarNotice, spoken: String? = nil) {
    noticeTask?.cancel()
    self.notice = notice
    if isQuickLooking, let island {
      let text = notice.text
      switch notice.kind {
      case .message: island.show("\(text)")
      case .warning: island.show("\(text)", tone: .warning)
      case .undo:
        island.show("\(text)", detail: "⌘Z 撤销", tone: .info, symbol: "minus.circle.fill")
      }
    } else {
      Island.post(spoken ?? notice.text)
    }
    noticeTask = Task {
      try? await Task.sleep(for: .seconds(notice.seconds))
      guard !Task.isCancelled else { return }
      self.notice = nil
    }
  }
}
