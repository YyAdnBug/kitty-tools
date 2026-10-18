// 设置 › 启动台（第八族，SPEC R10；2026-10-18）。五组：
// 「启动台」——总开关（关掉后快捷键、菜单栏、触发角、捏合都不打开）、按键速查；
// 「排列」——一页几列几行（改了按新容量重新分页）；
// 「触控板」——用捏合打开、灵敏度三档；系统的捏合手势还开着时给一行提示和「打开触控板设置」（只读系统设置，不改）；
//   私有框架加载不了时这一行灰掉写明；
// 「触发角」——选一个屏幕角，鼠标推到那里停一下打开（默认关）；
// 「排列数据」——从系统旧启动台导入（确认，导入前留一份可撤销）、恢复默认排列、撤销上一次导入。
// 页头由 SettingsRoot 画（家族色薄荷绿）。布局本身不在这里改，拖动、文件夹、抖动删 App 全在面板里（R4–R6）。

import AppKit
import SwiftUI

struct LaunchpadTab: View {
  /// 恢复默认排列（这里二次确认后调它）
  var resetDefault: () -> Void = {}
  /// 撤销上一次导入 / 恢复默认
  var undo: () -> Void = {}
  var canUndo: () -> Bool = { false }
  /// 行列数变了：按新容量重新分页并存盘
  var reflow: () -> Void = {}
  /// 从系统旧启动台重新导入（这里二次确认后调它）
  var importSystem: () -> Void = {}
  /// 捏合开关 / 灵敏度变了、触发角变了：重新起停监听
  var pinchChanged: () -> Void = {}
  var cornerChanged: () -> Void = {}
  /// 私有框架在这台 Mac 上能不能用
  var pinchAvailable: () -> Bool = { true }
  /// 系统的捏合手势还开着没有（每次出现读一次）
  var systemPinchOn: () -> Bool = { false }
  /// 打开系统设置 › 触控板 › 更多手势
  var openTrackpadSettings: () -> Void = {}

  @AppStorage(Prefs.launchpadEnabled) private var enabled = true
  @AppStorage(Prefs.launchpadColumns) private var columns = 7
  @AppStorage(Prefs.launchpadRows) private var rows = 5
  @AppStorage(Prefs.launchpadPinch) private var pinch = true
  @AppStorage(Prefs.launchpadPinchSense) private var pinchSense = PinchRecognizer.Sensitivity
    .standard.rawValue
  @AppStorage(Prefs.launchpadCorner) private var corner = LaunchpadCornerOption.off.rawValue
  @State private var systemPinch = false

