// 一个翻译服务的结果卡片（Whisker，mac-whisker §6 翻译）：标题行 = 18 pt 品牌色块 + 服务名 12 semibold + 模型 11 tertiary，
// 右侧朗读 / 复制 / 重试 / 折叠（平时 0.45 透明度）；正文状态：等待是骨架条 + 扫光，模型在思考时骨架上面多一行
// 「思考中」扫光（mac-whisker S3），生成中用 RevealText 显影 + 边框上一段强调色彗星光绕行（2.4 s 一圈），
// 完成时整圈闪一下；截断的照常显示正文、下面一行说明（体检 B19）；失败分两种（体检 C5）：配置 / 密钥问题是淡橙卡
// （钥匙图标，只给「打开设置」，直达这个服务的详情页），网络 / 服务错误是淡红卡（图标晃一下，给「重试」，
// 自建 AI 服务另给「打开设置」）。重新翻译时卡片原位不动，只让正文交叉淡变 0.18 s（§4）。
// 复制时对勾替换 + 整卡闪品牌粉。大模型完成后按行内 Markdown 渲染。
// 折叠状态由浮窗按服务记住（跨重启），不再因为出结果自动展开；复制的对勾状态在会话里（⌘1–9 也亮）。
// 正文最高 8 行（按字号算的常数），再长就在卡片里滚动：滚动区铺满卡宽，系统滚动条贴卡片右边、落在内边距里不压字；
// 下面还有时底部渐隐、滚下去后顶部也渐隐；
// 大模型生成中跟着末尾走，用户往上滚就停、滚回底部再接着跟。

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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var retries = 0
  @State private var errorTicks = 0
  /// 上次出完的正文高度：重新翻译时骨架先撑到这么高，面板不先缩再一行行长回来
  @State private var settledHeight: CGFloat = 0
  /// 正文超过上限时的滚动位置；生成中是否跟着末尾走；上下渐隐的程度（0–1）
  @State private var scroll = ScrollPosition(edge: .top)
  @State private var followsEnd = true
  @State private var fade = Fade()

  /// 正文最多显示几行
  static let bodyLines = 8
  /// 正文行距（Whisker §3：阅读 15 regular 行距 3.5）
  static let bodyLineSpacing: CGFloat = 3.5
  /// 左右内边距：标题行和正文各自缩进，滚动区不缩，滚动条才在卡片最右边
  static let sideInset: CGFloat = 12

  /// 渐隐遮罩不盖的右边条宽：浮动滚动条的细条落在内边距里；「总是显示滚动条」时滚动条另占一条
  /// （15 pt，正文离卡边 27），整条都不盖
  private static var unfadedStrip: CGFloat {
    NSScroller.preferredScrollerStyle == .legacy
      ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : sideInset
  }

  /// 正文一行的高度：正文字体（系统字体 15 × 字号）的 ascender、descender 各自向上取整到整点。
  /// 默认 15 pt 得 19，和 SwiftUI 实排一致；个别字号多 1–2 pt，末行下面露出一点下一行，正好在底部渐隐里
  static func bodyLineHeight(fontSize: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: fontSize)
    return font.ascender.rounded(.up) + (-font.descender).rounded(.up) + font.leading
  }

  /// 正文区的高度上限 = 8 行 + 7 个行距：只和字号有关，浮窗高度可预期
  static func bodyCap(fontSize: CGFloat) -> CGFloat {
    let lines = CGFloat(bodyLines)
    return lines * bodyLineHeight(fontSize: fontSize) + (lines - 1) * bodyLineSpacing
  }

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

  /// 失败的种类（没失败时 nil）：配置类橙色、网络 / 服务类红色
  private var failure: TranslateError? {
    if case .failed(let error) = card.state { error } else { nil }
  }

  private var failureTint: Color? {
    failure.map { Color(nsColor: $0.kind == .config ? .systemOrange : .systemRed) }
  }

  /// 正文区现在是哪一种（等待 / 思考、正文、截断、失败）：变了才交叉淡变；生成中到完成还是同一种（同一个显影视图）
  private var phase: Int {
    switch card.state {
    case .waiting: 0
    case .running(let text): text.isEmpty ? 0 : 1
    case .done(let text): card.service.isStreaming && Self.hasMarkdown(text) ? 2 : 1
    case .truncated: 1
    case .failed: 3
    }
  }

  private var isDone: Bool {
    if case .done = card.state { true } else { false }
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, Self.sideInset)
      // 正文放进裁剪的容器里收起 / 展开：往上收时不会滑过标题行
      VStack(spacing: 0) {
        if !isCollapsed {
          scroller
            .padding(.top, 3)
            .transition(
              reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
      }
      .clipped()
    }
    // 紧凑（对标 Bob）：一行译文的卡约 54 pt（上 7 + 标题 18 + 间距 3 + 一行 + 下 8）
    .padding(.top, 7)
    .padding(.bottom, isCollapsed ? 7 : 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
    // 卡片表面（Style.CardSurface）；错误卡按种类橙 / 红 0.05 底、0.18 描边
    .cardSurface(tint: failureTint)
    .overlay { if isGenerating { CometBorder() } }
    // 完成：整圈边框闪一下品牌粉 0.45 → 0（0.6 s）
    .overlay {
      shape.strokeBorder(Style.brand, lineWidth: 1.5)
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
    // 复制：整卡闪品牌粉 0 → 0.12 → 0（0.4 s）
    .overlay {
      shape.fill(Style.brand)
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

  private var header: some View {
    HStack(spacing: 8) {
      ServiceTile(service: card.service)
      Text(Self.displayName(card.service))
        .font(.system(size: 12, weight: .semibold))
        .opacity(0.85)
        .lineLimit(1)
      // 智谱存的旧值（glm-4.6v-flash 等）实际按回落后的模型请求，这里写同一个（体检 A17）
      if let model = card.service.kind == .zhipu
        ? TranslateService.zhipuModel(card.service.model) : card.service.model,
        !model.isEmpty, card.service.isStreaming
      {
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

  /// 正文的滚动区：放得下时和内容一样高（和不滚动时一模一样），超过 8 行就停在上限、在卡片里滚。
  /// 外层结果区纵向不给高度，滚动区自然取内容高度；fixedSize 让它放在别处（设置页预览）也这样。
  /// 高度只跟着内容变（越过上限那一下由浮窗的高度动画接住），滚动时不变。
  /// 左右内边距在正文上：滚动区铺满卡宽，滚动条贴卡片右边
  private var scroller: some View {
    let fontSize = 15 * fontScale
    let cap = Self.bodyCap(fontSize: fontSize)
    let fadeLength = Self.bodyLineHeight(fontSize: fontSize)
    return ScrollView {
      content
        .padding(.horizontal, Self.sideInset)
        .frame(minHeight: isPending ? min(settledHeight, cap) : 0, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { height in
          if isDone { settledHeight = height }
        }
    }
    .scrollPosition($scroll)
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxHeight: cap)
    .fixedSize(horizontal: false, vertical: true)
    .onScrollGeometryChange(for: ScrollMetrics.self) {
      ScrollMetrics(
        offset: $0.contentOffset.y, content: $0.contentSize.height,
        container: $0.containerSize.height)
    } action: { old, new in
      follow(old, new)
      fade = Fade(
        top: min(max(new.offset / fadeLength, 0), 1),
        bottom: min(max(new.remaining / fadeLength, 0), 1))
    }
    // 渐隐是遮罩（只动透明度，深浅色、降低透明度都不用另配颜色），一行高；没溢出时两端都是 1，等于没有。
    // 右边滚动条那条（没有正文）不渐隐，滚动条两头不跟着淡掉
    .mask {
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          LinearGradient(
            colors: [.black.opacity(1 - fade.top), .black], startPoint: .top, endPoint: .bottom
          )
          .frame(height: fadeLength)
          Color.black
          LinearGradient(
            colors: [.black, .black.opacity(1 - fade.bottom)], startPoint: .top, endPoint: .bottom
          )
          .frame(height: fadeLength)
        }
        Color.black.frame(width: Self.unfadedStrip)
      }
    }
  }

  /// 大模型生成时跟着末尾走：内容变高且还在跟就滚到底（瞬时，同结果刷新；最后一段和「完成」可能在同一次
  /// 更新里到，所以看「变高」不看「生成中」）。只有偏移变了 = 用户在滚：离开底部就停，滚回底部再接着跟；
  /// 内容放得下（新一轮的骨架）时复位。完成后内容不再变高，位置就留着
  private func follow(_ old: ScrollMetrics, _ new: ScrollMetrics) {
    // 第一次量到（新旧相同）：卡片刚出现，比如关掉历史时还在生成，也要贴到末尾
    let appeared = old == new
    if appeared || new.content != old.content || new.container != old.container {
      if new.content <= new.container + 0.5 {
        followsEnd = true
      } else if followsEnd, card.service.isStreaming,
        appeared ? isPending : new.content > old.content
      {
        scroll.scrollTo(y: new.content - new.container)
      } else if appeared {
        // 刚出现、不用跟（完成的长结果从开头看）：之后改字号变高也不自己滚到底
        followsEnd = false
      }
    } else if new.offset != old.offset {
      followsEnd = new.remaining <= 1
    }
  }

  /// 用 RevealText 显示的正文：生成中有字、或完成且不按 Markdown 渲染。两种状态放在同一个结构位置，
  /// 完成那一下还是同一个视图（身份一变就会整段重新显影）。
  /// 已知问题（macOS 15.7 实测）：两种状态都套着 .textSelection(.enabled)，可选中的文字不走 TextRenderer，
  /// 所以生成中的显影（淡入、去模糊、上浮）其实画不出来、字是直接出现的；末尾的光标是单独一层，照常显示。
  /// 恢复显影要在生成中先不让选中，等用户定（RevealText 头注释）
  private var revealed: (text: String, isStreaming: Bool)? {
    switch card.state {
    case .running(let text) where !text.isEmpty: (text, true)
    case .done(let text) where !(card.service.isStreaming && Self.hasMarkdown(text)): (text, false)
    case .truncated(let text): (text, false)
    default: nil
    }
  }

  /// 正文按状态换一种画法；换的时候交叉淡变 0.18 s（重新翻译时正文淡成骨架、出字时骨架淡成正文，卡片原位不动）
  private var content: some View {
    // ZStack：换的那一下新旧两种叠在一起淡变（各分支的默认转场就是透明度），不上下错开
    ZStack(alignment: .topLeading) {
      stateView(card.state)
    }
    .animation(.easeInOut(duration: 0.18), value: phase)
  }

  @ViewBuilder private func stateView(_ state: TranslateCoordinator.CardState) -> some View {
    if let revealed {
      VStack(alignment: .leading, spacing: 6) {
        RevealText(text: revealed.text, isStreaming: revealed.isStreaming, fontSize: 15 * fontScale)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if case .truncated = state {
          // 截断不是配置问题，用 secondary 小字说明（不用橙色）
          Label("只翻了前一部分：超出这个服务单次输出上限", systemImage: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      .id(phase)
    } else if case .done(let text) = state {
      // 大模型输出里有行内 Markdown 才按 Markdown 渲染
      Text(Self.markdown(text)).font(.system(size: 15 * fontScale)).lineSpacing(3.5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(phase)
    } else if case .failed(let error) = state {
      failureRow(error).id(phase)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        if state.isThinking { ThinkingLabel() }
        Skeleton()
      }
      .id(phase)
    }
  }

  /// 错误行：配置类橙色钥匙 + 只给「打开设置」（直达这个服务）；网络 / 服务类红色三角（晃一下）+「重试」，
  /// 自建 AI 服务另给「打开设置」（地址可能填错）
  private func failureRow(_ error: TranslateError) -> some View {
    let isConfig = error.kind == .config
    let tint = Color(nsColor: isConfig ? .systemOrange : .systemRed)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: isConfig ? "key.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(tint)
        .symbolEffect(.wiggle, value: errorTicks)
      // 橙字在浅色卡底上对比度不够（同剪贴板底栏的警告）：配置类只有钥匙是橙色，字用默认色
      Text(error.message)
        .font(.system(size: 13))
        .foregroundStyle(isConfig ? Color.primary : tint)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if !isConfig {
        Button("重试") {
          retries += 1
          onRetry()
        }
      }
      if !isConfig, card.service.kind == .ai {
        Text("·").foregroundStyle(.tertiary)
      }
      if isConfig || card.service.kind == .ai {
        Button("打开设置", action: onOpenSettings)
      }
    }
    .buttonStyle(.plain).foregroundStyle(Style.brandInk).pointerStyle(.link)
    .font(.system(size: 12))
    .onAppear { errorTicks += 1 }
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

/// 正文滚动区的几何：偏移、内容高、可视高
private struct ScrollMetrics: Equatable {
  var offset: CGFloat
  var content: CGFloat
  var container: CGFloat
  /// 下面还没露出来的高度
  var remaining: CGFloat { content - container - offset }
}

/// 正文上下渐隐的程度（0 = 不渐隐，1 = 一整行从实到透明）
private struct Fade: Equatable {
  var top: CGFloat = 0
  var bottom: CGFloat = 0
}

/// 服务身份：18 pt 方块（圆角 = 边长 × 0.225）。有官方 logo 用 logo（内置服务、AIVendor 认出的厂商），
/// 认不出的自建 AI 服务用官网图标（ServiceIcons，取的时候是色块、到了淡入），都没有的用品牌色块 + 白色首字母
struct ServiceTile: View {
  let service: TranslateService
  var size: CGFloat = 18
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let logo = Self.logo(for: service) {
      logoTile(Image(decorative: logo.name), onPlate: logo.onPlate)
    } else if let host = ServiceIcons.site(for: service)?.host() {
      let icon = ServiceIcons.shared.icon(for: host)
      ZStack {
        if let icon {
          logoTile(Image(nsImage: icon.image), onPlate: icon.onPlate)
            .accessibilityHidden(true)
            .transition(.opacity)
        } else {
          monogramTile.transition(.opacity)
        }
      }
      // 到了淡入（settle）；减弱动态效果时退成 0.2 s 纯淡入（Whisker §7）
      .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: icon != nil)
      .task(id: host) { await ServiceIcons.shared.load(host) }
    } else {
      monogramTile
    }
  }

  /// logo：自带底色的满版图直接裁圆角，只有图形的垫白底、四周留 14%；0.5 pt 发丝线
  private func logoTile(_ image: Image, onPlate: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(size), style: .continuous)
    return
      image
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .padding(onPlate ? size * 0.14 : 0)
      .frame(width: size, height: size)
      .background(onPlate ? Color.white : .clear)
      .clipShape(shape)
      .overlay(shape.hairlineBorder())
  }

  /// 品牌色块 + 白色首字母
  private var monogramTile: some View {
    let color = Self.color(for: service)
    return RoundedRectangle(cornerRadius: Style.Radius.tile(size), style: .continuous)
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

  /// 菜单项里的服务图标（设置「+」菜单）：NSMenu 只认图片、画不了 SwiftUI 视图，把 18 pt 的它渲染成图，
  /// 按种类 + 协议 + 地址 + 名字缓存（菜单每次画都要）
  static func menuIcon(_ service: TranslateService) -> Image {
    let key =
      "\(service.kind.rawValue)|\(service.aiProtocol?.rawValue ?? "")|\(service.baseURL ?? "")|\(service.name)"
    if let cached = menuIcons[key] { return Image(nsImage: cached) }
    let renderer = ImageRenderer(content: ServiceTile(service: service, size: 18))
    renderer.scale = 2
    let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
    menuIcons[key] = image
    return Image(nsImage: image)
  }

  private static var menuIcons: [String: NSImage] = [:]

  /// 官方 logo（`Assets.xcassets/ServiceLogo`，取自各家官网自己的图标）：内置服务按种类，AI 服务按厂商（AIVendor：
  /// 先看地址、再看名字、Anthropic 协议兜底），Azure 用微软。认不出是谁时 nil（再看官网图标、色块首字母）。
  /// ponytail: 百度、腾讯只有 32 px 的 favicon、Kimi 只有 48 px（官网 512 px 的图带颗粒噪点，小尺寸发脏），18 pt 下略虚；
  /// 拿到 ≥ 128 px 的干净官方图直接替换 PNG
  static func logo(for service: TranslateService) -> (name: String, onPlate: Bool)? {
    let name: String? =
      switch service.kind {
      case .zhipu, .baidu, .youdao, .google, .deepl, .microsoft, .volcengine, .tencent:
        service.kind.rawValue
      case .ai: service.aiProtocol == .azure ? "microsoft" : AIVendor(service: service)?.rawValue
      }
    return name.map { ("ServiceLogo/" + $0, !fullBleed.contains($0)) }
  }

  /// 自带底色的满版 logo（直接裁圆角）；其余只有图形，垫白底
  private static let fullBleed: Set = [
    "zhipu", "baidu", "youdao", "anthropic", "kimi", "openrouter", "grok", "minimax",
  ]

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

// 下面三处循环动效（彗星边框、「思考中」、骨架的扫光）都只动变换（mac-whisker §8）：渐变各是一层只画一次的图层，
// 循环的是 rotationEffect / offset 上的隐式动画（线性、无限循环，onAppear 里起），SwiftUI 在后台的显示链接线程上
// 逐帧只改图层的旋转 / 位置，不重画内容、不占主线程。
// 不能每帧改渐变的参数（AngularGradient 的 angle、LinearGradient 的起止点），也不用 TimelineView 驱动：
// 系统给正式版出过 3 份「CPU 占用过高」报告（56–70%，持续 2–3 分钟），栈都是主线程逐帧用 CPU 光栅化环形渐变
// （CA::Layer display → CGContextDrawConicGradient）。实测（两张 396 × 120 pt 的卡，@2x、60 Hz，一个核 = 100%，
// 只算本进程）：整张「思考中」的等待卡约 30% → 约 6%；单看边框 33% → 3.5%（原来卡越高越贵，300 pt 高时 46%，
// 现在和卡高无关）、骨架 12.5% → 4%、「思考中」9% → 3.5%；TimelineView 就算只把角度交给 rotationEffect
// 也有 4–5%（它空转自己就 3–6%）。减弱动态效果时三处都不起动画，CPU 是 0。
// ponytail: 剩下的约 6% 是 SwiftUI 逐帧推这几个隐式动画的开销。自绘 CALayer + CABasicAnimation 能到 0–0.6%
// （动画整个交给渲染服务），代价是三处各包一层 NSViewRepresentable，强调色、深浅色、减弱动态效果、出场淡入淡出
// 都得自己接，屏外截图自检里永远是没动的那一帧；等待时的 CPU 还嫌高再换。
// ResultCardLoopTests 锁住「渐变是图层、在动的只是变换」。

/// 生成中的彗星边框：一段强调色光沿边框绕行（2.4 s 一圈）；减弱动态效果时静止（出现那一刻看，开着就不转）。
/// 环形渐变只画一次，放进边长 = 卡片对角线的正方形（怎么转都盖得住四角），整块转，边框形状当遮罩
private struct CometBorder: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var spins = false

  var body: some View {
    GeometryReader { geometry in
      let side = hypot(geometry.size.width, geometry.size.height)
      AngularGradient(
        stops: [
          .init(color: .clear, location: 0), .init(color: .clear, location: 0.62),
          .init(color: Style.brand.opacity(0.35), location: 0.78),
          .init(color: Style.brand, location: 0.92), .init(color: .clear, location: 1),
        ], center: .center
      )
      .frame(width: side, height: side)
      .rotationEffect(.degrees(spins ? 360 : 0))
      // 动画只挂在旋转上：出字时卡片长高（side 跟着变）不带动画，也不打断这一圈
      .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: spins)
      .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
    }
    .mask {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .strokeBorder(lineWidth: 1.5)
    }
    .onAppear { spins = !reduceMotion }
    .transition(.opacity.animation(.easeOut(duration: 0.35)))
    .allowsHitTesting(false)
  }
}

/// 扫光用的高光带（骨架的两根条、「思考中」共用）：两头透明、正中是 peak 的一条渐变，和要扫的东西一样宽，
/// 只画一次；出现时贴在左边界外，1.3 s 一趟线性循环——前 2/3 从左扫到右，后 1/3 在右边界外歇着。
/// 位移是按宽度算的，宽度变了（拖宽浮窗）要重新起：调用处用 .id(宽度) 重建
private struct SweepBand: View {
  let peak: Color
  let width: CGFloat
  @State private var swept = false

  var body: some View {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0), .init(color: peak, location: 0.5),
        .init(color: .clear, location: 1),
      ], startPoint: .leading, endPoint: .trailing
    )
    .frame(width: width)
    .offset(x: (swept ? 2 : -1) * width)
    .animation(.linear(duration: 1.3).repeatForever(autoreverses: false), value: swept)
    .onAppear { swept = true }
  }
}

/// 推理模型在思考（reasoning 字段或开头的 <think> 段）时骨架上面的「思考中」：12 medium secondary，
/// 和骨架同一种 1.3 s 的扫光（mac-whisker S3）：高光带在文字后面移过去，文字做遮罩；减弱动态效果时没有高光
private struct ThinkingLabel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text("思考中")
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
      .overlay {
        if !reduceMotion {
          GeometryReader { geometry in
            SweepBand(peak: .primary.opacity(0.55), width: geometry.size.width)
              .id(geometry.size.width)
          }
          .mask(Text("思考中").font(.system(size: 12, weight: .medium)))
        }
      }
      .accessibilityLabel("思考中")
  }
}

