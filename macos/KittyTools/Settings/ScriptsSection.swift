// 设置 › 启动器「脚本命令」和「命令」两节（2026-11-07 拍板 A1 A2 B5 C3 E2，PLAN §10「脚本命令」；真机反馈后收紧：
// 那张 40 行的表、写法说明、查找路径都挪进推进去的详情页，这一页只留几行）。
// 「脚本命令」：总开关（默认开）、「怎么写脚本」（推进 ScriptGuidePage）、「让 AI 来写」（第二轮 A2：复制给 AI 的写法说明、
// 把 AI 给的脚本从剪贴板新建——同样先看一眼全文再存）、脚本文件夹（新建脚本 / 在访达中打开）、
// 另加的文件夹（只读、能移除）和「添加文件夹…」、把脚本文件拖进来导入（先看一眼全文，写明以你的身份运行、能用本 App 已有的
// 授权，点「导入」才复制进默认文件夹）、读不成的脚本和原因（橙字）。
// 「命令」：一行「命令和别名」推进 LauncherCommandsPage（那张名称 / 别名 / 启用的表），行里写各有几条、关了几条。
// 选文件夹的面板挂成设置窗上的表单（同全局同步的「选择文件夹…」）。

import SwiftUI
import UniformTypeIdentifiers

struct ScriptsSection: View {
  let library: ScriptLibrary?
  @AppStorage(Prefs.launcherScripts) private var scriptsOn = true
  @AppStorage(Prefs.scriptFolders) private var foldersText = ""
  @AppStorage(Prefs.launcherCommandsOff) private var offText = ""
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  @Environment(Island.self) private var island: Island?
  /// 拖进来、等着看一眼再导入的那个
  @State private var pending: Candidate?
  @State private var isTargeted = false

  struct Candidate: Identifiable {
    /// 拖进来的文件；从剪贴板新建的是 nil
    let url: URL?
    /// 存进脚本文件夹时的文件名
    let name: String
    let text: String
    /// 比能显示的长：没看全，不让导入
    var isTruncated = false
    var id: String { url?.path(percentEncoded: false) ?? "clipboard:" + name }
  }

  var body: some View {
    Section {
      Toggle(isOn: $scriptsOn) {
        Text("启用脚本命令")
        Text("脚本文件夹里的每个脚本就是启动器里的一条命令")
      }
      Group {
        SettingsPushRow(title: "怎么写脚本", detail: "三步上手、开头几行怎么写、结果给谁，带一个能直接用的例子") {
          navigation?.path = [ScriptGuidePage.route]
        }
        LabeledContent {
          HStack {
            Button("复制写法说明", action: copyGuide)
            Button("从剪贴板新建", action: newFromClipboard)
          }
        } label: {
          Text("让 AI 来写")
          Text("把写法说明贴给你常用的 AI、在最后写上想做什么；它给的脚本复制下来，点「从剪贴板新建」")
        }
        LabeledContent {
          HStack {
            Button("新建脚本", action: newScript)
            Button("在访达中打开") {
              NSWorkspace.shared.open(ScriptLibrary.ensureDefaultFolder())
            }
          }
        } label: {
          Text("脚本文件夹")
          Text(
            (ScriptLibrary.defaultFolder.path(percentEncoded: false) as NSString)
              .abbreviatingWithTildeInPath
          )
          .lineLimit(1)
          .truncationMode(.middle)
        }
        ForEach(addedFolders, id: \.self) { folder in
          LabeledContent {
            Button("移除") {
              ScriptLibrary.removeFolder(folder)
              library?.refresh()
            }
          } label: {
            Text(folder.lastPathComponent)
            Text((folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        LabeledContent {
          Button("添加文件夹…", action: addFolder)
        } label: {
          Text("其他文件夹")
          Text("比如放在 iCloud 云盘里、几台 Mac 共用的脚本文件夹（只读，不往里写）")
        }
        dropZone
        ForEach(library?.problems ?? [], id: \.path) { problem in
          LabeledContent {
            Button("在访达中显示") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: problem.path)])
            }
          } label: {
            Text((problem.path as NSString).lastPathComponent)
            Text(problem.problem.text).foregroundStyle(Color(nsColor: .systemOrange))
          }
        }
      }
      .disabled(!scriptsOn)
    } header: {
      Text("脚本命令")
    } footer: {
      SectionFootnote(
        "脚本以你的身份运行，能用 Kitty Tools 已有的辅助功能、屏幕录制等授权，只放你信得过的脚本；从网上下载的，第一次运行前会先给你看一眼全文。")
    }
    .sheet(item: $pending) { candidate in
      ScriptImportSheet(candidate: candidate) {
        pending = nil
      } confirm: {
        pending = nil
        if let url = candidate.url {
          Task {
            _ = await ScriptLibrary.importScript(url, into: ScriptLibrary.defaultFolder)
            library?.refresh()
          }
        } else if let url = ScriptLibrary.save(candidate.text, name: candidate.name) {
          library?.refresh()
          let keyword = (url.lastPathComponent as NSString).deletingPathExtension
          island?.show(
            "已存成「\(url.lastPathComponent)」",
            detail: candidate.name == "新脚本.sh" ? "在启动器里按名字找它" : "在启动器里输 \(keyword) 试试",
            actions: [.reveal(url)])
        }
      }
    }
    Section {
      SettingsPushRow(title: "命令和别名", detail: commandsSummary) {
        navigation?.path = [LauncherCommandsPage.route]
      }
    } header: {
      Text("命令")
    } footer: {
      SectionFootnote("给内置命令和脚本改在启动器里要打的词，关掉用不上的。")
    }
  }

