// 设置 › 访达右键 › 压缩时跳过（2026-11-15 用户说原来那一行「对用户体验不友好」：一个 220 宽的文本框里写逗号隔开的一串，
// 长了看不全、要懂 * 通配、写错了只有带「/」的有反馈、说明两行挤在标签里、常见的几项都得自己打）。收成「压缩和解压」里一行
// 推进来的这一页（同 启动器 ›「命令和别名」、通用 ›「功能」），页上：
// - 常见的几项一项一个开关（项目文件夹里的 / 别的系统、软件留下的两组），说明写这是什么；Mac 自己的杂文件总会跳过，写在页脚、不列；
// - 另外跳过的：一行一个的列表（写错的那一条下面橙字说为什么不算），下面系统样式的「+ −」：「+」弹一个小框，打字时就说哪里不对，
//   逗号隔开能一次加几个，结尾的「/」去掉（从忽略文件里抄来的「node_modules/」）。
// 存法不变：还是 Prefs.finderCompressSkip 那一行逗号隔开的字（导出、同步、旧版本照认），开关和列表都是从它拆出来、改完拼回去；
// 匹配还是 Archives.skipNames 那一套，这一页不改匹配。
// ponytail: 列表里的一条不能就地改名，删了再加；名字都短，真有人要再做双击编辑。

import SwiftUI

struct CompressSkipPage: View {
  static let route = "page:compress-skip"

  /// 常见的一项：名字照原样（存的、匹配的都是它，不翻），说明跟界面语言
  struct Preset {
    let name: String
    let detail: LocalizedStringResource
    init(_ name: String, _ detail: LocalizedStringResource) {
      self.name = name
      self.detail = detail
    }
  }

  /// 一组常见的（不写成元组：元组字面量里的字有的抽不进目录，TRANSLATION.md 二）
  struct Group {
    let title: LocalizedStringResource
    let items: [Preset]
    init(_ title: LocalizedStringResource, _ items: [Preset]) {
      self.title = title
      self.items = items
    }
  }

  /// 常见的几项（名字、一句说明），两组。默认都不开（默认值还是空的，同 0.9.0：改默认值会让没动过的电脑在同步、导入时变样）
  static let presets = [
    Group(
      "项目文件夹里的",
      [
        Preset("node_modules", "前端项目装的依赖，往往几万个文件"),
        Preset(".git", "版本库，存着每一次改动的历史"),
        Preset(".venv", "Python 项目的虚拟环境"),
        Preset("__pycache__", "Python 运行时生成的缓存"),
        Preset("*.log", "日志文件"),
      ]),
    Group(
      "别的系统、软件留下的",
      [
        Preset("~$*", "Office 打开文档时生成的临时文件，像「~$报告.docx」"),
        Preset("Thumbs.db", "Windows 生成的缩略图缓存"),
        Preset("desktop.ini", "Windows 记文件夹样子的文件"),
      ]),
  ]

  static var presetNames: Set<String> { Set(presets.flatMap { $0.items.map(\.name) }) }

  @AppStorage(Prefs.finderCompressSkip) private var text = ""
  @Environment(\.dismiss) private var dismiss
  @State private var selection: String?
  @State private var adding = false

