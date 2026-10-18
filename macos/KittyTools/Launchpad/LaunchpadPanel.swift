// 启动台的全屏面板（SPEC §8）。自建窗口例外：它要盖住整块屏（菜单栏、程序坞都在下面）、要当 key 收按键、无边框、
// 不激活本 App——和浮层的 OverlayPanel 没有交集（不居中、不点外关闭、没有 16 pt 圆角材质），所以单独子类化。
// - 层级 statusBar（高过菜单栏 mainMenu / 程序坞；低于截图的遮罩 popUpMenu+1），所有桌面和别的 App 的全屏里都能出。
// - 不调 NSApp.activate：makeKey 只把键盘拿过来，前台 App 不变（同 NoteDeckPanel 的做法）。
// - 背景 NSVisualEffectView `.fullScreenUI` 把整块桌面模糊掉，上面再压一层黑（SwiftUI 里画）；macOS 26 上同一块材质
//   仍可用，不另起玻璃分支（它不是 Panel / HUD / Island 三种皮肤里的一种，见 mac-whisker-launchpad）。
// - 滚轮 / 两指滑动从 sendEvent 进（不装事件监听）；⌘←/⌘→ 第一页 / 最后一页；其余方向键、↩、Esc 由搜索框的
//   doCommandBy 或这里的 keyDown 两支收（焦点在搜索框时是前一支）。

import AppKit
import SwiftUI

final class LaunchpadPanel: NSPanel {
  var onScroll: ((NSEvent) -> Void)?
  var onNavigate: ((LaunchpadDirection) -> Void)?
  var onReturn: (() -> Void)?
  var onCancel: (() -> Void)?
  var onFirstPage: (() -> Void)?
  var onLastPage: (() -> Void)?
  var onCloseRequest: (() -> Void)?

  private let host: NSHostingView<LaunchpadView>

  init(frame: NSRect, model: LaunchpadModel) {
    host = LaunchpadHost(rootView: LaunchpadView(model: model))
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    animationBehavior = .none
    acceptsMouseMovedEvents = true
    worksWhenModal = true

    let effect = NSVisualEffectView(frame: frame)
    effect.material = .fullScreenUI
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.autoresizingMask = [.width, .height]
    host.sizingOptions = []
    host.frame = effect.bounds
    host.autoresizingMask = [.width, .height]
    effect.addSubview(host)
    contentView = effect
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// 无边框全屏窗口别被系统挪到菜单栏下面
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  /// 两指滑动 / 滚轮只给翻页；别的事件照常派发（搜索框、按钮）
  override func sendEvent(_ event: NSEvent) {
    if event.type == .scrollWheel {
      onScroll?(event)
      return
    }
    super.sendEvent(event)
  }

  /// ⌘← / ⌘→ 第一页 / 最后一页（焦点在搜索框里也先到这里）；⌘W 收起
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.keyCode == 123 {
      onFirstPage?()
      return true
    }
    if flags == .command, event.keyCode == 124 {
      onLastPage?()
      return true
    }
    if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
      onCloseRequest?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// 焦点不在搜索框里时的方向键、↩、Esc
  override func keyDown(with event: NSEvent) {
    switch Int(event.keyCode) {
    case 123: onNavigate?(.left)
    case 124: onNavigate?(.right)
    case 125: onNavigate?(.down)
    case 126: onNavigate?(.up)
    case 36, 76: onReturn?()
    case 53: onCancel?()
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 第一下点击就给内容（本 App 不在前台时也一样）
private final class LaunchpadHost: NSHostingView<LaunchpadView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
