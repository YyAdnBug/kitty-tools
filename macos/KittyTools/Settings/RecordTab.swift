// 设置 › 录制（2026-10-03 用户要求从「截图」页拆出来，对标 CleanShot 的设置也是单独一页）：保存到（SaveDirectoryRow，
// 和截图页「快速保存到」同一个偏好）；录屏（录屏第 2 批，拍板 C4-a）：帧率 30 / 60、清晰度 原始 / 标准、编码 H.264 / HEVC
// （第二轮体检 R1：文件嫌大时调这两样）、开始前倒数、显示光标、显示按键时 全部按键 / 只显示快捷键（R2）；
// 录音（录音第 6 批，拍板 A2-a）：来源 麦克风 / 系统声音 / 两者（手测反馈第 3 批起录音控制条待录时也能切，两边读写同一个偏好）、
// 按快捷键后立即开始录音（手测反馈第 3 批，默认关：先出控制条，点 ● 或再按一次才开始）。
// 录屏用哪个麦克风（第四轮体检 X18）：跟随系统输入（默认）或某一个接着的设备，选的那个不在了开录时说一声、跟随系统。
// 按键不写进页里（N11）：一句话 +「查看全部快捷键…」；菜单栏、快捷键页、速查表里录屏录音仍和截图同在「截图与录制」一节。
// 2026-11-18 设置改版 S4：帧率、编码、显示按键时、按快捷键后立即开始录音收进「高级…」（文件嫌大、录音怎么开始，一年改一次）。

import AVFoundation
import SwiftUI

struct RecordTab: View {
  /// 截图自检直接画「高级…」表单（sheet 画不进屏外截图）
  var drawsAdvanced = false
  @AppStorage(Prefs.screenRecordFrameRate) private var frameRate = 30
  @AppStorage(Prefs.screenRecordCountdown) private var countdown = 3
  @AppStorage(Prefs.screenRecordShowsCursor) private var showsCursor = true
  @AppStorage(Prefs.screenRecordSharpness) private var sharpness = ScreenRecorder.Sharpness.original
  @AppStorage(Prefs.screenRecordCodec) private var codec = ScreenRecorder.Codec.h264
  @AppStorage(Prefs.screenRecordKeysShortcutsOnly) private var shortcutsOnly = false
  @AppStorage(Prefs.audioRecordSource) private var audioSource = AudioRecorder.Source.microphone
  @AppStorage(Prefs.audioRecordStartsImmediately) private var startsImmediately = false
  @AppStorage(Prefs.screenRecordMicrophoneDevice) private var microphoneDevice: String?
  /// 接着的麦克风：打开这一页时读一次，插拔时（系统的接上 / 拔掉通知，2026-11-23 美化与提速 P6）再读。onAppear 里读：
  /// @State 的初值每次建视图都会算一遍
  @State private var microphones: [(id: String, name: String)] = []