  /// 系统手势的开关读出来变了没有（变了才重起监听，G8；纯函数）
  nonisolated static func shouldReapply(old: Bool, new: Bool) -> Bool { old != new }
  @State private var confirmsReset = false
  @State private var confirmsImport = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        PageHeader(page: .launchpad)
        form
      }
      .navigationTitle(SettingsPage.launchpad.title)
    }
  }

  private var form: some View {
    Form {
      Section {
        Toggle(isOn: $enabled) {
          Text("打开启动台")
          Text("全屏的图标网格；关掉后入口都不响应")
        }
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("启动台的按键")
          Text("打开 / 收起、翻页、搜索、文件夹里按什么键")
        }
      } header: {
        Text("启动台")
      } footer: {
        SectionFootnote("现有的「启动器」是搜索框，和启动台是两个东西：名字、设置、快捷键都分开。")
      }
      Section {
        LabeledContent {
          HStack(spacing: 8) {
            Text("\(columns) 列")
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Stepper("一页几列", value: $columns, in: Prefs.launchpadColumnChoices)
              .labelsHidden()
          }
        } label: {
          Text("一页几列")
          Text("改了按新容量重新分页")
        }
        LabeledContent {
          HStack(spacing: 8) {
            Text("\(rows) 行")
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Stepper("一页几行", value: $rows, in: Prefs.launchpadRowChoices)
              .labelsHidden()
          }
        } label: {
          Text("一页几行")
          Text("大屏可以多放几行")
        }
      } header: {
        Text("排列")
      } footer: {
        SectionFootnote("新装的 App 自动追加到最后一页末尾；卸掉的从布局里拿掉。拖动排序、建文件夹、删 App 都在启动台里做。")
      }
      pinchSection
      Section {
        Picker(selection: $corner) {
          ForEach(LaunchpadCornerOption.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
          Text("屏幕角")
          Text("鼠标推到角上停一下打开")
        }
        if let option = LaunchpadCornerOption(rawValue: corner),
          option != .off, LaunchpadCorner.systemCornerIsOn(option)
        {
          LabeledContent {
            Text("已被系统占用").foregroundStyle(.orange)
          } label: {
            Text("这个角也设了系统的触发角")
            Text("启动台不在这个角响应（免得两个一起出来）；要用，去 系统设置 › 桌面与程序坞 › 触发角 把那个角关掉")
          }
        }
      } header: {
        Text("触发角")
      }
      Section {
        LabeledContent {
          Button("从系统启动台重新导入…") { confirmsImport = true }
        } label: {
          Text("从系统启动台导入")
          Text("页、文件夹、顺序照旧；卸掉的跳过")
        }
        LabeledContent {
          Button("恢复默认排列…") { confirmsReset = true }
        } label: {
          Text("恢复默认排列")
          Text("系统 App 在前、其余按名字排")
        }
        LabeledContent {
          Button("撤销上一次导入", action: undo)
            .disabled(!canUndo())
        } label: {
          Text("撤销上一次导入")
          Text("换回导入前的样子，只能用一次")
        }
      } header: {
        Text("排列数据")
      }
    }
    .onAppear {
      systemPinch = systemPinchOn()
      pinchChanged()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      // 用户照提示去系统设置关掉再回来：读到状态**变了**才重起监听（F13）。任何窗口变 key 都会走到这里
      // （设置窗关了也不放，打开启动台、呼出剪贴板都算），没变就别动——重起会把正在捏的那一下清掉（G8）
      let next = systemPinchOn()
      guard Self.shouldReapply(old: systemPinch, new: next) else { return }
      systemPinch = next
      pinchChanged()
    }
    .onChange(of: columns) { reflow() }
    .onChange(of: rows) { reflow() }
    .onChange(of: enabled) { pinchChanged() }
    .onChange(of: pinch) { pinchChanged() }
    .onChange(of: pinchSense) { pinchChanged() }
    .onChange(of: corner) { cornerChanged() }
    .confirmationDialog("恢复默认排列？", isPresented: $confirmsReset) {
      Button("恢复", role: .destructive, action: resetDefault)
    } message: {
      Text("现在的排法会被换掉；之后可以在「撤销上一次导入」里换回来一次。App 本身不受影响。")
    }
    .confirmationDialog("从系统启动台重新导入？", isPresented: $confirmsImport) {
      Button("导入", role: .destructive, action: importSystem)
    } message: {
      Text("现在的排法会被换掉；之后可以在「撤销上一次导入」里换回来一次。库里已经卸掉的 App 跳过。")
    }
    // macOS 上 Form 在有的容器里会取 columns 样式（标签右对齐一列、说明和标题挤成一行），
    // 和别的设置页（grouped：标题 + 说明堆叠、控件靠右）不一致——显式定成 grouped
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var pinchSection: some View {
    Section {
      if pinchAvailable() {
        Toggle(isOn: $pinch) {
          Text("用触控板捏合打开")
          Text("捏合打开，张开收起；多个触控板都认")
        }
        .disabled(!enabled)
        Picker(selection: $pinchSense) {
          ForEach(PinchRecognizer.Sensitivity.allCases, id: \.rawValue) { level in
            Text(level.title).tag(level.rawValue)
          }
        } label: {
          Text("灵敏度")
          Text("越松越容易捏出来")
        }
        .pickerStyle(.segmented)
        .disabled(!enabled || !pinch)
        if systemPinch {
          LabeledContent {
            Button("打开触控板设置") { openTrackpadSettings() }
          } label: {
            Text("系统的捏合手势还开着")
              .foregroundStyle(.orange)
            Text("这时捏合会打开系统自己的应用程序视图；先在 系统设置 › 触控板 › 更多手势 关掉它，再回来打开这一项")
          }
        }
      } else {
        LabeledContent {
          Text("用不了").foregroundStyle(.secondary)
        } label: {
          Text("用触控板捏合打开")
          Text("这台 Mac 上用不了（系统改了触控板的接口）：用快捷键或触发角打开")
        }
      }
    } header: {
      Text("触控板")
    }
  }
}
