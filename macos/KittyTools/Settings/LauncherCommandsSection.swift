// 设置 › 启动器「命令」那一节（2026-11-07 拍板 C3 C4，PLAN §10「脚本命令」）：一张「名称 / 别名 / 启用」的表，分四组——
// 关键词命令（open、kill、ip、cb、fy、提醒…）、系统命令（lock、sleep…）、自带脚本、我的脚本；上面能搜。
// 别名就是在启动器里要打的那个词：改了旧词不再认，清空就只能按名字搜；和别的命令、网页搜索的关键词撞了那一格描橙框
// （运行时用靠前的那个）。关掉 = 不出现在搜索里、关键词也不认。只存改过的（LauncherCommands.Settings，跟着设置导出、同步）。
// 脚本那几行：点名字在访达中显示，右键用文本编辑器打开、（我的脚本）移到废纸篓。脚本命令整个关着时脚本那两组变灰。

import SwiftUI

struct LauncherCommandsSection: View {
  /// 脚本库（单测 / 截图自检给固定的）；nil = 只列内置的
  let library: ScriptLibrary?
  @AppStorage(Prefs.launcherCommandAliases) private var aliasesText = ""
  @AppStorage(Prefs.launcherCommandsOff) private var offText = ""
  @AppStorage(Prefs.launcherScripts) private var scriptsOn = true
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
  @State private var filter = ""

  /// 表里的一行
  struct Row: Identifiable {
    enum Group: String, CaseIterable {
      case keyword = "关键词命令"
      case system = "系统命令"
      case bundled = "自带脚本"
      case mine = "我的脚本"
    }

    let id: String
    let title: String
    /// 名字后面的小字（脚本的文件名）
    var detail: String?
    let symbol: String
    var icon: ScriptCommand.Icon?
    /// 原来的别名（关键词命令的关键词、脚本头部写的 keyword）
    let keyword: String?
    let group: Group
    var script: ScriptCommand?
  }

  private var settings: LauncherCommands.Settings {
    LauncherCommands.Settings(aliasesText: aliasesText, offText: offText)
  }

  /// 全部的行（纯函数，配单测）
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
        symbol: "terminal.fill", icon: $0.icon, keyword: $0.keyword,
        group: $0.isBundled ? .bundled : .mine, script: $0)
    }
    return keyword + system + scripts
  }

  var body: some View {
    let settings = settings
    let all = Self.rows(scripts: library?.scripts ?? [])
    let conflicts = LauncherCommands.conflicts(
      all.map { ($0.id, settings.alias($0.id, default: $0.keyword)) },
      engineKeywords: SearchEngineDetail.decode(enginesData).map(\.keyword))
    let shown = Self.filter(all, by: filter, settings: settings)
    Section {
      TextField("搜索命令", text: $filter, prompt: Text("按名字或别名找"))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
      HStack {
        Text("名称")
        Spacer()
        Text("别名").frame(width: Self.aliasWidth, alignment: .leading)
        Text("启用").frame(width: Self.toggleWidth, alignment: .trailing)
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
      ForEach(Row.Group.allCases, id: \.self) { group in
        let rows = shown.filter { $0.group == group }
        if !rows.isEmpty {
          Text(group.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
          ForEach(rows) { row in
            CommandRow(
              row: row, alias: aliasBinding(row), isOn: onBinding(row),
              conflicted: conflicts.contains(row.id), refresh: { library?.refresh() }
            )
            .disabled(row.script != nil && !scriptsOn)
          }
        }
      }
      if shown.isEmpty {
        Text("没有找到「\(filter)」").foregroundStyle(.secondary)
      }
    } header: {
      Text("命令")
    } footer: {
      SectionFootnote(
        conflicts.isEmpty
          ? "别名就是在启动器里要打的那个词，改了以后原来的词不再认；清空就只能按名字搜。关掉的不出现在搜索里。"
          : "描了橙框的别名重复了（也算网页搜索的关键词），启动器里用排在前面的那个，改一个吧。")
    }
  }

  static let aliasWidth: CGFloat = 110
  static let toggleWidth: CGFloat = 44

  /// 搜索框：名字、别名、文件名里带着这几个字的（不分大小写）
  static func filter(_ rows: [Row], by text: String, settings: LauncherCommands.Settings) -> [Row] {
    let needle = LauncherMatch.fold(text.trimmingCharacters(in: .whitespaces))
    guard !needle.isEmpty else { return rows }
    return rows.filter { row in
      [row.title, row.detail, settings.alias(row.id, default: row.keyword)].compactMap { $0 }
        .contains { LauncherMatch.fold($0).contains(needle) }
    }
  }

  private func aliasBinding(_ row: Row) -> Binding<String> {
    Binding {
      settings.alias(row.id, default: row.keyword) ?? ""
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

/// 表里的一行：图标 + 名字（脚本另有文件名），别名输入框（撞了描橙框），开关
private struct CommandRow: View {
  let row: LauncherCommandsSection.Row
  @Binding var alias: String
  @Binding var isOn: Bool
  let conflicted: Bool
  /// 复制、移到废纸篓之后重读脚本库
  var refresh: () -> Void = {}

  var body: some View {
    HStack(spacing: 10) {
      icon
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
      .contentShape(.rect)
      .onTapGesture {
        if let script = row.script {
          NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: script.path)])
        }
      }
      Spacer(minLength: 8)
      TextField("别名", text: $alias, prompt: Text("无"))
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
        .frame(width: LauncherCommandsSection.aliasWidth)
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
        .controlSize(.small)
        .labelsHidden()
        .frame(width: LauncherCommandsSection.toggleWidth, alignment: .trailing)
    }
    .opacity(isOn ? 1 : 0.55)
    .contextMenu {
      if let script = row.script {
        Button("在访达中显示") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: script.path)])
        }
        Button("用文本编辑器打开") { ScriptLibrary.edit(script.path) }
        if script.isBundled {
          // 复制出来的那份和自带的同一个关键词：把自带的关掉，启动器里只剩自己那份（拍板 D2「用你的」）
          Button("复制一份到我的脚本") {
            if ScriptLibrary.copyBundled(script) != nil {
              isOn = false
              refresh()
            }
          }
        } else {
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

  @ViewBuilder private var icon: some View {
    switch row.icon {
    case .emoji(let emoji)?:
      Text(emoji).font(.system(size: 14)).frame(width: 20, height: 20)
    case .symbol(let name)?
    where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil:
      KindTile(symbol: name, color: Style.Family.command, size: 20)
    default:
      KindTile(symbol: row.symbol, color: Style.Family.command, size: 20)
    }
  }
}