  var body: some View {
    // 关着时（Feature）变灰；存到哪个文件夹截图也在用，照常能改
    Form {
      Section { FeatureToggle(feature: .record, inPage: true) }
      Section {
        SaveDirectoryRow(
          title: "保存到", subtitle: "和截图的「快速保存到」是同一个",
          info: "文件名是「录屏 日期 时间.mp4」「录音 日期 时间.m4a」。"
        )
        .settingsAnchor(.recordSaveFolder)
      }
      Group {
        Section {
          SettingRow(
            title: "清晰度", subtitle: "标准：文件小一半，小字糊一些",
            info: "标准清晰度在高分屏上宽高各减半。录好的也可以在角落的缩略图上点「压缩」另存一份小的。"
          ) {
            Picker("清晰度", selection: $sharpness) {
              Text("原始").tag(ScreenRecorder.Sharpness.original)
              Text("标准").tag(ScreenRecorder.Sharpness.standard)
            }
            .pickerStyle(.segmented)
          }
          .settingsAnchor(.recordSharpness)
          Picker("开始前倒数", selection: $countdown) {
            Text("不倒数").tag(0)
            Text("3 秒").tag(3)
            Text("5 秒").tag(5)
          }
          .settingsAnchor(.recordCountdown)
          Toggle("显示光标", isOn: $showsCursor)
            .settingsAnchor(.recordCursor)
          SettingRow(
            title: "麦克风", subtitle: "录制条上的麦克风开着时用哪个",
            info: "选的那个没接着时这次用系统默认的；录音照旧用系统默认的输入。"
          ) {
            Picker("麦克风", selection: $microphoneDevice) {
              Text("跟随系统输入").tag(String?.none)
              ForEach(microphones, id: \.id) { Text(verbatim: $0.name).tag(String?.some($0.id)) }
              // 选过的那个现在没接着：照样列出来（不然选单是空的、像被清掉了）
              if let microphoneDevice, !microphones.contains(where: { $0.id == microphoneDevice }) {
                Text("选过的麦克风（没接着）").tag(String?.some(microphoneDevice))
              }
            }
          }
          .settingsAnchor(.recordMicrophone)
        } header: {
          Text(ScreenRecorder.Medium.screen.nounResource)
        }
        Section {
          SettingRow(title: "来源", info: "录系统声音时菜单栏会出现屏幕录制指示；录着时锁屏会停止。") {
            Picker("来源", selection: $audioSource) {
              Text("麦克风").tag(AudioRecorder.Source.microphone)
              Text("系统声音").tag(AudioRecorder.Source.system)
              Text("两者").tag(AudioRecorder.Source.both)
            }
            .pickerStyle(.segmented)
          }
          .settingsAnchor(.recordAudioSource)
        } header: {
          Text(ScreenRecorder.Medium.audio.nounResource)
        }
        Section {
          SettingRow(
            title: "录屏和录音的按键", subtitle: "↩ 开始，再按一次快捷键停止",
            info: "框选和截图一样，双击选区也开始，Esc 取消。"
          ) {
            ShortcutsButton()
          }
          .settingsAnchor(.recordKeys)
        }
      }
      .gated(by: .record)
      Section {
      } footer: {
        AdvancedButton(page: .record)
      }
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
    .onAppear { microphones = ScreenRecorder.microphones() }
    .task { await reloadMicrophones(on: AVCaptureDevice.wasConnectedNotification) }
    .task { await reloadMicrophones(on: AVCaptureDevice.wasDisconnectedNotification) }
    .advancedSheet(.record, summary: "文件大小和录音怎么开始", inline: drawsAdvanced) { advanced }
  }

  /// 插上 / 拔掉设备时重读选单（异步序列在主线程上接：通知不一定在主线程上发）
  private func reloadMicrophones(on name: Notification.Name) async {
    for await _ in NotificationCenter.default.notifications(named: name) {
      microphones = ScreenRecorder.microphones()
    }
  }

  /// 「高级…」表单：帧率、编码、显示按键时；录音的立即开始
  @ViewBuilder private var advanced: some View {
    Section {
      SettingRow(title: "帧率", info: "60 fps 更顺，文件大约大一半；大屏上可能录不满 60。") {
        Picker("帧率", selection: $frameRate) {
          Text("30 fps").tag(30)
          Text("60 fps").tag(60)
        }
        .pickerStyle(.segmented)
      }
      .settingsAnchor(.recordFrameRate)
      SettingRow(title: "编码", info: "HEVC 同样的画面小三分之一左右，部分 App 和旧设备可能放不了。") {
        Picker("编码", selection: $codec) {
          Text("H.264").tag(ScreenRecorder.Codec.h264)
          Text("HEVC").tag(ScreenRecorder.Codec.hevc)
        }
        .pickerStyle(.segmented)
      }
      .settingsAnchor(.recordCodec)
      SettingRow(title: "显示按键时", info: "只显示快捷键：带 ⌘ ⌃ ⌥ 的组合键、Esc 和 F 键才进画面，打字不显示。") {
        Picker("显示按键时", selection: $shortcutsOnly) {
          Text("全部按键").tag(false)
          Text("只显示快捷键").tag(true)
        }
        .pickerStyle(.segmented)
      }
      .settingsAnchor(.recordKeysShown)
    } header: {
      Text(ScreenRecorder.Medium.screen.nounResource)
    }
    .gated(by: .record)
    Section {
      SettingRow(
        title: "按快捷键后立即开始录音", subtitle: "关着时先出录音控制条",
        info: "按快捷键（或点菜单栏、启动器里的「录音」）先在屏幕底部打开录音控制条，点 ● 或再按一次才开始录。"
      ) {
        Toggle("按快捷键后立即开始录音", isOn: $startsImmediately)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.recordStartsImmediately)
    } header: {
      Text(ScreenRecorder.Medium.audio.nounResource)
    }
    .gated(by: .record)
  }
}
