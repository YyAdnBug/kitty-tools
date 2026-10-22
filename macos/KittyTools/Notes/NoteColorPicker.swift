// 便签的「其他颜色…」：系统取色面板改一条便签的纸色（便签未来计划 B3 / B4，2026-10-22；拍板页 B3「系统取色面板，
// 边拖边变」）。颜色菜单（NotePaper.colorItems，五处共用）末尾那一项打开它；拖的时候走慢落盘（同打字，
// NoteStore.setColor(live:)），关掉时落一次盘、把最后挑的颜色记进「最近用过」（recentColors：这台电脑自己的偏好、
// 不注册默认值、不跟导出走，最多 8 个，颜色菜单里预设后面那一节）。挑的颜色正好是哪种预设的浅纸就存成那种预设。
// 窗口：那叠里打开的便签、浮动便签是不激活本 App 的面板。macOS 27 上实测（独立小程序
// macos/build/research/notes-roadmap-2026-10-19/colorpanel-repro/，LSUIElement 的 .app 用 open -g 起）：
// ① 请求激活被驳回时取色面板照样出得来（提到 .modalPanel、orderFrontRegardless），但 hidesOnDeactivate 是 true 就马上
//   被藏到别的窗口后面 → 设成 false；② 本 App 没到前台时它当不了 key，硬 makeKey 反而让便签也丢了键盘 → 没到前台就把
//   键盘留在便签上（点一下取色面板，系统自己会把本 App 叫到前台、它拿到键盘）；③ 程序设 color 也会发一次 action →
//   先设颜色再挂 target（不然一打开就把预设纸改成了自定义的）。
// 取色面板还会把 changeColor: 发给第一响应者（不看 target）：正文框接了会把整篇字染成挑的颜色——NoteTextView 不接它；
// 标题框（字段编辑器）开着时打开前先结束编辑。
// **怎么关的决定收尾**（评审后改的）：用户自己关掉取色面板（它的关闭钮）才把前台还给原来的 App、键盘还给打开它的
// 那扇窗口（还看得见的话）；打开它的那一处（owner：那叠 / 浮动便签的模型、全部便签窗口的模型）换了一条、收起、关掉，
// 改的那条被删了，别的 App 到了前台（它不该浮在别的 App 上面），重开另一条——都静默收（不抢前台、不动键盘）。
// 点取色面板不算「点别处」（NoteDeck.isOutside 放过 NSColorPanel）；吸管在屏幕上取色那一下那叠晚一拍再判断（NoteDeck）。
// 状态那一半（begin / apply / close / finish）不碰系统的取色面板：单测只走这一半（建 NSColorPanel 会往测试宿主的偏好域
// 写窗口状态，mac-native §4）。

import AppKit

@MainActor final class NoteColorPicker: NSObject {
  static let shared = NoteColorPicker()
  /// 「最近用过」最多几个
  static let recentLimit = 8

  /// 正在改哪一条（nil = 没开着）
  private(set) var noteID: String?
  private weak var store: NoteStore?
  /// 从哪一处打开的（那叠 / 浮动便签的模型、全部便签窗口的模型）：它换了一条、收起时关掉
  private weak var owner: AnyObject?
  /// 从哪扇窗口打开的：用户自己关掉取色面板后键盘还给它
  private weak var window: NSWindow?
  /// 打开前在前台的别的 App：用户自己关掉取色面板后还给它
  private var previous: NSRunningApplication?
  /// 这一次挑过的最后一个颜色（关掉时记进最近用过）
  private var picked: Int?
  /// 系统取色面板是不是我们摆出来的（单测只走状态那一半，不碰它）
  private var showsPanel = false
  /// 正在静默地关（我们自己关的：willClose 来了也不还前台和键盘）
  private var closingQuietly = false
  private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
  /// 最近用过存在哪（单测换成临时的偏好域）
  var defaults = UserDefaults.standard

  /// 打开取色面板改 id 这一条（owner：从哪一处打开的；window：用户关掉后键盘还给它）。已经开着别的就先静默收掉那一条
  /// （原来在前台的那个 App 接着记着）
  func open(_ id: String, in store: NoteStore, owner: AnyObject, from window: NSWindow?) {
    let me = NSRunningApplication.current.processIdentifier
    let front = NSWorkspace.shared.frontmostApplication
    let kept = previous
    guard begin(id, in: store, owner: owner, from: window) else { return }
    previous = kept ?? (front?.processIdentifier == me ? nil : front)
    // 标题框正在编辑：先结束（取色面板的 changeColor: 会把字段编辑器里的字也染了）
    if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
      window?.makeFirstResponder(nil)
    }
    let panel = NSColorPanel.shared
    panel.setTarget(nil)
    panel.setAction(nil)
    panel.showsAlpha = false
    panel.isContinuous = true
    panel.hidesOnDeactivate = false
    if let note = store.note(id) { panel.color = srgb(NotePaper.of(note).light.paper) }
    panel.setTarget(self)
    panel.setAction(#selector(changed(_:)))
    showsPanel = true
    observe(.default, NSWindow.willCloseNotification, object: panel) { picker, _ in
      picker.finish(restoring: !picker.closingQuietly)
    }
    // 别的 App 到了前台：静默收（不浮在别的 App 上面）
    observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) {
      picker, app in
      if app != me { picker.closeQuietly() }
    }
    if previous != nil {
      NSApp.activate()
      if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
    panel.orderFrontRegardless()
    panel.level = .modalPanel
    // 到前台了才让它拿键盘；没到（macOS 27 上从不激活的面板里请求会被驳回）就把键盘留给便签
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == me {
      panel.makeKey()
    } else {
      window?.makeKey()
    }
  }

