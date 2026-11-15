// 「新建脚本」的小表单（脚本命令第三轮 D2，对标 Raycast 的 Create Script Command）：名字、关键词、结果给谁（六种）、
// 用什么写（zsh、JavaScript、AppleScript、Python），按选的生成开头几行和一段能跑的示例（ScriptLibrary.template），
// 存进默认文件夹、用编辑器打开。设置 › 启动器「新建脚本」和启动器里的「新建脚本」（经 SettingsNavigation.showsNewScript）
// 都打开它，挂在设置窗上（ScriptsSection）。

import SwiftUI

struct NewScriptSheet: View {
  /// 建好了（文件的位置）
  let created: (URL) -> Void
  let cancel: () -> Void
  @State private var title = ""
  @State private var keyword = ""
  @State private var mode = ScriptCommand.Mode.island
  @State private var language = ScriptLibrary.Language.zsh
  @State private var failed = false

  /// 结果给谁：和写法说明里的说法一样
  static func modeTitle(_ mode: ScriptCommand.Mode) -> String {
    switch mode {
    case .island: String(localized: "岛上显示最后一行")
    case .paste: String(localized: "粘贴到前台 App")
    case .copy: String(localized: "复制到剪贴板")
    case .full: String(localized: "在启动器里看全部输出")
    case .list: String(localized: "列出几条结果来挑")
    case .none:
      String(localized: "launcher.scriptMode.none", defaultValue: "不显示", comment: "脚本的结果给谁：不显示")
    }
  }

  private var name: String {
    let text = title.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? ScriptLibrary.untitled : text
  }

  /// 关键词只取第一个词、折成小写（同读脚本时）
  private var folded: String? { ScriptCommand.keyword(keyword) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("新建脚本").font(.headline)
      Form {
        TextField("名字", text: $title, prompt: Text("新脚本"))
        TextField("关键词", text: $keyword, prompt: Text("可以不填，如 hello"))
        Picker("结果给谁", selection: $mode) {
          ForEach(ScriptCommand.Mode.allCases, id: \.self) { mode in
            Text(Self.modeTitle(mode)).tag(mode)
          }
        }
        Picker("用什么写", selection: $language) {
          ForEach(ScriptLibrary.Language.allCases, id: \.self) { language in
            Text(language.title).tag(language)
          }
        }
      }
      .formStyle(.columns)
      Text(verbatim: help)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if failed {
        Text("没建成：脚本文件夹写不进去。").foregroundStyle(Color(nsColor: .systemRed))
      }
      HStack {
        Spacer()
        Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button("新建", action: create)
          .buttonStyle(BrandButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  /// 表单下面那句：建好以后怎么跑（写了关键词的说打它，用 Python 的提一句要装 python3）
  private var help: String {
    let next =
      folded.map { String(localized: "在启动器里输 \($0) 就能跑。") } ?? String(localized: "在启动器里按名字找它。")
    let python = language == .python ? String(localized: "Python 要先装好 python3。") : ""
    return String(localized: "建好后用编辑器打开，里面有一段能直接跑的示例；改好保存，\(next)\(python)")
  }

  private func create() {
    guard
      let url = ScriptLibrary.newScript(
        title: name, keyword: folded, mode: mode, language: language)
    else {
      failed = true
      return
    }
    created(url)
  }
}
