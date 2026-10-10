// 设置 › 状态屏 › 某个状态（详情页，从列表推进来；同 SearchEngineDetail / TranslateServiceDetail 的形式）：
// 页头 40 pt 家族色块 + 标题 + 摘要，下面分组表单：标题、说明、图标（一格「无」+ 20 个符号）、样式（三选一，下面一块
// 预览：真的画面按 1200 × 750 的屏排好再缩小）、电源、自动结束，最后是删除（至少留一个；自己加的、改过的先确认）。
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
    return Form {
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
      } header: {
        DetailHeader(
          title: stored.title, status: editing.problem ?? stored.summary,
          isProblem: editing.problem != nil
        ) {
          KindTile(symbol: stored.rowSymbol, color: Style.Family.statusScreen, size: 40)
        }
      } footer: {
        OrderedList.footnote(
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
        StatusPreview(preset: stored)
      }
      Section {
        Picker("电源", selection: binding.power) {
          ForEach(StatusPreset.Power.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("自动结束", selection: binding.autoEndMinutes) {
          ForEach(StatusPreset.autoEndChoices, id: \.self) {
            Text(StatusPreset.autoEndTitle($0)).tag($0)
          }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
      } footer: {
        OrderedList.footnote("电源只管闲置的时候：屏幕锁定后照常熄灭，合上盖子照样睡眠。")
      }
      Section {
        DangerButton(stored.isPristine ? "删除" : "删除…") {
          if stored.isPristine { delete() } else { confirmsDelete = true }
        }
        .disabled(isOnly)
      } footer: {
        if isOnly { OrderedList.footnote("至少留一个状态。") }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog("删除「\(stored.title)」？", isPresented: $confirmsDelete) {
      Button("删除", role: .destructive, action: delete)
    } message: {
      Text(Self.deleteMessage)
    }
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

/// 图标格子：一格「无」+ StatusPreset.symbols 的 20 个，一行 7 个；选中的外面一圈强调色（同通用页的外观缩略图）
private struct SymbolGrid: View {
  @Binding var selection: String

  private static let cell: CGFloat = 28
  private static let ring: CGFloat = 2

  var body: some View {
    let column = GridItem(.fixed(Self.cell + Self.ring * 2), spacing: 4)
    LazyVGrid(columns: Array(repeating: column, count: 7), spacing: 4) {
      ForEach([""] + StatusPreset.symbols, id: \.self) { cell($0) }
    }
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图标")
  }

  private func cell(_ symbol: String) -> some View {
    let selected = selection == symbol
    return Button {
      selection = symbol
    } label: {
      Group {
        if symbol.isEmpty {
          Text("无").font(.system(size: 12, weight: .medium))
        } else {
          Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(.hierarchical)
        }
      }
      .foregroundStyle(selected ? .primary : .secondary)
      .frame(width: Self.cell, height: Self.cell)
      .background(
        Style.controlFill,
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
    // 名字不另起：符号的旁白名是系统给的（「时钟」「月亮」…），「无」那一格读它的字
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// 预览：真的画面（StatusScreenView）按一块 1200 × 750 的屏排好，再缩到页面宽度。透出样式底下垫一张示意的浅色桌面
/// （画的，不截真屏幕）。进入时刻、时长是摆的。只是预览：不接点击、不进旁白
private struct StatusPreview: View {
  let preset: StatusPreset

  private static let screen = CGSize(width: 1200, height: 750)

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let startedAt =
      Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: .now) ?? .now
    GeometryReader { proxy in
      ZStack {
        if preset.style == .dim { Self.desktop }
        StatusScreenView(
          screen: StatusScreen(showing: preset, startedAt: startedAt, elapsed: 23 * 60))
      }
      .frame(width: Self.screen.width, height: Self.screen.height)
      .scaleEffect(proxy.size.width / Self.screen.width, anchor: .topLeading)
    }
    .aspectRatio(Self.screen.width / Self.screen.height, contentMode: .fit)
    .clipShape(shape)
    .overlay(shape.hairlineBorder())
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// 示意的桌面：浅色壁纸上两扇有几行「字」的窗。颜色是示意用的定值，不跟外观走
  private static var desktop: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.62, green: 0.74, blue: 0.92), Color(red: 0.84, green: 0.80, blue: 0.94),
        ], startPoint: .top, endPoint: .bottom)
      window(lines: 9).frame(width: 640, height: 440).offset(x: -200, y: -70)
      window(lines: 6).frame(width: 520, height: 340).offset(x: 260, y: 140)
    }
  }

  private static func window(lines: Int) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(0..<lines, id: \.self) { line in
        Capsule()
          .fill(.black.opacity(line == 0 ? 0.6 : 0.3))
          .frame(width: line == 0 ? 180 : line % 3 == 0 ? 260 : 400, height: 12)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}
