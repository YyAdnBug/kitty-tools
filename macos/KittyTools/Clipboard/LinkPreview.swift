// 链接富预览（Whisker §6 剪贴板）：检查器的链接卡取网页标题、头图和网站图标，列表行的链接角标换成网站图标。
// 不用 LinkPresentation：实测它每次拉起 WebKit 的 GPU / 网络进程（GPU 进程取完还常驻约 13 MB），取 GitHub 要 3–3.5 s。
// 这里用临时会话（不带 Cookie、不落盘）按块收网页，只读 <head>（最多 512 KB）里的 og: / twitter: 标签和 <title>，
// 再取头图（≤ 4 MB）和图标（≤ 512 KB）缩成缩略图（@concurrent）。选中停留 0.25 s 才开始取；开始了就取完
// （同一条再选中时等它，不重开），网络错误不记、下次选中再试。网页请求 3 s 没动静就放弃。
// 不取：非 http(s)、本机 / 内网 / 私有地址、带账号密码、像一次性令牌的网址（预取会把魔法登录、邮箱验证、退订链接用掉），
// 跳转到这些地址也拦下；头图、图标这类子资源只拦前三种（CDN 的文件名常是长哈希，不是令牌）。结果缓存在内存（最多 12 条）；
// 头图另留着下载来的字节：面板都收起两分钟后把缩略图丢掉（dropHeroes，空闲回收），再显示时照字节重解，不再联网。
// 翻译服务的官网图标（Translate/ServiceIcons，第 13 批）也经这里的 siteIcon 取，同一个下载器、同样的限制。

import AppKit
import ImageIO
import Observation

/// 网页 <head> 里读到的东西
nonisolated struct LinkMetadata: Equatable, Sendable {
  var title: String?
  var siteName: String?
  var image: URL?
  /// 按优先级：apple-touch-icon > icon > /favicon.ico
  var icons: [URL] = []
}

@Observable final class LinkPreview {
  struct Entry {
    var metadata = LinkMetadata()
    var image: NSImage?
    /// 头图下载来的字节（解得出来才留）：空闲回收丢掉 image 之后照它重解（restoreHero）
    var imageData: Data?
    var icon: NSImage?
    /// 图标的主色（没有头图时占位渐变用）
    var tint: NSColor?
    /// 还在取（头图区显示扫光）
    var isLoading = true
    /// 跳转后还在同一个网站：只有这样网站图标才记到这个主机名下（短链接跳到别处时，角标不能冒充短链接的网站）
    var isSameSite = true

    /// 头图被空闲回收丢了、字节还在：显示它的视图（LinkHero）看到就让 restoreHero 重解
    var isHeroDropped: Bool { image == nil && imageData != nil }
  }

  static let shared = LinkPreview()
  /// 头图缩略图的长边（像素）：⌘Y 大卡的头图区高 300 pt
  private static let heroPixel = 1200

  private(set) var entries: [URL: Entry] = [:]
  /// 按主机名记的网站图标：列表行的链接角标用
  private(set) var favicons: [String: NSImage] = [:]
  @ObservationIgnored private var order: [URL] = []
  /// 正在取的：同一条再选中时等它，不重开
  @ObservationIgnored private var inFlight: [URL: Task<Void, Never>] = [:]
  @ObservationIgnored private let fetcher = Fetcher()

  func entry(for url: URL) -> Entry? { entries[url] }

  /// 列表行：整段是链接的文本对应的网站图标（取过预览才有）
  func favicon(forLink text: String) -> NSImage? {
    Self.host(ofLink: text).flatMap { favicons[$0] }
  }

  /// 取一条链接的预览：取过就直接返回，正在取就等它。调用方先判断设置开关
  func load(_ url: URL) async {
    guard Self.isFetchable(url) else { return }
    if let running = inFlight[url] { return await running.value }
    guard entries[url] == nil else { return }
    let task = Task { await fetch(url) }
    inFlight[url] = task
    await task.value
    inFlight[url] = nil
  }

