// 一个翻译服务的结果卡片（Whisker，mac-whisker §6 翻译）：标题行 = 18 pt 品牌色块 + 服务名 12 semibold + 模型 11 tertiary
// （两段字按基线对齐），右侧朗读 / 复制 / 重试 / 折叠（CardActions：每个 20 × 18 的格子、平时 0.45 透明度，词典卡共用）；
// 正文状态：等待是骨架条 + 扫光，模型在思考时骨架上面多一行
// 「思考中」扫光（mac-whisker S3），生成中新字直接出现、末尾一根光标（ResultText）+ 边框上一段强调色彗星光绕行（2.4 s 一圈），
// 完成时整圈闪一下；截断的照常显示正文、下面一行说明（体检 B19）；失败分两种（体检 C5）：配置 / 密钥问题是淡橙卡
// （钥匙图标，只给「打开设置」，直达这个服务的详情页），网络 / 服务错误是淡红卡（图标晃一下，给「重试」，
// 自建 AI 服务另给「打开设置」）。重新翻译时卡片原位不动，只让正文交叉淡变 0.18 s（§4）。
// 复制时对勾替换 + 整卡闪品牌粉。大模型完成后按 Markdown 渲染（行内记号 + 标题、列表、引用、分隔线、代码块）。
// 折叠状态由浮窗按服务记住（跨重启），不再因为出结果自动展开；折叠着的服务不自动翻译、点开才翻（2026-11-15），
// 折叠着不画彗星光和完成时的闪光（看不到正文，闪了像在偷偷翻）。复制的对勾状态在会话里（⌘1–9 也亮）。
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
  /// 单词卡（大模型单词模式、词典类服务）：右上角的喇叭只读释义（R1）
  var wordStyle = false
  /// 讲解卡（issue #35）：喇叭只读第一段（译文）
  var explains = false
  /// 单词卡第一行是「美 /…/ 英 /…/」时，读音旁边的小喇叭念的英文词（R2）；不是英文词时 nil
  var pronounce: String?
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
    guard card.service.isStreaming, !isCollapsed else { return false }
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

  /// 正文区现在是哪一种（等待 / 思考、正文、截断、失败）：变了才交叉淡变；生成中到完成还是同一种（同一个 ResultText）
  private var phase: Int {
    switch card.state {
    case .idle: 4
    case .waiting: 0
    case .running(let text): text.isEmpty ? 0 : 1
    case .done(let text): card.service.isStreaming && Self.rendered(text) != nil ? 2 : 1
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
              isDone && card.service.isStreaming && !isCollapsed && !reduceMotion ? 0.45 : 0,
              duration: 0.01)
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
    let name = card.service.shortName
    return HStack(spacing: 8) {
      ServiceTile(service: card.service)
      // 服务名 12 和模型名 11 按基线对齐（居中对齐的话两段字的基线差 0.5–1 pt）
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(name)
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
      }
      Spacer(minLength: 6)
      CardActions {
        if let text = card.state.text, !text.isEmpty {
          // 只读译文：单词卡读第一行释义，讲解卡读第一段，别的去掉 Markdown 记号再读（R1）。
          // 用到才算（P5）：生成中每来一段字标题行都要重算一遍，去记号这一步不便宜，没在朗读时不用比
          let speech = { Speaker.speechText(text, wordStyle: wordStyle, explanation: explains) }
          let isSpeaking = speaker.speaking.map { $0 == speech() } ?? false
          Button("朗读", systemImage: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2") {
            speaker.toggle(speech(), language: language)
          }
          .symbolEffect(.variableColor.iterative.reversing, isActive: isSpeaking && !reduceMotion)
          // 读屏名字带上服务名（第四轮体检 U12）：几张卡的按钮一样，光读「复制」分不清是哪一张的
          .accessibilityLabel("朗读\(name)的译文")
          Button("复制", systemImage: isCopied ? "checkmark" : "doc.on.doc", action: onCopy)
            .contentTransition(.symbolEffect(.replace))
            .help(index < 9 ? "复制（⌘\(String(index + 1))）" : "复制")
            .accessibilityLabel("复制\(name)的译文")
        }
        Button("重新翻译", systemImage: "arrow.clockwise") {
          retries += 1
          onRetry()
        }
        .symbolEffect(.rotate, value: retries)
        .accessibilityLabel("用\(name)重新翻译")
        Button(isCollapsed ? "展开" : "收起", systemImage: "chevron.down", action: onToggleCollapse)
          .rotationEffect(.degrees(isCollapsed ? 0 : 180))
          .help(isCollapsed ? "展开：以后自动翻译" : "收起：以后不自动翻译，点开再翻")
          // 读屏名字带上服务名（第五轮体检 A4①）：几张卡分不清，它还决定这个服务以后自不自动翻译
          .accessibilityLabel(isCollapsed ? "展开\(name)" : "收起\(name)")
          .accessibilityHint(isCollapsed ? "以后自动翻译" : "以后不自动翻译，点开再翻")
      }
    }
    .frame(height: 18)
  }

  /// 正文的滚动区：放得下时和内容一样高（和不滚动时一模一样），超过 8 行就停在上限、在卡片里滚。
  /// 外层结果区纵向不给高度，滚动区自然取内容高度；fixedSize 让它放在别处（设置页预览）也这样。
  /// 高度只跟着内容变（浮窗跟着改高：出字时直接到位，别的时候越过上限那一下由浮窗的高度动画接住），滚动时不变。
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

  /// 用 ResultText 显示的正文：生成中有字、或完成且不按 Markdown 渲染。两种状态放在同一个结构位置，
  /// 完成那一下还是同一个视图（身份一变文字会整段重建、闪一下），只是光标收掉
  private var plain: (text: String, isStreaming: Bool)? {
    switch card.state {
    case .running(let text) where !text.isEmpty: (shown(text), true)
    case .done(let text) where !(card.service.isStreaming && Self.rendered(shown(text)) != nil):
      (shown(text), false)
    case .truncated(let text): (shown(text), false)
    default: nil
    }
  }

  /// 单词卡第一行的读音（美 /…/ 英 /…/）：换成带小喇叭的一行（R2），正文从第二行起。第一行还没出完时照原样
  private var phoneticLine: (phonetics: [DictionaryEntry.Phonetic], rest: String)? {
    guard pronounce != nil, let text = card.state.text else { return nil }
    return Speaker.phoneticLine(text)
  }

  private func shown(_ text: String) -> String { phoneticLine?.rest ?? text }

  /// 读音行：「美 /rʌn/ 🔊  英 /rʌn/ 🔊」，字和正文一样大
  @ViewBuilder private var pronunciationRow: some View {
    if let pronounce, let line = phoneticLine {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        ForEach(Array(line.phonetics.enumerated()), id: \.offset) { _, phonetic in
          HStack(alignment: .firstTextBaseline, spacing: 2) {
            // 读音的口音标签跟界面语言（存着的字里是「美 /…/」，Speaker.phoneticLine 认出来的）
            Text(verbatim: DictionaryCardView.label(phonetic))
              .font(.system(size: 15 * fontScale))
              .textSelection(.enabled)
            PronounceButton(word: pronounce, accent: phonetic.accent ?? .us, speaker: speaker)
          }
        }
      }
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
    if let plain {
      VStack(alignment: .leading, spacing: 6) {
        pronunciationRow
        ResultText(text: plain.text, isStreaming: plain.isStreaming, fontSize: 15 * fontScale)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if case .truncated = state {
          // 截断不是配置问题，用 secondary 小字说明（不用橙色）。图标放进和服务色块同宽的格子，字对上服务名（同错误行）
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
              .frame(width: Self.iconSlot)
              .accessibilityHidden(true)
            Text("只翻了前一部分：超出这个服务单次输出上限")
          }
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        }
      }
      .id(phase)
    } else if case .done(let text) = state {
      // 大模型输出里有 Markdown 才按 Markdown 渲染
      VStack(alignment: .leading, spacing: 6) {
        pronunciationRow
        Text(Self.rendered(shown(text)) ?? AttributedString(shown(text)))
          .font(.system(size: 15 * fontScale))
          .lineSpacing(3.5)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .id(phase)
    } else if case .failed(let error) = state {
      failureRow(error).id(phase)
    } else if state == .idle {
      // 展开着却没翻（折叠状态从别处改过来的，正常点开会马上开跑）：说一句，不画骨架（骨架会一直在）
      Text("折叠着时没有翻译，点右上角的重新翻译")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .id(phase)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        if state.isThinking { ThinkingLabel() }
        Skeleton()
      }
      .id(phase)
    }
  }

  /// 正文里带图标的一行（错误、截断说明）的图标格：和标题行的服务色块同宽，后面的字就对上服务名
  private static let iconSlot: CGFloat = 18

  /// 错误行：配置类橙色钥匙 + 只给「打开设置」（直达这个服务）；网络 / 服务类红色三角（晃一下）+「重试」，
  /// 自建 AI 服务另给「打开设置」（地址可能填错）
  private func failureRow(_ error: TranslateError) -> some View {
    let isConfig = error.kind == .config
    let tint = Color(nsColor: isConfig ? .systemOrange : .systemRed)
    // 图标格 18 × 18，中线对着第一行字（13 pt）大写字高的中线——SF 符号本来的对法，但不靠符号自己的基线：
    // 钥匙和三角高矮不一样，各按各的基线两种错误卡会差 1 pt 高
    let halfCap = NSFont.systemFont(ofSize: 13).capHeight / 2
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: isConfig ? "key.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(tint)
        .symbolEffect(.wiggle, value: errorTicks)
        .frame(width: Self.iconSlot, height: Self.iconSlot)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + halfCap }
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

  /// 完成的大模型结果按 Markdown 画成的样子，没有 Markdown 是 nil。完成的卡每次重画（复制闪光、朗读、换字号、
  /// 别的卡出字）都要判一次、画一次：200 行一段 Debug 约 6 ms（第四轮体检 F4④，ResultMarkdownTests.parseCost），
  /// 按文字记住。ponytail: 记 16 段、满了整个清掉；要更细再换成按卡片 id 存
  static func rendered(_ text: String) -> AttributedString? {
    if let cached = renderedCache[text] { return cached }
    let value = hasMarkdown(text) ? markdown(text) : nil
    if renderedCache.count >= 16 { renderedCache.removeAll() }
    renderedCache[text] = value
    return value
  }

  private static var renderedCache: [String: AttributedString?] = [:]

  /// 有没有值得按 Markdown 显示的记号：行内的粗体、代码、链接，或者哪一行以标题、列表、引用、分隔线开头
  static func hasMarkdown(_ text: String) -> Bool {
    text.contains("**") || text.contains("__") || text.contains("`") || text.contains("](")
      || text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .contains { block(of: String($0)).kind != .plain }
  }

  /// 大模型结果的 Markdown（2026-10-29 用户反馈「结果没解析 Markdown」：以前只认行内记号，大模型照原文留下的标题、
  /// 列表原样显示）。逐行先认块级：# 标题 → 粗体，- * + 列表 → •（缩进保留），> 引用 → 次要色，--- → 一段次要色横线，
  /// ``` 围栏里的行 → 等宽、不解析（围栏行本身去掉）；编号列表本来好读，原样。剩下的按行内 Markdown，行内记号只在
  /// 一行里配对；某行解析失败就按纯文本。复制按钮复制的还是原文。同 Windows 的 InlineMarkdown。
  /// ponytail: 表格、任务框、嵌套引用的层级按普通行显示；要整套 Markdown 再换成按块排的视图
  static func markdown(_ text: String) -> AttributedString {
    var result = AttributedString()
    var fenced = false
    var first = true
    for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(raw)
      if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("```") {
        fenced.toggle()
        continue
      }
      if !first { result += AttributedString("\n") }
      first = false
      if fenced {
        var code = AttributedString(line)
        code.inlinePresentationIntent = .code
        result += code
        continue
      }
      let (kind, prefix, body) = block(of: line)
      var lead = AttributedString(prefix)
      if kind == .rule { lead.foregroundColor = .secondary }
      var part =
        (try? AttributedString(
          markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(body)
      switch kind {
      case .heading:
        part = part.transformingAttributes(\.inlinePresentationIntent) {
          $0.value = ($0.value ?? []).union(.stronglyEmphasized)
        }
      case .quote: part.foregroundColor = .secondary
      default: break
      }
      result += lead + part
    }
    return result
  }

  private enum Block { case plain, heading, bullet, quote, rule }

  /// 一行是哪种块：prefix 是换掉行首记号后显示的字（列表的缩进 + •、分隔线），body 是剩下按行内 Markdown 解析的
  private static func block(of line: String) -> (kind: Block, prefix: String, body: String) {
    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
    let rest = line.dropFirst(indent.count)
    let hashes = rest.prefix { $0 == "#" }.count
    if (1...6).contains(hashes), rest.count == hashes || rest.dropFirst(hashes).first == " " {
      return (.heading, "", rest.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }
    let compact = rest.filter { $0 != " " }
    if compact.count >= 3, let mark = compact.first, "-*_".contains(mark),
      compact.allSatisfy({ $0 == mark })
    {
      return (.rule, "────────", "")
    }
    if let mark = rest.first, "-*+".contains(mark), rest.dropFirst().first == " " {
      return (.bullet, indent + "• ", String(rest.dropFirst(2)))
    }
    if rest.first == ">" {
      return (.quote, "", String(rest.drop { $0 == ">" || $0 == " " }))
    }
    return (.plain, "", line)
  }
}

/// 卡片标题行右上角的一组图标按钮（服务卡：朗读、复制、重试、折叠；词典卡：朗读、词典），两种卡共用：每个按钮一个
/// 20 × 18 的格子（整格能点）、格子之间 4——中心相隔 24，两种卡的按钮上下同列；图标 13 medium + hierarchical
/// （同原文框的朗读、复制），平时 0.45 透明度。整组往右让 2：图标在格子里居中，最右那个（折叠箭头、书本）的右缘才落在
/// 原文框星标那条线上（离卡片右边 12 上下）
struct CardActions<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 4) { content }
      .labelStyle(SlotLabelStyle())
      .buttonStyle(.borderless)
      .font(.system(size: 13, weight: .medium))
      .symbolRenderingMode(.hierarchical)
      .opacity(0.45)
      .padding(.trailing, -2)
  }

  /// 只画图标、放进定宽的格子。标题留给旁白：里面还是一个 iconOnly 的 Label
  private struct SlotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
      Label {
        configuration.title
      } icon: {
        configuration.icon.frame(width: 20, height: 18).contentShape(.rect)
      }
      .labelStyle(.iconOnly)
    }
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
      // 有道词典和有道翻译是同一个牌子；系统翻译没有 logo，用色块
      case .youdaoDict: "youdao"
      case .apple: nil
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
      case .apple: 0x5E5CE6
      case .youdaoDict: 0xE1251B
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
    let name = service.shortName.trimmingCharacters(in: .whitespaces)
    guard let first = name.first else { return "?" }
    if !first.isASCII { return String(first) }
    return name.first(where: { $0.isLetter }).map { String($0).uppercased() } ?? String(first)
  }
}

