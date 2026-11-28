// 设置 › 触控板手势（插件，issue #59 第 2 批，PLAN §10「触控板手势」）。页头由 SettingsRoot 画（家族色同平滑滚动）。
// 私有框架不在、找不到触控板时最上面一行说一声；下面三组 三指 / 四指 / 五指，各三行 轻点 / 双击 / 长按，再一组「角落」八行
// （四个角 × 轻点 / 双击，2026-11-28），每行一个弹出菜单：
// 「没有设」、快捷键页那几节动作（只列开着的功能）、启动器命令（启动器开着时，分组同「命令和别名」，只列此刻能做事的，拍板 B4）。
// 绑着的东西现在用不了（功能关了、脚本没了）时菜单最上面多一项写明，绑着的照样留着。
// 系统自己也用三指时（三指轻点查询、三指拖移，拍板 B6）那几行下面橙字，照样能选；三指轻点那一行另给「打开触控板设置」。
// 最后「关于这个插件」。行为在 TrackpadGestures/。

import SwiftUI

struct TrackpadGesturesTab: View {
  /// 最上面那一行说的
  enum Status { case unsupported, noTrackpad }

  /// 截图自检摆好的（不读这台的触控板设置、不看触控板在不在）
  struct Fixed {
    var conflicts = TrackpadSystemConflicts()
    var status: Status?
  }

  /// 启动器的脚本（列脚本命令；nil = 只列内置的命令）
  let library: ScriptLibrary?
  let fixed: Fixed?
  let openTrackpadSettings: () -> Void

  @AppStorage(Prefs.trackpadGestureBindings) private var text = TrackpadGestureBindings.defaultText
  @AppStorage(Prefs.launcherScripts) private var scriptsOn = true
  @AppStorage(Prefs.launcherCommandAliases) private var aliasesText = ""
  @AppStorage(Prefs.launcherCommandsOff) private var offText = ""
  @AppStorage private var launcherOn: Bool
  /// 系统的三指手势：出现时、设置窗重新当 key 时（从系统设置改完回来）重读
  @State private var system = TrackpadSystemConflicts()

  init(
    library: ScriptLibrary? = nil, fixed: Fixed? = nil,
    openTrackpadSettings: @escaping () -> Void = {}
  ) {
    self.library = library
    self.fixed = fixed
    self.openTrackpadSettings = openTrackpadSettings
    _launcherOn = AppStorage(wrappedValue: Feature.launcher.defaultOn, Feature.launcher.prefsKey)
  }

  static let lookUpHint: LocalizedStringResource = "系统的三指轻点用来查询"
  static let dragHint: LocalizedStringResource = "系统的三指拖移开着"
  /// 开着轻点来点按时角落那一组最上面一行（2026-11-28 真机探针：离边 1–2% 的轻点都被系统点了，手势让开）
  static let tapToClickHint: LocalizedStringResource = "开着「轻点来点按」，点在最边上才认得出"