  private var addedFolders: [URL] {
    _ = foldersText  // 跟着偏好变
    return ScriptLibrary.addedFolders
  }

  /// 「命令和别名」那一行的小字：各有几条、关了几条
  private var commandsSummary: String {
    let rows = LauncherCommandsSection.rows(scripts: scriptsOn ? library?.scripts ?? [] : [])
    let count = { (group: LauncherCommandsSection.Row.Group) in
      rows.filter { $0.group == group }.count
    }
    var parts: [String] = []
    if count(.mine) > 0 { parts.append("\(count(.mine)) 个我的脚本") }
    if count(.bundled) > 0 { parts.append("\(count(.bundled)) 个自带脚本") }
    parts += ["\(count(.keyword)) 个关键词命令", "\(count(.system)) 个系统命令"]
    let off = LauncherCommands.Settings(aliasesText: "", offText: offText).off
    let closed = rows.filter { off.contains($0.id) }.count
    return parts.joined(separator: "、") + (closed > 0 ? "，关了 \(closed) 个" : "")
  }

  /// 「复制写法说明」：给 AI 的那一份（ScriptAIGuide）
  private func copyGuide() {
    Paster.write(string: ScriptAIGuide.text, record: true)
    island?.show("已复制脚本写法说明", detail: "贴给你常用的 AI，在最后一段写上想做什么")
  }

  /// 「从剪贴板新建」：剪贴板里是一整个脚本（#! 开头，带不带 ``` 都行）就先给看全文，点了才存
  private func newFromClipboard() {
    guard let raw = NSPasteboard.general.string(forType: .string),
      let text = ScriptLibrary.scriptText(fromClipboard: raw)
    else {
      island?.show(
        "剪贴板里不是脚本", detail: "要第一行是 #! 的一整个脚本：先把 AI 给的脚本复制下来", tone: .warning)
      return
    }
    pending = Candidate(
      url: nil, name: ScriptLibrary.suggestedName(for: text), text: text,
      isTruncated: text.utf8.count > ScriptRunner.reviewLimit)
  }

  /// 「新建脚本」：照模板建一个、用编辑器打开，岛上说接下来怎么做
  private func newScript() {
    guard let url = ScriptLibrary.newScriptAndEdit() else { return }
    library?.refresh()
    island?.show(
      "已新建「\(url.lastPathComponent)」",
      detail: "改好开头几行保存，在启动器里输 hello 就能跑", actions: [.reveal(url)])
  }

