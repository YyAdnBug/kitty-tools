// 截图历史窗口（历史第 2 批，2026-10-26 拍板 C1）：一扇正经窗口（同全部便签窗口的做法），
// 左边是按日期分组的缩略图网格、顶上搜索和筛选，选中一条右边是大预览、信息和一排操作。
// 这里是窗口和模型（过滤、分组、每条的操作、缩略图缓存），界面在 ShotHistoryView.swift。
// 操作本身不自己做：拷贝、存储、另存为、钉图、识字、改标注都由 AppDelegate 接到截图那条路上（同 ShotShelf、PinBoard）。

import AppKit
import Carbon.HIToolbox
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
  /// 选中的那几条（多选，2026-10-27 用户要的）：空 = 没选中。
  /// 右边正好一条时是预览，多条时是「已选 N 张」+ 能一起做的那几件
  var picked: Set<UUID> = []
  /// ⇧ 点选连过去的锚点，也是方向键现在落在哪一条（同访达）
  var anchor: UUID?

  /// 正好选中一条时是它，否则 nil：右边的预览、只能单条做的那几件（改标注、钉图、识字）都看它。
  /// 写它 = 只选这一条
  var selection: UUID? {
    get { picked.count == 1 ? picked.first : nil }
    set {
      picked = newValue.map { [$0] } ?? []
      anchor = newValue
    }
  }
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

  /// 筛过、搜过的那些（新的在前，和网格里的先后一样）
  var shown: [ShotHistory.Item] { groups.flatMap(\.items) }

  /// 按天分组（新的在前），标题是「今天」「昨天」或者日期。
  /// 按历史的版本号、搜索词、筛选和今天是哪天记一份（P2：原来每次画都筛一遍、排一遍、按天分一遍）
  var groups: [Group] {
    let key = GroupKey(
      revision: history.revision, search: search, filter: filter,
      day: Calendar.current.startOfDay(for: .now))
    if let memo, memo.key == key { return memo.groups }
    let groups = Self.group(
      Self.filtered(history.items, search: search, filter: filter), now: .now)
    memo = (key, groups)
    return groups
  }

  private struct GroupKey: Equatable {
    let revision: Int
    let search: String
    let filter: Filter
    let day: Date
  }
  @ObservationIgnored private var memo: (key: GroupKey, groups: [Group])?

  struct Group: Identifiable {
    let title: String
    let items: [ShotHistory.Item]
    var id: String { title }
  }

  var selected: ShotHistory.Item? { selection.flatMap(history.item) }

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
    let formatter =
      calendar.isDate(day, equalTo: now, toGranularity: .year) ? thisYear : otherYears
    return formatter.string(from: day)
  }

  /// 分组标题的两种写法（建一个 DateFormatter 不便宜，P2：原来每组都新建一个）
  private static let thisYear = dayFormatter("Md")
  private static let otherYears = dayFormatter("yMd")

  private static func dayFormatter(_ template: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
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

  /// 录制的那几条：文件还在不在（拍板 D2：不在了那一条照常能看）。
  /// 在访达中显示、打开都挪到了 ShotHistory 上（晾衣绳也要用），这里留两个薄壳给界面调
  func fileExists(_ item: ShotHistory.Item) -> Bool { ShotHistory.fileExists(item) }

  func reveal(_ item: ShotHistory.Item) { ShotHistory.reveal(item, notice: actions.notice) }

  func open(_ item: ShotHistory.Item) { ShotHistory.open(item, notice: actions.notice) }

  /// 拖到别的 App 里去（同晾衣绳，见 ShotHistory.dragFile：截图拖现合成的成品、录制的拖一份克隆）
  func dragProvider(for item: ShotHistory.Item) -> NSItemProvider {
    history.dragProvider(for: item)
  }

  /// 这一条有没有文件可以显示 / 打开（没有时那一项置灰）
  func hasFile(_ item: ShotHistory.Item) -> Bool { (item.filePath ?? item.savedPath) != nil }

  /// 网格一行放得下几张：方向键的 ↑↓ 要跳一行。由视图量出宽度后写进来
  @ObservationIgnored var columnsPerRow = 4

  /// 一行几张：LazyVGrid 的 .adaptive(minimum:) 就是「按最小宽尽量塞，至少一列」。纯函数，配单测
  static func columns(width: CGFloat, card: CGFloat, spacing: CGFloat, padding: CGFloat) -> Int {
    max(1, Int((width - padding * 2 + spacing) / (card + spacing)))
  }

  /// 方向键挪到第几张：夹在两头、不绕圈（绕圈时按住 → 会从最后一张跳回开头，看着像乱跳）。纯函数，配单测
  static func stepped(from index: Int, by step: Int, count: Int) -> Int {
    min(max(index + step, 0), max(count - 1, 0))
  }

  /// 方向键换选中（没选中的时候选第一张）。extend = 按着 ⇧：从锚点连过去，不是只选新落到的那张
  func move(by step: Int, extend: Bool = false) {
    let list = shown
    guard !list.isEmpty else { return }
    guard let now = (anchor ?? picked.first).flatMap({ id in list.firstIndex { $0.id == id } })
    else { return pick(list[0].id) }
    let next = list[Self.stepped(from: now, by: step, count: list.count)].id
    guard extend else { return pick(next) }
    picked.formUnion(Self.span(from: anchor ?? next, to: next, in: list.map(\.id)) ?? [next])
    anchor = next
  }

  // MARK: 多选

  /// 选中的那几条，按现在列出来的顺序（批量动作都拿它）
  var chosen: [ShotHistory.Item] {
    let ids = picked
    return shown.filter { ids.contains($0.id) }
  }

  /// 点一张卡：按着 ⌘ 是加选 / 去掉，按着 ⇧ 是从锚点连过去，都没按就只选它。
  /// 修饰键当场从 NSEvent 读——SwiftUI 的 TapGesture 不带修饰键，而加了 .modifiers(_:) 的那颗不排他，
  /// 按着 ⌘ 点会和没带修饰键的那颗一起响（单测注入 flags）
  func click(_ id: UUID, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
    if flags.contains(.command) {
      toggle(id)
    } else if flags.contains(.shift) {
      extend(to: id)
    } else {
      pick(id)
    }
  }

  /// 单点一张：只选它
  func pick(_ id: UUID) {
    picked = [id]
    anchor = id
  }

  /// ⌘ 点：加进来 / 去掉（去掉的那一下锚点也挪过来，同访达）
  func toggle(_ id: UUID) {
    if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    anchor = id
  }

  /// ⇧ 点：从锚点一直连到它，和现在选着的并起来（同访达：⌘ 点出几个零散的、再 ⇧ 点一段，零散的不丢）。
  /// 锚点不在现在列出来的里面就当单点
  func extend(to id: UUID) {
    guard let from = anchor, let span = Self.span(from: from, to: id, in: shown.map(\.id))
    else { return pick(id) }
    picked.formUnion(span)
  }

  /// ⌘A：现在列出来的全选上（筛选、搜索之外的不算）
  func pickAll() {
    picked = Set(shown.map(\.id))
    anchor = shown.first?.id
  }

  /// 两条之间那一段（含两头；谁在前面都行）。纯函数，配单测
  static func span(from: UUID, to: UUID, in list: [UUID]) -> [UUID]? {
    guard let a = list.firstIndex(of: from), let b = list.firstIndex(of: to) else { return nil }
    return Array(list[min(a, b)...max(a, b)])
  }

  /// 多选时右边那一行说明：各几个、一共多大。纯函数，配单测
  static func summary(_ items: [ShotHistory.Item]) -> String {
    var parts = ShotHistory.Kind.allCases.compactMap { kind -> String? in
      let count = items.filter { $0.kind == kind }.count
      return count > 0 ? "\(kind.title) × \(count)" : nil
    }
    let bytes = items.reduce(0) { $0 + $1.bytes }
    if bytes > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
    }
    return parts.joined(separator: " · ")
  }

  /// 多选「在访达中显示」：存过文件的那几条一起选中
  func reveal(_ items: [ShotHistory.Item]) { ShotHistory.reveal(items, notice: actions.notice) }

  // MARK: 对着选中的那几条做
  //
  // 都是**按下那一刻**才去读 chosen：挂在按钮上的闭包捕获的是渲染那一刻的选中状态，
  // ⌘A 之后紧接着按 ⌘C，那一下会按「只选着一条」走（2026-10-27 写多选时被这个咬过）

  /// 能不能拷（选中了就行，录制的那几条拷的是文件）
  var canCopy: Bool { !picked.isEmpty }
  /// 能不能存（选中的里面有图才行：录制的那几条本来就是文件）
  var canSave: Bool { chosen.contains { $0.filePath == nil } }

  func copySelection() {
    let items = chosen
    guard !items.isEmpty else { return }
    if items.count > 1 { actions.copyMany(items) } else { actions.copy(items[0]) }
  }

  func saveSelection() {
    let items = chosen
    guard !items.isEmpty else { return }
    if items.count > 1 { actions.saveMany(items) } else { actions.save(items[0]) }
  }

  func revealSelection() { reveal(chosen) }

  func deleteSelection() {
    let ids = chosen.map(\.id)
    guard !ids.isEmpty else { return }
    deleting = ids
  }

  func delete(_ ids: [UUID]) {
    picked.subtract(ids)
    if let anchor, ids.contains(anchor) { self.anchor = picked.first }
    history.remove(ids)
  }
}

