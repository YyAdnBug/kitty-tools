// 截图历史窗口（历史第 2 批，2026-10-26 拍板 C1）：一扇正经窗口（同全部便签窗口的做法），
// 左边是按日期分组的缩略图网格、顶上搜索和筛选，选中一条右边是大预览、信息和一排操作。
// 这里是窗口和模型（过滤、分组、每条的操作、缩略图缓存），界面在 ShotHistoryView.swift。
// 操作本身不自己做：拷贝、存储、另存为、钉图、识字、改标注都由 AppDelegate 接到截图那条路上（同 ShotShelf、PinBoard）。

import AppKit
import SwiftUI

@MainActor @Observable final class ShotHistoryModel {
  /// 顶上的筛选（拍板 C1）
  enum Filter: String, CaseIterable, Identifiable {
    case all, shot, scroll, recording

    var id: String { rawValue }

    var title: String {
      switch self {
      case .all: "全部"
      case .shot: "截图"
      case .scroll: "长截图"
      case .recording: "录制"
      }
    }

    func matches(_ kind: ShotHistory.Kind) -> Bool {
      switch self {
      case .all: true
      case .shot: kind == .shot
      case .scroll: kind == .scroll
      case .recording: kind == .video || kind == .audio || kind == .gif
      }
    }
  }

  let history: ShotHistory
  var search = ""
  var filter = Filter.all
  var selection: UUID?
  /// 正在问「删掉这几条？」
  var deleting: [UUID] = []
  /// 缩略图重做好了要重画（改完标注那一下）：视图读它来建立依赖
  private(set) var redraws = 0

  func touch() { redraws += 1 }

  /// 每条的操作（AppDelegate 给，晾衣绳和这里共用一份 ShotActions；说一句话的 notice 也在里面）
  @ObservationIgnored var actions = ShotActions()

  init(history: ShotHistory, actions: ShotActions = ShotActions()) {
    self.history = history
    self.actions = actions
  }

  /// 筛过、搜过的那些（新的在前）
  var shown: [ShotHistory.Item] {
    Self.filtered(history.items, search: search, filter: filter)
  }

  /// 按天分组（新的在前），标题是「今天」「昨天」或者日期
  var groups: [Group] {
    Self.group(shown, now: .now)
  }

  struct Group: Identifiable {
    let title: String
    let items: [ShotHistory.Item]
    var id: String { title }
  }

  var selected: ShotHistory.Item? {
    selection.flatMap { id in history.items.first { $0.id == id } }
  }

  /// 搜的是来源 App 和种类（截图里没有文字可搜，拍板「搜图里的文字」留到以后）。纯函数，配单测
  static func filtered(_ items: [ShotHistory.Item], search: String, filter: Filter)
    -> [ShotHistory.Item]
  {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return items.filter { item in
      guard filter.matches(item.kind) else { return false }
      guard !needle.isEmpty else { return true }
      return (item.source ?? "").lowercased().contains(needle)
        || item.kind.title.lowercased().contains(needle)
        || (item.savedPath.map { ($0 as NSString).lastPathComponent.lowercased().contains(needle) }
          ?? false)
    }
  }

