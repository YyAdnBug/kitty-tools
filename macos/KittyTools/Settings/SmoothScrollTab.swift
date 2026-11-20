// 设置 › 平滑滚动（插件，2026-11-17，issue #14；PLAN §10「平滑滚动」）。页头由 SettingsRoot 画（家族色橄榄绿）。
// 四组（缺辅助功能时「权限」在最上面）+「关于这个插件」：
// 「滚动」——平滑程度（轻 ↔ 重）、滚动距离（近 ↔ 远，旁边写百分比）；ⓘ 说只管滚轮鼠标（妙控鼠标只反向）、几个修饰键、点一下停下；
//   页脚右边「恢复默认」只管这两条滑块（拖过就拖不回原来那一格，0.10.1 用户反馈；同子页页脚那一个，ResetDefaultsButton）；
// 「方向」——鼠标上下 / 左右反向（只反鼠标；副标题写系统设置里的「自然滚动」现在开没开）；页脚说不同步；
// 「在这些 App 里停用」——同快捷键页那张停用名单的样子（AppListRow、「＋ −」、⌫ 删除）；页脚说虚拟机、远程桌面、游戏自动照原样；
// 「权限」——辅助功能（PluginPermissionSection，按 Shell/Plugin.swift 的声明；没有它用不了）；授权有却接不住滚轮、别的改滚轮的
//   工具开着时页脚橙字说；
// 最后「关于这个插件」（后台、同步、移除）。行为在 SmoothScroll/。

import SwiftUI

struct SmoothScrollTab: View {
  let smoothScroll: SmoothScroll
  /// 截图自检传固定的；正常是 nil = 现读
  private let authorized: Bool?
  private let others: [String]?
  private let natural: Bool?
  private let fixedExcluded: [String]?

  @AppStorage(Prefs.smoothScrollStrength) private var strength = 50
  @AppStorage(Prefs.smoothScrollSpeed) private var speed = 100
  @AppStorage(Prefs.smoothScrollReverseVertical) private var reverseVertical = false
  @AppStorage(Prefs.smoothScrollReverseHorizontal) private var reverseHorizontal = false
  /// 设置窗重新当 key 时 +1：「权限」组重查（从系统设置授权回来）
  @State private var accessChecks = 0
  /// 别的改滚轮的工具：出现时、设置窗当 key 时现读（不放在初值里：视图每次重建都会求一遍）
  @State private var running: [String] = []
  @State private var systemNatural = SmoothScroll.naturalScrolling
  @State private var selection: String?
  @State private var excluded: [String]

  init(
    smoothScroll: SmoothScroll, authorized: Bool? = nil, others: [String]? = nil,
    natural: Bool? = nil, excluded: [String]? = nil
  ) {
    self.smoothScroll = smoothScroll
    self.authorized = authorized
    self.others = others
    self.natural = natural
    fixedExcluded = excluded
    _excluded = State(initialValue: excluded ?? Self.stored)
  }

  var body: some View {
    form
      .onAppear { running = SmoothScroll.runningOtherTools() }
      // 从系统设置授权回来、设置窗再当 key：刷新授权、别的工具、系统的方向；授权刚给了的话这会儿接上
      .onSettingsBecameKey {
        accessChecks += 1
        running = SmoothScroll.runningOtherTools()
        systemNatural = SmoothScroll.naturalScrolling
        smoothScroll.refresh()
      }
  }