/// 窗口本体：同全部便签窗口（正经窗口、记住大小位置、关掉时 leaveDockIfNoWindows）
@MainActor final class ShotHistoryWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  let model: ShotHistoryModel
  var onClose: () -> Void = {}
  private var keyMonitor: Any?

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
    removeKeyMonitor()
    NSApp.leaveDockIfNoWindows(closing: window)
    onClose()
  }

  /// 窗口自己认的键：**⇧⌘S 另存为**和 **⇧ + 方向键连选**。不挂 SwiftUI 的隐藏按钮——同一个键上挂
  /// 带 ⇧ 和不带 ⇧ 的两颗按钮，实测不带 ⇧ 的那颗会被抢走（⌘S 三次里错一两次走成另存为；⇧← 一挂上，
  /// 光按 ← 就变成连选），和 NotesWindow 的 ⇧⌘Z 是同一个坑。别的键都在 ShotHistoryView.shortcuts
  static func handlesKeyDown(_ event: NSEvent, in window: NSWindow, model: ShotHistoryModel)
    -> Bool
  {
    guard event.window === window else { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    // ⇧ + 方向键：从锚点连着选过去
    if flags == .shift, let step = Self.arrowStep(event.keyCode, columns: model.columnsPerRow) {
      model.move(by: step, extend: true)
      return true
    }
    guard flags == [.command, .shift],
      event.charactersIgnoringModifiers?.lowercased() == "s",
      let item = model.selected, item.filePath == nil  // 录制的那几条没有「另存为」
    else { return false }
    model.actions.saveAs(item)
    return true
  }

  /// 方向键挪几格（←→ 一张，↑↓ 一行）；不是方向键就 nil。纯函数，配单测
  static func arrowStep(_ keyCode: UInt16, columns: Int) -> Int? {
    switch Int(keyCode) {
    case kVK_LeftArrow: -1
    case kVK_RightArrow: 1
    case kVK_UpArrow: -max(columns, 1)
    case kVK_DownArrow: max(columns, 1)
    default: nil
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        self.map { Self.handlesKeyDown(event, in: $0.window, model: $0.model) } ?? false
      }
      return handled ? nil : event
    }
  }

  func windowDidResignKey(_ notification: Notification) { removeKeyMonitor() }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }
}

