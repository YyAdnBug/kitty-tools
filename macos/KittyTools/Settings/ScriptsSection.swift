// 设置 › 启动器「脚本命令」那一节（2026-11-07 拍板 A1 A2 B3 B5 E2，PLAN §10「脚本命令」）：总开关（默认开）、脚本文件夹
// （默认的在数据目录里，「在访达中打开」；另外添加的只读、能移除）、「新建脚本」（照模板建一个、用文本编辑器打开）、
// 把脚本文件拖进来导入（先看一眼全文，写明以你的身份运行、能用本 App 已有的授权，点「导入」才复制进默认文件夹）、
// 读不成的脚本和原因（橙字）、跑脚本用的 PATH（第一次跑脚本时从终端读的，「重新读取」）。
// 选文件夹的面板挂成设置窗上的表单（同全局同步的「选择文件夹…」）。

import SwiftUI
import UniformTypeIdentifiers

struct ScriptsSection: View {
  let library: ScriptLibrary?
  @AppStorage(Prefs.launcherScripts) private var scriptsOn = true
  @AppStorage(Prefs.scriptFolders) private var foldersText = ""
  @AppStorage(Prefs.scriptShellPath) private var shellPath: String?
  /// 拖进来、等着看一眼再导入的那个
  @State private var pending: Candidate?
  @State private var isTargeted = false
  @State private var readingPath = false

  struct Candidate: Identifiable {
    let url: URL
    let text: String
    var id: String { url.path(percentEncoded: false) }
  }

  var body: some View {
    Section {
      Toggle(isOn: $scriptsOn) {
        Text("启用脚本命令")
        Text("脚本文件夹里的每个脚本就是启动器里的一条命令，开头几行注释写它叫什么、关键词、结果给谁")
      }
      Group {
        LabeledContent {
          Button("在访达中打开") {
            NSWorkspace.shared.open(ScriptLibrary.ensureDefaultFolder())
          }
        } label: {
          Text("脚本文件夹")
          Text(
            (ScriptLibrary.defaultFolder.path(percentEncoded: false) as NSString)
              .abbreviatingWithTildeInPath)
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
          }
        }
        HStack {
          Button("添加文件夹…", action: addFolder)
          Button("新建脚本") {
            if let url = ScriptLibrary.newScript() {
              ScriptLibrary.edit(url.path(percentEncoded: false))
              library?.refresh()
            }
          }
          Spacer()
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
        LabeledContent {
          Button(readingPath ? "正在读取…" : "重新读取") {
            readingPath = true
            ScriptRunner.forgetSearchPath()
            Task {
              _ = await ScriptRunner.searchPath()
              readingPath = false
            }
          }
          .disabled(readingPath)
        } label: {
          Text("命令的查找路径")
          Text(
            shellPath.map { "从终端里读到的：\($0)" }
              ?? "第一次运行脚本时从终端里读一遍，nvm、pyenv 装的命令也找得到"
          )
          .lineLimit(2)
          .truncationMode(.middle)
        }
      }
      .disabled(!scriptsOn)
    } header: {
      Text("脚本命令")
    } footer: {
      SectionFootnote(
        "脚本以你的身份运行，能用 Kitty Tools 已有的辅助功能、屏幕录制、完全磁盘访问授权，只放你信得过的脚本。"
          + "从网上下载的脚本，第一次运行前会先给你看一眼全文。脚本文件不跟着同步，几台 Mac 共用就把文件夹放进 iCloud 云盘、在每台添加。")
    }
    .sheet(item: $pending) { candidate in
      ScriptImportSheet(candidate: candidate) {
        pending = nil
      } confirm: {
        pending = nil
        Task {
          _ = await ScriptLibrary.importScript(candidate.url, into: ScriptLibrary.defaultFolder)
          library?.refresh()
        }
      }
    }
  }

  private var addedFolders: [URL] {
    _ = foldersText  // 跟着偏好变
    return ScriptLibrary.addedFolders
  }

  /// 拖脚本文件进来：先看一眼再导入（一次一个；拖了几个只看第一个）
  private var dropZone: some View {
    HStack(spacing: 8) {
      Image(systemName: "square.and.arrow.down")
      Text("把脚本文件拖到这里导入")
    }
    .font(.system(size: 12))
    .foregroundStyle(isTargeted ? AnyShapeStyle(Style.brandInk) : AnyShapeStyle(.secondary))
    .frame(maxWidth: .infinity, minHeight: 44)
    .background {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .strokeBorder(
          isTargeted ? AnyShapeStyle(Style.brand) : AnyShapeStyle(.separator),
          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: \.isFileURL) else { return false }
      Task {
        let text = await ScriptRunner.text(of: url.path(percentEncoded: false))
        pending = Candidate(url: url, text: text)
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

/// 导入之前看一眼：名字、写明会以你的身份运行、整段脚本（等宽字，能滚、能选）；「导入」才复制进默认文件夹
private struct ScriptImportSheet: View {
  let candidate: ScriptsSection.Candidate
  let cancel: () -> Void
  let confirm: () -> Void

  var body: some View {
    let script = ScriptCommand.parse(
      candidate.text, path: candidate.url.path(percentEncoded: false))
    VStack(alignment: .leading, spacing: 12) {
      Text("导入「\(candidate.url.lastPathComponent)」？").font(.headline)
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
      ScrollView {
        Text(candidate.text.isEmpty ? "读不出来" : candidate.text)
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
        Button("导入", action: confirm).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560)
  }
}