  private var form: some View {
    Form {
      permissions(at: .top)
      Section {
        LabeledContent {
          Slider(value: binding($strength, in: ScrollSmoothing.Settings.strengthRange), in: 0...100)
          {
            Text("平滑程度")
          } minimumValueLabel: {
            Text("轻").foregroundStyle(Color.secondary)
          } maximumValueLabel: {
            Text("重").foregroundStyle(Color.secondary)
          }
          .labelsHidden()
          .tint(Style.brand)
          .frame(maxWidth: 240)
        } label: {
          Text("平滑程度")
          Text(strength > 0 ? "越往右，拨一格滑得越久" : "拉到最左：不平滑，只按下面的开关反向")
        }
        .settingsAnchor(.smoothStrength)
        LabeledContent {
          HStack(spacing: 8) {
            Slider(
              value: binding($speed, in: ScrollSmoothing.Settings.speedRange, step: 10),
              in: 50...300
            ) {
              Text("滚动距离")
            } minimumValueLabel: {
              Text("近").foregroundStyle(Color.secondary)
            } maximumValueLabel: {
              Text("远").foregroundStyle(Color.secondary)
            }
            .labelsHidden()
            .tint(Style.brand)
            Text(Double(min(max(speed, 50), 300)) / 100, format: .percent)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(width: 40, alignment: .trailing)
          }
          .frame(maxWidth: 288)
        } label: {
          Text("滚动距离")
          Text("拨一格滚多远；跟着系统设置里鼠标的「滚动速度」一起变")
        }
        .settingsAnchor(.smoothDistance)
      } header: {
        InfoHeader(
          "滚动",
          info:
            "平滑只管滚轮鼠标；妙控鼠标本来就滑着滚，这两项不管它，它只跟着下面的反向开关；触控板都照系统的。按住 ⌥ 滚动时不平滑；按住 ⇧ 改成左右滚；按着 ⌘ 或 ⌃ 时交给 App（缩放这类）。滑着的时候点一下鼠标就停下。"
        )
      } footer: {
        HStack {
          Spacer()
          ResetDefaultsButton(
            keys: Self.resetKeys,
            place: "\(SettingsPage.smoothScroll.title) › \(String(localized: "滚动"))")
        }
      }
      .gated(by: .smoothScroll)
      Section {
        Toggle(isOn: $reverseVertical) {
          Text("鼠标上下反向")
          Text(
            natural ?? systemNatural
              ? "系统设置里开着「自然滚动」（鼠标和触控板是一个开关）：打开这一项，鼠标往下滚就往下翻（妙控鼠标也是），触控板不变"
              : "系统设置里关着「自然滚动」：打开这一项，鼠标滚动的方向反过来（妙控鼠标也是），触控板不变")
        }
        .settingsAnchor(.smoothReverseVertical)
        Toggle(isOn: $reverseHorizontal) {
          Text("鼠标左右反向")
          Text("横向的滚轮、妙控鼠标左右划；按住 ⇧ 拨的还是上下那个滚轮，跟着上面那一项")
        }
        .settingsAnchor(.smoothReverseHorizontal)
      } header: {
        InfoHeader("方向", info: "反向只管这台 Mac 接的鼠标，不跟着同步；停用的 App 里也不反向。")
      }
      .gated(by: .smoothScroll)
      excludedSection.gated(by: .smoothScroll)
      permissions(at: .bottom)
      PluginAboutSection(plugin: .smoothScroll)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
  }

  /// 「权限」组（辅助功能）；缺授权时画在最上面（插件页改版 C2）。页脚：接不住滚轮、别的改滚轮的工具开着时的橙字
  private func permissions(at placement: PluginPermissionPlacement) -> some View {
    PluginPermissionSection(
      plugin: .smoothScroll, at: placement, checks: accessChecks,
      granted: authorized.map { value in { (_: Permissions.Kind) -> Bool? in value } }
    ) {
      if let warning = Self.warning(
        failed: authorized == nil && smoothScroll.status == .failed, others: others ?? running)
      {
        Text(verbatim: warning)
          .font(.caption)
          .foregroundStyle(Color(nsColor: .systemOrange))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
      }
    }
  }

  /// 权限页脚的橙字：接不住滚轮、别的改滚轮的工具开着（纯函数，配单测；别的工具的名字是运行着的 App 自己的名字）
  static func warning(failed: Bool, others: [String]) -> String? {
    var lines: [String] = []
    if failed {
      lines.append(
        String(
          localized: "授权显示给了，却接不住滚轮：到 系统设置 › \(Permissions.privacyPane) › 辅助功能 里把它关掉再打开。"))
    }
    if !others.isEmpty {
      let names = others.joined(
        separator: String(
          localized: "list.quoted", defaultValue: "」「", comment: "「A」「B」这样一串名字里两个名字之间的那一段"))
      lines.append(
        String(localized: "「\(names)」也在处理鼠标滚轮：两边一起开会平滑两次、反向两次。用这里的就把那边的平滑和反向关掉。"))
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  /// 「滚动」页脚的「恢复默认」管的键：两条滑块（方向的两个开关点一下就回去，不归它）
  static let resetKeys = SettingsReset.keys(of: [.smoothStrength, .smoothDistance])

  /// 滑块是 Double，偏好里存整数（读的时候夹进范围：导入、同步来的值也许不在里面）；按 step 取整（不用 Slider 的 step：
  /// 那样会画一排刻度）
  private func binding(_ value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1)
    -> Binding<Double>
  {
    Binding {
      Double(min(max(value.wrappedValue, range.lowerBound), range.upperBound))
    } set: {
      value.wrappedValue = Int(($0 / Double(step)).rounded()) * step
    }
  }

  // MARK: 停用的 App

  private var excludedSection: some View {
    Section {
      List(selection: $selection) {
        if excluded.isEmpty {
          Text("没有停用平滑滚动的 App").foregroundStyle(.secondary)
        }
        ForEach(excluded, id: \.self) { AppListRow(bundleID: $0).tag($0) }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .orderedListFrame(rows: excluded.count)
      .onDeleteCommand(perform: removeSelected)
      ListEditBar(removeTitle: "移除所选的 App", canRemove: selection != nil, remove: removeSelected) {
        Menu {
          Menu("正在运行的 App") {
            ForEach(AppListRow.runningApps, id: \.bundleID) { app in
              Button(app.name) { add(app.bundleID) }
                .disabled(excluded.contains(app.bundleID))
            }
          }
          Button("选择 App…") {
            AppListRow.chooseApps(prompt: "停用平滑滚动", message: "选择的 App 在前台时，滚轮照系统原样")
              .forEach(add)
          }
        } label: {
          Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("添加 App")
      }
    } header: {
      InfoHeader(
        "在这些 App 里停用",
        info: "列表里的 App 在前台时，滚轮照系统原样（也不反向）。常见的虚拟机、远程桌面和标明是游戏的 App 自动照原样，不用放进来；别的游戏、自己管滚轮的 App 放进来。"
      )
      .settingsAnchor(.smoothExcluded)
    }
    // 同步、导入落下了新的名单：页面跟上（偏好里是字符串数组，@AppStorage 存不了，自己读）
    .task {
      guard fixedExcluded == nil else { return }
      for await _ in NotificationCenter.default.notifications(
        named: UserDefaults.didChangeNotification)
      where Self.stored != excluded {
        excluded = Self.stored
      }
    }
  }

  private static var stored: [String] {
    UserDefaults.standard.stringArray(forKey: Prefs.smoothScrollExcluded) ?? []
  }

  private func add(_ bundleID: String) {
    guard !excluded.contains(bundleID) else { return }
    save(excluded + [bundleID])
  }

  private func removeSelected() {
    guard let selection else { return }
    save(excluded.filter { $0 != selection })
    self.selection = nil
  }

  private func save(_ list: [String]) {
    excluded = list
    UserDefaults.standard.set(list, forKey: Prefs.smoothScrollExcluded)
  }
}