/// 缩略图：读盘解码一次就留着（历史窗口滚动、晾衣绳每帧重画都不再读盘），读不到的也记下、不再读（P2：原来读不到的
/// 每次画都再读一遍，晾衣绳的物理跑起来就是每帧每张卡读一次盘）。读盘解码在主线程外（见 ShotThumbnail）。
/// 最多留 limit 张（NSCache，原来是没上限的字典）；历史窗口关掉、空闲回收时只留挂在晾衣绳上的那几张
/// （AppDelegate），历史里删掉的跟着丢（ShotHistory.remove）
@MainActor final class ShotThumbnails {
  static let shared = ShotThumbnails()
  /// 一张最长边 480 像素，解好约 0.6–0.9 MB：一百张封顶约 90 MB（历史窗口一屏二三十张）
  static let limit = 100
  private let cache: NSCache<NSUUID, NSImage> = {
    let cache = NSCache<NSUUID, NSImage>()
    cache.countLimit = limit
    return cache
  }()
  /// 读过、读不到的（录制时没取到封面的那几条）
  private var missing: Set<UUID> = []
  /// 丢过一次就加一：丢之前开始读的那份读回来不进缓存（改完标注时还在读的是旧图）
  private var generation = 0

  /// 已经解好的（不读盘）
  func cached(_ id: UUID) -> NSImage? { cache.object(forKey: id as NSUUID) }

  /// 有就给；没有就在主线程外读盘解码一次
  func image(for item: ShotHistory.Item, in history: ShotHistory) async -> NSImage? {
    await image(for: item) { await history.thumbnail(for: item.id) }
  }

  /// 同上，读法另给（单测拿它卡在「正在读」的那一刻）
  func image(for item: ShotHistory.Item, loading: () async -> CGImage?) async -> NSImage? {
    if let cached = cached(item.id) { return cached }
    guard !missing.contains(item.id) else { return nil }
    let started = generation
    let cg = await loading()
    guard started == generation else { return cg.map { Self.image($0, scale: item.scale) } }
    guard let cg else {
      missing.insert(item.id)
      return nil
    }
    let image = Self.image(cg, scale: item.scale)
    cache.setObject(image, forKey: item.id as NSUUID)
    return image
  }

  private static func image(_ cg: CGImage, scale: CGFloat) -> NSImage {
    NSImage(
      cgImage: cg,
      size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
  }

  func forget(_ id: UUID) {
    cache.removeObject(forKey: id as NSUUID)
    missing.remove(id)
    generation += 1
  }

  /// 只留这几张（挂在晾衣绳上的），别的都丢
  func keep(only ids: some Sequence<UUID>) {
    let kept = ids.compactMap { id in cached(id).map { (id, $0) } }
    cache.removeAllObjects()
    missing.removeAll()
    generation += 1
    for (id, image) in kept { cache.setObject(image, forKey: id as NSUUID) }
  }

  func clear() { keep(only: []) }
}
