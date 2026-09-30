// 设置 › 截图：⌘S 快速保存的位置（文件夹图标 + 访达里的名字，选过的能恢复默认，体检 A28；录屏、录音也存这里）、快门声（可试听）、
// 截图后留不留常驻缩略图（体检 D18）、识字是否把同一段里的换行接起来（开关旁边实时对照效果，体检 A32）、
// 录屏（录屏第 2 批，拍板 C4-a）：帧率 30 / 60、开始前倒数、显示光标。
// 框选、标注、长截图、录屏的按键不写进页里（N11）：一句话 +「查看全部快捷键…」打开速查表；全局快捷键在「快捷键」页。

import AppKit
import SwiftUI

struct ScreenshotTab: View {
  /// 选过的文件夹（没选过 = nil，跟随系统截屏的存储位置）；实际位置按 ScreenshotOutput.directory 算（有兜底）
  @AppStorage(Prefs.screenshotSaveDirectory) private var savedDirectory: String?
  @AppStorage(Prefs.ocrJoinLines) private var joinLines = false
  @AppStorage(Prefs.screenshotShutterSound) private var shutterSound = true
  @AppStorage(Prefs.screenshotShelf) private var keepsThumbnail = true
  @AppStorage(Prefs.screenRecordFrameRate) private var frameRate = 30
  @AppStorage(Prefs.screenRecordCountdown) private var countdown = 3
  @AppStorage(Prefs.screenRecordShowsCursor) private var showsCursor = true

  var body: some View {
    Form {
      Section {
        LabeledContent("快速保存到") {
          HStack(spacing: 8) {
            let directory = ScreenshotOutput.directory(saved: savedDirectory)
            // 同工具栏「存储到「桌面」」：访达里的名字 + 文件夹图标，完整路径在悬停提示里
            Label {
              Text(FileManager.default.displayName(atPath: directory.path))
                .lineLimit(1)
                .truncationMode(.middle)
            } icon: {
              Image(nsImage: NSWorkspace.shared.icon(forFile: directory.path))
                .resizable()
                .frame(width: 16, height: 16)
            }
            .foregroundStyle(.secondary)
            .help((directory.path as NSString).abbreviatingWithTildeInPath)
            if savedDirectory != nil {
              Button("恢复默认") { savedDirectory = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Style.brandInk)
                .pointerStyle(.link)
                .help("跟随系统截屏的存储位置")
            }
            Button("更改…", action: chooseDirectory)
          }
        }
      } footer: {
        caption(
          "按 ⌘S 或工具栏的「存储」存到这里，文件名是「截图 日期 时间.png」，重名自动加序号。没选过时跟随系统截屏的存储位置。录屏、录音也存这里，文件名是「录屏 日期 时间.mp4」「录音 日期 时间.m4a」。"
        )
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
        caption("拷贝、存储、钉图时响；还要系统设置 › 声音里的「播放用户界面音效」开着。截图翻译、识字不出声。")
      }
      Section {
        Toggle("截图后在屏幕角落留缩略图", isOn: $keepsThumbnail)
      } footer: {
        caption("可以拖出、钉图、存储；关掉后截图只在右下角闪一下。")
      }
      Section {
        Toggle("识字后把同一段里的换行接起来", isOn: $joinLines)
        JoinLinesPreview(joins: joinLines)
      } footer: {
        caption("同一段里的行接起来，段和段之间保留换行：中文、日文的行直接接上，其它文字之间加空格。截图翻译总是这样接。框选里有二维码或条码时复制它的内容。")
      }
      Section {
        Picker("帧率", selection: $frameRate) {
          Text("30 fps").tag(30)
          Text("60 fps").tag(60)
        }
        .pickerStyle(.segmented)
        Picker("开始前倒数", selection: $countdown) {
          Text("不倒数").tag(0)
          Text("3 秒").tag(3)
          Text("5 秒").tag(5)
        }
        Toggle("显示光标", isOn: $showsCursor)
      } header: {
        Text("录屏")
      } footer: {
        caption("60 fps 更顺，文件大约大一半；大屏上可能录不满 60。")
      }
      Section {
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("框选、标注、长截图和录屏的按键")
          Text("拖动框选，数字键 1–0 换标注工具，↩ 拷贝，S 长截图，R 录屏。")
        }
      }
    }
    .formStyle(.grouped)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = ScreenshotOutput.directory(saved: savedDirectory)
    panel.prompt = "选取"
    panel.begin { response in
      if response == .OK, let url = panel.url { savedDirectory = url.path }
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }
}

/// 「接起来」的实时对照：两段四行的识别结果（带行框，两段之间空出一行），开关打开时按 OCR.text 分段接好
/// （中文直接连、英文加空格，段间换行）
private struct JoinLinesPreview: View {
  let joins: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 行高 0.1、行距 0.03，两段之间空 0.15（> 1.2 倍行高）
  private static let sample: [OCR.Line] = [
    ("敏捷的棕色狐狸", 0.9, 0.7), ("跳过了懒狗。", 0.77, 0.6), ("The quick brown", 0.52, 0.75),
    ("fox jumps over it.", 0.39, 0.7),
  ].map { OCR.Line(text: $0.0, box: CGRect(x: 0.1, y: $0.1 - 0.1, width: $0.2, height: 0.1)) }

  var body: some View {
    let text = OCR.text(Self.sample, joined: joins)
    Text(text)
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
      .accessibilityValue(text)
  }
}