// 下面三处循环动效（彗星边框、「思考中」、骨架的扫光）和生成中的光标（ResultText）都是 LoopLayer：渐变 / 色块各是一层
// 只画一次的子图层，循环是加在它上面的 CABasicAnimation（旋转、平移、透明度），整个交给渲染服务——主线程一帧都不管
// （美化与提速 P5）。SwiftUI 只管摆放、遮罩（边框形状、文字）、淡入淡出和给颜色（强调色、深浅色随环境重取）。
// 来历：第二轮体检第 1 批之前是逐帧改渐变参数（系统出过 3 份「CPU 占用过高」报告，56–70%，主线程逐帧光栅化环形渐变）；
// 第 1 批换成 SwiftUI 的 rotationEffect / offset 隐式循环动画，渐变不再重画，但 SwiftUI 每帧还要在主线程推一遍
// 动画（三张等待卡 9.6%，单看彗星约 4%、光标约 3.6%）；P5 换成这里，三张等待卡 ≤ 1%（数在 mac-whisker §8）。
// 不能每帧改渐变的参数、不用 TimelineView、不用 SwiftUI 的 repeatForever 驱动这几处。
// 屏外截图（cacheDisplay）画的是模型值：彗星停在 0°、扫光的带子停在正中（一趟的 1/3 处）、光标全亮。
// ResultCardLoopTests 锁住「循环是图层上的动画、模型值不动；减弱动态效果时没有动画」。

