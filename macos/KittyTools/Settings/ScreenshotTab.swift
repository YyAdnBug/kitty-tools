// 设置 › 截图：⌘S 快速保存的位置、快门声（可试听）、识字是否把换行合成一段（开关旁边实时对照效果）。
// 框选、标注、长截图的按键不写进页里（N11）：一句话 +「查看全部快捷键…」打开速查表；全局快捷键在「快捷键」页。

import AppKit
import SwiftUI

struct ScreenshotTab: View {
  /// 读它只为了在「更改…」之后刷新显示；实际位置以 ScreenshotOutput.saveDirectory 为准（有兜底）
  @AppStorage(Prefs.screenshotSaveDirectory) private var savedDirectory: String?
  @AppStorage(Prefs.ocrJoinLines) private var joinLines = false
  @AppStorage(Prefs.screenshotShutterSound) private var shutterSound = true

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
        Toggle(isOn: $shutterSound) {
          HStack(spacing: 6) {
            Text("截图时播放快门声")
            Button("试听", systemImage: "speaker.wave.2.fill") { FlyCard.playShutter() }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .disabled(!shutterSound)
              .help("试听快门声")
          }
        }
      } footer: {
        caption("复制、保存、钉图时响；还要系统设置 › 声音里的「播放用户界面音效」开着。截图翻译、识字不出声。")
      }
      Section {
        Toggle("识字后把换行合成一段", isOn: $joinLines)
        JoinLinesPreview(joins: joinLines)
      } footer: {
        caption("整段合成一行：中文、日文的行直接接上，其它文字之间加空格。框选里有二维码或条码时复制它的内容。")
      }
      Section {
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("框选、标注和长截图的按键")
          Text("拖动框选，数字键 1–0 换标注工具，↩ 拷贝，S 长截图。")
        }
      }
    }
    .formStyle(.grouped)
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

/// 「合成一段」的实时对照：同一段识别结果，开关打开时按 OCR.joiningLines 接成一行（中文直接连、英文加空格）
private struct JoinLinesPreview: View {
  let joins: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let sample = "敏捷的棕色狐狸\n跳过了懒狗。The quick\nbrown fox jumps."

  var body: some View {
    Text(joins ? OCR.joiningLines(Self.sample) : Self.sample)
      .font(.system(size: 12, design: .monospaced))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(
        Style.controlFill, in: .rect(cornerRadius: Style.Radius.control, style: .continuous)
      )
      .contentTransition(.opacity)
      .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: joins)
      .accessibilityLabel("效果示例")
      .accessibilityValue(joins ? OCR.joiningLines(Self.sample) : Self.sample)
  }
}
