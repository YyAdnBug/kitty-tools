// 快捷键录制框（N13，对标 Raycast / KeyboardShortcuts）：输入框式的圆角框，键位用 Whisker 键帽显示，
// 没有键时写占位「按下快捷键」；点一下开始录（品牌粉焦点环，按住的修饰键实时显示成键帽），按下组合即保存并重新注册，
// Esc 取消、⌫ 清除；右侧 ⓧ 清除（录制中是取消），「恢复默认」在右键菜单里。录制期间注销全部全局热键。
// 不按组合一刀切：直接尝试注册，注册失败的原因由那一行自己显示（HotKeyCenter.failureMessage）；
// 录制时的提示（缺修饰键、各 App 通用的编辑键如 ⌘C、和别的动作重复）经 message 交给那一行，同样显示在行下面，
// 并主动发 VoiceOver 播报。
// 录制时快速按两下同一个修饰键 = 连按两下（拍板 B7，ModifierTaps 认；显示两个键帽「⌘ ⌘」），录上后那一行下面提醒一句
// 可能和谁撞（B6：⇧ 是输入法切中英文，别的是系统听写）。一个动作只有一个快捷键，组合和连按二选一。
// 也录截图时的快捷键（2026-11-06 拍板 A，KeyTarget.shot）：单个键、带不带修饰键都行，规矩在 ShotKey.problem；
// 不认连按。录的时候全局热键同样停着（不然按 ⌥A 会开截图）。
// 也录启动器「命令和别名」里每条命令的快捷键（脚本命令第三轮 D1，KeyTarget.command）：规矩同全局动作（要带修饰键、不收通用
// 编辑键），不认连按；和全局动作、别的命令一起查重（两边都查）。

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 录制框录的是哪一个：全局动作，或截图时的一个键
enum KeyTarget: Hashable {
  case global(HotKeyAction)
  case shot(ShotKey)
  /// 「命令和别名」里的一条命令（编号、名字）
  case command(id: String, title: String)

  var title: String {
    switch self {
    case .global(let action): action.title
    case .shot(let key): key.title
    case .command(_, let title): title
    }
  }

  /// 现在的键（nil = 没设 / 清除了）
  var current: HotKey? {
    switch self {
    case .global(let action): action.hotKey
    case .shot(let key): key.key()
    case .command(let id, _): LauncherModel.savedCommandHotKeys()[id]
    }
  }

  var defaultKey: HotKey? {
    switch self {
    case .global(let action): action.defaultHotKey
    case .shot(let key): key.defaultKey
    case .command: nil
    }
  }
}

struct HotKeyRecorder: View {
  let target: KeyTarget
  let center: HotKeyCenter
  /// 录制时的提示，显示在那一行下面
  @Binding var message: String?
  /// 设好的组合（UserDefaults 不可观察：这里记一份，save 时改；同步、导入改了偏好后热键中心会 reload，跟着重读）
  @State private var current: HotKey?
  @State private var monitor: Any?
  /// 录制中按住的修饰键（例如「⌥⇧」）
  @State private var held = ""
  /// 录制中认连按两下修饰键
  @State private var taps = ModifierTaps()

  /// 框的宽（「命令和别名」的表里窄一些）
  var width: CGFloat = 164

  init(
    target: KeyTarget, center: HotKeyCenter, message: Binding<String?>, width: CGFloat = 164
  ) {
    self.target = target
    self.center = center
    self.width = width
    _message = message
    _current = State(initialValue: target.current)
  }

  private var isRecording: Bool { center.recording == target }

