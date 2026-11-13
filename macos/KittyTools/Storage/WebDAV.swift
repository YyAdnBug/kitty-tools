// WebDAV 客户端（issue #18，2026-11-13：同步除了本机文件夹，也能直接连 WebDAV 服务器；用户定直接做进 设置 › 通用「同步」）。
// 只做同步要的几样：PROPFIND 列一层（Depth 1：有的服务只认 1）、GET、PUT（可选「已经有了就不写」）、DELETE、MKCOL、
// MOVE（不覆盖）。怎么用在 NoteSyncServer。
// - 认证：每个请求先带上 Basic（等 401 再补的话，按次数限流的服务器上请求数翻一倍）；服务器要 Digest 时 URLSession 的
//   认证回调补同一组用户名密码，错了不重试。密码只在内存里（存在钥匙串，NoteSyncer 取），不进日志。
// - 不缓存、Cookie 不落盘（ephemeral）；单个请求 30 秒超时；一次一个请求（调用方串着发）。
// - 出错分几种（Failure）：连不上、用户名密码不对、没权限、不在、已经有了（412）、请求太多（429 / 503，带 Retry-After 的
//   按它）、空间满了、别的 HTTP 状态、回的东西解不出来。界面上的话在 Failure.message。
// - multistatus 用 XMLParser 解（开命名空间：各家前缀不一样），只认状态 200 那组 propstat 里的属性；href 有的是整个网址、
//   有的是绝对路径，解码后按路径认出「自己」那一项，名字取最后一段。
// 全是 nonisolated：跑在调用方（NoteSyncServer 的 @concurrent）那里，不碰主线程（mac-native §3）。

import Foundation