  private func fetch(_ url: URL) async {
    store(Entry(), for: url)
    // 网络错误：不记，下次选中再试
    guard let page = try? await fetcher.get(url, as: .page) else { return forget(url) }
    var entry = Entry()
    let base = page.response.url ?? url
    entry.isSameSite = base.host()?.lowercased() == Self.host(ofLink: url.absoluteString)
    var imageData: Data?
    if (200..<300).contains(page.response.statusCode) {
      let mime = page.response.mimeType?.lowercased() ?? ""
      if mime.hasPrefix("image/") {
        imageData = page.data  // 链接本身是图片：直接当头图
      } else if !page.data.isEmpty {
        entry.metadata = Self.parse(
          html: Self.decode(page.data, charset: page.response.textEncodingName), base: base)
      }
    }
    if entry.metadata.icons.isEmpty, let icon = URL(string: "/favicon.ico", relativeTo: base) {
      entry.metadata.icons = [icon.absoluteURL]
    }
    store(entry, for: url)  // 标题先出来，图片接着取
    let (imageURL, iconURLs) = (entry.metadata.image, entry.metadata.icons)
    async let hero = imageData != nil ? imageData : download(imageURL, limit: 4_000_000)
    async let icon = fetchIcon(iconURLs)
    let (heroData, loadedIcon) = await (hero, icon)
    if let heroData, let image = await Self.thumbnail(heroData, maxPixel: Self.heroPixel) {
      entry.image = NSImage(cgImage: image, size: .zero)
      entry.imageData = heroData
    }
    entry.icon = loadedIcon.map { NSImage(cgImage: $0, size: .zero) }
    entry.tint = entry.icon.flatMap(AppIcons.average)
    entry.isLoading = false
    store(entry, for: url)
  }

  private func forget(_ url: URL) {
    entries[url] = nil
    order.removeAll { $0 == url }
  }

  /// 空闲回收（AppDelegate.idleReclaim，面板都收起两分钟后）：头图的缩略图都丢掉，只留下载来的字节。缩略图一做好
  /// 像素就在内存里（一份「宽 × 高 × 4」，长边 1200 约 3 MB；没画过时不计入本进程的 footprint，全机的匿名页实测涨了
  /// 这么多），画过再多一份 CoreAnimation 的：12 条都看过约 70 MB，窗口收起也不还，放手才还。
  /// 没留字节的不丢（丢了回不来；产品里有头图就有字节，只有截图自检摆的状态没有）。
  /// ponytail: 字节一直留到条目被挤掉（常见一条几十到几百 KB，最多 12 条 × 4 MB）；嫌多就在这里按总量封顶，
  /// 超出的整条 forget（下次选中重新取）
  func dropHeroes() {
    for (url, entry) in entries where entry.imageData != nil { entries[url]?.image = nil }
  }

  /// 被 dropHeroes 丢掉的头图照留着的字节重解一张（不联网；实测 JPEG 2–15 ms、要缩小的 PNG 20–44 ms，在主线程外）
  func restoreHero(for url: URL) async {
    guard let entry = entries[url], entry.isHeroDropped, let data = entry.imageData,
      let image = await Self.thumbnail(data, maxPixel: Self.heroPixel),
      // 解的这会儿条目可能被挤掉、重新取过、被另一个视图先解好了：还是丢了头图的那一条才放回去
      entries[url]?.isHeroDropped == true
    else { return }
    entries[url]?.image = NSImage(cgImage: image, size: .zero)
  }

