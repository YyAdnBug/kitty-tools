// 设置 › 便签（PLAN §10「便签」F②，排在「录制」后面；2026-10-12 第 2 批只有骨架，边缘那叠的设置第 3 批再加）：
// 「便签」组——全部便签窗口里正文的字号（四档单选）；「数据」组——打开全部便签窗口的按钮、按键速查，
// 页脚说便签存在哪、怎么备份、删掉的留多久、导出导入在哪。页头由 SettingsRoot 画（家族色黄）。

import SwiftUI

struct NotesTab: View {
  /// 打开全部便签窗口（AppDelegate.showNotes；便签这次用不了时它自己说）
  let openNotes: () -> Void
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15

  private static let fontTitles = [13: "小", 15: "标准", 17: "大", 20: "特大"]

  var body: some View {
    Form {
      Section {
        // 横排单选包进 LabeledContent：贴着右边线（同设置 › 剪贴板「图片最多占用」）
        LabeledContent {
          Picker("正文字号", selection: $fontSize) {
            ForEach(Prefs.notesFontSizeChoices, id: \.self) {
              Text(Self.fontTitles[$0] ?? "\($0)").tag($0)
            }
          }
          .pickerStyle(.radioGroup)
          .horizontalRadioGroupLayout()
          .labelsHidden()
          .fixedSize()
        } label: {
          Text("正文字号")
          Text("全部便签窗口里正文的大小")
        }
      } header: {
        Text("便签")
      }
      Section {
        LabeledContent {
          Button("打开全部便签…", action: openNotes)
        } label: {
          Text(HotKeyAction.noteAll.title)
          Text("看、改、搜索、归档便签，找回删掉的")
        }
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("便签的按键")
          Text("快速记一条和全部便签窗口里按什么键")
        }
      } header: {
        Text("数据")
      } footer: {
        SectionFootnote(
          "便签存在这台 Mac 上，和剪贴板历史分开：清空历史、保留天数都碰不到它。每天自动备份一份，留最近 7 份。删掉的便签在「最近删除」里留 \(NoteStore.trashDays) 天。导出与导入在 设置 › 通用 里。"
        )
      }
    }
    .formStyle(.grouped)
  }
}
