// 设置 › 关于（Whisker 品牌页）：128 pt 大图标（点一下摇一摇，悬停时跟着指针 3D 倾斜 ≤ 6°）+ 26 pt 圆体字标 +
// 版本胶囊 + 应用内更新（Updater：检查更新、发现新版本时「更新并重新打开」、下载中「取消」、自动检查开关）+ 更新日志时间线
// （随包分发的 changelog.json，最新版在前；只展开当前版本，别的折叠成一行、点了才排它的条目——2026-11-05 用户报全部展开太长、
// 滚动卡）；可以重看欢迎引导。更新后第一次启动不再自动打开这一页，只由刘海岛说
// 「已更新到 x」+ 本版摘要（AppDelegate 比较 lastSeenVersion，体检 A29），全文在这里。
// 页面最底下两行小字是素材和参考产品的出处（状态屏的动画表情、便签参考的 Noty，都是 MIT，许可要求随包带着许可全文；
// mac-whisker §11）。

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

  static let releases: [Release] = load()
  /// 更新日志一开始展开的那一版
  static let expandedVersion = firstExpanded(in: releases, current: version)

  /// 当前版本；changelog 里没有它（开发中的新版本号）就是最新的那一条（列表最新在前）
  static func firstExpanded(in releases: [Release], current: String) -> String? {
    releases.contains { $0.version == current } ? current : releases.first?.version
  }

  /// 随包的 changelog.json（读不出来就是空的）
  private static func load() -> [Release] {
    guard let url = Bundle.main.url(forResource: "changelog", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return [] }
    return (try? JSONDecoder().decode([Release].self, from: data)) ?? []
  }

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
            Button("重看欢迎引导", action: showOnboarding)
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
              isFirst: index == 0, isLast: index == Self.releases.count - 1,
              isExpanded: release.version == Self.expandedVersion)
          }
          credits
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// 素材和参考产品的出处：更新日志下面两行小字，每行后面跟着打开随包那份许可全文的链接
  private var credits: some View {
    VStack(alignment: .leading, spacing: 4) {
      credit(Self.emojiCredit, license: "status-emoji-LICENSE")
      credit(Self.noteCredit, license: "notes-LICENSE")
    }
    .font(.caption)
    .padding(.top, 4)
  }

  private func credit(_ text: String, license: String) -> some View {
    HStack(spacing: 6) {
      Text(text).foregroundStyle(.tertiary)
      if let url = Bundle.main.url(forResource: license, withExtension: "txt") {
        Button("许可全文") { NSWorkspace.shared.open(url) }
          .buttonStyle(.plain).foregroundStyle(Style.brandInk).pointerStyle(.link)
      }
    }
  }

  static let emojiCredit = "状态屏的动画表情来自 Microsoft Fluent Emoji（MIT 许可）"
  static let noteCredit = "便签的交互参考了 Noty（MIT 许可）"

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
            .buttonStyle(BrandButtonStyle())
            .disabled(updater.blocker != nil)
          if let blocker = updater.blocker {
            Text(blocker).foregroundStyle(.secondary)
          } else {
            link("更新内容") { NSWorkspace.shared.open(release.page) }
          }
        case .installing(let release):
          // 下载有进度就是一条真的进度条（服务器没给大小、还没开始时是来回走的那种），后面一句话带百分比
          ProgressView(value: updater.progress)
            .progressViewStyle(.linear)
            .tint(Style.brand)
            .frame(width: 140)
            .accessibilityLabel("更新进度")
          Text(Updater.installingLine(release.version, progress: updater.progress))
            .monospacedDigit()
            .foregroundStyle(.secondary)
          // 下载中能取消（E23，回到「有新版本」）；下完在装的那一两秒不能停
          if updater.isDownloading { link("取消") { updater.cancelDownload() } }
        case .installed(let release):
          Label(
            "新版本 \(release.version) 已装好，\(Updater.installedDetail)",
            systemImage: "checkmark.circle.fill"
          )
          .foregroundStyle(.secondary)
          link("现在重新打开") { NSApp.terminate(nil) }
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

/// 时间线上的一个版本：左边竖线 + 圆点（当前版本是品牌粉），右边一行标题（版本号、日期、展开三角，整行能点）。
/// 展开时下面是摘要和逐条改动；折叠时摘要截成一行夹在版本号和日期中间，条目不排
private struct ReleaseView: View {
  let release: AboutTab.Release
  let isCurrent: Bool
  let isFirst: Bool
  let isLast: Bool
  @State private var isExpanded: Bool

  init(
    release: AboutTab.Release, isCurrent: Bool, isFirst: Bool, isLast: Bool, isExpanded: Bool
  ) {
    self.release = release
    self.isCurrent = isCurrent
    self.isFirst = isFirst
    self.isLast = isLast
    _isExpanded = State(initialValue: isExpanded)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(spacing: 0) {
        // 圆点上面这 5 pt 接着上一版的竖线（第一版不画）：折叠成一行时线不断开
        Rectangle().fill(Style.hairline).frame(width: 1, height: 5).opacity(isFirst ? 0 : 1)
        Circle()
          .fill(isCurrent ? Style.brand : Color.secondary.opacity(0.4))
          .frame(width: 10, height: 10)
        if !isLast { Rectangle().fill(Style.hairline).frame(width: 1) }
      }
      .frame(width: 10)
      VStack(alignment: .leading, spacing: 8) {
        header
        if isExpanded {
          VStack(alignment: .leading, spacing: 8) {
            Text(release.summary).foregroundStyle(.secondary)
            ForEach(release.changes, id: \.self) { change in
              ChangeRow(type: change.type, scope: change.scope, text: change.text)
            }
          }
          .textSelection(.enabled)
          .transition(.opacity)
        }
      }
      .padding(.bottom, isExpanded ? 22 : 12)
    }
  }

  private var header: some View {
    Button {
      withAnimation(Style.Motion.settle.animation()) { isExpanded.toggle() }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(release.version).font(.system(.headline, design: .rounded)).fixedSize()
        if isCurrent {
          Text("当前版本")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Style.brand.opacity(0.12), in: .capsule)
            .foregroundStyle(Style.brandInk)
            .fixedSize()
        }
        if isExpanded {
          Spacer(minLength: 8)
        } else {
          Text(release.summary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(release.date).font(.caption).monospacedDigit().foregroundStyle(.secondary)
          .fixedSize()
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 12)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "已展开" : "已折叠")
  }
}

/// 更新日志的一条改动：左边种类的小标签（颜色按种类），右边「范围　一句话」
private struct ChangeRow: View {
  let type: String
  let scope: String
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(Self.label(type))
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Self.color(type))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Self.color(type).opacity(0.12), in: .rect(cornerRadius: Style.Radius.mini))
      Text("\(Text(scope).fontWeight(.medium))　\(text)")
        .fixedSize(horizontal: false, vertical: true)
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

  /// 新增绿、修复橙、性能紫、界面蓝
  private static func color(_ type: String) -> Color {
    switch type {
    case "feat": Color(nsColor: .systemGreen)
    case "fix": Color(nsColor: .systemOrange)
    case "perf": Color(nsColor: .systemPurple)
    default: Color(nsColor: .systemBlue)
    }
  }
}