nonisolated struct WebDAV: Sendable {
  /// 服务器上用来同步的那个文件夹（网址以 / 结尾）和登录的账号
  struct Account: Equatable, Sendable {
    var folder: URL
    var user: String
    var password: String
  }

  /// 列出来的一项
  struct Item: Equatable, Sendable {
    var name: String
    var isFolder: Bool
    var etag: String?
    var modified: Date?
    var size: Int
  }

  enum Failure: Error, Equatable, Sendable {
    /// 连不上（没联网、找不到服务器、超时、证书不受信任）：系统给的原因
    case offline(String)
    case unauthorized
    case forbidden
    case notFound
    /// 412：要写的地方已经有了
    case exists
    /// 429 / 503：请求太多（坚果云叫 BlockedTemporarily），过一会儿再来；服务器说了等多久就是它
    case busy(retryAfter: TimeInterval?)
    case full
    case status(Int)
    case invalid

    /// 设置页、状态行上的一句话
    var message: String {
      switch self {
      case .offline(let reason): "连不上服务器：\(reason.trimmingCharacters(in: ["。", "."]))"
      case .unauthorized: "用户名或密码不对（有的服务要在网页上另外生成给第三方应用用的密码）"
      case .forbidden: "服务器不让读写这个文件夹"
      case .notFound: "服务器上没有这个文件夹"
      case .exists: "服务器上已经有同名的了"
      case .busy: "服务器说请求太多，过一会儿再试"
      case .full: "服务器上的空间满了"
      case .status(let code): "服务器出错（HTTP \(code)）"
      case .invalid: "服务器回的东西看不懂，可能不是 WebDAV 地址"
      }
    }
  }

  let account: Account
  var session = Self.session

  /// 同步用的那个会话（测试换成带假服务器的）
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: configuration)
  }()

  /// 设置里填的地址 + 文件夹 → 同步用的那个文件夹的网址（以 / 结尾）。地址不是 http(s)、没有主机时是 nil；地址里带的
  /// 用户名密码、查询串扔掉（密码另填、存钥匙串）
  static func folder(address: String, path: String) -> URL? {
    guard let typed = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      var components = URLComponents(url: typed, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      components.host?.isEmpty == false
    else { return nil }
    components.scheme = scheme
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    guard var url = components.url else { return nil }
    if !url.absoluteString.hasSuffix("/") {
      guard let slashed = URL(string: url.absoluteString + "/") else { return nil }
      url = slashed
    }
    for part in path.split(separator: "/") {
      let name = part.trimmingCharacters(in: .whitespaces)
      if !name.isEmpty { url = url.appending(path: name, directoryHint: .isDirectory) }
    }
    return url
  }

  /// 文件夹里一个东西的网址：path 是一段一段的名字（文件夹最后带 /）
  func url(_ path: [String], folder: Bool = false) -> URL {
    var url = account.folder
    for (index, name) in path.enumerated() {
      let last = index == path.count - 1
      url = url.appending(path: name, directoryHint: last && !folder ? .notDirectory : .isDirectory)
    }
    return url
  }

  // MARK: 请求

  /// 列一层：不在是 nil（文件夹本身不算在里面）
  func list(_ path: [String]) async throws(Failure) -> [Item]? {
    let target = url(path, folder: true)
    let (data, response) = try await send(
      "PROPFIND", target, body: Self.propfind,
      headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"])
    if response.statusCode == 404 || response.statusCode == 410 { return nil }
    guard response.statusCode == 207 else { throw Self.failure(response) }
    guard let items = Self.parseListing(data, of: target) else { throw .invalid }
    return items
  }

  /// 读一个文件：不在是 nil
  func get(_ path: [String]) async throws(Failure) -> Data? {
    let (data, response) = try await send("GET", url(path))
    if response.statusCode == 404 || response.statusCode == 410 { return nil }
    guard (200..<300).contains(response.statusCode) else { throw Self.failure(response) }
    return data
  }

  /// 写一个文件（data 或本机的一个文件）；ifAbsent：已经有了就不写（.exists）。返回服务器给的 ETag（没给是 nil）
  @discardableResult
  func put(_ data: Data? = nil, file: URL? = nil, to path: [String], ifAbsent: Bool = false)
    async throws(Failure) -> String?
  {
    var headers = ["Content-Type": "application/octet-stream"]
    if ifAbsent { headers["If-None-Match"] = "*" }
    let (_, response) = try await send(
      "PUT", url(path), body: data ?? (file == nil ? Data() : nil), file: file, headers: headers)
    if response.statusCode == 412 { throw .exists }
    guard (200..<300).contains(response.statusCode) else { throw Self.failure(response) }
    return response.value(forHTTPHeaderField: "ETag")
  }

  /// 删一个文件（本来就不在也算删了）
  func delete(_ path: [String]) async throws(Failure) {
    let (_, response) = try await send("DELETE", url(path))
    guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
      throw Self.failure(response)
    }
  }

  /// 建一个文件夹（已经有了也算建好：405）
  func makeFolder(_ path: [String]) async throws(Failure) {
    let (_, response) = try await send("MKCOL", url(path, folder: true))
    guard (200..<300).contains(response.statusCode) || response.statusCode == 405 else {
      throw Self.failure(response)
    }
  }

  /// 建好同步的那个文件夹，连同没有的上级（409 = 上级没有：往上找到有的那一级，再一级一级往下建）
  func makeFolders() async throws(Failure) {
    var missing: [URL] = []
    var target = account.folder
    while true {
      let (_, response) = try await send("MKCOL", target)
      if (200..<300).contains(response.statusCode) || response.statusCode == 405 { break }
      guard response.statusCode == 409, target.pathComponents.count > 2 else {
        throw Self.failure(response)
      }
      missing.append(target)
      target = target.deletingLastPathComponent()
    }
    for folder in missing.reversed() {
      let (_, response) = try await send("MKCOL", folder)
      guard (200..<300).contains(response.statusCode) || response.statusCode == 405 else {
        throw Self.failure(response)
      }
    }
  }

  /// 改名 / 挪到别处，不覆盖（目标已经有了：.exists）
  func move(_ from: [String], to: [String]) async throws(Failure) {
    let (_, response) = try await send(
      "MOVE", url(from), headers: ["Destination": url(to).absoluteString, "Overwrite": "F"])
    if response.statusCode == 412 { throw .exists }
    guard (200..<300).contains(response.statusCode) else { throw Self.failure(response) }
  }

  private func send(
    _ method: String, _ url: URL, body: Data? = nil, file: URL? = nil,
    headers: [String: String] = [:]
  ) async throws(Failure) -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    let credential = Data("\(account.user):\(account.password)".utf8).base64EncodedString()
    request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let delegate = Challenge(user: account.user, password: account.password)
    let result: (Data, URLResponse)
    do {
      if let file {
        result = try await session.upload(for: request, fromFile: file, delegate: delegate)
      } else if let body {
        result = try await session.upload(for: request, from: body, delegate: delegate)
      } else {
        result = try await session.data(for: request, delegate: delegate)
      }
    } catch {
      throw Self.failure(error)
    }
    guard let response = result.1 as? HTTPURLResponse else { throw .invalid }
    if response.statusCode == 401 { throw .unauthorized }
    return (result.0, response)
  }

  // MARK: 出错

  static func failure(_ response: HTTPURLResponse) -> Failure {
    switch response.statusCode {
    case 401: .unauthorized
    case 403: .forbidden
    case 404, 410: .notFound
    case 412: .exists
    case 429, 503:
      .busy(
        retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    case 507: .full
    default: .status(response.statusCode)
    }
  }

  static func failure(_ error: Error) -> Failure {
    if let failure = error as? Failure { return failure }
    if let error = error as? URLError {
      switch error.code {
      case .notConnectedToInternet, .networkConnectionLost: return .offline("没联网")
      case .cannotFindHost, .dnsLookupFailed: return .offline("找不到这个服务器")
      case .cannotConnectToHost: return .offline("服务器没开或者端口不对")
      case .timedOut: return .offline("服务器很久没回应")
      case .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
        .secureConnectionFailed:
        return .offline("服务器的证书不受信任（不支持自签的证书）")
      case .userCancelledAuthentication, .userAuthenticationRequired: return .unauthorized
      default: break
      }
    }
    return .offline(error.localizedDescription)
  }

  // MARK: multistatus

  static let propfind = Data(
    """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/>\
    <d:getcontentlength/></d:prop></d:propfind>
    """.utf8)

  /// 解出来的一项（还没认哪个是文件夹自己）
  struct Raw: Equatable, Sendable {
    var href: String
    var isFolder = false
    var etag: String?
    var modified: Date?
    var size = 0
  }

  /// PROPFIND Depth 1 回的 multistatus → 文件夹里的东西（不含自己）；解不出来是 nil
  static func parseListing(_ data: Data, of folder: URL) -> [Item]? {
    Multistatus.parse(data).map { children($0, of: folder) }
  }

  /// 去掉文件夹自己、取名字：href 解码后和请求的路径一样的是自己；对不上（前面隔着改路径的反向代理）时，第一项是同名的文件夹也算
  static func children(_ raw: [Raw], of folder: URL) -> [Item] {
    func path(_ href: String) -> String {
      let decoded =
        href.hasPrefix("http://") || href.hasPrefix("https://")
        ? URL(string: href)?.path(percentEncoded: false) ?? href
        : href.removingPercentEncoding ?? href
      return String(decoded.reversed().drop { $0 == "/" }.reversed())
        .precomposedStringWithCanonicalMapping
    }
    let own = path(folder.path(percentEncoded: true))
    let ownName = own.split(separator: "/").last.map(String.init)
    var items: [Item] = []
    for (index, entry) in raw.enumerated() {
      let entryPath = path(entry.href)
      guard let name = entryPath.split(separator: "/").last.map(String.init), !name.isEmpty
      else { continue }
      if entryPath == own || (index == 0 && entry.isFolder && name == ownName) { continue }
      items.append(
        Item(
          name: name, isFolder: entry.isFolder, etag: entry.etag, modified: entry.modified,
          size: entry.size))
    }
    return items
  }

  /// HTTP 的日期（RFC 1123：Wed, 13 Nov 2026 03:30:46 GMT）。ponytail: 只认这一种写法（RFC 要求服务器发这一种），
  /// 认不出来当没有（镜像里的文件用写下来的时刻）；macOS 26 起有 Date.HTTPFormatStyle，最低版本升到 26 再换
  static func date(_ text: String) -> Date? {
    try? Date(text.trimmingCharacters(in: .whitespaces), strategy: httpDate)
  }

  private static let httpDate = Date.ParseStrategy(
    format:
      "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
    locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)
}

