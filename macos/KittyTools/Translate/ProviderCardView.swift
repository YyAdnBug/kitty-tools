// 一个翻译服务的结果卡片（Whisker，mac-whisker §6 翻译）：标题行 = 18 pt 品牌色块 + 服务名 12 semibold + 模型 11 tertiary，
// 右侧朗读 / 复制 / 重试 / 折叠（平时 0.45 透明度）；正文四种状态：等待和「生成中还没有字」是骨架条 + 扫光，
// 生成中用 RevealText 显影 + 边框上一段强调色彗星光绕行（2.4 s 一圈），完成时整圈闪一下，失败是淡红错误卡
// （图标晃一下，给「重试 · 打开设置」）。复制时对勾替换 + 整卡闪 accent。大模型完成后按行内 Markdown 渲染。
// 折叠状态由浮窗按服务记住（跨重启），不再因为出结果自动展开；复制的对勾状态在会话里（⌘1–9 也亮）。

import SwiftUI

struct ProviderCardView: View {
  let card: TranslateCoordinator.Card
  /// 第几张（⌘1–9 复制）
  let index: Int
  let language: Lang?
  let speaker: Speaker
  var fontScale = 1.0
  var isCollapsed = false
  /// 这张卡被复制时 = 协调器的复制计数（每次都不同，好重放闪光），平时 0
  var copyTick = 0
  let onRetry: () -> Void
  var onCopy: () -> Void = {}
  var onToggleCollapse: () -> Void = {}
  var onOpenSettings: () -> Void = {}
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var retries = 0
  @State private var errorTicks = 0
  /// 上次出完的正文高度：重新翻译时骨架先撑到这么高，面板不先缩再一行行长回来
  @State private var settledHeight: CGFloat = 0

  private var isCopied: Bool { copyTick != 0 }

  private var isPending: Bool {
    switch card.state {
    case .waiting, .running: true
    default: false
    }
  }

  private var isGenerating: Bool {
    guard card.service.isStreaming else { return false }
    switch card.state {
    case .waiting, .running: return true
    default: return false
    }
  }

  private var isFailed: Bool {
    if case .failed = card.state { true } else { false }
  }

