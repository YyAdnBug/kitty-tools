// AppDelegate 里截图上的字（第五轮体检 H1 从 AppDelegate.swift 拆出）：截图翻译（翻译浮窗 / 逐段盖回截图上）、识字（框选、访达右键「拷贝图中文字」）。

import AppKit
import SwiftUI
import VisionKit

extension AppDelegate {
  /// 本机识别文字 → 原文记进剪贴板历史 → 现有的多服务翻译浮窗（钉图上的翻译走这里）。
  /// 总是按段送去翻（体检 A32：同一段的行接起来、段间空一行，不看「接起来」开关）
  func translateInPanel(_ image: CGImage) async {
    guard let recognized = await recognizeForTranslation(image) else { return }
    await untilCaptureEnds()
    coordinator.translate(recognized.text)
    presentTranslate()
  }

  /// 就地翻译（截图工具栏「翻译」用）：识别 + 逐段翻译 + 覆盖渲染，交回贴了译文的图和放不下的段。
  /// pixelsPerPoint 是选区图每点几个像素（字号下限按点算）。
  /// 失败时消息交回遮罩上的提示，岛上另外说一遍（收起遮罩后也能看到原因）
  func overlayTranslate(_ image: CGImage, pixelsPerPoint: CGFloat) async
    -> ScreenshotOverlay.Outcome
  {
    // 图标被认成的单字（首页的剪贴板图标认成「目」）不翻、不擦（拍板 F1）
    guard let recognized = await recognizeForTranslation(image, droppingIcons: true) else {
      return .init(message: String(localized: "识别失败"))
    }
    let segments = await ScreenshotOverlay.prepareSegments(of: recognized.lines, in: image)
    guard !segments.isEmpty else { return .init(message: String(localized: "没有识别到文字")) }
    do {
      let translations = try await translateSegments(segments, source: recognized.text)
      var composed = await ScreenshotOverlay.render(
        image, segments: segments, translations: translations, pixelsPerPoint: pixelsPerPoint)
      guard composed.image != nil || !composed.leftovers.isEmpty else {
        return .init(message: String(localized: "合成失败"))
      }
      // 卡片的「拷贝译文」拷全部段（纯符号段原样占位，不算）
      composed.translation = zip(segments, translations)
        .filter { ScreenshotOverlay.hasTranslatableContent($0.0.text) }
        .map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "\n\n")
      return composed
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else {
        return .init(message: String(localized: "已取消"))
      }
      island.show("翻译失败", detail: "\(error.localizedDescription)", tone: .error)
      return .init(message: error.localizedDescription)
    }
  }

  /// 截图翻译和钉图的翻译共用的那一半：识别 + 原文记进剪贴板历史（设置 › 翻译 开着「截图翻译时复制识别出的原文」
  /// 时同时写进剪贴板）。返回 nil 时岛上已经说过原因
  private func recognizeForTranslation(_ image: CGImage, droppingIcons: Bool = false) async
    -> (lines: [OCR.Line], text: String)?
  {
    guard
      let lines = await recognizing({
        await OCR.recognizeLines(in: image, droppingIcons: droppingIcons)
      })
    else {
      island.show("文字识别失败", detail: "请重试", tone: .error)
      return nil
    }
    // 识别这段时间里会话可能已经被取消（用户按 Esc 收起截图）：这时不要再写剪贴板历史、也不往下翻
    guard !Task.isCancelled else { return nil }
    guard !lines.isEmpty else {
      island.show("没有识别到文字", detail: "可以把选区框大一些再试", tone: .warning)
      return nil
    }
    // 没有结果岛（接着翻译、开浮窗）：「识别中」「正在准备」出过就收掉
    island.dismiss(ifShowing: Self.recognizingTitle)
    island.dismiss(ifShowing: Self.preparingTitle)
    let text = OCR.text(lines, joined: true, separator: "\n\n")
    // 默认不写剪贴板、只记进历史（同一个入口：过敏感文本过滤、已有同文只挪到最前）；开了就当复制一次（写剪贴板 + 记历史）
    if UserDefaults.standard.bool(forKey: Prefs.translateCopyRecognized) {
      Paster.write(string: text, record: true)
    } else {
      Paster.recordText?(text)
    }
    return (lines, text)
  }

  /// 截图翻译盖回时的进度岛：和划词翻译并替换那条「翻译中…」分开（同名的话进度会写到那条上）
  private static let overlayTitle: LocalizedStringResource = "截图翻译中…"

  /// 逐段翻译（原位覆盖用）：整段原文检测一次语种，各段用同一个方向；同时最多 3 段一起请求（inParallel），
  /// 每段按顺序试启用的服务（没折叠的在前）。
  /// 不走 coordinator.translate：那条路按服务写翻译历史，一块图拆成十几段会往历史里塞十几条碎片
  private func translateSegments(
    _ segments: [ScreenshotOverlay.Segment], source: String
  ) async throws -> [String] {
    // 没折叠的服务先试（浮窗里折叠 = 不自动翻译，排第一的贵模型折叠了也不先用它）
    let services = coordinator.orderedServices
    guard !services.isEmpty else {
      throw TranslateError(message: String(localized: "没有启用的翻译服务，先在设置 › 翻译里开一个"))
    }
    let plan = TranslateCoordinator.plan(for: source, inPanel: false).request
    // 纯符号段不发请求（有道这类接口会回错误码，一段失败整张图就白翻了），原样占位；覆盖那一步也会跳过它
    var results = segments.map(\.text)
    let pending = segments.indices.filter {
      ScreenshotOverlay.hasTranslatableContent(segments[$0].text)
    }
    // 同时最多 3 段一起请求（2026-11-08 第二轮拍板 G1：以前一段一段等，整屏十几段要十秒上下）：免费服务会限流，不开太多。
    // 每段自己按启用顺序换服务，所有服务都失败才算整张图失败（同原来）
    let requests = pending.map {
      TranslateRequest(text: segments[$0].text, from: plan.from, to: plan.to)
    }
    // 要翻好几轮（段数多过同时请求的数）才出进度岛：一轮就翻完的不弹，免得一闪而过；翻完、失败、取消都收掉
    let showsProgress = requests.count > Self.overlayConcurrency
    if showsProgress {
      island.show(
        Self.overlayTitle, detail: "0/\(requests.count)", tone: .progress, symbol: "translate")
    }
    defer { if showsProgress { island.dismiss(ifShowing: Self.overlayTitle) } }
    let outputs = try await Self.inParallel(
      requests.count, limit: Self.overlayConcurrency,
      finished: { [island] done in
        if showsProgress { island.progress(Self.overlayTitle, detail: "\(done)/\(requests.count)") }
      },
      work: { index in try await Self.translateSegment(requests[index], services: services) })
    for (index, output) in zip(pending, outputs) { results[index] = output.text }
    // 历史里记的服务：按段的顺序第一个用上的那个（同原来串行时）
    let used = outputs.first?.service
    // 和浮窗那条一样记一份翻译历史（整段原文 + 整段译文），不然截图翻译在翻译历史里会凭空消失
    if let used, UserDefaults.standard.bool(forKey: Prefs.translateHistoryEnabled) {
      coordinator.history.add(
        source: source, target: plan.to, result: results.joined(separator: "\n\n"),
        service: used.name,
        limit: UserDefaults.standard.integer(forKey: Prefs.translateHistoryLimit))
    }
    return results
  }

  /// 截图翻译盖回时同时最多请求几段（第二轮 G1）
  private static let overlayConcurrency = 3

  /// 最多 limit 个一起跑、一个完成补下一个，结果按下标放回（第二轮 G1）；任何一个抛错就整个抛（其余的取消）。
  /// finished(完成了几个) 每完成一个调一次（在调用方这边，可以直接动界面）。纯调度，配单测
  static func inParallel<T: Sendable>(
    _ count: Int, limit: Int, finished: (Int) -> Void = { _ in },
    work: @escaping @Sendable (Int) async throws -> T
  ) async throws -> [T] {
    var results = [T?](repeating: nil, count: count)
    try await withThrowingTaskGroup(of: (Int, T).self) { group in
      var next = 0
      var done = 0
      func launch() {
        guard next < count else { return }
        let index = next
        next += 1
        group.addTask { (index, try await work(index)) }
      }
      for _ in 0..<max(1, limit) { launch() }
      while let (index, value) = try await group.next() {
        results[index] = value
        done += 1
        finished(done)
        launch()
      }
    }
    // 没抛错就每个位置都有值；真少了一个是这里写错了，别让它悄悄变短、对应的段留成原文
    assert(!results.contains { $0 == nil }, "inParallel 有位置没填上")
    return results.compactMap { $0 }
  }

  /// 一段：按启用顺序试服务，第一个出了非空译文的就用；都失败抛最后一个错误，取消照样往外抛
  private nonisolated static func translateSegment(
    _ request: TranslateRequest, services: [TranslateService]
  ) async throws -> (text: String, service: TranslateService) {
    var failure: Error = TranslateError(message: String(localized: "翻译失败"))
    for service in services {
      try Task.checkCancellation()
      do {
        var latest = ""
        for try await partial in service.translate(request) { latest = partial }
        try Task.checkCancellation()
        guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw TranslateError.emptyResult
        }
        return (latest, service)
      } catch {
        if error is CancellationError || Task.isCancelled { throw error }
        failure = error
      }
    }
    throw failure
  }

  /// 识字慢的时候先出「识别中」（第二轮体检 R3）：常见选区 0.04–0.13 s，不出；整屏密集文字约 0.9 s，过了 0.3 s 还没出结果
  /// 刘海岛先说一声，结果出来原地换掉（识字、截图翻译、钉图上的识字 / 翻译都走这里）
  private static let recognizingTitle: LocalizedStringResource = "识别中…"
  /// 新装、系统更新后第一次识字：系统要先现场编译识字模型（OCR.prepare，冷的约一分钟）。岛一直挂着、每秒报等了多久，
  /// 不然看着像卡死了
  private static let preparingTitle: LocalizedStringResource = "正在准备识字模型…"

  private func recognizing<T>(_ work: () async -> T) async -> T {
    // 进程内识过字，模型就留在内存里：这一路不一定开关面板（⌥O 识字、钉图上识字），自己记得回头放掉
    defer { idleReclaim.schedule() }
    let warmup = OCR.foreground.beginUse()
    await prepareRecognition()
    return await island.showIfSlow(Self.recognizingTitle) {
      await warmup?.value
      return await work()
    }
  }

  /// 识字模型还没加载：刘海岛上说一声、按秒报已等多久，等它加载好（第一次要一分钟左右）
  private func prepareRecognition(showingProgress: Bool = true) async {
    guard !OCR.isPrepared() else { return }
    var ticker: Task<Void, Never>?
    if showingProgress {
      let note = String(localized: "第一次识字要等一分钟左右，以后就快了")
      island.show(
        Self.preparingTitle, detail: "\(note)", tone: .progress, symbol: "text.viewfinder")
      let started = ContinuousClock.now
      ticker = Task { [island] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          let seconds = (ContinuousClock.now - started).components.seconds
          island.progress(Self.preparingTitle, detail: "\(note) · 已等 \(seconds) 秒")
        }
      }
    }
    if await OCR.prepare() { ocrMarkerWatcher?.preparationSucceeded() }
    ticker?.cancel()
  }

  enum CopyResult: Equatable {
    case codes(String)
    case text(String)
    case unreadable
    case cancelled
  }

  /// 拷贝图中文字用不用实况文本（PR #45）：它的 transcript 自己就按段接好了（同一段的折行接起来，标题、标签各占一行；
  /// 实测分段比按行框接的好、字也认得准），所以「接起来」开着时用它；关着要一行一行原样，只有 Vision 给得出，
  /// 除非 Vision 还没准备好（新装、系统更新后、缓存刚被清的那一分钟）——先用实况文本，不让人干等
  static func usesLiveText(joined: Bool, visionPrepared: Bool) -> Bool {
    joined || !visionPrepared
  }

  /// 有码拷码；nil = 走 Vision（不用实况文本、机器不支持、它报错）。实况文本成功但没字就到此为止，不再跑 Vision
  static func fastTextForCopy(
    codes: [String], liveText: Bool, transcript: () async throws -> String?
  ) async -> CopyResult? {
    guard !Task.isCancelled else { return .cancelled }
    if !codes.isEmpty { return .codes(codes.joined(separator: "\n")) }
    guard liveText else { return nil }
    do {
      let text = try await transcript()
      guard !Task.isCancelled else { return .cancelled }
      return text.map { .text($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    } catch {
      return error is CancellationError || Task.isCancelled ? .cancelled : nil
    }
  }

  /// 每张图只走一次。有整批进度时不弹单张的岛；单张先结束查码 / 实况文本的慢提示，再进入 Vision 的准备提示。
  private func recognizeForCopy(
    _ image: CGImage, joined: Bool, liveText: Bool, prepareBatchVision: (() async -> Void)? = nil
  ) async -> CopyResult {
    func fastRead() async -> CopyResult? {
      guard !Task.isCancelled else { return .cancelled }
      let codes = await OCR.barcodes(in: image)
      return await Self.fastTextForCopy(codes: codes, liveText: liveText) {
        try await LiveText.analysis(of: image)?.transcript
      }
    }

    func readLines() async -> [OCR.Line]? {
      guard !Task.isCancelled else { return nil }
      return await OCR.recognizeLines(in: image)
    }

    let lines: [OCR.Line]?
    if let prepareBatchVision {
      if let result = await fastRead() { return result }
      guard !Task.isCancelled else { return .cancelled }
      await prepareBatchVision()
      lines = await readLines()
    } else {
      let fast = await island.showIfSlow(Self.recognizingTitle, fastRead)
      if let result = Task.isCancelled ? .cancelled : fast {
        idleReclaim.schedule()  // 查码也会留下模型；下面的 Vision 分支由 recognizing 安排回收
        return result
      }
      lines = await recognizing(readLines)
    }
    guard !Task.isCancelled else { return .cancelled }
    guard let lines else { return .unreadable }
    return .text(OCR.text(lines, joined: joined))
  }

  /// 有二维码 / 条码就复制它的内容，否则复制识别出的文字（设置里开了就把换行合成一段）；记进剪贴板历史
  func copyRecognizedText(in image: CGImage) async {
    let joined = UserDefaults.standard.bool(forKey: Prefs.ocrJoinLines)
    let result = await recognizeForCopy(
      image, joined: joined,
      liveText: Self.usesLiveText(joined: joined, visionPrepared: OCR.isPrepared()))
    let text: String
    let isCode: Bool
    switch Task.isCancelled ? .cancelled : result {
    case .codes(let codes): (text, isCode) = (codes, true)
    case .text(let transcript): (text, isCode) = (transcript, false)
    case .unreadable: return island.show("文字识别失败", detail: "请重试", tone: .error)
    case .cancelled:
      return
    }
    guard !text.isEmpty else {
      return island.show("没有识别到文字", tone: .warning)
    }
    Paster.write(string: text, record: true)
    island.show(
      isCode ? "已复制二维码" : "已复制",
      detail: "\(Island.excerpt(text))",
      symbol: isCode ? "qrcode" : nil)
  }

  /// 访达右键「拷贝图中文字」（2026-11-17 拍板 C1）：一张张认，每张同截图识字（有二维码 / 条码拷它的内容，没有就识字、
  /// 按设置接不接行），几张之间空一行；拷进剪贴板、记进历史，刘海岛说一声。排进访达右键那条队（FileMoves.enqueue）：
  /// 超过 1 秒挂进度条「3/20」和「停止」，停了什么都不拷。一次最多 maxImageFiles 张；还没从 iCloud 下载下来的不读
  /// （一读就要整个下载，同解压不预读没下载的包）
  func copyRecognizedText(inFiles files: [URL]) {
    let urls = Array(files.prefix(Self.maxImageFiles))
    let joined = UserDefaults.standard.bool(forKey: Prefs.ocrJoinLines)
    FileMoves.enqueue("正在识别图里的文字…", detail: "0/\(urls.count)", island: island) {
      [unowned self] report in
      defer { idleReclaim.schedule() }
      // 整批按开始时定的走（中途 Vision 在后台准备好了也不换，一批的格式一样）
      let liveText = Self.usesLiveText(joined: joined, visionPrepared: OCR.isPrepared())
      // 真有一张图要走 Vision 才准备；整批只等一次（准备没成也不为下一张图重来一遍）。
      var startedVision = false
      @MainActor func prepareBatchVision() async {
        guard !startedVision else { return }
        startedVision = true
        let warmup = OCR.foreground.beginUse()
        await prepareRecognition(showingProgress: false)
        if !Task.isCancelled { await warmup?.value }
      }
      var texts: [String] = []
      var codesOnly = true
      var unreadable = 0
      for (index, url) in urls.enumerated() where !Task.isCancelled {
        report(Double(index) / Double(urls.count), "\(index)/\(urls.count)")
        let cloud = try? url.resourceValues(forKeys: [
          .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard
          !(cloud?.isUbiquitousItem == true
            && cloud?.ubiquitousItemDownloadingStatus == .notDownloaded),
          let image = await OCR.image(at: url)
        else {
          unreadable += 1
          continue
        }
        switch await recognizeForCopy(
          image, joined: joined, liveText: liveText, prepareBatchVision: prepareBatchVision)
        {
        case .codes(let codes): texts.append(codes)
        case .text(let text):
          codesOnly = false
          if !text.isEmpty { texts.append(text) }
        case .unreadable:
          codesOnly = false
          unreadable += 1
        case .cancelled:
          return (texts: [String](), codesOnly: false, unreadable: unreadable, stopped: true)
        }
      }
      return (
        texts: texts, codesOnly: codesOnly, unreadable: unreadable, stopped: Task.isCancelled
      )
    } finish: { [unowned self] result in
      guard !result.stopped, !Task.isCancelled else {
        return island.show("已停止识别", detail: "什么都没拷", tone: .info)
      }
      let text = result.texts.joined(separator: "\n\n")
      guard !text.isEmpty else {
        let title: LocalizedStringResource =
          result.unreadable < urls.count
          ? "没有识别到文字" : urls.count == 1 ? "没能读这张图" : "这几张图都没能读"
        return island.show(title, tone: .warning)
      }
      Paster.write(string: text, record: true)
      let title: LocalizedStringResource =
        result.codesOnly
        ? "已复制二维码" : result.texts.count > 1 ? "已复制 \(result.texts.count) 张图里的文字" : "已复制"
      // 有没读成的、超过上限没认的：照实说（不然以为全拷上了）
      let unread = result.unreadable
      let capped = files.count > urls.count
      let detail: LocalizedStringResource =
        if unread > 0 && capped {
          "有 \(unread) 张没能读；一次最多认 \(Self.maxImageFiles) 张，后面的没认"
        } else if unread > 0 {
          "有 \(unread) 张没能读（读不了，或者还没从 iCloud 下载）"
        } else if capped {
          "一次最多认 \(Self.maxImageFiles) 张，后面的没认"
        } else {
          "\(Island.excerpt(text))"
        }
      island.show(
        title, detail: detail, tone: unread > 0 || capped ? .warning : .success,
        symbol: result.codesOnly ? "qrcode" : nil)
    }
  }

  /// 访达右键「拷贝图中文字」一次最多认几张（一张 0.2–0.5 s，再多就让人分几次）
  private static let maxImageFiles = 50
}
