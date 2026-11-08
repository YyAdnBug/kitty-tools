// 设置 › 启动器 › 命令和别名（2026-11-07 拍板 C3 C4，PLAN §10「脚本命令」；真机反馈嫌长，从启动器页挪进推进去的这一页，
// LauncherCommandsPage）：一张「名称 / 别名 / 启用」的表，分四组——我的脚本、自带脚本、关键词命令（open、kill、ip、cb、fy、
// 提醒、汇率…）、系统命令（lock、sleep…），组里按名字排（第二轮 C1：来这一页多半是管自己的脚本，我的排最前）；上面能搜，
// 一排筛选「全部 / 我的脚本 / 自带脚本 / 内置」和「只看开着的」。脚本的图标读不出来、下不下来时名字下面写橙字原因（B2）。
// 别名就是在启动器里要打的那个词：改了旧词不再认，清空就只能按名字搜；和别的命令、网页搜索的关键词撞了那一格描橙框
// （只打这个词时脚本排第一；后面接了空格和文字时内置命令先认，其次脚本，网页搜索的关键词最后）。关掉 = 不出现在搜索里、关键词也不认。只存改过的（LauncherCommands.Settings，跟着设置导出、同步）。
// 脚本那几行：点名字在访达中显示，右键编辑、（我的脚本）移到废纸篓。脚本命令整个关着时脚本那两组变灰。
// 一个自己的脚本都没有时，「我的脚本」组照样列出来，一行「还没有自己的脚本」带「用例子新建」（只在没搜、没筛「只看开着的」时）。
// 启动器 ⌘K「改别名…」推进来时（SettingsNavigation.focusedCommand）只列那一条（按 id，同名的复制品不跟着出来）、别名框拿着
// 焦点，上面一行「显示全部」；动一下搜索框或筛选就回到全部（第二轮 D1）。

import SwiftUI

struct LauncherCommandsSection: View {
  /// 脚本库（单测 / 截图自检给固定的）；nil = 只列内置的
  let library: ScriptLibrary?
  @AppStorage(Prefs.launcherCommandAliases) private var aliasesText = ""
  @AppStorage(Prefs.launcherCommandsOff) private var offText = ""
  @AppStorage(Prefs.launcherScripts) private var scriptsOn = true
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
  @State private var filter = ""
  @State private var scope = Scope.all
  @State private var onlyOn = false
  @FocusState private var focusedAlias: String?
  /// 「改别名…」要的那一行：只列它
  @State private var only: String?
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  @Environment(Island.self) private var island: Island?

  /// 上面那一排筛选
  enum Scope: String, CaseIterable {
    case all = "全部"
    case mine = "我的脚本"
    case bundled = "自带脚本"
    case builtIn = "内置"

    func contains(_ group: Row.Group) -> Bool {
      switch self {
      case .all: true
      case .mine: group == .mine
      case .bundled: group == .bundled
      case .builtIn: group == .keyword || group == .system
      }
    }
  }

  /// 表里的一行
  struct Row: Identifiable {
    enum Group: String, CaseIterable {
      case mine = "我的脚本"
      case bundled = "自带脚本"
      case keyword = "关键词命令"
      case system = "系统命令"
    }

    let id: String
    let title: String
    /// 名字后面的小字（脚本的文件名）
    var detail: String?
    let symbol: String
    var icon: ScriptCommand.Icon?
    var iconDark: ScriptCommand.Icon?
    /// 原来的别名（关键词命令的关键词、脚本头部写的 keyword）
    let keyword: String?
    let group: Group
    var script: ScriptCommand?
  }

  private var settings: LauncherCommands.Settings {
    LauncherCommands.Settings(aliasesText: aliasesText, offText: offText)
  }

