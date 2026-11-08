// 设置 › 启动器 › 怎么写脚本（2026-11-07 真机反馈「脚本如何使用、新建是不是要说明一下，不然用户不会用」；PLAN §10「脚本命令」）：
// 从「脚本命令」一节推进来的说明页。让 AI 来写（第二轮 A2：复制给 AI 的写法说明、能展开看全文；AI 给的脚本从剪贴板新建在
// 「脚本命令」那一节）；三步上手；一个能直接用的例子（查天气：带参数、岛上显示一行），「复制这个例子」「用它新建」；
// 开头几行能写什么（每个字段一行：写法、做什么、怎么填）；列表脚本怎么吐结果；用什么跑、环境变量、命令的查找路径（「重新读取」）；
// 安全和同步。界面文案不提别的产品（另一种写法只写字段前缀 @raycast.，那是功能本身要认的写法）。

import SwiftUI

struct ScriptGuidePage: View {
  static let route = "page:script-guide"
  let library: ScriptLibrary?
  @AppStorage(Prefs.scriptShellPath) private var shellPath: String?
  @Environment(Island.self) private var island: Island?
  @Environment(\.dismiss) private var dismiss
  @State private var readingPath = false

  /// 开头能写的字段：写法、做什么、怎么填
  static let fields: [(name: String, title: String, detail: String)] = [
    ("@kitty.title", "名字", "启动器里显示的名字，不写就用文件名"),
    ("@kitty.keyword", "关键词", "在启动器里打它就排第一；设置 › 启动器「命令和别名」里还能改"),
    (
      "@kitty.mode", "结果给谁",
      "island 岛上显示最后一行（不写就是它）、paste 粘贴到前台 App、copy 复制、full 在启动器里看全部输出、list 每行一条结果可以挑、none 不显示"
    ),
    (
      "@kitty.argument1", "参数（最多 3 个）",
      "写参数的名字，如「城市」；在启动器里输「关键词 空格 文字」，文字在 $1 里。可以不填的写成 `{\"placeholder\": \"城市\", \"optional\": true}`；要直接拼进网址的再加 `\"percentEncoded\": true`（先做网址编码）"
    ),
    ("@kitty.description", "副标题", "启动器里名字后面的那行小字"),
    (
      "@kitty.icon", "图标",
      "一个 emoji、SF 符号的名字、同一个文件夹里的图片文件名，或者 https 开头的图片网址（第一次用时下载一次，以后不再联网）；深色主题换一张写在 @kitty.iconDark"
    ),
    ("@kitty.confirm", "先确认再跑", "写一句话：↩ 第一下只显示这句（红字），再按一次才跑；列表脚本打字时就跑，不能写"),
    ("@kitty.timeout", "超时", "秒数，不写是 60 秒，写 0 不限"),
  ]

