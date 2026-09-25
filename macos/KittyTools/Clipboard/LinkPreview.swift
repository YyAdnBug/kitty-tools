// 链接富预览（Whisker §6 剪贴板）：检查器的链接卡取网页标题、头图和网站图标，列表行的链接角标换成网站图标。
// 不用 LinkPresentation：实测它每次拉起 WebKit 的 GPU / 网络进程（GPU 进程取完还常驻约 13 MB），取 GitHub 要 3–3.5 s。
// 这里用临时会话（不带 Cookie、不落盘）只读网页 <head>（最多 512 KB）里的 og: / twitter: 标签和 <title>，再取头图
// （≤ 4 MB）和图标（≤ 512 KB）缩成缩略图（@concurrent）。网页请求 3 s 没动静就放弃；选中停留 0.25 s 才开始取，换条目就取消。
// 不取：非 http(s)、本机 / 内网 / 私有地址、带账号密码、像一次性令牌的网址（预取会把魔法登录、邮箱验证、退订链接用掉），
// 跳转到这些地址也拦下。结果按网址缓存在内存（最多 16 条）；网络错误不记，下次选中再试。

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
    var icon: NSImage?
    /// 图标的主色（没有头图时占位渐变用）
    var tint: NSColor?
    /// 还在取（头图区显示扫光）
    var isLoading = true
  }

  static let shared = LinkPreview()

  private(set) var entries: [URL: Entry] = [:]
  /// 按主机名记的网站图标：列表行的链接角标用
  private(set) var favicons: [String: NSImage] = [:]
  @ObservationIgnored private var order: [URL] = []

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 10
    return URLSession(configuration: configuration)
  }()

  func entry(for url: URL) -> Entry? { entries[url] }

  /// 列表行：整段是链接的文本对应的网站图标（取过预览才有）
  func favicon(forLink text: String) -> NSImage? {
    Self.host(ofLink: text).flatMap { favicons[$0] }
  }

  /// 取一条链接的预览（已在取或取过就直接返回）。调用方先判断设置开关和 isFetchable
  func load(_ url: URL) async {
    guard entries[url] == nil, Self.isFetchable(url) else { return }
    store(Entry(), for: url)
    guard var entry = await fetchPage(url) else { return forget(url) }  // 网络错误、被取消：下次选中再试
    store(entry, for: url)  // 标题先出来，图片接着取
    let (imageURL, iconURLs) = (entry.metadata.image, entry.metadata.icons)
    async let image = fetchImage(imageURL, limit: 4_000_000, maxPixel: 720)
    async let icon = fetchIcon(iconURLs)
    let (loadedImage, loadedIcon) = await (image, icon)
    // 取图时换了条目（任务被取消，图片多半没取完）：整条不记，下次选中重取
    if Task.isCancelled { return forget(url) }
    entry.image = loadedImage.map { NSImage(cgImage: $0, size: .zero) }
    entry.icon = loadedIcon.map { NSImage(cgImage: $0, size: .zero) }
    entry.tint = entry.icon.flatMap(AppIcons.average)
    entry.isLoading = false
    store(entry, for: url)
  }

  private func forget(_ url: URL) {
    entries[url] = nil
    order.removeAll { $0 == url }
  }

  /// 最多留 16 条（头图缩略图约 1 MB 一张），多了丢最早的；有图标就按主机名记下给列表行用（截图自检也用它摆状态）
  func store(_ entry: Entry, for url: URL) {
    if entries[url] == nil {
      order.append(url)
      if order.count > 16 { entries[order.removeFirst()] = nil }
    }
    entries[url] = entry
    if let icon = entry.icon, let host = Self.host(ofLink: url.absoluteString) {
      if favicons.count >= 64 { favicons.removeAll() }
      favicons[host] = icon
    }
  }

  // MARK: 取

  /// 读网页 <head>。收到了响应（哪怕不是网页、没有标签）就返回一条（不再重取）；网络错误返回 nil。
  /// 链接本身是图片时直接当头图
  private func fetchPage(_ url: URL) async -> Entry? {
    do {
      let (bytes, response) = try await Self.session.bytes(
        for: Self.request(Self.upgraded(url)), delegate: RedirectGuard())
      defer { bytes.task.cancel() }
      var entry = Entry()
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return entry
      }
      let base = http.url ?? url
      let mime = http.mimeType?.lowercased() ?? ""
      if mime.hasPrefix("image/") {
        entry.metadata.image = base
      } else if mime == "text/html" || mime == "application/xhtml+xml" {
        let data = try await Self.read(bytes, limit: 512_000, stopAtHeadEnd: true)
        entry.metadata = Self.parse(
          html: Self.decode(data, charset: http.textEncodingName), base: base)
      }
      if entry.metadata.icons.isEmpty, let icon = URL(string: "/favicon.ico", relativeTo: base) {
        entry.metadata.icons = [icon.absoluteURL]
      }
      return entry
    } catch {
      return nil
    }
  }

  /// 头图 / 图标：只收图片、不超过 limit 字节，缩成长边 maxPixel 的缩略图
  private func fetchImage(_ url: URL?, limit: Int, maxPixel: Int) async -> CGImage? {
    guard let url, Self.isFetchable(url),
      let fetched = try? await Self.session.bytes(
        for: Self.request(Self.upgraded(url)), delegate: RedirectGuard())
    else { return nil }
    let (bytes, response) = fetched
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      http.mimeType?.lowercased().hasPrefix("image/") == true || url.pathExtension == "ico",
      http.expectedContentLength <= limit,
      let data = try? await Self.read(bytes, limit: limit + 1, stopAtHeadEnd: false),
      data.count <= limit
    else { return nil }
    return await Self.thumbnail(data, maxPixel: maxPixel)
  }

  /// 图标候选依次试，最多两个
  private func fetchIcon(_ candidates: [URL]) async -> CGImage? {
    for url in candidates.prefix(2) {
      if let icon = await fetchImage(url, limit: 512_000, maxPixel: 96) { return icon }
    }
    return nil
  }

  private static func request(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("text/html,application/xhtml+xml,image/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    return request
  }

  /// http 换成 https：App 默认不许明文 HTTP（ATS），多数网站两个都有
  private static func upgraded(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "http",
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.scheme = "https"
    return components.url ?? url
  }

  /// 读到 limit 字节为止；网页读到 </head> 就停
  private static func read(_ bytes: URLSession.AsyncBytes, limit: Int, stopAtHeadEnd: Bool)
    async throws -> Data
  {
    var data = Data()
    let marker = Data("</head".utf8)
    for try await byte in bytes {
      data.append(byte)
      if data.count >= limit { break }
      if stopAtHeadEnd, data.count % 8192 == 0,
        data.range(of: marker, in: max(0, data.count - 8192 - marker.count)..<data.count) != nil
      {
        break
      }
    }
    return data
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

/// 跳转到不该取的地址（内网、带令牌…）就停在跳转那一步
nonisolated private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    request.url.map(LinkPreview.isFetchable) == true ? request : nil
  }
}