/// 生成中的彗星边框：一段强调色光沿边框绕行（2.4 s 一圈）；减弱动态效果时静止在 0°（出现那一刻看，开着就不转）。
/// 环形渐变放进边长 = 卡片对角线的正方形（怎么转都盖得住四角），整块转，边框形状当遮罩
private struct CometBorder: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    LoopLayer(kind: .comet, color: Style.brand, animates: !reduceMotion)
      .mask {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .strokeBorder(lineWidth: 1.5)
      }
      .transition(.opacity.animation(.easeOut(duration: 0.35)))
      .allowsHitTesting(false)
  }
}

/// 推理模型在思考（reasoning 字段或开头的 <think> 段）时骨架上面的「思考中」：12 medium secondary，
/// 和骨架同一种 1.3 s 的扫光（mac-whisker S3）：高光带（正中 primary 0.55）在文字后面移过去，文字做遮罩；
/// 减弱动态效果时没有高光
private struct ThinkingLabel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text("思考中")
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
      .overlay {
        if !reduceMotion {
          LoopLayer(kind: .sweep, color: .primary.opacity(0.55))
            .mask(Text("思考中").font(.system(size: 12, weight: .medium)))
        }
      }
      .accessibilityLabel("思考中")
  }
}

/// 等第一个字时的骨架：两根条（高 8，宽 94 / 58%，约一行半译文高）+ 扫光（1.3 s 一趟）；减弱动态效果时没有高光带。
/// 条的底色 primary 0.07，高光带正中 primary 0.07 / 0.93：叠在底色上正好是 0.14，和原来直接画 0.07 → 0.14 → 0.07
/// 的渐变是同一个结果（各相位、深浅色对过，差不超过 1 / 255）。条（胶囊）和带子都在 LoopLayer 里，条自己裁带子
private struct Skeleton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 6) {
        ForEach([0.94, 0.58], id: \.self) { width in
          LoopLayer(
            kind: .sweep, color: .primary.opacity(0.07 / 0.93), base: .primary.opacity(0.07),
            animates: !reduceMotion
          )
          .frame(width: geometry.size.width * width, height: 8)
        }
      }
      .padding(.vertical, 2)
    }
    .frame(height: 26)
    .accessibilityLabel("翻译中")
  }
}

