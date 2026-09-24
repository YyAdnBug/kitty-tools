// 不激活前台的浮层（NSPanel）：剪贴板面板、翻译浮窗共用这一个类，各建一个实例（PLAN §4）。
// 显示只 orderFrontRegardless + makeKey，永远不调 NSApp.activate：前台 App 保持不变，
// 粘贴时发的 ⌘V、划词时发的 ⌘C 才会落到它身上。

import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
  enum AutoHide {
    /// 点本 App 浮层以外的地方就关（剪贴板面板）；Esc 固定时也关
    case clickOutside
    /// 失去 key 就关（翻译浮窗）；固定时 Esc 也不关
    case resignKey
  }

  var onHide: (() -> Void)?
  /// 这次显示前处于 key 的自家浮层：收起时把 key 还给它（翻译浮窗用）
  private(set) weak var previousKeyPanel: OverlayPanel?
  /// ⌘ 组合键先给它处理，返回 true 表示已处理
  var keyEquivalentHandler: ((NSEvent) -> Bool)?
  private let autoHide: AutoHide
  private let isPinned: () -> Bool
  private let centersOnEveryShow: Bool
  /// 启动器：每次都放在鼠标所在屏、顶边在可见区 20% 处，高度随内容往下伸缩
  private let topAnchored: Bool
  private var mouseMonitors: [Any] = []

  /// - Parameters:
  ///   - minSize: 传了就允许调整大小
  ///   - autosaveName: 传了就记住位置和大小（首次居中）；不传则每次显示都居中到鼠标所在屏幕
  ///   - topAnchored: 放在屏幕上部（启动器），配合 setContentHeight 伸缩
  init<Content: View>(
    size: NSSize, minSize: NSSize? = nil, autosaveName: String? = nil, topAnchored: Bool = false,
    autoHide: AutoHide, isPinned: @escaping () -> Bool, content: Content
  ) {
    self.autoHide = autoHide
    self.isPinned = isPinned
    centersOnEveryShow = autosaveName == nil
    self.topAnchored = topAnchored
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    var style: StyleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
    if minSize != nil { style.insert(.resizable) }
    super.init(
      contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered,
      defer: true)
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isMovableByWindowBackground = true
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    for button in [ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(button)?.isHidden = true
    }
    if let minSize { contentMinSize = minSize }
    let host = NSHostingView(rootView: content.ignoresSafeArea())
    host.sizingOptions = []  // 窗口大小由这里定，不让 SwiftUI 的理想尺寸反推窗口
    // 系统毛玻璃底：state 必须 .active，本 App 从不激活，跟随窗口状态会一直是灰的非激活外观
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    host.frame = background.bounds
    host.autoresizingMask = [.width, .height]
    background.addSubview(host)
    contentView = background
    if let autosaveName, !setFrameUsingName(autosaveName) { center() }
    if let autosaveName { setFrameAutosaveName(autosaveName) }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// makingKey = false：只露出来、不抢键盘（复制即译），此时靠点外关闭
  func present(makingKey: Bool = true) {
    if !isVisible { placeForShow() }
    orderFrontRegardless()
    if makingKey {
      if let current = NSApp.keyWindow as? OverlayPanel, current !== self {
        previousKeyPanel = current
      }
      makeKey()
      // 首次显示时 SwiftUI 还没建出输入框，先把布局跑完再聚焦
      contentView?.layoutSubtreeIfNeeded()
      if let field = initialFirstResponder { makeFirstResponder(field) }
    }
    if autoHide == .clickOutside || !makingKey, mouseMonitors.isEmpty { installMouseMonitors() }
  }

  func hide() {
    guard isVisible else { return }
    orderOut(nil)
    removeMouseMonitors()
    onHide?()
  }

  func toggle() {
    if isVisible && isKeyWindow { hide() } else { present() }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event) {
      return true
    }
    // 浮层不激活本 App，主菜单的 ⌘C / ⌘V 等不一定收得到：直接发给当前输入框
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      let action = Self.editActions[event.charactersIgnoringModifiers?.lowercased() ?? ""]
    else { return false }
    return NSApp.sendAction(action, to: nil, from: self)
  }

  /// 截图里输入文字时也用它（同样不激活本 App）
  static let editActions: [String: Selector] = [
    "x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
    "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
    "z": Selector(("undo:")),
  ]

  override func cancelOperation(_ sender: Any?) {
    if autoHide == .resignKey && isPinned() { return }
    hide()
  }

  override func resignKey() {
    super.resignKey()
    // key 让给自己的 sheet（确认框等）时不算失焦
    if autoHide == .resignKey, isVisible, attachedSheet == nil, !isPinned() { hide() }
  }

  /// 改高度时顶边不动，只往下伸缩（启动器随结果条数变化）
  func setContentHeight(_ height: CGFloat) {
    guard abs(frame.height - height) > 0.5 else { return }
    var frame = frame
    frame.origin.y = frame.maxY - height
    frame.size.height = height
    setFrame(frame, display: true)
  }

  private func placeForShow() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    if topAnchored {
      let top = visible.maxY - visible.height * 0.2
      setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: top - frame.height))
      return
    }
    // 记住的位置落在某块屏幕里就沿用（拔掉外接屏后才重新居中）
    if !centersOnEveryShow, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) })
    {
      return
    }
    setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
  }

  /// 点外即关：global 监听管别的 App，local 监听管自家窗口。点中任一自家浮层不关（兄弟窗口豁免），
  /// 点击时实时判断；显示时装、隐藏时卸，成对出现
  private func installMouseMonitors() {
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.clickedOutside() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        if !(event.window is OverlayPanel) { self?.clickedOutside() }
      }
      return event
    }
    mouseMonitors = [global, local].compactMap { $0 }
  }

  private func removeMouseMonitors() {
    mouseMonitors.forEach(NSEvent.removeMonitor)
    mouseMonitors = []
  }

  private func clickedOutside() {
    if !isPinned() { hide() }
  }
}
