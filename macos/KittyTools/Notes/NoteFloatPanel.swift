// 浮动便签的面板和它的界面（PLAN §10「便签」拍板 B⑤ C②，第 4 批；规矩在 mac-overlay-panel §12「浮动便签」）：
// 从屏幕边缘那叠里拖出来（或者从操作菜单「浮在屏幕上」）、留在屏幕上的那一张便签。它是「浮层只有 OverlayPanel 一种」
// 的第六个例外——无边框、nonactivating、要当 key 收按键才子类化；和 OverlayPanel 的行为没有交集（不居中、不点外关闭、
// 没有材质底：窗口透明，纸是内容自己画的）。
// - 一扇窗口就是一张便签那么大（不像那叠的面板是一大块透明的）：阴影用系统的窗口阴影（跟着纸的圆角走；改了大小要
//   invalidateShadow），截图的悬停列表里就是整扇窗口。
// - **能拉大小**：styleMask 带 .resizable——无边框的窗口带上它，四边四角就是系统的拉伸区，光标也是系统给的，不另画
//   把手、不自己算；最小 NoteFloatLayout.minSize。挪动不靠系统（没有标题栏）：按着把手拖，NoteFloat 跟着鼠标摆。
// - 层级跟着这条便签固定没固定走（NoteFloat.applyLevel）：固定着在别的窗口上面，没固定是普通窗口。没固定时被别的
//   App 的窗口盖住了，点它要回到前面——不激活的面板在普通层级点一下会不会自己到最前没在真机上看过，这里每次鼠标
//   按下都明说一次（orderFrontRegardless；已经在最前就什么都不发生）。
// - 所有桌面、别的 App 的全屏里都在（同钉图、同那叠里打开的便签：是人自己放在屏幕上的内容；设置里「盖在全屏 App 上」
//   管的是自己待在边上的药丸和「一直展开」的那一列，不管它）。
// - 永远不调 NSApp.activate；点按钮、把手不抢键盘（becomesKeyOnlyIfNeeded），点正文、标题才当 key。
// - 按键、撤销的入口在基类 NotePanel 里（和那叠的面板同一份）。
// - 位置自己管（落下、屏幕变了都夹进可见区，NoteFloatLayout）：constrainFrameRect 原样返回，不让系统再挪一遍。
// 界面（NoteFloatView）就是 NoteSheet 铺满这扇窗口——和那叠里打开的便签同一个视图。

import AppKit
import SwiftUI

final class NoteFloatPanel: NotePanel {
  init(frame: NSRect, model: NoteFloatModel) {
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
      backing: .buffered, defer: true)
    // 没有标题栏，这个名字只给旁白读窗口时用
    title = "浮动便签"
    level = .normal
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = false
    animationBehavior = .none
    minSize = NoteFloatLayout.minSize
    let host = NoteFloatHost(rootView: NoteFloatView(model: model))
    host.sizingOptions = []  // 窗口大小由 NoteFloat 和用户定，不让 SwiftUI 的理想尺寸反推
    contentView = host
    setFrame(frame, display: false)
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  override func sendEvent(_ event: NSEvent) {
    // 没固定时是普通层级：被别的窗口盖住一部分，点它就到前面（不激活本 App）
    if event.type == .leftMouseDown || event.type == .rightMouseDown { orderFrontRegardless() }
    super.sendEvent(event)
  }
}

/// 浮动便签的 SwiftUI 宿主：第一下点击就给内容（点按钮、按把手时面板不是 key、本 App 也不在前台）。
/// 不写成泛型子类（Release 优化时编译器会崩，见 RecordingHUD 的 PassiveHost）
private final class NoteFloatHost: NSHostingView<NoteFloatView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 浮动便签的界面：NoteSheet 铺满窗口（纸、它带着的标签、头部、正文、小字、操作菜单都是那一份）
struct NoteFloatView: View {
  let model: NoteFloatModel
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      if let note = model.current {
        NoteSheet(
          model: model, note: note, metrics: model.metrics, height: proxy.size.height,
          fontSize: Prefs.notesFontSize(fontSize), tabOnLeading: model.tabOnLeading,
          castsShadow: false
        )
        // 一条便签一块编辑区：换一条时光标、滚动位置、撤销栈都从头来
        .id(note.id)
      }
    }
    .symbolEffectsRemoved(reduceMotion)
    .appAccent()
  }
}
