// 设置 › 录制（2026-10-03 用户要求从「截图」页拆出来，对标 CleanShot 的设置也是单独一页）：保存到（SaveDirectoryRow，
// 和截图页「快速保存到」同一个偏好）；录屏（录屏第 2 批，拍板 C4-a）：帧率 30 / 60、清晰度 原始 / 标准、编码 H.264 / HEVC
// （第二轮体检 R1：文件嫌大时调这两样）、开始前倒数、显示光标、显示按键时 全部按键 / 只显示快捷键（R2）；
// 录音（录音第 6 批，拍板 A2-a）：来源 麦克风 / 系统声音 / 两者（手测反馈第 3 批起录音控制条待录时也能切，两边读写同一个偏好）、
// 按快捷键后立即开始录音（手测反馈第 3 批，默认关：先出控制条，点 ● 或再按一次才开始）。
// 按键不写进页里（N11）：一句话 +「查看全部快捷键…」；菜单栏、快捷键页、速查表里录屏录音仍和截图同在「截图与录制」一节。

import SwiftUI

struct RecordTab: View {
  @AppStorage(Prefs.screenRecordFrameRate) private var frameRate = 30
  @AppStorage(Prefs.screenRecordCountdown) private var countdown = 3
  @AppStorage(Prefs.screenRecordShowsCursor) private var showsCursor = true
  @AppStorage(Prefs.screenRecordSharpness) private var sharpness = ScreenRecorder.Sharpness.original
  @AppStorage(Prefs.screenRecordCodec) private var codec = ScreenRecorder.Codec.h264
  @AppStorage(Prefs.screenRecordKeysShortcutsOnly) private var shortcutsOnly = false
  @AppStorage(Prefs.audioRecordSource) private var audioSource = AudioRecorder.Source.microphone
  @AppStorage(Prefs.audioRecordStartsImmediately) private var startsImmediately = false

  var body: some View {
    Form {
      Section {
        SaveDirectoryRow(title: "保存到")
      } footer: {
        caption("和「截图」页的「快速保存到」是同一个文件夹，文件名是「录屏 日期 时间.mp4」「录音 日期 时间.m4a」。")
      }
      Section {
        Picker("帧率", selection: $frameRate) {
          Text("30 fps").tag(30)
          Text("60 fps").tag(60)
        }
        .pickerStyle(.segmented)
        Picker("清晰度", selection: $sharpness) {
          Text("原始").tag(ScreenRecorder.Sharpness.original)
          Text("标准").tag(ScreenRecorder.Sharpness.standard)
        }
        .pickerStyle(.segmented)
        Picker("编码", selection: $codec) {
          Text("H.264").tag(ScreenRecorder.Codec.h264)
          Text("HEVC").tag(ScreenRecorder.Codec.hevc)
        }
        .pickerStyle(.segmented)
        Picker("开始前倒数", selection: $countdown) {
          Text("不倒数").tag(0)
          Text("3 秒").tag(3)
          Text("5 秒").tag(5)
        }
        Toggle("显示光标", isOn: $showsCursor)
        Picker("显示按键时", selection: $shortcutsOnly) {
          Text("全部按键").tag(false)
          Text("只显示快捷键").tag(true)
        }
        .pickerStyle(.segmented)
      } header: {
        Text("录屏")
      } footer: {
        caption(
          "60 fps 更顺，文件大约大一半；大屏上可能录不满 60。文件嫌大：标准清晰度在高分屏上宽高各减半，文件小一半多，小字会糊一些；HEVC 同样的画面小三分之一左右，部分 App 和旧设备可能放不了。录好的也可以在角落的缩略图上点「压缩」另存一份小的。只显示快捷键：带 ⌘ ⌃ ⌥ 的组合键、Esc 和 F 键才进画面，打字不显示。"
        )
      }
      Section {
        Picker("来源", selection: $audioSource) {
          Text("麦克风").tag(AudioRecorder.Source.microphone)
          Text("系统声音").tag(AudioRecorder.Source.system)
          Text("两者").tag(AudioRecorder.Source.both)
        }
        .pickerStyle(.segmented)
        Toggle("按快捷键后立即开始录音", isOn: $startsImmediately)
      } header: {
        Text("录音")
      } footer: {
        caption(
          "录系统声音时菜单栏会出现屏幕录制指示；锁屏会停止；不能暂停。立即开始关着时，按快捷键（或点菜单栏、启动器里的「录音」）先在屏幕底部打开录音控制条，点 ● 或再按一次才开始录。"
        )
      }
      Section {
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("录屏和录音的按键")
          Text("框选和截图一样，↩ 或双击选区开始，Esc 取消；录着时再按一次快捷键停止并保存。")
        }
      }
    }
    .formStyle(.grouped)
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }
}