  /// 最多留 12 条（头图缩略图长边 1200，做好约 3 MB 一张、画过两份约 6 MB；空闲时丢掉，见 dropHeroes），多了丢最早的；
  /// 同一网站的图标按主机名记下给列表行用（截图自检也用它摆状态）
  func store(_ entry: Entry, for url: URL) {
    if entries[url] == nil {
      order.append(url)
      if order.count > 12 { entries[order.removeFirst()] = nil }
    }
    entries[url] = entry
    if let icon = entry.icon, entry.isSameSite, let host = Self.host(ofLink: url.absoluteString) {
      if favicons.count >= 64 { favicons.removeAll() }
      favicons[host] = icon
    }
  }

  /// 头图 / 图标的字节：只收图片、不超过 limit 字节
  private func download(_ url: URL?, limit: Int) async -> Data? {
    guard let url, Self.isPublicHTTP(url),
      let result = try? await fetcher.get(url, as: .image(limit: limit)),
      (200..<300).contains(result.response.statusCode), !result.data.isEmpty
    else { return nil }
    return result.data
  }

  /// 图标候选依次试，最多两个；缩成长边 maxPixel 的缩略图
  private func fetchIcon(_ candidates: [URL], maxPixel: Int = 96) async -> CGImage? {
    for url in candidates.prefix(2) {
      if let data = await download(url, limit: 512_000),
        let icon = await Self.thumbnail(data, maxPixel: maxPixel)
      {
        return icon
      }
    }
    return nil
  }

  /// 一个网站的图标（翻译服务的官网图标，第 13 批）：同一套下载与取图——首页 <head> 里 apple-touch-icon 优先、
  /// 再 icon 里声明最大的，都没有用 /favicon.ico；限大小、超时、公网检查、临时会话都照上面。取不到返回 nil，不报错。
  /// 不看「链接预览」开关：只访问用户自己配置的服务所在的官网
  func siteIcon(_ site: URL, maxPixel: Int) async -> CGImage? {
    guard Self.isFetchable(site), let page = try? await fetcher.get(site, as: .page) else {
      return nil
    }
    let base = page.response.url ?? site
    var icons: [URL] = []
    if (200..<300).contains(page.response.statusCode),
      page.response.mimeType?.lowercased().hasPrefix("image/") == false
    {
      icons =
        Self.parse(
          html: Self.decode(page.data, charset: page.response.textEncodingName), base: base
        )
        .icons
    }
    if icons.isEmpty, let icon = URL(string: "/favicon.ico", relativeTo: base) {
      icons = [icon.absoluteURL]
    }
    return await fetchIcon(icons, maxPixel: maxPixel)
  }

