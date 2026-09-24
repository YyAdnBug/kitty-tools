// 设置 › 截图：⌘S 快速保存的位置、识字是否把换行合成一段，以及框选里的按键说明。快捷键在「快捷键」页。

import AppKit
import SwiftUI

struct ScreenshotTab: View {
  /// 读它只为了在「更改…」之后刷新显示；实际位置以 ScreenshotOutput.saveDirectory 为准（有兜底）
  @AppStorage(Prefs.screenshotSaveDirectory) private var savedDirectory: String?
  @AppStorage(Prefs.ocrJoinLines) private var joinLines = false

  var body: some View {
    Form {
      Section {
        LabeledContent("快速保存到") {
          HStack {
            Text(displayPath)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(.secondary)
            Button("更改…", action: chooseDirectory)
          }
        }
      } footer: {
        caption("框选后按 ⌘S 存到这里，文件名是「截图 日期 时间.png」，重名自动加序号；「另存为」选的文件夹也会记成这里。")
      }
      Section {
        Toggle("识字后把换行合成一段", isOn: $joinLines)
      } footer: {
        caption("整段合成一行：中文、日文的行直接接上，其它文字之间加空格。框选里有二维码或条码时复制它的内容。")
      }
      Section("框选时的按键") {
        caption(
          "拖动框选，单击截取鼠标下的窗口；拖动时按住空格平移。选好后：1–4 标注（矩形、箭头、文字、马赛克，按住 ⇧ 画正方形 / 45° 箭头），"
            + "点中标注可拖动、改颜色粗细、⌫ 删除，双击文字重新编辑，⌘Z 撤销、⇧⌘Z 重做；方向键微调（⇧ 10 点）。"
            + "↩ 复制，⌘S 保存，⇧⌘S 另存为，T 钉图，C 复制放大镜里的色值，D 选中上次的区域，右键重新框选，Esc 取消。")
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var displayPath: String {
    _ = savedDirectory
    return (ScreenshotOutput.saveDirectory.path as NSString).abbreviatingWithTildeInPath
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = ScreenshotOutput.saveDirectory
    panel.prompt = "选取"
    panel.begin { response in
      if response == .OK, let url = panel.url { savedDirectory = url.path }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }
}