  /// 拖脚本文件进来：先看一眼再导入（一次一个；拖了几个只看第一个）
  private var dropZone: some View {
    HStack(spacing: 8) {
      Image(systemName: "square.and.arrow.down")
      Text("把别人给的脚本文件拖到这里导入（导入前先看一眼全文）")
    }
    .font(.system(size: 12))
    .foregroundStyle(isTargeted ? AnyShapeStyle(Style.brandInk) : AnyShapeStyle(.secondary))
    .frame(maxWidth: .infinity, minHeight: 34)
    .background {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .strokeBorder(
          isTargeted ? AnyShapeStyle(Style.brand) : AnyShapeStyle(.separator),
          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: \.isFileURL) else { return false }
      Task {
        let read = await ScriptRunner.text(of: url.path(percentEncoded: false))
        pending = Candidate(
          url: url, name: url.lastPathComponent, text: read.text, isTruncated: read.isTruncated)
      }
      return true
    } isTargeted: {
      isTargeted = $0
    }
    .accessibilityLabel("把脚本文件拖到这里导入")
  }

  /// 「添加文件夹…」：挂在设置窗上的选文件夹面板
  private func addFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "添加"
    panel.message = "选一个放脚本的文件夹（只读，不往里写）"
    let done: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      ScriptLibrary.addFolder(url)
      library?.refresh()
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: done)
    } else {
      FilePanel.begin(panel, completion: done)
    }
  }
}

/// 设置里推进一页的那种行：标题 + 一行小字 + 右边 ›（整行能点）
struct SettingsPushRow: View {
  let title: String
  let detail: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      LabeledContent {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      } label: {
        Text(title)
        Text(detail)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityHint("打开「\(title)」")
  }
}

/// 导入之前看一眼：名字、写明会以你的身份运行、整段脚本（等宽字，能滚、能选）；「导入」才复制进默认文件夹
private struct ScriptImportSheet: View {
  let candidate: ScriptsSection.Candidate
  let cancel: () -> Void
  let confirm: () -> Void

  var body: some View {
    let script = ScriptCommand.parse(candidate.text, path: "/脚本/" + candidate.name)
    VStack(alignment: .leading, spacing: 12) {
      Text(candidate.url == nil ? "把剪贴板里的脚本存成「\(candidate.name)」？" : "导入「\(candidate.name)」？")
        .font(.headline)
      switch script {
      case .success(let script)?:
        Text(
          "启动器里叫「\(script.title)」"
            + (script.keyword.map { "，关键词「\($0)」" } ?? "") + "。")
      case .failure(let problem)?:
        Text("这个文件现在还跑不了：\(problem.text)。").foregroundStyle(Color(nsColor: .systemOrange))
      case nil:
        Text("这个文件第一行不是 #!，不像脚本。").foregroundStyle(Color(nsColor: .systemOrange))
      }
      Text("它会以你的身份运行，能用 Kitty Tools 已有的辅助功能、屏幕录制、完全磁盘访问授权。只导入你信得过的脚本。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if candidate.isTruncated {
        Text("这个文件超过 \(ScriptRunner.reviewLimit / 1024) KB，下面只显示了开头，看不全的脚本不能在这里导入。")
          .foregroundStyle(Style.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
      ScrollView {
        Text(
          candidate.text.isEmpty ? "读不出来" : String(candidate.text.prefix(ScriptRunner.reviewLimit))
        )
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
      }
      .frame(height: 280)
      .background(Style.hoverFill, in: .rect(cornerRadius: Style.Radius.card, style: .continuous))
      HStack {
        Spacer()
        Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button(candidate.url == nil ? "存进脚本文件夹" : "导入", action: confirm)
          .keyboardShortcut(.defaultAction)
          .disabled(candidate.isTruncated)
      }
    }
    .padding(20)
    .frame(width: 560)
  }
}