  /// 缩略图（白名单第 1 类）：不解码整张原图
  @concurrent nonisolated private static func thumbnail(_ data: Data, maxPixel: Int) async
    -> CGImage?
  {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

/// 按块收的下载：URLSessionDataDelegate，回调投递到主队列（里面 MainActor.assumeIsolated）。看过响应头再决定收不收
/// （类型、长度不对立刻取消），网页收到 </head> 或上限就停、图片超过上限就放弃；跳转按同样的规则拦。
/// 不用 `for try await byte in AsyncBytes`：在主线程上逐字节 await 每个字节都要来回跳一次，512 KB 要近 3 s（审查实测）
@MainActor private final class Fetcher: NSObject, URLSessionDataDelegate {
  enum Kind {
    /// 网页（链接本身是图片时按 4 MB 收）
    case page
    case image(limit: Int)
  }

  struct Result {
    let data: Data
    let response: HTTPURLResponse
  }

  private struct Pending {
    let kind: Kind
    let continuation: CheckedContinuation<Result, any Error>
    var data = Data()
    var response: HTTPURLResponse?
    var limit = 0
    var stopsAtHeadEnd = false
    /// 自己停下的（收够了、类型不对）：完成回调里的「已取消」不算错
    var stopped = false
    var failed = false
  }

  private var pending: [Int: Pending] = [:]
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 10
    // 会话强引用代理：它和这个单例一起活到退出
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }()

  func get(_ url: URL, as kind: Kind) async throws -> Result {
    var request = URLRequest(url: url)
    request.setValue("text/html,application/xhtml+xml,image/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    return try await withCheckedThrowingContinuation { continuation in
      let task = session.dataTask(with: request)
      pending[task.taskIdentifier] = Pending(kind: kind, continuation: continuation)
      task.resume()
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    MainActor.assumeIsolated {
      completionHandler(accept(response, task: dataTask.taskIdentifier) ? .allow : .cancel)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
  ) {
    MainActor.assumeIsolated {
      guard var job = pending[dataTask.taskIdentifier], !job.stopped else { return }
      job.data.append(data)
      if job.data.count > job.limit {
        // 网页收够了就停（截到上限）；图片超过上限整张不要
        job.stopped = true
        if job.stopsAtHeadEnd { job.data = job.data.prefix(job.limit) } else { job.failed = true }
      } else if job.stopsAtHeadEnd,
        job.data.range(
          of: Data("</head".utf8), in: max(0, job.data.count - data.count - 8)..<job.data.count)
          != nil
      {
        job.stopped = true
      }
      pending[dataTask.taskIdentifier] = job
      if job.stopped { dataTask.cancel() }
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    MainActor.assumeIsolated {
      guard let job = pending.removeValue(forKey: task.taskIdentifier) else { return }
      if let response = job.response, !job.failed, error == nil || job.stopped {
        job.continuation.resume(returning: Result(data: job.data, response: response))
      } else {
        job.continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData))
      }
    }
  }

  /// 跳转：网页按 isFetchable（也拦令牌样子的），头图 / 图标只拦内网和账号密码
  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    MainActor.assumeIsolated {
      let isPage = pending[task.taskIdentifier].map {
        if case .page = $0.kind { true } else { false }
      }
      let allowed =
        request.url.map {
          isPage == true ? LinkPreview.isFetchable($0) : LinkPreview.isPublicHTTP($0)
        }
        ?? false
      completionHandler(allowed ? request : nil)
    }
  }

  /// 看响应头：非 2xx 收下（空的，算「有响应、没东西」不重取）；网页只收 HTML（链接本身是图片也收），图片只收图片；
  /// 声明的长度超过上限不收
  private func accept(_ response: URLResponse, task: Int) -> Bool {
    guard var job = pending[task], let http = response as? HTTPURLResponse else { return false }
    job.response = http
    defer { pending[task] = job }
    let mime = http.mimeType?.lowercased() ?? ""
    let isImage =
      mime.hasPrefix("image/") || http.url?.pathExtension.lowercased() == "ico"
    switch job.kind {
    case .page where mime == "text/html" || mime == "application/xhtml+xml":
      job.limit = 512_000
      job.stopsAtHeadEnd = true
    case .page where isImage:
      job.limit = 4_000_000
    case .image(let limit) where isImage:
      job.limit = limit
    default:
      job.stopped = true
      if case .image = job.kind { job.failed = true }
      return false
    }
    guard (200..<300).contains(http.statusCode), http.expectedContentLength <= job.limit else {
      job.stopped = true
      if case .image = job.kind { job.failed = true }
      return false
    }
    return true
  }
}

// MARK: 纯函数（配单测）

extension LinkPreview {
  /// 能不能联网取这条链接的预览：isPublicHTTP，而且不像一次性令牌：查询参数名或路径里有 token / verify / unsubscribe
  /// 之类，或路径里有 32 位以上字母数字混排的随机段（预取会把魔法登录、邮箱验证、退订链接用掉）
  nonisolated static func isFetchable(_ url: URL) -> Bool {
    guard isPublicHTTP(url) else { return false }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let names = (components?.queryItems ?? []).map { $0.name.lowercased() }
    if names.contains(where: { name in tokenWords.contains { name.contains($0) } }) { return false }
    let path = url.path(percentEncoded: false).lowercased()
    if pathWords.contains(where: path.contains) { return false }
    return !path.matches(of: /[a-z0-9]{32,}/).contains { run in
      run.output.contains(where: \.isLetter) && run.output.contains(where: \.isNumber)
    }
  }

