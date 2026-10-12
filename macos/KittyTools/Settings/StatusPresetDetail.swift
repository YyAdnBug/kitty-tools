// 设置 › 状态屏 › 某个状态（详情页，从列表推进来；同 SearchEngineDetail / TranslateServiceDetail 的形式）：
// 页头 40 pt 图标 + 标题 + 摘要（在表单外面，和列表页的页头同一个位置），下面分组表单：标题、说明、图标（一格「无」+ 16 个表情）、样式（三选一，下面一块
// 预览：StatusScreenView.swift 的 StatusPreview，真的画面缩小，表情会动）、电源、自动结束，最后是删除（至少留一个；
// 自己加的、改过的先确认）。
// 改动即时写回偏好里的 JSON 列表（和 StatusScreenTab 读写同一个键），存之前过 StatusPreset.sanitized。
// 输入框绑的是一份草稿：存进偏好的标题 / 说明去了首尾空白、截到上限，边打边收拾会吃掉正在打的空格；标题删光了重打时
// 留着原来的标题（空标题存不下）。有问题（没标题、超长）时页头的摘要换成橙色说明，不拦着改。
// 工具栏「‹ 返回」/ ⌘[ 回列表（SettingsBackButton）。这里没有「进入」「试一下」：进入会拦住键盘鼠标。

import SwiftUI

struct StatusPresetDetail: View {
  let id: String
  /// 截图自检传一份固定的列表：只画，不读不写偏好。正常使用是 nil = 偏好里那份
  var fixed: [StatusPreset]?
  @AppStorage(Prefs.statusScreenPresets) private var data: Data?
  @Environment(\.dismiss) private var dismiss
  /// 正在改的这一份（输入框里的原样）；nil = 还没改过，用存着的
  @State private var draft: StatusPreset?
  @State private var confirmsDelete = false

  static let deleteMessage = "自己加的、改过的状态删掉就找不回来了。"

  var body: some View {
    let list = fixed ?? StatusPreset.decode(data)
    // 删掉之后、退回列表之前的这一帧没有这一条：什么都不画
    if let stored = list.first(where: { $0.id == id }) {
      form(editing: draft ?? stored, stored: stored, isOnly: list.count <= 1)
        .navigationTitle(stored.title)
        .toolbar { SettingsBackButton { dismiss() } }
    }
  }

  private func form(editing: StatusPreset, stored: StatusPreset, isOnly: Bool) -> some View {
    let binding = Binding {
      editing
    } set: {
      draft = $0
      save($0)
    }
    return VStack(spacing: 0) {
      DetailHeader(
        title: stored.title, status: editing.problem ?? stored.summary,
        isProblem: editing.problem != nil
      ) {
        StatusPresetIcon(symbol: stored.symbol, size: 40)
      }
      fields(binding, editing: editing, stored: stored, isOnly: isOnly)
    }
    .confirmationDialog("删除「\(stored.title)」？", isPresented: $confirmsDelete) {
      Button("删除", role: .destructive, action: delete)
    } message: {
      Text(Self.deleteMessage)
    }
  }

  private func fields(
    _ binding: Binding<StatusPreset>, editing: StatusPreset, stored: StatusPreset, isOnly: Bool
  ) -> some View {
    Form {
      Section {
        TextField("标题", text: binding.title, prompt: Text("如 马上回来"))
        TextField(
          "说明",
          text: Binding {
            editing.detail ?? ""
          } set: {
            binding.wrappedValue.detail = $0
          }, prompt: Text("可不填"))
        LabeledContent("图标") { SymbolGrid(selection: binding.symbol) }
      } footer: {
        SectionFootnote(
          "标题最多 \(StatusPreset.maxTitle) 个字，说明最多 \(StatusPreset.maxDetail) 个字。")
      }
      Section {
        Picker(selection: binding.style) {
          ForEach(StatusPreset.Look.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: {
          Text("样式")
          Text(editing.style.explanation)
        }
        .pickerStyle(.segmented)
        StatusPreview(preset: stored, animated: true)
      }
      Section {
        Picker("电源", selection: binding.power) {
          ForEach(StatusPreset.Power.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        // 横排单选包进 LabeledContent：贴着右边线（同设置 › 剪贴板「图片最多占用」）
        LabeledContent("自动结束") {
          Picker("自动结束", selection: binding.autoEndMinutes) {
            ForEach(StatusPreset.autoEndChoices, id: \.self) {
              Text(StatusPreset.autoEndTitle($0)).tag($0)
            }
          }
          .pickerStyle(.radioGroup)
          .horizontalRadioGroupLayout()
          .labelsHidden()
          .fixedSize()
        }
      } footer: {
        SectionFootnote("电源只管闲置的时候：屏幕锁定后照常熄灭，合上盖子照样睡眠。屏幕常亮时电脑也不睡眠。")
      }
      Section {
        DangerButton(stored.isPristine ? "删除" : "删除…") {
          if stored.isPristine { delete() } else { confirmsDelete = true }
        }
        .disabled(isOnly)
      } footer: {
        if isOnly { SectionFootnote("至少留一个状态。") }
      }
    }
    .formStyle(.grouped)
  }

  private func delete() {
    dismiss()
    guard fixed == nil else { return }
    data = StatusPreset.encoded(StatusPreset.removing(id, from: StatusPreset.decode(data)))
  }

  private func save(_ draft: StatusPreset) {
    guard fixed == nil else { return }
    data = StatusPreset.encoded(StatusPreset.updating(StatusPreset.decode(data), with: draft))
  }
}

/// 图标格子：一格「无」+ StatusEmoji.choices 的 16 个表情（静止画面），一行 7 个；选中的外面一圈强调色
/// （同通用页的外观缩略图）。深色外观下颜色很深的那两个表情（开会、黑猫）的格子换成浅底（StatusEmoji.plated）
private struct SymbolGrid: View {
  @Binding var selection: String
  @Environment(\.colorScheme) private var scheme

  private static let cell: CGFloat = 28
  private static let ring: CGFloat = 2

  var body: some View {
    let column = GridItem(.fixed(Self.cell + Self.ring * 2), spacing: 4)
    LazyVGrid(columns: Array(repeating: column, count: 7), spacing: 4) {
      ForEach([""] + StatusEmoji.ids, id: \.self) { cell($0) }
    }
    .fixedSize()
    // 选中圈往外露：最右一列格子自己的右边贴着同组控件的右边线（同通用页的外观缩略图）
    .padding(.trailing, -Self.ring)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图标")
  }

  private func cell(_ symbol: String) -> some View {
    let selected = selection == symbol
    return Button {
      selection = symbol
    } label: {
      Group {
        if let still = StatusEmoji.still(symbol) {
          Image(decorative: still, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: Self.cell - 6, height: Self.cell - 6)
        } else {
          Text("无").font(.system(size: 12, weight: .medium))
        }
      }
      .foregroundStyle(selected ? .primary : .secondary)
      .frame(width: Self.cell, height: Self.cell)
      .background(
        StatusEmoji.needsPlate(symbol, dark: scheme == .dark)
          ? Color(white: StatusEmoji.plateWhite) : Style.controlFill,
        in: RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
      )
      .padding(Self.ring)
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: Style.Radius.control + Self.ring, style: .continuous)
            .strokeBorder(Style.brand, lineWidth: Self.ring)
            .transition(.opacity)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: Style.fadeIn), value: selected)
    // 旁白读表情的中文名（「举手」「闹钟」…），「无」那一格读它的字
    .accessibilityLabel(StatusEmoji.name(symbol) ?? "无")
    .help(StatusEmoji.name(symbol) ?? "不要图标")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
