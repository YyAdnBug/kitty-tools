// 首次安装的欢迎引导（Whisker 品牌时刻，D 阶段）：盖在设置窗上的 sheet，四步——欢迎 → 授权（辅助功能、屏幕录制，
// 状态实时刷新）→ 快捷键一览 → 完成。每步从右边滑进来（settle），减弱动态效果时只淡入淡出。「关于」页里可以重看。

import SwiftUI

struct OnboardingView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var step: Step
  /// 往前翻还是往回翻（决定从哪边滑进来）
  @State private var forward = true

  /// step：从第几步开始（截图自检摆各步用）
  init(step: Step = .welcome) {
    _step = State(initialValue: step)
  }

  enum Step: Int, CaseIterable {
    case welcome, permissions, shortcuts, done
  }

  private let steps = Step.allCases

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        content(step)
          .id(step)
          .transition(
            reduceMotion
              ? .opacity
              : .asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      footer
    }
    .frame(width: 580, height: 460)
    .background(Style.brandCream)
  }

  @ViewBuilder private func content(_ step: Step) -> some View {
    switch step {
    case .welcome: WelcomeStep()
    case .permissions: PermissionsStep()
    case .shortcuts: ShortcutsStep()
    case .done: DoneStep()
    }
  }

  private var footer: some View {
    let index = steps.firstIndex(of: step) ?? 0
    return HStack {
      if step != .done {
        Button("跳过") { dismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .keyboardShortcut(.cancelAction)
      }
      Spacer()
      HStack(spacing: 6) {
        ForEach(steps, id: \.self) { item in
          Capsule()
            .fill(item == step ? Style.brand : Color.primary.opacity(0.15))
            .frame(width: item == step ? 18 : 6, height: 6)
        }
      }
      .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: step)
      .accessibilityLabel("第 \(index + 1) 步，共 \(steps.count) 步")
      Spacer()
      if index > 0, step != .done {
        Button("上一步") { go(to: steps[index - 1]) }
      }
      Button(step == .done ? "开始使用" : "下一步") {
        if index + 1 < steps.count { go(to: steps[index + 1]) } else { dismiss() }
      }
      .buttonStyle(.borderedProminent)
      .tint(Style.brand)
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .frame(height: 56)
    .overlay(alignment: .top) { Style.hairline.frame(height: 0.5) }
  }

  private func go(to next: Step) {
    forward = next.rawValue > step.rawValue
    withAnimation(Style.Motion.settle.animation(reduced: reduceMotion)) { step = next }
  }
}

/// 一步的排版：大标题（品牌圆体）+ 一句说明 + 内容
private struct StepLayout<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 18) {
      VStack(spacing: 6) {
        Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
        Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      content
    }
    .padding(.horizontal, 36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct WelcomeStep: View {
  var body: some View {
    VStack(spacing: 20) {
      BrandIcon(size: 104)
      VStack(spacing: 6) {
        Text("欢迎使用 Kitty Tools")
          .font(.system(size: 26, weight: .bold, design: .rounded))
        Text("剪贴板历史、启动器、翻译和截图，都住在菜单栏里。")
          .font(.callout).foregroundStyle(.secondary)
      }
      HStack(spacing: 22) {
        feature("剪贴板", "doc.on.clipboard.fill", Style.Family.clipboard)
        feature("启动器", "command", Style.Family.command)
        feature("翻译", "character.bubble.fill", Style.Family.translate)
        feature("截图", "camera.viewfinder", Style.Family.screenshot)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func feature(_ title: String, _ symbol: String, _ color: Color) -> some View {
    VStack(spacing: 6) {
      KindTile(symbol: symbol, color: color, size: 40)
      Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }
  }
}

/// 授权：状态每秒刷新一次（在系统设置里打开开关后，回到这里马上变成已授权）
private struct PermissionsStep: View {
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed

  var body: some View {
    StepLayout(title: "两项授权", subtitle: "都只在本机使用；不授权也能用，只是对应的功能用不了。") {
      VStack(spacing: 0) {
        PermissionRow(
          title: "辅助功能", detail: "把剪贴板内容粘贴回原 App、划词翻译、长截图自动滚动",
          symbol: "hand.raised.fill", color: Style.Family.command, granted: trusted
        ) {
          Permissions.requestAccessibility()
          Permissions.openAccessibilitySettings()
        }
        .padding(12)
        Style.hairline.frame(height: 0.5).padding(.leading, 46)
        PermissionRow(
          title: "屏幕录制", detail: "截图、截图翻译、识字；授权后可能要重新打开本 App",
          symbol: "record.circle", color: Style.Family.screenshot, granted: screenRecording
        ) {
          Permissions.requestScreenRecording()
          Permissions.Kind.screenRecording.openSettings()
        }
        .padding(12)
      }
      .background(.background, in: .rect(cornerRadius: Style.Radius.card, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous).strokeBorder(
          Style.hairline, lineWidth: 0.5))
    }
    .task {
      while !Task.isCancelled {
        trusted = Permissions.isAccessibilityTrusted
        screenRecording = Permissions.isScreenRecordingAllowed
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}

/// 显示设好的组合（不是注册成功的：15.0–15.1 上只带 ⌥ 的注册不了，那种情况快捷键页会提示）
private struct ShortcutsStep: View {
  private static let shown: [(HotKeyAction, String, Color)] = [
    (.launcher, "command", Style.Family.command),
    (.clipboard, "doc.on.clipboard.fill", Style.Family.clipboard),
    (.selectionTranslate, "character.bubble.fill", Style.Family.translate),
    (.inputTranslate, "keyboard.fill", Style.Family.translate),
    (.screenshot, "camera.viewfinder", Style.Family.screenshot),
    (.screenshotTranslate, "text.viewfinder", Style.Family.screenshot),
    (.recognizeText, "text.magnifyingglass", Style.Family.screenshot),
  ]

  var body: some View {
    StepLayout(title: "记住这几个键", subtitle: "在任何 App 里都能按；想换可以到「设置 › 快捷键」里改。") {
      Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
        ForEach(Array(stride(from: 0, to: Self.shown.count, by: 2)), id: \.self) { index in
          GridRow {
            row(Self.shown[index])
            if index + 1 < Self.shown.count { row(Self.shown[index + 1]) }
          }
        }
      }
    }
  }

  private func row(_ entry: (HotKeyAction, String, Color)) -> some View {
    HStack(spacing: 10) {
      KindTile(symbol: entry.1, color: entry.2, size: 24)
      Text(entry.0.title).frame(width: 84, alignment: .leading)
      KeyCap(entry.0.hotKey?.display ?? "未设置")
    }
  }
}

private struct DoneStep: View {
  @State private var shown = false

  var body: some View {
    StepLayout(title: "都准备好了", subtitle: "点菜单栏里的图标，随时打开这些功能和设置。") {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56, weight: .medium))
        .foregroundStyle(Style.brand)
        .symbolEffect(.bounce, value: shown)
        .onAppear { shown = true }
    }
  }
}