  var body: some View {
    let entries = Archives.skipEntries(text)
    let applied = Set(Archives.skipNames(text))
    let custom = entries.filter { !Self.presetNames.contains($0) }
    VStack(spacing: 0) {
      DetailHeader(title: "压缩时跳过", status: "文件夹里叫这些名字的文件和文件夹，都不压进去") {
        KindTile(symbol: "doc.zipper", color: Style.Family.finderMenu, size: 40)
      }
      Form {
        ForEach(Self.presets, id: \.title.key) { group in
          Section {
            ForEach(group.items, id: \.name) { item in
              Toggle(isOn: preset(item.name, in: entries)) {
                Text(verbatim: item.name)
                Text(plain: item.detail)
              }
            }
          } header: {
            Text(group.title)
          } footer: {
            if group.title.key == Self.presets.last?.title.key {
              SectionFootnote("Mac 自己的隐藏文件（.DS_Store、._*、__MACOSX）总会跳过，不用加。")
            }
          }
        }
        Section {
          List(selection: $selection) {
            if custom.isEmpty {
              Text("还没有：点下面的「+」加一个名字").foregroundStyle(.secondary)
            }
            ForEach(custom, id: \.self) { name in
              SkipRow(name: name, problem: Self.problem(name, applied: applied)).tag(name)
            }
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .orderedListFrame(rows: custom.count)
          .onDeleteCommand(perform: removeSelected)
          ListEditBar(
            removeTitle: "移除所选的名字", canRemove: selection != nil, remove: removeSelected
          ) {
            Button {
              adding = true
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("添加名字")
            .popover(isPresented: $adding, arrowEdge: .bottom) {
              SkipNameForm(text: $text) { adding = false }
            }
          }
        } header: {
          Text("另外跳过的")
        } footer: {
          SectionFootnote(
            "* 代表任意几个字、? 代表一个字，比如 *.tmp 跳过所有 .tmp 文件；只认名字、不认路径。右键选中的那几样自己照压，只跳它们里面的；只压一个 App 这类包时不跳，跳了签名会坏。"
          )
        }
      }
      .formStyle(.grouped)
      .gated(by: .finderMenu)
    }
    .navigationTitle("压缩时跳过")
    .toolbar { SettingsBackButton { dismiss() } }
  }

  /// 常见的那一项开没开：开 = 名单里有它，关 = 拿掉；从偏好现读再改、拼回去（同步刚落下的不丢）
  private func preset(_ name: String, in entries: [String]) -> Binding<Bool> {
    Binding {
      entries.contains(name)
    } set: { on in
      var list = Archives.skipEntries(text)
      list.removeAll { $0 == name }
      if on { list.append(name) }
      text = Self.joined(list)
    }
  }

  private func removeSelected() {
    guard let name = selection else { return }
    text = Self.joined(Archives.skipEntries(text).filter { $0 != name })
    selection = nil
  }

  /// 拼回那一行字（Archives.skipNames 认全角半角逗号、去两头空白，这样写旧版本也照认）
  static func joined(_ entries: [String]) -> String { entries.joined(separator: ", ") }

  /// 列表里那一条的橙字：nil = 照跳
  static func problem(_ name: String, applied: Set<String>) -> String? {
    if let problem = Archives.skipProblem(name) { return String(localized: "\(problem)，这条不算") }
    return applied.contains(name) ? nil : String(localized: "超过 50 个了，这条不算")
  }

  /// 「压缩和解压」里那一行的小字：跳哪几个（多了只列前 4 个）、几条写错了
  static func summary(_ text: String) -> String {
    let applied = Archives.skipNames(text)
    let wrong = Archives.skipEntries(text).count - applied.count
    let names = applied.prefix(4).joinedAsList()
    let line =
      applied.isEmpty
      ? String(localized: "只跳过 Mac 自己的隐藏文件")
      : applied.count > 4 ? String(localized: "\(names) 等 \(applied.count) 个") : names
    guard wrong > 0 else { return line }
    return [line, String(localized: "\(wrong) 条写错了、不算")].joinedAsClauses()
  }

  /// 添加框里打的字 → 要加进去的名字，或者为什么加不了。逗号隔开（全角半角）能一次加几个；两头空白、结尾的「/」去掉
  /// （从忽略文件里抄来的「node_modules/」）；已经有了的不重复加
  static func additions(_ input: String, to text: String) -> (names: [String], problem: String?) {
    var names: [String] = []
    for part in input.split(whereSeparator: { $0 == "," || $0 == "，" }) {
      var name = part.trimmingCharacters(in: .whitespaces)
      while name.count > 1, name.hasSuffix("/") { name.removeLast() }
      if !name.isEmpty, !names.contains(name) { names.append(name) }
    }
    for name in names {
      let problem: String? =
        name.allSatisfy({ $0 == "*" })
        ? String(localized: "只写「*」会把文件夹里的东西全跳过") : Archives.skipProblem(name)
      if let problem {
        return ([], names.count > 1 ? String(localized: "「\(name)」\(problem)") : problem)
      }
    }
    let existing = Archives.skipEntries(text)
    let new = names.filter { !existing.contains($0) }
    if !names.isEmpty, new.isEmpty {
      return (
        [], names.count > 1 ? String(localized: "这几个都已经在里面了") : String(localized: "已经在里面了")
      )
    }
    if Archives.skipNames(text).count + new.count > 50 {
      return ([], String(localized: "最多 50 个，先移除几个不用的"))
    }
    return (new, nil)
  }
}

/// 另外跳过的一行：名字，写错了右边橙字说为什么（放在同一行：列表按一行 36 算总高，两行的行会把最后一行挤出去）
private struct SkipRow: View {
  let name: String
  let problem: String?

  var body: some View {
    HStack(spacing: 8) {
      Text(name)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
      if let problem {
        Text(problem)
          .font(.subheadline)
          .foregroundStyle(.orange)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .frame(height: OrderedList.rowHeight - 8)
    .help(name)
    .accessibilityElement(children: .combine)
  }
}

/// 「+」弹出来的小框：打一个名字（逗号隔开能一次几个），打字时就说哪里不对；↩ 或「添加」加进去、收起
struct SkipNameForm: View {
  @Binding var text: String
  let done: () -> Void
  @State private var input: String
  @FocusState private var focused: Bool

  /// input：框里先放的字（截图自检摆状态用）
  init(text: Binding<String>, input: String = "", done: @escaping () -> Void) {
    _text = text
    _input = State(initialValue: input)
    self.done = done
  }

  var body: some View {
    let check = CompressSkipPage.additions(input, to: text)
    VStack(alignment: .leading, spacing: 8) {
      Text("跳过叫这个名字的文件和文件夹")
        .font(.headline)
      TextField("名字", text: $input, prompt: Text("比如 build、*.tmp"))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .focused($focused)
        .onSubmit(add)
      (check.problem.map(Text.init(verbatim:)) ?? Text("* 代表任意几个字；几个名字用逗号隔开，一次加进去"))
        .font(.subheadline)
        .foregroundStyle(check.problem == nil ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("添加", action: add)
          .buttonStyle(BrandButtonStyle())
          .disabled(check.names.isEmpty)
      }
    }
    .padding(16)
    .frame(width: 300)
    .onAppear { focused = true }
  }

  private func add() {
    let names = CompressSkipPage.additions(input, to: text).names
    guard !names.isEmpty else { return }
    text = CompressSkipPage.joined(Archives.skipEntries(text) + names)
    done()
  }
}