  /// 公网的 http(s)：本机、内网（单段主机名、.local 等后缀、私有 / 链路本地 IPv4、所有 IPv6 字面量）、带账号密码的都不算。
  /// 头图、图标这类子资源只查这个（CDN 文件名常是长哈希、签名参数，取它们用不掉谁的令牌）。
  /// ponytail: 不防「公网域名解析到内网」，要防得自己解析 DNS 再连 IP
  nonisolated static func isPublicHTTP(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.user == nil, url.password == nil,
      let host = url.host(percentEncoded: false)?.lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: ".")),
      !host.isEmpty, !host.contains(":")
    else { return false }
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count >= 2,
      !privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    else { return false }
    // 全是数字（含 0x 十六进制）的主机名是 IP 字面量：只放行规范写法的公网 IPv4
    if labels.allSatisfy({ $0.wholeMatch(of: /[0-9]+|0x[0-9a-f]+/) != nil }) {
      let octets = labels.compactMap { UInt8($0) }
      guard labels.count == 4, octets.count == 4,
        labels.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") })
      else { return false }
      switch (octets[0], octets[1]) {
      case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31), (100, 64...127),
        (224...255, _):
        return false
      default: break
      }
    }
    return true
  }

  private nonisolated static let privateSuffixes = [
    "localhost", "local", "localdomain", "internal", "intranet", "lan", "home", "corp",
    "home.arpa", "test", "invalid",
  ]
  /// 查询参数名里出现就不取
  private nonisolated static let tokenWords = [
    "token", "code", "key", "secret", "sig", "auth", "pass", "pwd", "session", "sid", "otp",
    "ticket", "nonce", "credential", "jwt", "magic", "invite", "reset", "verif", "confirm",
  ]
  /// 路径里出现就不取
  private nonisolated static let pathWords = [
    "token", "verif", "confirm", "unsubscribe", "magic", "reset", "activate", "approve", "invite",
    "login", "signin", "sign-in", "oauth", "callback", "auth",
  ]

  /// 整段是链接的文本 → 小写主机名（没写协议的按 https 补上）
  nonisolated static func host(ofLink text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
    return url?.host(percentEncoded: false)?.lowercased()
  }

  /// 从网页头部读标题、网站名、头图和图标（相对地址按 base 补全；SVG 图标跳过，ImageIO 解不了；
  /// 图标 apple-touch-icon 优先，同一种里 sizes 声明得大的在前）
  nonisolated static func parse(html: String, base: URL) -> LinkMetadata {
    let head =
      html.range(of: "</head", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) }
      ?? html
    var meta: [String: String] = [:]
    for tag in head.matches(of: /<meta\b[^>]*>/.ignoresCase()) {
      let attributes = attributes(of: String(tag.output))
      guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
        let content = attributes["content"], meta[key] == nil
      else { continue }
      meta[key] = cleaned(content)
    }
    var result = LinkMetadata()
    let title =
      meta["og:title"] ?? meta["twitter:title"]
      ?? head.firstMatch(of: /<title\b[^>]*>([\s\S]*?)<\/title>/.ignoresCase()).map {
        cleaned(String($0.output.1))
      }
    result.title = title.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
    result.siteName = meta["og:site_name"].flatMap { $0.isEmpty ? nil : $0 }
    result.image =
      [
        "og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src",
      ].lazy.compactMap { meta[$0].flatMap { resolve($0, base) } }.first
    var icons: [(priority: Int, size: Int, url: URL)] = []
    for tag in head.matches(of: /<link\b[^>]*>/.ignoresCase()) {
      let attributes = attributes(of: String(tag.output))
      guard let rel = attributes["rel"]?.lowercased().split(separator: " "),
        let href = attributes["href"], !href.lowercased().hasSuffix(".svg"),
        attributes["type"]?.lowercased() != "image/svg+xml",
        let url = resolve(cleaned(href), base)
      else { continue }
      // 声明的边长（sizes="180x180"，几个尺寸取最大；没写算 0，排在声明了的后面）
      let size =
        attributes["sizes"].map {
          $0.matches(of: /(\d+)[xX]\d+/).compactMap { Int($0.output.1) }.max() ?? 0
        } ?? 0
      if rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") {
        icons.append((0, size, url))
      } else if rel.contains("icon") {
        icons.append((1, size, url))
      }
    }
    // apple-touch-icon 在前，同一种里声明得大的在前，其余按网页里的顺序
    result.icons = icons.enumerated().sorted {
      ($0.element.priority, -$0.element.size, $0.offset)
        < ($1.element.priority, -$1.element.size, $1.offset)
    }
    .map(\.element.url)
    return result
  }

  /// 按响应头的字符集解码，没有就看 <meta charset>，都没有按 UTF-8。只解 </head 之前的部分（「<」不会是 GBK / Big5 /
  /// Shift_JIS 双字节的后半个，从这里切不会切坏字）；收到上限被截断的，末尾可能有半个字，去掉 1–3 个字节再试。
  /// gb2312 / gbk 按 GB18030 解（和浏览器一样：标 gb2312 的网页常混着 GBK 才有的字）
  nonisolated static func decode(_ data: Data, charset: String?) -> String {
    let head = data.range(of: Data("</head".utf8)).map { data[..<$0.lowerBound] } ?? data[...]
    let declared =
      charset
      ?? String(decoding: head.prefix(2048), as: UTF8.self)
      .firstMatch(of: /charset=["']?([A-Za-z0-9_-]+)/.ignoresCase()).map { String($0.output.1) }
    if let declared {
      let label = declared.lowercased()
      let encoding =
        ["gb2312", "gbk", "x-gbk", "gb_2312-80", "cp936"].contains(label)
        ? CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        : CFStringConvertIANACharSetNameToEncoding(label as CFString)
      if encoding != kCFStringEncodingInvalidId {
        let nsEncoding = String.Encoding(
          rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        for trim in 0...3 where head.count > trim {
          if let text = String(data: Data(head.dropLast(trim)), encoding: nsEncoding) {
            return text
          }
        }
      }
    }
    return String(decoding: head, as: UTF8.self)
  }

  private nonisolated static func resolve(_ string: String, _ base: URL) -> URL? {
    guard let url = URL(string: string, relativeTo: base)?.absoluteURL,
      ["http", "https"].contains(url.scheme?.lowercased())
    else { return nil }
    return url
  }

  /// 标签属性：名字转小写，同名取第一个
  private nonisolated static func attributes(of tag: String) -> [String: String] {
    var result: [String: String] = [:]
    for match in tag.matches(
      of: /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/)
    {
      let name = match.output.1.lowercased()
      if result[name] == nil {
        result[name] = String(match.output.2 ?? match.output.3 ?? match.output.4 ?? "")
      }
    }
    return result
  }

  /// 解 HTML 实体、合并空白
  private nonisolated static func cleaned(_ text: String) -> String {
    let named = [
      "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—",
      "ndash": "–", "hellip": "…", "middot": "·", "laquo": "«", "raquo": "»", "lsquo": "‘",
      "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "times": "×",
      "bull": "•",
    ]
    return text.replacing(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/) { match in
      let body = match.output.1
      if body.hasPrefix("#") {
        let digits = body.dropFirst()
        let value =
          digits.first == "x" || digits.first == "X"
          ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
          ?? String(match.output.0)
      }
      return named[String(body).lowercased()] ?? String(match.output.0)
    }
    .replacing(/\s+/, with: " ")
    .trimmingCharacters(in: .whitespaces)
  }
}