/// 服务器要先问再答的认证（Digest；Basic 已经先带上了）时补上用户名密码，答错了不再试（→ 用户名或密码不对）。
/// 证书这类别的认证照系统的来
private nonisolated final class Challenge: NSObject, URLSessionTaskDelegate, Sendable {
  let user: String
  let password: String

  init(user: String, password: String) {
    self.user = user
    self.password = password
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    let method = challenge.protectionSpace.authenticationMethod
    guard
      method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest
    else { return (.performDefaultHandling, nil) }
    guard challenge.previousFailureCount == 0 else { return (.cancelAuthenticationChallenge, nil) }
    return (.useCredential, URLCredential(user: user, password: password, persistence: .none))
  }
}

/// multistatus 的解析：每个 response 一项；只认状态是 200 的那组 propstat 里的属性
private nonisolated final class Multistatus: NSObject, XMLParserDelegate {
  private var items: [WebDAV.Raw] = []
  private var current: WebDAV.Raw?
  /// 这一组 propstat 里读到的（到 </propstat> 看状态再并进 current）
  private var pending = WebDAV.Raw(href: "")
  private var status = ""
  private var text = ""

  static func parse(_ data: Data) -> [WebDAV.Raw]? {
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    let delegate = Multistatus()
    parser.delegate = delegate
    guard parser.parse() else { return nil }
    return delegate.items
  }

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName _: String?, attributes _: [String: String] = [:]
  ) {
    text = ""
    guard namespaceURI == "DAV:" else { return }
    switch name {
    case "response": current = WebDAV.Raw(href: "")
    case "propstat":
      pending = WebDAV.Raw(href: "")
      status = ""
    case "collection": pending.isFolder = true
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName _: String?
  ) {
    guard namespaceURI == "DAV:" else { return }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch name {
    case "href": current?.href = value
    case "status": status = value
    case "getetag": pending.etag = value.isEmpty ? nil : value
    case "getlastmodified": pending.modified = WebDAV.date(value)
    case "getcontentlength": pending.size = Int(value) ?? 0
    case "propstat":
      // 「HTTP/1.1 200 OK」；没写状态的当成 200
      guard status.isEmpty || status.split(separator: " ").dropFirst().first == "200" else { break }
      if pending.isFolder { current?.isFolder = true }
      if let etag = pending.etag { current?.etag = etag }
      if let modified = pending.modified { current?.modified = modified }
      if pending.size > 0 { current?.size = pending.size }
    case "response":
      if let current, !current.href.isEmpty { items.append(current) }
      current = nil
    default: break
    }
    text = ""
  }
}