  /// 全部的行：我的脚本、自带脚本、关键词命令、系统命令，组里按名字排（纯函数，配单测）
  static func rows(scripts: [ScriptCommand]) -> [Row] {
    let keyword = LauncherCommands.builtIns.map {
      Row(id: $0.id, title: $0.title, symbol: $0.symbol, keyword: $0.keyword, group: .keyword)
    }
    let system = SystemCommand.allCases.map {
      Row(
        id: LauncherCommands.systemID($0.rawValue), title: $0.title, symbol: $0.symbol,
        keyword: $0.rawValue, group: .system)
    }
    let scripts = scripts.map {
      Row(
        id: LauncherCommands.scriptID($0), title: $0.title, detail: $0.fileName,
        symbol: "terminal.fill", icon: $0.icon, iconDark: $0.iconDark, keyword: $0.keyword,
        group: $0.isBundled ? .bundled : .mine, script: $0)
    }
    let all = scripts + keyword + system
    return Row.Group.allCases.flatMap { group in
      all.filter { $0.group == group }.sorted {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
    }
  }

  var body: some View {
    let settings = settings
    let all = Self.rows(scripts: library?.scripts ?? [])
    let conflicts = LauncherCommands.conflicts(
      all.map { ($0.id, settings.alias($0.id, default: $0.keyword)) },
      engineKeywords: SearchEngineDetail.decode(enginesData).map(\.keyword))
    let shown =
      only.map { id in all.filter { $0.id == id } }
      ?? Self.filter(all, by: filter, scope: scope, onlyOn: onlyOn, settings: settings)
    Section {
      TextField("搜索命令", text: showingAll($filter), prompt: Text("按名字或别名找"))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
      HStack {
        Picker("显示", selection: showingAll($scope)) {
          ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer()
        Toggle("只看开着的", isOn: showingAll($onlyOn))
          .toggleStyle(.checkbox)
      }
      if let row = shown.first, only != nil {
        HStack {
          Text("只列出了「\(row.title)」").foregroundStyle(.secondary)
          Spacer()
          Button("显示全部") { only = nil }
        }
      }
      HStack {
        Text("名称")
        Spacer()
        Text("别名").frame(width: Self.aliasWidth, alignment: .leading)
        Text("启用").frame(width: Self.toggleWidth, alignment: .trailing)
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
      let emptyMine =
        library?.hasNoOwnScripts == true && only == nil && !onlyOn
        && filter.trimmingCharacters(in: .whitespaces).isEmpty && scope.contains(.mine)
      ForEach(Row.Group.allCases, id: \.self) { group in
        let rows = shown.filter { $0.group == group }
        if group == .mine, emptyMine {
          Text(group.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
          HStack {
            Text("还没有自己的脚本").foregroundStyle(.secondary)
            Spacer()
            Button("用例子新建") { library?.newExample(island: island) }
          }
          .disabled(!scriptsOn)
        }
        if !rows.isEmpty {
          Text(group.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
          ForEach(rows) { row in
            CommandRow(
              row: row, alias: aliasBinding(row), isOn: onBinding(row),
              conflicted: conflicts.contains(row.id), focus: $focusedAlias,
              refresh: { library?.refresh() }
            )
            .disabled(row.script != nil && !scriptsOn)
          }
        }
      }
      if shown.isEmpty, !emptyMine {
        Text(filter.isEmpty ? "这里还没有" : "没有找到「\(filter)」").foregroundStyle(.secondary)
      }
    } footer: {
      SectionFootnote(
        !shown.contains { conflicts.contains($0.id) }
          ? "别名就是在启动器里要打的那个词，改了以后原来的词不再认；清空就只能按名字搜。关掉的不出现在搜索里。"
          : "描了橙框的别名重复了（也算网页搜索的关键词）：只打这个词时脚本排第一；后面接了空格和文字时，内置命令先认，其次脚本，网页搜索最后。改一个吧。")
    }
    .onAppear { focus(in: all) }
    .onChange(of: navigation?.focusedCommand) { focus(in: all) }
  }

  /// 搜索框、筛选被人动了：不再只列「改别名…」那一行
  private func showingAll<Value>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding {
      binding.wrappedValue
    } set: {
      only = nil
      binding.wrappedValue = $0
    }
  }

  /// 启动器 ⌘K「改别名…」要的那一行：只列它，等这一行出来再把焦点给它的别名框
  private func focus(in rows: [Row]) {
    guard let id = navigation?.focusedCommand else { return }
    navigation?.focusedCommand = nil
    guard rows.contains(where: { $0.id == id }) else { return }
    only = id
    Task {
      await Task.yield()
      focusedAlias = id
    }
  }

  static let aliasWidth: CGFloat = 110
  static let toggleWidth: CGFloat = 44

  /// 筛选：哪几组、只看开着的、搜索框（名字、别名、文件名里带着这几个字的，不分大小写）
  static func filter(
    _ rows: [Row], by text: String, scope: Scope = .all, onlyOn: Bool = false,
    settings: LauncherCommands.Settings
  ) -> [Row] {
    let rows = rows.filter { scope.contains($0.group) && (!onlyOn || settings.isOn($0.id)) }
    let needle = LauncherMatch.fold(text.trimmingCharacters(in: .whitespaces))
    guard !needle.isEmpty else { return rows }
    return rows.filter { row in
      [row.title, row.detail, settings.alias(row.id, default: row.keyword)].compactMap { $0 }
        .contains { LauncherMatch.fold($0).contains(needle) }
    }
  }

  private func aliasBinding(_ row: Row) -> Binding<String> {
    // 显示存着的原样（打字时光标不跳）；比的时候才折叠
    Binding {
      settings.aliases[row.id] ?? row.keyword ?? ""
    } set: { text in
      var settings = settings
      settings.setAlias(text, for: row.id, default: row.keyword)
      aliasesText = settings.aliasesText
    }
  }

  private func onBinding(_ row: Row) -> Binding<Bool> {
    Binding {
      settings.isOn(row.id)
    } set: { on in
      var settings = settings
      settings.set(on, for: row.id)
      offText = settings.offText
    }
  }
}

/// 推进去的那一页：页头 + 那张表
struct LauncherCommandsPage: View {
  static let route = "page:launcher-commands"
  let library: ScriptLibrary?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      DetailHeader(title: "命令和别名", status: "改在启动器里要打的词，关掉用不上的") {
        KindTile(symbol: "command", color: Style.Family.command, size: 40)
      }
      Form { LauncherCommandsSection(library: library) }
        .formStyle(.grouped)
    }
    .navigationTitle("命令和别名")
    .toolbar { SettingsBackButton { dismiss() } }
  }
}

/// 表里的一行：图标 + 名字（脚本另有文件名），别名输入框（撞了描橙框），开关
private struct CommandRow: View {
  let row: LauncherCommandsSection.Row
  @Binding var alias: String
  @Binding var isOn: Bool
  let conflicted: Bool
  var focus: FocusState<String?>.Binding
  /// 复制、移到废纸篓之后重读脚本库
  var refresh: () -> Void = {}

  var body: some View {
    HStack(spacing: 10) {
      icon
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(row.title).lineLimit(1).truncationMode(.tail)
          if let detail = row.detail {
            Text(detail)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        if let iconProblem {
          Text(iconProblem)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .contentShape(.rect)
      // 点脚本的名字在访达中显示（拍板 C3）；悬停有提示、读屏能当动作用（第三轮评审：原来事先看不出来）
      .onTapGesture { reveal() }
      .help(row.script == nil ? "" : "在访达中显示")
      .accessibilityActions {
        if row.script != nil { Button("在访达中显示", action: reveal) }
      }
      Spacer(minLength: 8)
      TextField("别名", text: $alias, prompt: Text("无"))
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
        .frame(width: LauncherCommandsSection.aliasWidth)
        .focused(focus, equals: row.id)
        .overlay {
          if conflicted {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .strokeBorder(Color(nsColor: .systemOrange), lineWidth: 1.5)
              .allowsHitTesting(false)
          }
        }
        .labelsHidden()
        .accessibilityLabel("「\(row.title)」的别名")
        .accessibilityValue(conflicted ? "\(alias)，和别的重复了" : alias)
      Toggle("启用「\(row.title)」", isOn: $isOn)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .frame(width: LauncherCommandsSection.toggleWidth, alignment: .trailing)
    }
    .opacity(isOn ? 1 : 0.55)
    .contextMenu {
      if let script = row.script {
        Button("在访达中显示", action: reveal)
        if script.isBundled {
          // 复制出来的那份和自带的同一个关键词：把自带的关掉，启动器里只剩自己那份（拍板 D2「用你的」）
          Button("复制一份到我的脚本") {
            if ScriptLibrary.copyBundled(script) != nil {
              isOn = false
              refresh()
            }
          }
        } else {
          // 自带的在 App 包里，不在原地改（复制一份再改）
          Button("编辑脚本") { ScriptLibrary.edit(script.path) }
          Divider()
          Button("移到废纸篓", role: .destructive) {
            NSWorkspace.shared.recycle([URL(filePath: script.path)]) { _, _ in
              Task { @MainActor in refresh() }
            }
          }
        }
      }
    }
  }

  private func reveal() {
    guard let script = row.script else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: script.path)])
  }

  @ViewBuilder private var icon: some View {
    let fallback = KindTile(symbol: row.symbol, color: Style.Family.command, size: 20)
    if let icon = row.icon {
      ScriptIconView(icon: icon, dark: row.iconDark, size: 20, fallback: fallback)
    } else {
      fallback
    }
  }

  /// 脚本的图标读不出来、下不下来的原因（B2）
  private var iconProblem: String? {
    [row.icon, row.iconDark].compactMap { $0.flatMap(ScriptIcons.shared.failure(for:)) }.first
  }
}