/// 一层自己循环的图层（翻译卡片的彗星边框、扫光、生成中的光标，P5）：子图层只画一次，循环是它上面的 CABasicAnimation，
/// 由渲染服务逐帧推，主线程不管。颜色在 updateNSView 里按 SwiftUI 的环境取（深浅色、增强对比度、换了强调色都会再调它）
struct LoopLayer: NSViewRepresentable {
  enum Kind {
    /// 彗星：环形渐变（透明 → 0.62 处起 → 0.78 处 color 0.35 → 0.92 处 color → 透明），放进边长 = 对角线的正方形，
    /// 2.4 s 顺时针转一圈
    case comet
    /// 扫光：两头透明、正中是 color 的一条和自己一样宽的带子，1.3 s 一趟线性循环——从左边界外起，前 2/3 扫到右边界外，
    /// 后 1/3 在外面歇着；有 base 时它是胶囊条的底色、带子裁在条里
    case sweep
    /// 光标：color 的圆角条（圆角 1）摆在 mark 处，透明度 1 ↔ 0.35、0.55 s 一程往返（正弦缓入缓出）
    case blink
  }

  let kind: Kind
  let color: Color
  var base: Color?
  /// false：不动（减弱动态效果）——彗星停在 0°、扫光没有带子、光标全亮
  var animates = true
  /// 光标在这一层里的位置（blink；nil = 没有字、不画）
  var mark: CGRect?