// MARK: 纯函数（配单测）

extension LinkPreview {
  /// 能不能联网取预览：只取公网的 http(s)。本机、内网（单段主机名、.local 等后缀、私有 / 链路本地 IPv4、所有 IPv6
  /// 字面量）、带账号密码的不取；像一次性令牌的也不取：查询参数名或路径里有 token / verify / unsubscribe 之类，
  /// 或路径里有 32 位以上字母数字混排的随机段。ponytail: 不防「公网域名解析到内网」，要防得自己解析 DNS 再连 IP
  nonisolated static func isFetchable(_ url: URL) -> Bool {
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
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let names = (components?.queryItems ?? []).map { $0.name.lowercased() }
    if names.contains(where: { name in tokenWords.contains { name.contains($0) } }) { return false }
    let path = url.path(percentEncoded: false).lowercased()
    if pathWords.contains(where: path.contains) { return false }
    return !path.matches(of: /[a-z0-9]{32,}/).contains { run in
      run.output.contains(where: \.isLetter) && run.output.contains(where: \.isNumber)
    }
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

  /// 从网页头部读标题、网站名、头图和图标（相对地址按 base 补全；SVG 图标跳过，ImageIO 解不了）
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
    var icons: [(priority: Int, url: URL)] = []
    for tag in head.matches(of: /<link\b[^>]*>/.ignoresCase()) {
      let attributes = attributes(of: String(tag.output))
      guard let rel = attributes["rel"]?.lowercased().split(separator: " "),
        let href = attributes["href"], !href.lowercased().hasSuffix(".svg"),
        attributes["type"]?.lowercased() != "image/svg+xml",
        let url = resolve(cleaned(href), base)
      else { continue }
      if rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") {
        icons.append((0, url))
      } else if rel.contains("icon") {
        icons.append((1, url))
      }
    }
    result.icons = icons.enumerated().sorted {
      ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset)
    }
    .map(\.element.url)
    return result
  }

  /// 按响应头的字符集解码，没有就看 <meta charset>，都没有按 UTF-8
  nonisolated static func decode(_ data: Data, charset: String?) -> String {
    let declared =
      charset
      ?? String(decoding: data.prefix(2048), as: UTF8.self)
      .firstMatch(of: /charset=["']?([A-Za-z0-9_-]+)/.ignoresCase()).map { String($0.output.1) }
    if let declared {
      let encoding = CFStringConvertIANACharSetNameToEncoding(declared as CFString)
      if encoding != kCFStringEncodingInvalidId,
        let text = String(
          data: data,
          encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
      {
        return text
      }
    }
    return String(decoding: data, as: UTF8.self)
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
    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
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