  private var isDone: Bool {
    if case .done = card.state { true } else { false }
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      header
      // 正文放进裁剪的容器里收起 / 展开：往上收时不会滑过标题行
      VStack(spacing: 0) {
        if !isCollapsed {
          content
            .frame(minHeight: isPending ? settledHeight : 0, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) {
              $0.size.height
            } action: { height in
              if isDone { settledHeight = height }
            }
            .padding(.top, 3)
            .transition(
              reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
      }
      .clipped()
    }
    // 紧凑（对标 Bob）：一行译文的卡约 54 pt（上 7 + 标题 18 + 间距 3 + 一行 + 下 8）
    .padding(.horizontal, 12)
    .padding(.top, 7)
    .padding(.bottom, isCollapsed ? 7 : 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
    .background(background, in: shape)
    .overlay(shape.strokeBorder(stroke, lineWidth: 0.5))
    .overlay { if isGenerating { CometBorder() } }
    // 完成：整圈边框闪一下 accent 0.45 → 0（0.6 s）
    .overlay {
      shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
        .keyframeAnimator(initialValue: 0.0, trigger: isDone) { view, value in
          view.opacity(value)
        } keyframes: { _ in
          KeyframeTrack {
            LinearKeyframe(
              isDone && card.service.isStreaming && !reduceMotion ? 0.45 : 0, duration: 0.01)
            LinearKeyframe(0, duration: 0.6)
          }
        }
        .allowsHitTesting(false)
    }
    // 复制：整卡闪 accent 0 → 0.12 → 0（0.4 s）
    .overlay {
      shape.fill(Color.accentColor)
        .keyframeAnimator(initialValue: 0.0, trigger: copyTick) { view, value in
          view.opacity(value)
        } keyframes: { _ in
          KeyframeTrack {
            LinearKeyframe(isCopied && !reduceMotion ? 0.12 : 0, duration: 0.15)
            LinearKeyframe(0, duration: 0.25)
          }
        }
        .allowsHitTesting(false)
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: isCollapsed)
  }

  private var background: Color {
    if isFailed { return Color(nsColor: .systemRed).opacity(0.05) }
    return scheme == .dark ? .white.opacity(0.06) : .white.opacity(0.55)
  }

  private var stroke: Color {
    isFailed ? Color(nsColor: .systemRed).opacity(0.18) : Style.hairline
  }

  private var header: some View {
    HStack(spacing: 8) {
      ServiceTile(service: card.service)
      Text(Self.displayName(card.service))
        .font(.system(size: 12, weight: .semibold))
        .opacity(0.85)
        .lineLimit(1)
      if let model = card.service.model, !model.isEmpty, card.service.isStreaming {
        Text(model).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
      }
      Spacer(minLength: 6)
      Group {
        if let text = card.state.text, !text.isEmpty {
          Button(
            "朗读", systemImage: speaker.speaking == text ? "speaker.wave.2.fill" : "speaker.wave.2"
          ) { speaker.toggle(text, language: language) }
          .symbolEffect(
            .variableColor.iterative.reversing, isActive: speaker.speaking == text && !reduceMotion)
          Button("复制", systemImage: isCopied ? "checkmark" : "doc.on.doc", action: onCopy)
            .contentTransition(.symbolEffect(.replace))
            .help(index < 9 ? "复制（⌘\(index + 1)）" : "复制")
        }
        Button("重新翻译", systemImage: "arrow.clockwise") {
          retries += 1
          onRetry()
        }
        .symbolEffect(.rotate, value: retries)
        Button(isCollapsed ? "展开" : "收起", systemImage: "chevron.down", action: onToggleCollapse)
          .rotationEffect(.degrees(isCollapsed ? 0 : 180))
          .help(isCollapsed ? "展开（会一直记住）" : "收起（会一直记住）")
      }
      .opacity(0.45)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .font(.system(size: 12, weight: .medium))
    .frame(height: 18)
  }

  /// 用 RevealText 显示的正文：生成中有字、或完成且不按 Markdown 渲染。两种状态放在同一个结构位置，
  /// 完成那一下还是同一个视图（身份一变就会整段重新显影）
  private var revealed: (text: String, isStreaming: Bool)? {
    switch card.state {
    case .running(let text) where !text.isEmpty: (text, true)
    case .done(let text) where !(card.service.isStreaming && Self.hasMarkdown(text)): (text, false)
    default: nil
    }
  }

  @ViewBuilder private var content: some View {
    if let revealed {
      RevealText(text: revealed.text, isStreaming: revealed.isStreaming, fontSize: 15 * fontScale)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if case .done(let text) = card.state {
      // 大模型输出里有行内 Markdown 才按 Markdown 渲染
      Text(Self.markdown(text)).font(.system(size: 15 * fontScale)).lineSpacing(3.5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if case .failed(let message) = card.state {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Color(nsColor: .systemRed))
          .symbolEffect(.wiggle, value: errorTicks)
        Text(message)
          .font(.system(size: 13))
          .foregroundStyle(Color(nsColor: .systemRed))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("重试") {
          retries += 1
          onRetry()
        }
        Text("·").foregroundStyle(.tertiary)
        Button("打开设置", action: onOpenSettings)
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
      .onAppear { errorTicks += 1 }
    } else {
      Skeleton()
    }
  }

  /// 「智谱 GLM（免费）」这类默认名去掉括号里的说明
  static func displayName(_ service: TranslateService) -> String {
    service.name.replacing(/（.*）$/, with: "")
  }

  static func hasMarkdown(_ text: String) -> Bool {
    text.contains("**") || text.contains("__") || text.contains("`") || text.contains("](")
  }

  /// 行内 Markdown（块级标记原样显示）；解析失败按纯文本
  private static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

/// 服务身份：18 pt 方块（圆角 = 边长 × 0.225）。有官方 logo 用 logo，没有的用品牌色块 + 白色首字母
struct ServiceTile: View {
  let service: TranslateService
  var size: CGFloat = 18

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(size), style: .continuous)
    if let logo = Self.logo(for: service) {
      Image(decorative: logo.name)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .padding(logo.onPlate ? size * 0.14 : 0)
        .frame(width: size, height: size)
        .background(logo.onPlate ? Color.white : .clear)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
    } else {
      let color = Self.color(for: service)
      shape
        .fill(
          LinearGradient(
            colors: [color, color.mix(with: .black, by: 0.15)], startPoint: .top, endPoint: .bottom)
        )
        .overlay(
          Text(Self.monogram(service))
            .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
        )
        .frame(width: size, height: size)
    }
  }

  /// 官方 logo（`Assets.xcassets/ServiceLogo`，取自各家官网的图标）：自带底色的满版图直接裁圆角，
  /// 只有图形的垫白底留边（onPlate）。自定义的 AI 服务认不出是谁时用色块首字母。
  /// ponytail: 百度、腾讯只有 32 px 的 favicon，18 pt 下略虚；拿到 ≥ 128 px 的官方图直接替换 PNG
  static func logo(for service: TranslateService) -> (name: String, onPlate: Bool)? {
    let name: String? =
      switch service.kind {
      case .zhipu, .baidu, .youdao, .google, .deepl, .microsoft, .volcengine, .tencent:
        service.kind.rawValue
      case .ai:
        switch service.aiProtocol {
        case .anthropic: "anthropic"
        case .azure: "microsoft"
        case .openai, nil:
          if service.name.localizedCaseInsensitiveContains("gemini") {
            "gemini"
          } else if ["gpt", "openai"].contains(where: {
            service.name.localizedCaseInsensitiveContains($0)
          }) {
            "openai"
          } else {
            nil
          }
        }
      }
    return name.map {
      ("ServiceLogo/" + $0, !["zhipu", "baidu", "youdao", "anthropic"].contains($0))
    }
  }

  /// 服务品牌色（mac-whisker §3）；自定义 AI 按协议，其余按名字哈希取色相
  static func color(for service: TranslateService) -> Color {
    let hex: Int? =
      switch service.kind {
      case .zhipu: 0x3D5AFE
      case .baidu: 0x2932E1
      case .youdao: 0xE1251B
      case .google: 0x4285F4
      case .deepl: 0x0F2B46
      case .microsoft: 0x0078D4
      case .volcengine: 0x1664FF
      case .tencent: 0x0052D9
      case .ai:
        switch service.aiProtocol {
        case .anthropic: 0xD97757
        case .azure: 0x0078D4
        case .openai, nil: service.name.localizedCaseInsensitiveContains("gemini") ? 0x4F7DF3 : nil
        }
      }
    if let hex {
      return Color(
        red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255)
    }
    if service.name.localizedCaseInsensitiveContains("gpt")
      || service.name.localizedCaseInsensitiveContains("openai")
    {
      return Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)
    }
    let hue =
      Double(service.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360)
      / 360
    return Color(hue: hue, saturation: 0.55, brightness: 0.85)
  }

  /// 首字母：名字以中文开头取第一个字（智谱 GLM → 智），否则取第一个拉丁字母（大写）
  static func monogram(_ service: TranslateService) -> String {
    let name = ProviderCardView.displayName(service).trimmingCharacters(in: .whitespaces)
    guard let first = name.first else { return "?" }
    if !first.isASCII { return String(first) }
    return name.first(where: { $0.isLetter }).map { String($0).uppercased() } ?? String(first)
  }
}

/// 生成中的彗星边框：一段强调色光沿边框绕行（2.4 s 一圈，只做旋转）；减弱动态效果时静止
private struct CometBorder: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let turn =
        context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .strokeBorder(
          AngularGradient(
            stops: [
              .init(color: .clear, location: 0), .init(color: .clear, location: 0.62),
              .init(color: .accentColor.opacity(0.35), location: 0.78),
              .init(color: .accentColor, location: 0.92), .init(color: .clear, location: 1),
            ], center: .center, angle: .degrees(turn * 360)), lineWidth: 1.5)
    }
    .transition(.opacity.animation(.easeOut(duration: 0.35)))
    .allowsHitTesting(false)
  }
}

/// 等第一个字时的骨架：两根条（高 8，宽 94 / 58%，约一行半译文高）+ 扫光（1.3 s 一趟）
private struct Skeleton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let phase =
        context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
      GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 6) {
          ForEach([0.94, 0.58], id: \.self) { width in
            Capsule()
              .fill(
                LinearGradient(
                  stops: [
                    .init(color: .primary.opacity(0.07), location: 0),
                    .init(color: .primary.opacity(0.14), location: 0.5),
                    .init(color: .primary.opacity(0.07), location: 1),
                  ],
                  startPoint: UnitPoint(x: phase * 3 - 2, y: 0.5),
                  endPoint: UnitPoint(x: phase * 3 - 1, y: 0.5))
              )
              .frame(width: geometry.size.width * width, height: 8)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(height: 26)
    }
    .accessibilityLabel("翻译中")
  }
}