/// 等第一个字时的骨架：两根条（高 8，宽 94 / 58%，约一行半译文高）+ 扫光（1.3 s 一趟）；减弱动态效果时没有高光带。
/// 条的底色 primary 0.07，高光带正中 primary 0.07 / 0.93：叠在底色上正好是 0.14，和原来直接画 0.07 → 0.14 → 0.07
/// 的渐变是同一个结果（各相位、深浅色对过，差不超过 1 / 255）
private struct Skeleton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 6) {
        ForEach([0.94, 0.58], id: \.self) { width in
          let length = geometry.size.width * width
          Color.primary.opacity(0.07)
            .overlay(alignment: .leading) {
              if !reduceMotion {
                SweepBand(peak: .primary.opacity(0.07 / 0.93), width: length).id(length)
              }
            }
            // 先成组再裁，别省：直接 clipShape 的话，SwiftUI（macOS 15.7 实测）会把「裁剪区里一条带 offset 的渐变」
            // 压成一层贴着裁剪区的渐变层、位移只记在图层的 bounds 原点上，而渐变是照 bounds 铺的——高光带就停在
            // 条的正中不动，只是到点出现、到点消失（屏外用 CARenderer 把图层树画出来对过）。成组后带子是组里
            // 一层自己挪位置的图层。「思考中」的遮罩是文字，不走这条路
            .compositingGroup()
            .clipShape(Capsule())
            .frame(width: length, height: 8)
        }
      }
      .padding(.vertical, 2)
    }
    .frame(height: 26)
    .accessibilityLabel("翻译中")
  }
}
