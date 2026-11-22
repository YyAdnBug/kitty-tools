// 设置 › 键位映射。选择键盘后编辑它的系统映射规则。

import SwiftUI

struct KeyRemappingTab: View {
  let remapping: KeyRemapping
  @State private var keyboardID: String?
  @State private var source: UInt64?
  @State private var target: UInt64?
  @State private var customSource = ""
  @State private var customTarget = ""

  var body: some View {
    Form {
      Section {
        Picker("键盘", selection: $keyboardID) {
          Text("选择键盘").tag(nil as String?)
          ForEach(remapping.keyboards) { keyboard in
            if remapping.connected.contains(where: { $0.id == keyboard.id }) {
              Text(verbatim: keyboard.name).tag(keyboard.id)
            } else {
              Text("\(keyboard.name)（未连接）").tag(keyboard.id)
            }
          }
        }
        .settingsAnchor(.keyRemappingKeyboard)

        if let problem = remapping.configProblem {
          Text(verbatim: problem).foregroundStyle(.secondary)
        }
        if let keyboardID, let problem = remapping.problems[keyboardID] {
          LabeledContent {
            if problem.needsInputMonitoring {
              Button("打开输入监听设置") { Permissions.Kind.inputMonitoring.openSettings() }
            }
          } label: {
            Text(verbatim: problem.message)
          }
        }
      }
      if let keyboard = remapping.keyboards.first(where: { $0.id == keyboardID }) {
        rules(for: keyboard)
      }
      PluginAboutSection(plugin: .keyRemapping)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
    .onAppear { remapping.refresh(recheck: true) }
    .onSettingsBecameKey { remapping.refresh(recheck: true) }
  }

  private func rules(for keyboard: RemapKeyboard) -> some View {
    let saved = remapping.rules(for: keyboard)
    let from = source == 0 ? HIDKey.customID(customSource) : source
    let to = target == 0 ? HIDKey.customID(customTarget) : target
    let updatesExisting = saved.contains { $0.source == from }
    return Section {
      ForEach(saved) { rule in
        LabeledContent {
          Button {
            remapping.remove(rule, from: keyboard)
          } label: {
            Image(systemName: "minus.circle")
          }
          .accessibilityLabel(Text("移除映射"))
        } label: {
          Text(verbatim: "\(HIDKey.title(rule.source)) → \(HIDKey.title(rule.target))")
        }
      }
      keyPicker("源键", selection: $source, custom: $customSource)
      keyPicker("目标键", selection: $target, custom: $customTarget)
      Button(updatesExisting ? "更新映射" : "添加映射") {
        if let from, let to, from != to {
          remapping.save(RemapRule(source: from, target: to), for: keyboard)
        }
      }
      .disabled(from == nil || to == nil || from == to)
    } header: {
      Text("映射规则")
    }
  }

  @ViewBuilder private func keyPicker(
    _ title: LocalizedStringKey, selection: Binding<UInt64?>, custom: Binding<String>
  ) -> some View {
    Picker(title, selection: selection) {
      Text("选择键位").tag(nil as UInt64?)
      Section("功能键") { keyOptions(HIDKey.functionKeys) }
      Section("修饰键") { keyOptions(HIDKey.modifiers) }
      Section("字母、数字和符号") { keyOptions(HIDKey.typing) }
      Section("导航键") { keyOptions(HIDKey.navigation) }
      Section("数字小键盘") { keyOptions(HIDKey.keypad) }
      Section("媒体键") { keyOptions(HIDKey.media) }
      Text("自定义 HID 用法").tag(UInt64(0))
    }
    if selection.wrappedValue == 0 {
      TextField("HID 用法编号", text: custom, prompt: Text(verbatim: "0x700000073"))
      if !custom.wrappedValue.isEmpty, HIDKey.customID(custom.wrappedValue) == nil {
        Text("请输入有效的十六进制 HID 用法编号").foregroundStyle(.secondary)
      }
    }
  }

  private func keyOptions(_ keys: [HIDKey]) -> some View {
    ForEach(keys) { key in
      Text(verbatim: key.title).tag(key.id)
    }
  }
}