  func makeNSView(context: Context) -> LoopLayerView { LoopLayerView(kind: kind) }

  func updateNSView(_ view: LoopLayerView, context: Context) {
    let environment = context.environment
    view.update(
      color: color.resolve(in: environment), base: base?.resolve(in: environment).cgColor,
      animates: animates, mark: mark)
  }
}

/// LoopLayer 的视图：clip（裁到自己的边界，光标除外：它贴在最后一个字后面，可能伸出正文右边；扫光条的底色和胶囊圆角
/// 在它上面）里放一层 moving，循环的动画挂在 moving 上。坐标翻转成左上原点（同 SwiftUI），旋转的正方向就是顺时针
final class LoopLayerView: NSView {
  /// 动画的 key（单测按它找）
  static let animationKey = "loop"

  let kind: LoopLayer.Kind
  private let clip = CALayer()
  private let moving: CALayer
  private var animates = false
  /// 扫光是骨架的胶囊条（有底色）：圆角 = 半高
  private var isBar = false
  /// 扫光是按宽度平移的：宽度变了（拖宽浮窗）要按新宽度重起
  private var animatedWidth: CGFloat = 0

  init(kind: LoopLayer.Kind) {
    self.kind = kind
    switch kind {
    case .comet:
      let gradient = CAGradientLayer()
      gradient.type = .conic
      gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
      gradient.endPoint = CGPoint(x: 1, y: 0.5)
      gradient.locations = [0, 0.31, 0.62, 0.7, 0.78, 0.85, 0.92, 0.96, 1]
      moving = gradient
    case .sweep:
      let gradient = CAGradientLayer()
      gradient.startPoint = CGPoint(x: 0, y: 0.5)
      gradient.endPoint = CGPoint(x: 1, y: 0.5)
      gradient.locations = [0, 0.25, 0.5, 0.75, 1]
      moving = gradient
    case .blink:
      moving = CALayer()
      moving.cornerRadius = 1
      moving.cornerCurve = .continuous
    }
    super.init(frame: .zero)
    wantsLayer = true
    if case .blink = kind {} else { clip.masksToBounds = true }
    clip.cornerCurve = .continuous
    clip.addSublayer(moving)
    layer?.addSublayer(clip)
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// 自己加的子图层 AppKit 不管倍率：换到别的屏（1x / 2x）时跟上，渐变别按 1x 画了再放大
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? 2
    clip.contentsScale = scale
    moving.contentsScale = scale
  }

