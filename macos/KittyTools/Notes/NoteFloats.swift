// 同时浮在屏幕上的几张便签（便签未来计划 C1–C4，2026-10-22；规矩在 mac-overlay-panel §12「浮动便签」）。
// **每张一个 NoteFloat**（窗口、模型、状态机都是一张的：拖出来、落下、挪、拉大小、收回、替身退场照旧），这里管集合：
// - 上限 limit 张（拍板 C1：5）。再浮一张时把**最久没碰的**那张收回边缘，刘海岛说是哪张。「碰」= 面板当上 key、
//   被叫到前面、按着把手挪、刚浮出来（touch：挪到 floats 的末尾）。
// - 按编号找、建、放：浮着的那条再浮一次 = 叫到前面；一张收回 / 没了，从集合里拿掉（面板它自己放）。
// - **收回拿着键盘的那一张之后，键盘还给原来的 App**（拍板 C3）：AppKit 会自己把 key 交给另一块浮动面板（独立小程序实测，
//   macos/build/research/notes-roadmap-2026-10-19/multifloat-repro/：B 收回后 C 当上 key、一直不放），本 App 又不在前台
//   （不激活的面板）——这时调一次 NSApp.deactivate()：本进程谁都不是 key，键盘回到前台的 App。本 App 真在前台
//   （人在用全部便签窗口）时不管：AppKit 交给哪扇自家窗口都对。
// - 固定着的**每一张**都记位置（Prefs.notesFloatPlaces，一组 {id, frame}，这台电脑自己的、不注册默认值；0.6.0 之前只记
//   一张的 notesFloatPlace 读成一条、删掉），重启后都回来、都不当 key（拍板 C4）。「全部收回」先不做。
// 那叠（NoteEdge 转过来）、全部便签窗口、AppDelegate 都拿它，不拿单张。

import AppKit
import Observation

@Observable final class NoteFloats {
  /// 最多同时浮几张
  static let limit = 5

  /// 浮着的几张，最久没碰的在前
  private(set) var floats: [NoteFloat] = []
  /// 屏幕边缘现在有没有那叠（菜单里那一项叫「收回边缘」还是「取消浮动」）
  private(set) var edgeShown = true

  /// 浮着的便签的编号（那叠的标签上的记号、菜单里那一项叫什么）
  var floatingIDs: Set<String> { Set(floats.compactMap(\.model.state.noteID)) }

  @ObservationIgnored let store: NoteStore
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let island: Island?
  @ObservationIgnored private let takesKeyboard: Bool
  @ObservationIgnored private let animates: Bool
  @ObservationIgnored private var options = NoteDeckOptions()
  /// 现在接着的显示器（单测给一块离所有屏幕很远的）
  @ObservationIgnored var screens: () -> [NoteDeckScreen] = { NoteDeckScreen.attached() }
  /// 屏幕边缘的那叠在哪条边（同 NoteFloat.homeEdge）
  @ObservationIgnored var homeEdge: (CGRect) -> NoteDeckOptions.Edge? = { _ in nil }
  /// 浮着的多了一张 / 少了一张 / 换了位置（NoteEdge 据此告诉各块屏的那叠）
  @ObservationIgnored var onChange: () -> Void = {}
  /// 有一张的面板放掉了（NoteEdge 转给 AppDelegate 排空闲回收）
  @ObservationIgnored var onHide: () -> Void = {}
  /// 新的一张建出来时给它的模型接线（NoteEdge：在全部便签里打开、设置、颜色菜单的那两样）
  @ObservationIgnored var configure: (NoteFloat) -> Void = { _ in }

  init(
    store: NoteStore, defaults: UserDefaults = .standard, island: Island?,
    takesKeyboard: Bool = true, animates: Bool = true
  ) {
    self.store = store
    self.defaults = defaults
    self.island = island
    self.takesKeyboard = takesKeyboard
    self.animates = animates
  }

  /// 这条便签正浮着的那一张
  func float(of id: String) -> NoteFloat? { floats.first { $0.model.state.noteID == id } }

  /// 正被拖出来、还没松手的那一张
  private var dragging: NoteFloat? { floats.first { $0.model.state.isDragging } }

  // MARK: 浮出来、收回去

  /// 从那叠里拖出来，过了阈值（鼠标还按着）：新的一张在它原来的地方出来，之后跟着鼠标走
  func detach(_ id: String, from origin: NoteFloat.Origin, at pointer: CGPoint) {
    guard dragging == nil, float(of: id) == nil else { return }
    let float = make()
    float.detach(id, from: origin, at: pointer)
    admit(float, id)
  }

  func drag(to pointer: CGPoint) { dragging?.drag(to: pointer) }

  func drop(at pointer: CGPoint) { dragging?.drop(at: pointer) }

  /// 不靠拖浮出来（操作菜单、全部便签窗口）：已经浮着的就叫到前面
  func present(
    _ id: String, from origin: NoteFloat.Origin? = nil, mouse: CGPoint = NSEvent.mouseLocation
  ) {
    guard dragging == nil else { return }
    if let existing = float(of: id) { return existing.focus() }
    let float = make()
    float.present(id, from: origin, mouse: mouse)
    admit(float, id)
  }

  /// 全部便签窗口的「浮在屏幕上」/「收回边缘」
  func toggle(_ id: String) {
    if let existing = float(of: id) { existing.model.close() } else { present(id) }
  }