  /// 按天分组（新的在前；今天、昨天写成字，更早的写日期）。纯函数，配单测
  static func group(_ items: [ShotHistory.Item], now: Date) -> [Group] {
    let calendar = Calendar.current
    var order: [Date] = []
    var buckets: [Date: [ShotHistory.Item]] = [:]
    for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
      let day = calendar.startOfDay(for: item.createdAt)
      if buckets[day] == nil { order.append(day) }
      buckets[day, default: []].append(item)
    }
    return order.map { day in
      Group(title: title(for: day, now: now, calendar: calendar), items: buckets[day] ?? [])
    }
  }

  static func title(for day: Date, now: Date, calendar: Calendar = .current) -> String {
    // 和传进来的 now 比，不用 isDateInToday（那是和真实的今天比，单测没法固定时间）
    let today = calendar.startOfDay(for: now)
    if day == today { return "今天" }
    if day == calendar.date(byAdding: .day, value: -1, to: today) { return "昨天" }
    // 只要日期、不带时间（Date.FormatStyle 加了字段也还会带上 0:00，实测）；今年的不写年份
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(
      calendar.isDate(day, equalTo: now, toGranularity: .year) ? "Md" : "yMd")
    return formatter.string(from: day)
  }

  /// 一条的说明（时间 · 尺寸 · 来源）。纯函数，配单测
  static func caption(_ item: ShotHistory.Item) -> String {
    var parts = [item.createdAt.formatted(date: .omitted, time: .shortened)]
    if item.pixelSize.width > 0 {
      parts.append("\(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height))")
    }
    if let source = item.source, !source.isEmpty { parts.append(source) }
    return parts.joined(separator: " · ")
  }

  /// 第二行：存到哪、几条标注、钉过没有
  static func details(_ item: ShotHistory.Item) -> String {
    var parts: [String] = []
    if let path = item.savedPath {
      let folder = (path as NSString).deletingLastPathComponent
      parts.append("已存到「\(FileManager.default.displayName(atPath: folder))」")
    }
    if !item.annotations.isEmpty { parts.append("\(item.annotations.count) 条标注") }
    if item.pinnedAt != nil { parts.append("钉过") }
    return parts.joined(separator: " · ")
  }

  /// 成品图：有标注才合成（拍板 A1、C2），录制的那几条没有图
  func composed(_ item: ShotHistory.Item) -> CGImage? { history.composed(item) }

  /// 录制的那几条：文件还在不在（拍板 D2：不在了那一条照常能看）。
  /// 在访达中显示、打开都挪到了 ShotHistory 上（晾衣绳也要用），这里留两个薄壳给界面调
  func fileExists(_ item: ShotHistory.Item) -> Bool { ShotHistory.fileExists(item) }

  func reveal(_ item: ShotHistory.Item) { ShotHistory.reveal(item, notice: actions.notice) }

  func open(_ item: ShotHistory.Item) { ShotHistory.open(item, notice: actions.notice) }

  /// 这一条有没有文件可以显示 / 打开（没有时那一项置灰）
  func hasFile(_ item: ShotHistory.Item) -> Bool { (item.filePath ?? item.savedPath) != nil }

  func delete(_ ids: [UUID]) {
    if let selection, ids.contains(selection) { self.selection = nil }
    history.remove(ids)
  }
}

/// 窗口本体：同全部便签窗口（正经窗口、记住大小位置、关掉时 leaveDockIfNoWindows）
@MainActor final class ShotHistoryWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  let model: ShotHistoryModel
  var onClose: () -> Void = {}

  var isVisible: Bool { window.isVisible }

  init(model: ShotHistoryModel, frameName: String? = "ShotHistory") {
    self.model = model
    window = NSWindow(
      contentViewController: .windowContent(ShotHistoryView(model: model)))
    window.title = "截图历史"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.setContentSize(NSSize(width: 960, height: 620))
    window.contentMinSize = NSSize(width: 720, height: 420)
    super.init()
    window.delegate = self
    if let frameName {
      if !window.setFrameUsingName(frameName) { window.center() }
      window.setFrameAutosaveName(frameName)
    } else {
      window.center()
    }
  }

  /// 显示并激活（同设置窗、全部便签窗口）
  func show() {
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.leaveDockIfNoWindows(closing: window)
    onClose()
  }
}

/// 缩略图：读盘解码一次就留着（历史窗口滚动时不反复读）。窗口关掉时清空
@MainActor final class ShotThumbnails {
  static let shared = ShotThumbnails()
  private var cache: [UUID: NSImage] = [:]

  func image(for item: ShotHistory.Item, in history: ShotHistory) -> NSImage? {
    if let cached = cache[item.id] { return cached }
    guard let cg = history.thumbnail(for: item.id) else { return nil }
    let image = NSImage(
      cgImage: cg,
      size: NSSize(
        width: CGFloat(cg.width) / item.scale, height: CGFloat(cg.height) / item.scale))
    cache[item.id] = image
    return image
  }

  func forget(_ id: UUID) { cache[id] = nil }

  func clear() { cache.removeAll() }
}