  func update(color: Color.Resolved, base: CGColor?, animates: Bool, mark: CGRect? = nil) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // 色标照 SwiftUI 画这两种渐变时交给图层的那一套（P5 换之前把它建的图层打出来对过）：每一段中间补一个色标。
    // 透明的那几个也用同一种颜色、只是透明度 0：图层按没预乘的颜色插值，拿黑色的透明去插，两头那一段会发暗
    // （SwiftUI 自己的渐变层按预乘插值，屏外出图对过：原来差到 17 / 255，这样之后一样）
    func tint(_ alpha: Double) -> CGColor {
      var faded = color
      faded.opacity *= Float(alpha)
      return faded.cgColor
    }
    switch kind {
    case .comet:
      (moving as? CAGradientLayer)?.colors = [
        tint(0), tint(0), tint(0), tint(0.175), tint(0.35), tint(0.675), tint(1), tint(0.5),
        tint(0),
      ]
    case .sweep:
      (moving as? CAGradientLayer)?.colors = [tint(0), tint(0.5), tint(1), tint(0.5), tint(0)]
      clip.backgroundColor = base
      isBar = base != nil
    case .blink:
      moving.backgroundColor = color.cgColor
      if let mark { moving.frame = mark }
    }
    // 减弱动态效果时扫光没有带子（同原来的写法：带子整个不画）；光标没有位置就不画
    switch kind {
    case .comet: break
    case .sweep: moving.isHidden = !animates
    case .blink: moving.isHidden = mark == nil
    }
    CATransaction.commit()
    if animates != self.animates {
      self.animates = animates
      restart()
    }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clip.frame = bounds
    switch kind {
    case .comet:
      let side = hypot(bounds.width, bounds.height)
      moving.bounds = CGRect(x: 0, y: 0, width: side, height: side)
      moving.position = CGPoint(x: bounds.midX, y: bounds.midY)
    case .sweep:
      // 胶囊条：圆角 = 半高（同 Capsule）。带子的模型值停在正中：屏外截图画的就是这一帧
      clip.cornerRadius = isBar ? bounds.height / 2 : 0
      moving.frame = bounds
    case .blink: break
    }
    CATransaction.commit()
    // 第一次排出尺寸时才挂得上（彗星、扫光要尺寸）；扫光的宽度变了按新宽度重起
    let missing = animates && moving.animation(forKey: Self.animationKey) == nil
    if missing || (kind == .sweep && abs(bounds.width - animatedWidth) > 0.5) { restart() }
  }

  /// 按现在的开关、尺寸重挂循环的动画（从头起：同原来 .id(宽度) 重建）
  private func restart() {
    moving.removeAnimation(forKey: Self.animationKey)
    animatedWidth = bounds.width
    guard animates, bounds.width > 0 || kind == .blink else { return }
    let animation: CABasicAnimation
    switch kind {
    case .comet:
      animation = CABasicAnimation(keyPath: "transform.rotation.z")
      animation.fromValue = 0
      animation.toValue = 2 * Double.pi
      animation.duration = 2.4
      animation.timingFunction = CAMediaTimingFunction(name: .linear)
    case .sweep:
      animation = CABasicAnimation(keyPath: "transform.translation.x")
      animation.fromValue = -bounds.width
      animation.toValue = 2 * bounds.width
      animation.duration = 1.3
      animation.timingFunction = CAMediaTimingFunction(name: .linear)
    case .blink:
      animation = CABasicAnimation(keyPath: "opacity")
      animation.fromValue = 1
      animation.toValue = 0.35
      animation.duration = 0.55
      animation.autoreverses = true
      animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
    }
    animation.repeatCount = .infinity
    moving.add(animation, forKey: Self.animationKey)
  }
}
