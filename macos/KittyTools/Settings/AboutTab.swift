// 设置 › 关于（Whisker 品牌页）：128 pt 大图标（点一下摇一摇，悬停时跟着指针 3D 倾斜 ≤ 6°）+ 26 pt 圆体字标 +
// 版本胶囊 + 应用内更新（Updater：检查更新、发现新版本时「更新并重新打开」、自动检查开关）+ 更新日志时间线
// （随包分发的 changelog.json，最新版在前）；可以重看欢迎引导。更新后第一次启动会自动打开这一页（AppDelegate 比较 lastSeenVersion）。

import SwiftUI

struct AboutTab: View {
  /// changelog.json 的一个版本
  struct Release: Decodable, Identifiable {
    struct Change: Decodable, Hashable {
      let type: String
      let scope: String
      let text: String
    }

    let version: String
    let date: String
    let summary: String
    let changes: [Change]
    var id: String { version }
  }

  /// 应用内更新（截图自检里传一个摆好状态的；nil 就不显示更新那一行）
  var updater: Updater?
  /// 重看欢迎引导
  var showOnboarding: () -> Void = {}
  @AppStorage(Prefs.updateAutoCheck) private var autoCheck = true

  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

  static let releases: [Release] = {
    guard let url = Bundle.main.url(forResource: "changelog", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return [] }
    return (try? JSONDecoder().decode([Release].self, from: data)) ?? []
  }()

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 12) {
          BrandIcon(size: 128)
          Text("Kitty Tools")
            .font(.system(size: 26, weight: .bold, design: .rounded))
          Text("版本 \(Self.version)" + (Self.build.map { "（\($0)）" } ?? ""))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Style.brandInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Style.brand.opacity(0.12), in: .capsule)
            .textSelection(.enabled)
          if let updater { updateRow(updater) }
          HStack(spacing: 16) {
            Button("打开发布页") { NSWorkspace.shared.open(Updater.releasesPage) }
            Button("重看欢迎指南", action: showOnboarding)
          }
          .buttonStyle(.plain).foregroundStyle(Style.brandInk).pointerStyle(.link)
          .font(.callout)
        }
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
          LinearGradient(
            colors: [Style.brandCream, Style.brandCream.opacity(0)], startPoint: .top,
            endPoint: .bottom))
        VStack(alignment: .leading, spacing: 0) {
          Text("更新日志").font(.headline).padding(.bottom, 12)
          ForEach(Array(Self.releases.enumerated()), id: \.element.id) { index, release in
            ReleaseView(
              release: release, isCurrent: release.version == Self.version,
              isLast: index == Self.releases.count - 1)
          }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// 版本胶囊下面的更新状态。强调色只给「现在该操作的」：有新版本时的「更新并重新打开」；其余是文字链接
  private func updateRow(_ updater: Updater) -> some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        switch updater.state {
        case .idle:
          link("检查更新") { await updater.check(.page) }
        case .checking:
          ProgressView().controlSize(.small)
          Text("正在检查更新…").foregroundStyle(.secondary)
        case .upToDate:
          Label("已是最新版本", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
          link("再查一次") { await updater.check(.page) }
        case .available(let release):
          Text("有新版本 \(release.version)")
          Button("更新并重新打开") { Task { await updater.install(.page) } }
            .buttonStyle(.borderedProminent).tint(Style.brand)
          link("更新内容") { NSWorkspace.shared.open(release.page) }
        case .installing(let release):
          ProgressView().controlSize(.small)
          Text("正在更新到 \(release.version)…").foregroundStyle(.secondary)
        case .failed(let message):
          Text(message).foregroundStyle(Color(nsColor: .systemRed))
            .lineLimit(1).truncationMode(.tail)
          link("重试") { await updater.check(.page) }
        }
      }
      .font(.callout)
      // 定高：有按钮和只有文字的状态一样高，切换时下面的内容不跳
      .frame(height: 24)
      .animation(Style.Motion.settle.animation(), value: updater.state)
      Toggle("自动检查更新", isOn: $autoCheck)
        .toggleStyle(.checkbox)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func link(_ title: String, _ action: @escaping () async -> Void) -> some View {
    Button(title) { Task { await action() } }
      .buttonStyle(.plain).foregroundStyle(Style.brandInk).pointerStyle(.link)
  }
}

/// 品牌大图标：点一下摇一摇（KeyframeAnimator），悬停时跟着指针 3D 倾斜（最多 6°）；减弱动态效果时都不做
struct BrandIcon: View {
  let size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var taps = 0
  /// 指针在图标上的位置，−1…1（中心为 0）
  @State private var tilt = CGSize.zero

  var body: some View {
    Button {
      if !reduceMotion { taps += 1 }
    } label: {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
    }
    .buttonStyle(.plain)
    .rotation3DEffect(.degrees(tilt.width * 6), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
    .rotation3DEffect(.degrees(-tilt.height * 6), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
    .keyframeAnimator(initialValue: 0.0, trigger: taps) { content, angle in
      content.rotationEffect(.degrees(angle), anchor: .bottom)
    } keyframes: { _ in
      KeyframeTrack {
        SpringKeyframe(-9, duration: 0.1)
        SpringKeyframe(8, duration: 0.12)
        SpringKeyframe(-5, duration: 0.12)
        SpringKeyframe(2, duration: 0.1)
        SpringKeyframe(0, duration: 0.16)
      }
    }
    .onContinuousHover { phase in
      guard !reduceMotion else { return }
      switch phase {
      case .active(let point):
        withAnimation(.smooth(duration: 0.18)) {
          tilt = CGSize(width: point.x / size * 2 - 1, height: point.y / size * 2 - 1)
        }
      case .ended:
        withAnimation(Style.Motion.settle.animation()) { tilt = .zero }
      }
    }
    .accessibilityLabel("Kitty Tools 图标")
  }
}

/// 时间线上的一个版本：左边竖线 + 圆点（当前版本是品牌粉），右边版本号、日期、摘要和逐条改动
private struct ReleaseView: View {
  let release: AboutTab.Release
  let isCurrent: Bool
  let isLast: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(spacing: 0) {
        Circle()
          .fill(isCurrent ? Style.brand : Color.secondary.opacity(0.4))
          .frame(width: 10, height: 10)
          .padding(.top, 5)
        if !isLast { Rectangle().fill(Style.hairline).frame(width: 1) }
      }
      .frame(width: 10)
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(release.version).font(.system(.headline, design: .rounded))
          if isCurrent {
            Text("当前版本")
              .font(.caption.weight(.medium))
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Style.brand.opacity(0.12), in: .capsule)
              .foregroundStyle(Style.brandInk)
          }
          Spacer()
          Text(release.date).font(.caption).foregroundStyle(.secondary)
        }
        Text(release.summary).foregroundStyle(.secondary)
        ForEach(release.changes, id: \.self) { change in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.label(change.type))
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Self.color(change.type))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(
                Self.color(change.type).opacity(0.12), in: .rect(cornerRadius: Style.Radius.mini))
            Text("\(Text(change.scope).fontWeight(.medium))　\(change.text)")
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.bottom, 22)
      .textSelection(.enabled)
    }
  }

  private static func label(_ type: String) -> String {
    switch type {
    case "feat": "新增"
    case "fix": "修复"
    case "perf": "性能"
    case "ui": "界面"
    default: type
    }
  }

  private static func color(_ type: String) -> Color {
    switch type {
    case "feat": Color(nsColor: .systemGreen)
    case "fix": Color(nsColor: .systemOrange)
    case "perf": Color(nsColor: .systemPurple)
    default: Color(nsColor: .systemBlue)
    }
  }
}