  /// 把浮着的这条叫到前面、给它键盘（点了那叠里它的标签、「新建便签」落在它身上）
  func focus(_ id: String) { float(of: id)?.focus() }

  /// 重启后：固定着浮在屏幕上的那几张回到原处（都不当 key）。记着的那条不在了、不固定了就不回来；一块屏都没有时
  /// 什么都不动（记着的留着）
  func restore() {
    let screens = screens()
    guard !screens.isEmpty else { return }
    var places = (defaults.array(forKey: Prefs.notesFloatPlaces) ?? []).compactMap {
      NoteFloatLayout.Place(stored: $0)
    }
    // 0.6.0 之前只记一张
    if let old = NoteFloatLayout.Place(stored: defaults.object(forKey: Prefs.notesFloatPlace)),
      !places.contains(where: { $0.id == old.id })
    {
      places.append(old)
    }
    for place in places where floats.count < Self.limit && float(of: place.id) == nil {
      guard let frame = NoteFloatLayout.restored(place, note: store.note(place.id), in: screens)
      else { continue }
      let float = make()
      float.restore(place.id, frame: frame)
      admit(float, place.id)
    }
    defaults.removeObject(forKey: Prefs.notesFloatPlace)
    persist()
  }

  // MARK: 跟着变（NoteEdge 转过来的）

  func update(options: NoteDeckOptions, edgeShown: Bool) {
    self.options = options
    if self.edgeShown != edgeShown { self.edgeShown = edgeShown }
    for float in floats { float.update(options: options, edgeShown: edgeShown) }
  }

  /// 仓库里的便签变了：没了的那几张关掉；固定变了，记着的位置跟着变（打字时差不多每一下都来：只 reconcile、写一次）
  func storeChanged() {
    for float in floats { float.model.reconcile() }
    persist()
  }

  /// 长截图开始 / 结束：压在选区上的那几张让开、放回（同钉图）
  func suspend(covering region: CGRect) {
    for float in floats { float.suspend(covering: region) }
  }

  func resume() {
    for float in floats { float.resume() }
  }

  // MARK: 集合

  private func make() -> NoteFloat {
    let float = NoteFloat(
      store: store, defaults: defaults, island: island, takesKeyboard: takesKeyboard,
      animates: animates)
    float.screens = { [weak self] in self?.screens() ?? [] }
    float.homeEdge = { [weak self] in self?.homeEdge($0) }
    float.update(options: options, edgeShown: edgeShown)
    float.onChange = { [weak self, weak float] in
      if let self, let float { stateChanged(of: float) }
    }
    float.onHide = { [weak self] in self?.onHide() }
    float.onTouch = { [weak self, weak float] in
      if let self, let float { touch(float) }
    }
    float.onPersist = { [weak self] in self?.persist() }
    float.onKeyReleased = { Self.returnKeyboard() }
    configure(float)
    return float
  }

  /// 新的一张浮起来了就收进集合（没浮起来——便签不能浮——就扔掉）；多过上限，最久没碰的那张收回边缘
  private func admit(_ float: NoteFloat, _ id: String) {
    guard float.model.state.noteID == id else { return }
    floats.append(float)
    while floats.count > Self.limit,
      let oldest = floats.first(where: { $0 !== float && !$0.model.state.isDragging })
    {
      let title = oldest.model.current?.displayTitle ?? Note.untitled
      oldest.model.close()
      floats.removeAll { $0 === oldest }
      island?.show(
        "最多同时浮 \(Self.limit) 张", detail: "「\(title)」收回了边缘", tone: .info,
        symbol: "rectangle.stack")
    }
    persist()
    onChange()
  }

  /// 碰了一下：挪到最后（最近碰过的）
  private func touch(_ float: NoteFloat) {
    guard floats.last !== float, let index = floats.firstIndex(where: { $0 === float }) else {
      return
    }
    floats.append(floats.remove(at: index))
  }

  /// 一张的状态变了：收回 / 没了的从集合里拿掉
  private func stateChanged(of float: NoteFloat) {
    if float.model.state.noteID == nil { floats.removeAll { $0 === float } }
    persist()
    onChange()
  }

  /// 固定着的那几张在哪（和记着的一样就不写）
  private func persist() {
    let stored = floats.compactMap(\.place).map(\.stored)
    if stored.isEmpty {
      // 存坏了的（不是一组字典）也清掉
      if defaults.object(forKey: Prefs.notesFloatPlaces) != nil {
        defaults.removeObject(forKey: Prefs.notesFloatPlaces)
      }
    } else if defaults.array(forKey: Prefs.notesFloatPlaces) as? [[String: String]] != stored {
      defaults.set(stored, forKey: Prefs.notesFloatPlaces)
    }
  }

  /// 收走了拿着键盘的那块（浮动便签收回、那叠里的便签关掉）：AppKit 会把 key 交给之前当过 key 的另一块自家面板
  /// （另一张浮动便签、那叠）——本 App 不在前台时 deactivate 一次，键盘回到前台的 App（见文件头）。本 App 在前台
  /// （人在用全部便签窗口）时不管。会被失活收走的窗口都设了 hidesOnDeactivate = false（替身、刘海岛、常驻缩略图……）
  static func returnKeyboard() {
    guard NSApp.keyWindow != nil,
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        != NSRunningApplication.current.processIdentifier
    else { return }
    NSApp.deactivate()
  }
}