  var body: some View {
    VStack(spacing: 0) {
      DetailHeader(title: "怎么写脚本", status: "一个脚本文件就是启动器里的一条命令") {
        KindTile(symbol: "terminal.fill", color: Style.Family.command, size: 40)
      }
      Form {
        Section {
          Text(
            "不会写也没关系：把这份写法说明复制给你常用的 AI，在最后一段写上想让脚本做什么，AI 会照规矩写好。把它给的脚本复制下来，回到「脚本命令」点「从剪贴板新建」，看一眼就能存。"
          )
          .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("复制写法说明") {
              Paster.write(string: ScriptAIGuide.text, record: true)
              island?.show("已复制脚本写法说明", detail: "贴给你常用的 AI，在最后一段写上想做什么")
            }
            Spacer()
          }
          DisclosureGroup("看说明全文") {
            code(ScriptAIGuide.text)
          }
        } header: {
          Text("让 AI 来写")
        }
        Section {
          step(1, "在「脚本命令」里点「新建脚本」", "脚本文件夹里多一个照模板写好的脚本，用编辑器打开")
          step(2, "改开头几行，下面写要跑的命令", "开头几行写它叫什么、关键词、结果给谁；下面就是普通的 shell 命令")
          step(3, "保存，在启动器里输关键词，按 ↩", "不用重启、不用给可执行权限；改了随时生效")
        } header: {
          Text("三步上手")
        } footer: {
          SectionFootnote(
            "脚本用 .sh 文件的默认 App 打开；默认的那个不是编辑器（比如终端，一开就跑了）时，改用打开纯文本的那个编辑器。想换编辑器：在访达里选一个 .sh 文件，⌘I 显示简介，「打开方式」选好后点「全部更改…」。启动器里选中一条脚本，⌘E 就能改它。"
          )
        }
        Section {
          code(ScriptLibrary.example)
          HStack {
            Button("复制这个例子") {
              Paster.write(string: ScriptLibrary.example, record: true)
              island?.show("已复制例子", detail: "贴进脚本文件夹里的一个 .sh 文件就能用")
            }
            Button("用它新建") { library?.newExample(island: island) }
            Spacer()
          }
        } header: {
          Text("一个例子：查天气")
        } footer: {
          SectionFootnote("在启动器里输「tq 空格 北京」，↩ 后刘海岛显示北京的天气。要联网。")
        }
        Section {
          ForEach(Self.fields, id: \.name) { field in
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 8) {
                Text(field.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(
                  Style.brandInk)
                Text(field.title).font(.system(size: 13, weight: .medium))
              }
              // 反引号里的（JSON、取值）是等宽字，和左边的字段名一样
              Text(
                (try? AttributedString(markdown: field.detail)) ?? AttributedString(field.detail)
              )
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
          }
        } header: {
          Text("开头几行能写什么")
        } footer: {
          SectionFootnote(
            "每行以 #、// 或 -- 开头都行。网上常见的另一种写法（字段以 @raycast. 开头）也认，下载下来不用改。文件名里带 .template. 的不列出来。")
        }
        Section {
          Text(
            "mode 写 list 时，脚本每打印一行就是一条结果，写成「结果⇥说明」（中间是 Tab），↩ 粘贴选中的那条。打字时会重新跑。"
          )
          .fixedSize(horizontal: false, vertical: true)
          code(#"{"items": [{"title": "显示的", "subtitle": "说明", "arg": "↩ 粘贴的"}]}"#)
          Text("要显示的和粘贴的不一样时，打印上面这样一段 JSON。")
            .foregroundStyle(.secondary)
        } header: {
          Text("列出几条结果让人挑")
        }
        Section {
          Text(
            "第一行 #! 写用什么跑：/bin/zsh、/bin/bash、/usr/bin/osascript（AppleScript，加 -l JavaScript 写 JavaScript），或者 /usr/bin/env node、/usr/bin/env python3（要先装好）。"
          )
          .fixedSize(horizontal: false, vertical: true)
          Text(
            "工作目录是脚本所在的文件夹。能用的环境变量：KITTY_SCRIPT_DIR（脚本所在的文件夹）、KITTY_DATA_DIR（Kitty Tools 的数据目录）、KITTY_VERSION。退出码不是 0 算出错，最后一行显示在刘海岛上。"
          )
          .fixedSize(horizontal: false, vertical: true)
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
            Text(shellPath ?? "第一次运行脚本时从终端里读一遍，nvm、pyenv、Homebrew 装的命令也找得到")
              .lineLimit(3)
              .truncationMode(.middle)
          }
        } header: {
          Text("用什么跑")
        }
        Section {
          Text(
            "脚本以你的身份运行，能用 Kitty Tools 已有的辅助功能、屏幕录制、完全磁盘访问授权，只放你信得过的。从网上下载的脚本，第一次运行前会先在启动器里给你看一眼全文。"
          )
          .fixedSize(horizontal: false, vertical: true)
          Text("脚本文件不跟着同步，也不进设置的导出；别名和开关跟着走。几台 Mac 共用，就把脚本文件夹放进 iCloud 云盘，在每台「添加文件夹…」。")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
          Text("安全和同步")
        }
      }
      .formStyle(.grouped)
    }
    .navigationTitle("怎么写脚本")
    .toolbar { SettingsBackButton { dismiss() } }
  }

  private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Style.onBrand)
        .frame(width: 20, height: 20)
        .background(Style.brand, in: .circle)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func code(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12, design: .monospaced))
      .lineSpacing(2)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Style.hoverFill, in: .rect(cornerRadius: Style.Radius.card, style: .continuous))
  }
}