  var body: some View {
    HStack(spacing: 2) {
      Button(action: toggle) {
        HStack {
          if isRecording, !held.isEmpty {
            KeyCombo(held)
          } else if !isRecording, let current {
            KeyCombo(current.display)
          } else {
            Text(isRecording ? "按下快捷键…" : "按下快捷键")
              .foregroundStyle(
                isRecording ? AnyShapeStyle(Style.brandInk) : AnyShapeStyle(.tertiary))
          }
          Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(target.title)的快捷键")
      .accessibilityValue(isRecording ? "正在录制" : current?.display ?? "未设置")
      .accessibilityHint(isRecording ? "按下新的组合，Esc 取消" : "按下后录制新的快捷键")
      if isRecording || current != nil {
        Button(isRecording ? "取消录制" : "清除快捷键", systemImage: "xmark.circle.fill") {
          if isRecording { stop() } else { save(nil) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(isRecording ? "取消录制（Esc）" : "清除")
        .padding(.trailing, 6)
      }
    }
    .font(.system(size: 12))
    .frame(width: width, height: 26)
    // 录制中就是拿着焦点：和其它输入框同一个焦点环（Whisker §3「输入框焦点」）
    .modifier(InputBox(isFocused: isRecording))
    .contextMenu {
      Button("恢复默认") { save(target.defaultKey) }
        .disabled(current == target.defaultKey)
      Button("清除") { save(nil) }
        .disabled(current == nil)
    }
    .onChange(of: center.generation) { current = target.current }
    .onChange(of: center.recording) { _, recording in
      // 点了别的录制框：这里停止监听、收掉这一行录错的提示，热键由那一个录完再恢复
      if recording != target, monitor != nil {
        removeMonitor()
        message = nil
      }
    }
    // 设置窗失去键盘（切到别的 App、点了钉图、关窗）就停：不然全局热键一直停着。只看设置窗自己（普通 NSWindow；
    // 浮层、截图遮罩、钉图都是 NSPanel，它们失去 key 不相干）。录制中从菜单栏开截图、key 让给遮罩也不停：
    // 停了会重新注册热键，框选中按别的热键会弹出浮层抢走遮罩的 key；框选完 frozenSelection 把 key 还给设置窗，接着录
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      note in
      guard isRecording, !(note.object is NSPanel),
        !OverlayPanel.isSelectingRegion(in: NSApp.windows)
      else { return }
      stop()
    }
    .onDisappear { if isRecording { stop() } }
    // 录制被拒（缺修饰键、通用编辑键、重复）只在行下改橙字，VoiceOver 看不到：主动播报
    .onChange(of: message) { _, text in
      if let text { AccessibilityNotification.Announcement(text).post() }
    }
  }

  private func toggle() {
    if isRecording { stop() } else { start() }
  }

  private func start() {
    message = nil
    held = ""
    taps = ModifierTaps()
    center.recording = target
    center.suspend()
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      // 录制中从菜单栏开了截图框选：按键归遮罩（Esc 取消框选），不录进快捷键
      if event.window is SelectionOverlay { return event }
      MainActor.assumeIsolated { handle(event) }
      return nil
    }
  }

  private func handle(_ event: NSEvent) {
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    if event.type == .flagsChanged {
      held = Self.symbols(flags)
      if case .global = target,
        let tap = taps.handle(flags: event.modifierFlags, at: event.timestamp)
      {
        save(HotKey(doubleTap: tap.key))
      }
      return
    }
    taps = ModifierTaps()  // 按了别的键：前面按过的修饰键不算连按的第一下
    switch Int(event.keyCode) {
    case kVK_Escape where flags.isEmpty:
      stop()
    case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
      save(nil)
    default:
      // 截图时的键：单个键也行，固定的键、重复的由 save 里的 ShotKey.problem 拒
      if case .shot = target {
        return save(HotKey(keyCode: event.keyCode, flags: event.modifierFlags))
      }
      if let hotKey = HotKey(event: event) {
        save(hotKey)
      } else {
        message = "要带 ⌘、⌃ 或 ⌥（F1–F20 可以单独用），或者连按两下一个修饰键"
      }
    }
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    held = ""
  }

  private func stop() {
    removeMonitor()
    guard isRecording else { return }
    message = nil
    center.recording = nil
    center.reload()
  }

  private func save(_ hotKey: HotKey?) {
    if case .command(let id, _) = target { return saveCommand(hotKey, id: id) }
    guard case .global(let action) = target else {
      if case .shot(let key) = target {
        if let hotKey, let problem = ShotKey.problem(with: hotKey, for: key) {
          message = problem
          return
        }
        key.set(hotKey)
      }
      current = hotKey
      message = nil
      if isRecording { stop() } else if center.recording == nil { center.reload() }
      return
    }
    // ⌘C、⌘V 这类各 App 通用的键设成全局热键，会在所有 App 里被吞掉：拒绝，继续录
    if let hotKey, hotKey.isReservedEditKey {
      message = "这是各 App 通用的快捷键，设成全局会让它在所有 App 里失效"
      return
    }
    // 关着的功能的键也算（isAvailable，不是 isActive）：不然它重新打开时两个动作抢同一个组合，后注册的那个失败
    if let hotKey,
      let other = HotKeyAction.allCases.first(where: {
        $0 != action && $0.isAvailable && $0.hotKey == hotKey
      })
    {
      message =
        other.isActive
        ? "和「\(other.title)」重复" : "和「\(other.title)」重复（\(other.feature?.title ?? "它")已关闭）"
      return
    }
    // 和「命令和别名」里某条命令的快捷键重复（第三轮 D1）
    if let hotKey, let other = Self.commandOwner(of: hotKey, except: nil) {
      message = "和启动器命令「\(other)」重复"
      return
    }
    action.hotKey = hotKey
    current = hotKey
    message = nil
    // 别的行正在录（点了这一行的 ⓧ 或右键菜单）：热键先别恢复，等那一行录完 stop 时一起重新注册
    if isRecording { stop() } else if center.recording == nil { center.reload() }
    if let key = hotKey?.doubleTap { message = key.hint }
  }

  /// 命令的快捷键：同全局动作的规矩，和全局动作、别的命令查重；存进「命令和别名」的那段 JSON
  private func saveCommand(_ hotKey: HotKey?, id: String) {
    if let hotKey, hotKey.isReservedEditKey {
      message = "这是各 App 通用的快捷键，设成全局会让它在所有 App 里失效"
      return
    }
    if let hotKey,
      let other = HotKeyAction.allCases.first(where: { $0.isAvailable && $0.hotKey == hotKey })
    {
      message = "和「\(other.title)」重复"
      return
    }
    if let hotKey, let other = Self.commandOwner(of: hotKey, except: id) {
      message = "和「\(other)」重复"
      return
    }
    LauncherModel.setCommandHotKey(hotKey, for: id)
    current = hotKey
    message = nil
    if isRecording { stop() } else if center.recording == nil { center.reload() }
  }

  /// 哪条命令用了这个组合（名字）
  private static func commandOwner(of hotKey: HotKey, except id: String?) -> String? {
    LauncherModel.savedCommandHotKeys()
      .first { $0.key != id && $0.value == hotKey }
      .map { LauncherModel.commandTitle($0.key) }
  }

  /// 修饰键按系统菜单的顺序：⌃⌥⇧⌘
  private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
    [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { flags.contains($0.0) }.map(\.1).joined()
  }
}
