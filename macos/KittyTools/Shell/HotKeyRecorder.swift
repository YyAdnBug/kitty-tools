// 快捷键录制控件：点一下开始录，按下组合即保存并重新注册；Esc 取消。录制期间注销全部全局热键。
// 不按组合一刀切：直接尝试注册，注册失败把 OSStatus 翻译成提示。

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorder: View {
  let action: HotKeyAction
  let center: HotKeyCenter
  @State private var isRecording = false
  @State private var monitor: Any?
  @State private var message: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(spacing: 6) {
        Button(isRecording ? "请按下快捷键…" : action.hotKey?.display ?? "未设置") {
          isRecording ? stop() : start()
        }
        .frame(minWidth: 110)
        if action.hotKey != nil {
          Button("清除") { save(nil) }
        }
        if action.hotKey != action.defaultHotKey {
          Button("恢复默认") { save(action.defaultHotKey) }
        }
      }
      if let text = message ?? center.failures[action].map(Self.describe) {
        Text(text).font(.caption).foregroundStyle(.red)
      }
    }
    .onDisappear(perform: stop)
  }

  private func start() {
    message = nil
    isRecording = true
    center.suspend()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // 录制中从菜单栏开了截图框选：按键归遮罩（Esc 取消框选），不录进快捷键
      if event.window is SelectionOverlay { return event }
      MainActor.assumeIsolated {
        if Int(event.keyCode) == kVK_Escape {
          stop()
        } else if let hotKey = HotKey(event: event) {
          save(hotKey)
        } else {
          message = "要带 ⌘、⌃ 或 ⌥（F1–F20 可以单独用）"
        }
      }
      return nil
    }
  }

  private func stop() {
    guard isRecording else { return }
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    isRecording = false
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
    message = nil
    if isRecording { stop() } else { center.reload() }
  }

  private static func describe(_ status: OSStatus) -> String {
    switch Int(status) {
    case eventHotKeyInvalidErr: "注册失败：当前系统（15.0 / 15.1）不支持只带 ⌥ 的组合"
    case eventHotKeyExistsErr: "注册失败：组合已被本 App 占用"
    default: "注册失败（错误 \(status)）"
    }
  }
}
