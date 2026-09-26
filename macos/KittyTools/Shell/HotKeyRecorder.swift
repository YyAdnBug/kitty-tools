// 快捷键录制框（N13，对标 Raycast / KeyboardShortcuts）：输入框式的圆角框，键位用 Whisker 键帽显示，
// 没有键时写占位「按下快捷键」；点一下开始录（品牌粉焦点环，按住的修饰键实时显示成键帽），按下组合即保存并重新注册，
// Esc 取消、⌫ 清除；右侧 ⓧ 清除（录制中是取消），「恢复默认」在右键菜单里。录制期间注销全部全局热键。
// 不按组合一刀切：直接尝试注册，注册失败的原因由那一行自己显示（HotKeyCenter.failureMessage）；
// 录制时的提示（缺修饰键、和别的动作重复）经 message 交给那一行，同样显示在行下面。

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorder: View {
  let action: HotKeyAction
  let center: HotKeyCenter
  /// 录制时的提示，显示在那一行下面
  @Binding var message: String?
  /// 设好的组合（UserDefaults 不可观察：只经 save 改，这里跟着记一份）
  @State private var current: HotKey?
  @State private var monitor: Any?
  /// 录制中按住的修饰键（例如「⌥⇧」）
  @State private var held = ""
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  init(action: HotKeyAction, center: HotKeyCenter, message: Binding<String?>) {
    self.action = action
    self.center = center
    _message = message
    _current = State(initialValue: action.hotKey)
  }

  private var isRecording: Bool { center.recording == action }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
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
      .accessibilityLabel("\(action.title)的快捷键")
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
        .padding(.trailing, 5)
      }
    }
    .font(.system(size: 12))
    .frame(width: 164, height: 26)
    .background(fieldFill, in: shape)
    .overlay(
      shape.strokeBorder(
        isRecording
          ? Style.brand.opacity(0.55) : Color.primary.opacity(contrast == .increased ? 0.25 : 0.08),
        lineWidth: isRecording || contrast == .increased ? 1 : 0.5)
    )
    // 焦点外发光：框外一圈粉 0.18、3 pt（Whisker §3 状态「输入框焦点」）
    .background {
      if isRecording {
        RoundedRectangle(cornerRadius: Style.Radius.card + 3, style: .continuous)
          .strokeBorder(Style.brand.opacity(0.18), lineWidth: 3)
          .padding(-3)
      }
    }
    .contextMenu {
      Button("恢复默认") { save(action.defaultHotKey) }
        .disabled(current == action.defaultHotKey)
      Button("清除") { save(nil) }
        .disabled(current == nil)
    }
    .onChange(of: center.recording) { _, recording in
      // 点了别的录制框：这里停止监听，热键由那一个录完再恢复
      if recording != action { removeMonitor() }
    }
    // 设置窗失去键盘（切到别的 App、关窗）就停：不然全局热键一直停着
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
      if isRecording { stop() }
    }
    .onDisappear { if isRecording { stop() } }
  }

  /// 输入框底：primary 0.045（深色 0.07）
  private var fieldFill: Color { Color.primary.opacity(scheme == .dark ? 0.07 : 0.045) }

  private func toggle() {
    if isRecording { stop() } else { start() }
  }

  private func start() {
    message = nil
    held = ""
    center.recording = action
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
      return
    }
    switch Int(event.keyCode) {
    case kVK_Escape where flags.isEmpty:
      stop()
    case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
      save(nil)
    default:
      if let hotKey = HotKey(event: event) {
        save(hotKey)
      } else {
        message = "要带 ⌘、⌃ 或 ⌥（F1–F20 可以单独用）"
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
    if let hotKey,
      let other = HotKeyAction.allCases.first(where: { $0 != action && $0.hotKey == hotKey })
    {
      message = "和「\(other.title)」重复"
      return
    }
    action.hotKey = hotKey
    current = hotKey
    message = nil
    if isRecording { stop() } else { center.reload() }
  }

  /// 修饰键按系统菜单的顺序：⌃⌥⇧⌘
  private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
    [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { flags.contains($0.0) }.map(\.1).joined()
  }
}
