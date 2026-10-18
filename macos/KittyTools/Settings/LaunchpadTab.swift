// 设置 › 启动台（第八族，SPEC R10；2026-10-18）。三组：
// 「启动台」——总开关（关掉后快捷键、菜单栏、触发角、捏合都不打开）、按键速查；
// 「排列」——一页几列几行（改了按新容量重新分页）、恢复默认排列（二次确认，可撤销一次）；
// 「数据」——从系统旧启动台导入布局（第 3 批加）、导入 / 恢复前的撤销。
// 页头由 SettingsRoot 画（家族色薄荷绿）。布局本身不在这里改，拖动、文件夹全在面板里（R4–R6）。

import SwiftUI

struct LaunchpadTab: View {
  /// 恢复默认排列（AppDelegate 已确认？没有：这里二次确认后调它）
  var resetDefault: () -> Void = {}
  /// 撤销上一次导入 / 恢复默认
  var undo: () -> Void = {}
  var canUndo: () -> Bool = { false }
  /// 行列数变了：按新容量重新分页并存盘
  var reflow: () -> Void = {}

  @AppStorage(Prefs.launchpadEnabled) private var enabled = true
  @AppStorage(Prefs.launchpadColumns) private var columns = 7
  @AppStorage(Prefs.launchpadRows) private var rows = 5
  @State private var confirmsReset = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $enabled) {
          Text("打开启动台")
          Text("全屏的图标网格。关掉之后快捷键、菜单栏、触发角、触控板捏合都不打开它")
        }
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("启动台的按键")
          Text("打开 / 收起、翻页、搜索、选中和打开、抖动模式、文件夹里按什么键")
        }
      } header: {
        Text("启动台")
      } footer: {
        SectionFootnote("现有的「启动器」是 ⌥Space 的搜索框，和启动台是两个东西：名字、设置、快捷键都分开。")
      }
      Section {
        LabeledContent {
          Stepper("\(columns)", value: $columns, in: Prefs.launchpadColumnChoices)
            .labelsHidden()
        } label: {
          Text("一页几列")
          Text("改了之后按新的容量重新分页")
        }
        LabeledContent {
          Stepper("\(rows)", value: $rows, in: Prefs.launchpadRowChoices)
            .labelsHidden()
        } label: {
          Text("一页几行")
          Text("大屏可以多放几行")
        }
      } header: {
        Text("排列")
      } footer: {
        SectionFootnote("新装的 App 自动追加到最后一页末尾；卸掉的从布局里拿掉。拖动排序、建文件夹、删 App 都在启动台里做。")
      }
      Section {
        LabeledContent {
          Button("恢复默认排列…") { confirmsReset = true }
        } label: {
          Text("恢复默认排列")
          Text("系统 App 在前、「其他」文件夹装工具、其余按名字排。不影响 App 本身")
        }
        LabeledContent {
          Button("撤销上一次导入…", action: undo)
            .disabled(!canUndo())
        } label: {
          Text("撤销上一次导入")
          Text("把布局换回导入 / 恢复默认之前的样子，只能用一次")
        }
      } header: {
        Text("排列数据")
      }
    }
    .onChange(of: columns) { reflow() }
    .onChange(of: rows) { reflow() }
    .confirmationDialog("恢复默认排列？", isPresented: $confirmsReset) {
      Button("恢复", role: .destructive, action: resetDefault)
    } message: {
      Text("现在的排法会被换掉；之后可以在「撤销上一次导入」里换回来一次。App 本身不受影响。")
    }
  }
}