  var body: some View {
    let bindings = TrackpadGestureBindings(text: text)
    let commands = commands
    Form {
      if let status = fixed.map(\.status) ?? liveStatus {
        Section {
          LabeledContent {
            Text("用不了").foregroundStyle(.secondary)
          } label: {
            Text("触控板")
            Text(status == .unsupported ? "这台 Mac 上用不了：系统改了触控板的接口" : "没找到触控板，连上以后自动接上")
          }
        }
      }
      section([.fingers(3)], bindings, commands) {
        InfoHeader(
          "三指",
          info:
            "系统也用三指的时候（触控板设置里「查询与数据检测器」选了三指轻点，或者在 辅助功能 › 指针控制 › 触控板选项 里打开了三指拖移），那几行下面会写出来；照样能设，只是系统也会响应。"
        )
        .settingsAnchor(.trackpadThreeFingers)
      }
      section([.fingers(4)], bindings, commands) {
        Text("四指").settingsAnchor(.trackpadFourFingers)
      }
      section([.fingers(5)], bindings, commands) {
        Text("五指").settingsAnchor(.trackpadFiveFingers)
      }
      section(FingerGesture.Corner.allCases.map { .corner($0) }, bindings, commands) {
        InfoHeader(
          "角落",
          info: "用一根手指在触控板最角上轻点。系统当成点按的那一下（开着「轻点来点按」，或者按了下去）不算。"
        )
        .settingsAnchor(.trackpadCorners)
      }
      PluginAboutSection(plugin: .trackpadGestures)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
    .onAppear {
      system = .current()
      if scriptsOn, library?.isLoaded == false { library?.refresh() }
    }
    .onSettingsBecameKey { system = .current() }
  }

  private var conflicts: TrackpadSystemConflicts { fixed?.conflicts ?? system }

  /// 私有框架不在、枚举过却一个触控板都没有（还没订过的是 unknown，不说）
  private var liveStatus: Status? {
    guard Touchpad.libraryAvailable else { return .unsupported }
    return Touchpad.shared.availability == .unavailable ? .noTrackpad : nil
  }

  /// 能选的启动器命令：启动器开着时，此刻能做事的那些（同命令的快捷键注册的）
  private var commands: [LauncherCommandsSection.Row] {
    guard launcherOn else { return [] }
    let scripts = scriptsOn ? library?.scripts ?? [] : []
    let settings = LauncherCommands.Settings(aliasesText: aliasesText, offText: offText)
    let features = Feature.enabled
    return LauncherCommandsSection.rows(scripts: scripts).filter {
      LauncherModel.canRun($0.id, settings: settings, scripts: scripts, features: features)
    }
  }

  /// 一组：这几个来源能做的每一种一行
  private func section(
    _ sources: [TrackpadGesture.Source], _ bindings: TrackpadGestureBindings,
    _ commands: [LauncherCommandsSection.Row], @ViewBuilder header: () -> some View
  ) -> some View {
    Section {
      if conflicts.tapToClick, sources.contains(where: \.isCorner) {
        VStack(alignment: .leading, spacing: 2) {
          Text(plain: Self.tapToClickHint)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
          Button("打开触控板设置", action: openTrackpadSettings)
            .buttonStyle(.plain)
            .foregroundStyle(Style.brandInk)
            .pointerStyle(.link)
        }
        .font(.subheadline)
      }
      ForEach(
        sources.flatMap { source in source.kinds.map { TrackpadGesture(source, $0) } }, id: \.self
      ) {
        row($0, bindings, commands)
      }
    } header: {
      header()
    }
    .gated(by: .trackpadGestures)
  }

  /// 一行：名字（系统也用这一种时下面橙字）+ 弹出菜单
  private func row(
    _ gesture: TrackpadGesture, _ bindings: TrackpadGestureBindings,
    _ commands: [LauncherCommandsSection.Row]
  ) -> some View {
    let lookUp = gesture.fingers == 3 && gesture.kind == .tap && conflicts.lookUp
    let drag = gesture.fingers == 3 && conflicts.drag
    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(plain: gesture.title)
        Group {
          if lookUp { Text(plain: Self.lookUpHint) }
          if drag { Text(plain: Self.dragHint) }
        }
        .font(.subheadline)
        .foregroundStyle(Color(nsColor: .systemOrange))
        .fixedSize(horizontal: false, vertical: true)
        if lookUp {
          Button("打开触控板设置", action: openTrackpadSettings)
            .buttonStyle(.plain)
            .foregroundStyle(Style.brandInk)
            .pointerStyle(.link)
            .font(.subheadline)
        }
      }
      Spacer(minLength: 8)
      Picker(selection: binding(gesture, bindings)) {
        options(bindings[gesture], commands)
      } label: {
        Text(plain: gesture.title)
      }
      .labelsHidden()
      .fixedSize()
    }
  }

  /// 菜单里的项：没有设、（绑着的现在用不了时）它自己、快捷键页那几节、启动器命令
  @ViewBuilder
  private func options(
    _ current: TrackpadGestureTarget?, _ commands: [LauncherCommandsSection.Row]
  ) -> some View {
    let sections = HotKeyAction.sections
    Text("没有设").tag(TrackpadGestureTarget?.none)
    if let current, !Self.offers(current, sections: sections, commands: commands) {
      Text("\(Self.name(of: current))（现在用不了）").tag(Optional(current))
    }
    ForEach(sections, id: \.key) { section in
      Section(section.title) {
        ForEach(section.actions, id: \.self) { action in
          Text(action.rowTitle).tag(Optional(TrackpadGestureTarget.action(action)))
        }
      }
    }
    ForEach(LauncherCommandsSection.Row.Group.allCases, id: \.self) { group in
      let rows = commands.filter { $0.group == group }
      if !rows.isEmpty {
        Section {
          ForEach(rows) { row in
            Text(row.title).tag(Optional(TrackpadGestureTarget.command(row.id)))
          }
        } header: {
          Text(plain: group.title)
        }
      }
    }
  }

  static func offers(
    _ target: TrackpadGestureTarget, sections: [HotKeyAction.Section],
    commands: [LauncherCommandsSection.Row]
  ) -> Bool {
    switch target {
    case .action(let action): sections.contains { $0.actions.contains(action) }
    case .command(let id): commands.contains { $0.id == id }
    }
  }

  static func name(of target: TrackpadGestureTarget) -> String {
    switch target {
    case .action(let action): action.rowTitle
    case .command(let id): LauncherModel.commandTitle(id)
    }
  }

  /// 选了一项：从偏好现读再改（同 HotKeyBlock.change：页面上那份可能还没跟上同步刚落下的）
  private func binding(_ gesture: TrackpadGesture, _ bindings: TrackpadGestureBindings)
    -> Binding<TrackpadGestureTarget?>
  {
    Binding {
      bindings[gesture]
    } set: { target in
      var fresh = TrackpadGestureBindings(text: text)
      fresh[gesture] = target
      text = fresh.text
    }
  }
}