  /// 状态那一半：记下改哪一条、谁打开的。这条不在了（删了）给 false。已经开着别的就先静默收掉
  @discardableResult
  func begin(_ id: String, in store: NoteStore, owner: AnyObject, from window: NSWindow?) -> Bool {
    guard let note = store.note(id), note.deletedAt == nil else { return false }
    if noteID != nil { closeQuietly() }
    noteID = id
    self.store = store
    self.owner = owner
    self.window = window
    picked = nil
    return true
  }

  /// 是不是从 owner 那一处打开、正开着
  func isOpen(owner: AnyObject) -> Bool { noteID != nil && self.owner === owner }

  /// 是从 owner 那一处打开的就静默收（那叠、浮动便签换了一条 / 收起，全部便签窗口换了一条 / 关掉）。
  /// keeping：新打开的那条——正是取色面板在改的这条就不收（右键没打开的那条挑颜色，再点开它）
  func close(owner: AnyObject, keeping id: String? = nil) {
    guard isOpen(owner: owner), id == nil || id != noteID else { return }
    closeQuietly()
  }

  /// 拖着色轮 / 改十六进制：边拖边变，慢落盘（同打字）
  @objc func changed(_ sender: NSColorPanel) {
    apply(sender.color)
  }

  /// 挑了这个颜色：改的那条还在就换上（慢落盘），没了就静默收
  func apply(_ color: NSColor) {
    guard let id = noteID, let store, let note = store.note(id), note.deletedAt == nil else {
      return closeQuietly()
    }
    guard let rgb = Self.rgb(of: color) else { return }
    let value = Note.picked(rgb: rgb)
    picked = value
    store.setColor(value, of: id, live: true)
  }

  private func closeQuietly() {
    guard noteID != nil else { return }
    closingQuietly = true
    defer { closingQuietly = false }
    // close 会发 willClose → finish；面板不是我们摆的（单测）、已经被收起来了也收尾
    if showsPanel { NSColorPanel.shared.close() }
    if noteID != nil { finish(restoring: false) }
  }

  /// 收尾：摘掉 target 和通知、落盘、记最近用过；restoring（用户自己关的）才把前台还给原来的 App、键盘还给打开它的
  /// 那扇窗口（还看得见的话）
  private func finish(restoring: Bool) {
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    if showsPanel {
      NSColorPanel.shared.setTarget(nil)
      NSColorPanel.shared.setAction(nil)
    }
    showsPanel = false
    store?.flush()
    if let rgb = picked.flatMap(Note.customRGB(of:)) { Self.remember(rgb, in: defaults) }
    let (window, previous) = (window, previous)
    (noteID, store, owner, self.window, self.previous, picked) = (nil, nil, nil, nil, nil, nil)
    guard restoring else { return }
    previous?.activate()
    if let window, window.isVisible { window.makeKey() }
  }

  /// 挂一个通知（finish 里摘掉）。work 拿到的第二个值是通知里那个 App 的进程号（激活了哪个 App；别的通知是 nil）：
  /// 通知本身不是 Sendable，先在回调的线程上取出来
  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil,
    _ work: @escaping @MainActor (NoteColorPicker, pid_t?) -> Void
  ) {
    let token = center.addObserver(forName: name, object: object, queue: .main) {
      [weak self] note in
      let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .processIdentifier
      MainActor.assumeIsolated {
        if let self { work(self, app) }
      }
    }
    observers.append((center, token))
  }

  /// 颜色 → sRGB 的 0xRRGGBB（取色面板可能给 P3 / 灰度 / 别的色彩空间的；转不过去给 nil）
  static func rgb(of color: NSColor) -> Int? {
    guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
    let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
    return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8
      | channel(rgb.blueComponent)
  }

  // MARK: 最近用过

  /// 最近用过的自定义纸色（色值，最近的在前）
  static func recentColors(in defaults: UserDefaults = .standard) -> [Int] {
    (defaults.stringArray(forKey: Prefs.notesRecentColors) ?? []).compactMap(Note.rgb(hex:))
  }

  /// 挑了一次：挪到最前、去重、留 recentLimit 个
  static func remember(_ rgb: Int, in defaults: UserDefaults = .standard) {
    let list = [rgb] + recentColors(in: defaults).filter { $0 != rgb }
    defaults.set(list.prefix(recentLimit).map(Note.hex(rgb:)), forKey: Prefs.notesRecentColors)
  }
}
