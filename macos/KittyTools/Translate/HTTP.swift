// 翻译服务的网络请求：JSON POST、SSE 流式读取、面向用户的中文错误信息。
// 红线：错误信息和日志里不出现请求 URL、请求头和密钥。
// 公网不用 URLSession.shared：共享会话会记住 HTTP/3（Alt-Svc / HTTPS 记录）。部分企业网络扩展
// 会干扰 QUIC 握手（URLError.secureConnectionFailed，底层 errSSLPeerProtocolVersion），且不一定
// 回落到 HTTP/2。握手失败时改走 TLS over TCP 的 HTTP/1.1，证书校验不关。

import Foundation
@preconcurrency import Network
import Synchronization

nonisolated struct TranslateError: LocalizedError, Sendable, Equatable {
  /// 错误卡按它分（体检 C5，mac-whisker §3 语义色）：配置 / 密钥问题橙色、只给「打开设置」（直达这个服务的详情页）；
  /// 网络 / 服务错误红色、给「重试」（自建 AI 服务另给「打开设置」：地址可能填错）
  enum Kind: Sendable {
    /// 缺密钥、密钥不对、地址或模型没填 / 不存在（401 / 403 / 404、百度 52003 等）：重试没用，要去改设置
    case config
    /// 连不上、超时、断网（URLError）
    case network
    /// 服务端出错、太频繁、额度用完、空结果、截断、中断
    case service
  }

  let message: String
  /// HTTP 状态码（400 / 422 时调用方会降级重试）
  var status: Int?
  var kind = Kind.service

  var errorDescription: String? { message }

  static let emptyResult = TranslateError(message: "服务没有返回译文（输出额度可能被思考过程占满，可换非推理模型）")
  /// 流正常结束但服务说输出到上限了（OpenAI 兼容 / 智谱 finish_reason = length，Anthropic stop_reason = max_tokens）：
  /// 已出来的半截照常显示，但不算完成（不写历史、不自动复制、不给替换原文；体检 B19）
  static let truncated = TranslateError(message: "只翻了前一部分：超出这个服务单次输出上限")
  /// 浮窗收起、换了新会话时没出完的卡片（点重试、或再按输入翻译热键重新打开时自动重跑）
  static let interrupted = TranslateError(message: "已中断，点重试重新翻译")

  /// 配置类错误（缺密钥、地址或模型没填）
  static func config(_ message: String) -> TranslateError {
    TranslateError(message: message, kind: .config)
  }
}

nonisolated enum HTTP {
  /// 本机 / 局域网上的大模型可能很慢，给更长的空闲超时
  static func session(for url: URL) -> URLSession {
    isLocalNetwork(url) ? localSession : remoteSession
  }

  private static let localSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 180
    return URLSession(configuration: configuration)
  }()

  /// 公网翻译用独立会话，避免和系统共享会话里的 HTTP/3 记录缠在一起
  private static let remoteSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    configuration.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: configuration)
  }()

  /// 这一进程里已经确认 URLSession 握手失败、改走 TCP 的主机（不持久化）
  private static let tcpHosts = Mutex(Set<String>())

  static func request(_ url: URL, headers: [String: String], json: [String: Any]) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = isLocalNetwork(url) ? 180 : 30
    request.assumesHTTP3Capable = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try? JSONSerialization.data(withJSONObject: json)
    return request
  }

  /// 一次性请求，返回解析好的 JSON
  static func send(_ request: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await data(for: request)
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    try check(response, object)
    return object
  }

  /// 发给调用方用的一次性请求（模型列表、免费接口、朗读等也走同一套回落）
  static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await perform {
      let request = prepared(request)
      if prefersTCP(request.url) {
        return try await TCPHTTP.data(for: request)
      }
      do {
        return try await session(for: request.url!).data(for: request)
      } catch {
        guard shouldFallbackToTCP(error, url: request.url) else { throw error }
        rememberTCP(request.url)
        return try await TCPHTTP.data(for: request)
      }
    }
  }

  /// SSE：逐行给出 `data:` 之后的内容（遇到 [DONE] 结束）
  static func events(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
    let request = prepared(request)
    if prefersTCP(request.url) {
      return try await eventsOverTCP(request)
    }
    do {
      return try await eventsOverURLSession(request)
    } catch {
      guard shouldFallbackToTCP(error, url: request.url) else { throw userFacing(error) }
      rememberTCP(request.url)
      return try await eventsOverTCP(request)
    }
  }

  /// 2xx 也可能在 JSON 里带 error 字段
  static func check(_ response: URLResponse, _ object: [String: Any]) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let serverMessage = message(in: object)
    guard (200..<300).contains(status), serverMessage == nil else {
      throw TranslateError(
        message: describe(status: status, serverMessage: serverMessage), status: status,
        kind: [401, 403, 404].contains(status) ? .config : .service)
    }
  }

  /// 错误 JSON 里的说明：error.message → 字符串 error → 顶层 message
  static func message(in object: [String: Any]) -> String? {
    if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    if let error = object["error"] as? String, !error.isEmpty { return error }
    if object["error"] != nil, let message = object["message"] as? String { return message }
    return nil
  }

  private static func describe(status: Int, serverMessage: String?) -> String {
    let base =
      switch status {
      case 401, 403: "密钥无效或没有权限"
      case 404: "服务地址或模型不存在"
      case 429: "请求太频繁或额度用完"
      case 500...: "服务暂时不可用（\(status)）"
      default: "请求失败（\(status)）"
      }
    guard let serverMessage, !serverMessage.isEmpty else { return base }
    return "\(base)：\(serverMessage.prefix(160))"
  }

  /// 发请求一律包这一层：连不上、超时、断网报成统一的中文网络错误（`.network`），不让原始 URLError 被包成服务类错误
  static func perform<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch { throw userFacing(error) }
  }

  static func userFacing(_ error: Error) -> Error {
    if error is CancellationError { return error }
    if let translate = error as? TranslateError { return translate }
    guard let urlError = error as? URLError else { return error }
    if urlError.code == .cancelled { return CancellationError() }
    let message =
      switch urlError.code {
      case .timedOut: "请求超时，请检查网络或服务地址"
      case .notConnectedToInternet, .networkConnectionLost: "网络不可用"
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "连不上服务地址"
      case .serverCertificateUntrusted, .clientCertificateRejected, .clientCertificateRequired:
        "HTTPS 连接失败（证书问题）"
      case .secureConnectionFailed: "HTTPS 连接失败"
      default: "网络错误（\(urlError.code.rawValue)）"
      }
    return TranslateError(message: message, kind: .network)
  }

  /// 本机或局域网地址：回环、私网 / 链路本地 IP、localhost、*.local、不带点的主机名
  static func isLocalNetwork(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":")
    {
      return true
    }
    if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
      return host.contains(":")
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    switch (parts[0], parts[1]) {
    case (127, _), (10, _), (192, 168), (169, 254): return true
    case (172, 16...31): return true
    default: return false
    }
  }

  /// 企业网络干扰 QUIC 时，URLSession 常给出这类错误；证书不受信任不走这条回落来「跳过校验」
  static func isHandshakeFailure(_ error: Error) -> Bool {
    let candidate: Error = (error as? URLError) ?? (error as? TranslateError) ?? error
    if let urlError = candidate as? URLError {
      if urlError.code == .secureConnectionFailed { return true }
      let underlying = (urlError as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
      if underlying?.code == -9836 { return true }  // errSSLPeerProtocolVersion
    }
    if let translate = candidate as? TranslateError, translate.kind == .network,
      translate.message == "HTTPS 连接失败"
    {
      return true
    }
    return false
  }

  private static func prepared(_ request: URLRequest) -> URLRequest {
    var request = request
    request.assumesHTTP3Capable = false
    return request
  }

  private static func prefersTCP(_ url: URL?) -> Bool {
    guard let url, let host = url.host()?.lowercased(), !isLocalNetwork(url) else { return false }
    return tcpHosts.withLock { $0.contains(host) }
  }

  private static func rememberTCP(_ url: URL?) {
    guard let host = url?.host()?.lowercased() else { return }
    tcpHosts.withLock { $0.insert(host) }
  }

  static func shouldFallbackToTCP(_ error: Error, url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", !isLocalNetwork(url) else { return false }
    return isHandshakeFailure(error)
  }

  private static func eventsOverURLSession(_ request: URLRequest) async throws
    -> AsyncThrowingStream<String, Error>
  {
    let (bytes, response) = try await session(for: request.url!).bytes(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      var body = Data()
      for try await byte in bytes.prefix(64 * 1024) { body.append(byte) }
      try check(response, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }
    return sseStream(bytes.lines)
  }

  private static func eventsOverTCP(_ request: URLRequest) async throws
    -> AsyncThrowingStream<String, Error>
  {
    let (bytes, response) = try await TCPHTTP.bytes(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      var body = Data()
      for try await byte in bytes.prefix(64 * 1024) { body.append(byte) }
      try check(response, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }
    return sseStream(bytes.lines)
  }

  private static func sseStream<Lines: AsyncSequence>(
    _ lines: sending Lines
  ) -> AsyncThrowingStream<String, Error> where Lines.Element == String {
    let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
    let task = Task {
      do {
        for try await line in lines {
          guard line.hasPrefix("data:") else { continue }
          let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
          if payload == "[DONE]" { break }
          continuation.yield(payload)
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: userFacing(error))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }
}

/// TLS over TCP 的 HTTP/1.1 客户端（证书用系统默认校验）。
private nonisolated enum TCPHTTP {
  private static let maxHeaderBytes = 64 * 1024
  private static let maxBodyBytes = 8 * 1024 * 1024

  static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let (bytes, response) = try await exchange(request)
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count > maxBodyBytes {
        throw TranslateError(message: "服务返回的内容过长", kind: .service)
      }
    }
    return (body, response)
  }

  static func bytes(for request: URLRequest) async throws -> (
    AsyncThrowingStream<UInt8, Error>, URLResponse
  ) {
    try await exchange(request)
  }

  private static func exchange(_ request: URLRequest) async throws -> (
    AsyncThrowingStream<UInt8, Error>, URLResponse
  ) {
    let wire = try WireRequest(request)
    let connection = NWConnection(
      host: NWEndpoint.Host(wire.host),
      port: NWEndpoint.Port(rawValue: wire.port) ?? .https,
      using: parameters(tls: wire.tls, timeout: request.timeoutInterval))
    let raw: Data
    do {
      try await connect(connection, timeout: request.timeoutInterval)
      try await send(wire.bytes, on: connection)
      raw = try await read(from: connection, untilHeadersDone: true)
    } catch {
      connection.cancel()
      throw error
    }
    let parsed = try ResponseParser.parse(raw)
    let response = parsed.response(url: request.url!)
    let remainder = parsed.remainder
    let chunked = parsed.chunked
    let contentLength = parsed.contentLength
    let stream = AsyncThrowingStream<UInt8, Error> { continuation in
      let task = Task {
        do {
          if chunked {
            try await streamChunked(remainder, connection: connection, into: continuation)
          } else {
            try await streamBody(
              remainder, contentLength: contentLength, connection: connection, into: continuation)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
        connection.cancel()
      }
      continuation.onTermination = { _ in
        task.cancel()
        connection.cancel()
      }
    }
    return (stream, response)
  }

  private static func parameters(tls: Bool, timeout: TimeInterval) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
    let parameters: NWParameters
    if tls {
      parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
    } else {
      parameters = NWParameters(tls: nil, tcp: tcp)
    }
    return parameters
  }

  private static func connect(_ connection: NWConnection, timeout: TimeInterval) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          let once = Mutex(false)
          connection.stateUpdateHandler = { state in
            let resumeOnce = { (result: Result<Void, Error>) in
              let first = once.withLock { taken in
                if taken { return false }
                taken = true
                return true
              }
              guard first else { return }
              continuation.resume(with: result)
            }
            switch state {
            case .ready: resumeOnce(.success(()))
            case .failed(let error): resumeOnce(.failure(map(error)))
            case .cancelled: resumeOnce(.failure(CancellationError()))
            case .waiting(let error):
              // 证书失败会走 failed；waiting 多为路径未就绪，交给超时
              _ = error
            default: break
            }
          }
          connection.start(queue: .global(qos: .userInitiated))
        }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(max(1, timeout)))
        throw TranslateError(message: "请求超时，请检查网络或服务地址", kind: .network)
      }
      try await group.next()!
      group.cancelAll()
    }
  }

  private static func send(_ data: Data, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: map(error))
          } else {
            continuation.resume()
          }
        })
    }
  }

  private static func read(from connection: NWConnection, untilHeadersDone: Bool) async throws
    -> Data
  {
    var buffer = Data()
    while true {
      let chunk = try await receive(from: connection)
      guard let chunk else { break }
      buffer.append(chunk)
      if untilHeadersDone, let end = headerEnd(in: buffer) {
        _ = end
        return buffer
      }
      if buffer.count > maxHeaderBytes {
        throw TranslateError(message: "服务返回的内容过长", kind: .service)
      }
    }
    if untilHeadersDone, headerEnd(in: buffer) == nil {
      throw TranslateError(message: "服务没有返回完整响应", kind: .service)
    }
    return buffer
  }

  private static func receive(from connection: NWConnection) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: map(error))
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else {
          continuation.resume(returning: isComplete ? nil : Data())
        }
      }
    }
  }

  private static func streamBody(
    _ prefix: Data, contentLength: Int?, connection: NWConnection,
    into continuation: AsyncThrowingStream<UInt8, Error>.Continuation
  ) async throws {
    var sent = 0
    for byte in prefix {
      continuation.yield(byte)
      sent += 1
      if let contentLength, sent >= contentLength { return }
    }
    while true {
      if let contentLength, sent >= contentLength { return }
      guard let chunk = try await receive(from: connection) else { return }
      for byte in chunk {
        continuation.yield(byte)
        sent += 1
        if let contentLength, sent >= contentLength { return }
      }
    }
  }

  private static func streamChunked(
    _ prefix: Data, connection: NWConnection,
    into continuation: AsyncThrowingStream<UInt8, Error>.Continuation
  ) async throws {
    var buffer = prefix
    while true {
      switch try takeChunk(from: &buffer) {
      case .needMore:
        guard let chunk = try await receive(from: connection) else {
          throw TranslateError(message: "服务没有返回完整响应", kind: .service)
        }
        buffer.append(chunk)
        if buffer.count > maxBodyBytes {
          throw TranslateError(message: "服务返回的内容过长", kind: .service)
        }
      case .data(let data):
        for byte in data { continuation.yield(byte) }
      case .finished:
        return
      }
    }
  }

  private enum Chunk {
    case needMore
    case data(Data)
    case finished
  }

  private static func takeChunk(from buffer: inout Data) throws -> Chunk {
    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return .needMore }
    let sizeLine = buffer.subdata(in: buffer.startIndex..<lineEnd.lowerBound)
    let sizeText = String(data: sizeLine, encoding: .utf8)?
      .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .trimmingCharacters(in: .whitespaces)
    guard let sizeText, let size = Int(sizeText, radix: 16), size >= 0 else {
      throw TranslateError(message: "服务返回的内容无法解析", kind: .service)
    }
    let dataStart = lineEnd.upperBound
    let needed = size + 2
    guard buffer.distance(from: dataStart, to: buffer.endIndex) >= needed else { return .needMore }
    if size == 0 { return .finished }
    let dataEnd = buffer.index(dataStart, offsetBy: size)
    let crlfEnd = buffer.index(dataEnd, offsetBy: 2)
    let trailer = buffer.subdata(in: dataEnd..<crlfEnd)
    guard trailer == Data("\r\n".utf8) else {
      throw TranslateError(message: "服务返回的内容无法解析", kind: .service)
    }
    let chunk = buffer.subdata(in: dataStart..<dataEnd)
    buffer.removeSubrange(buffer.startIndex..<crlfEnd)
    return .data(chunk)
  }

  fileprivate static func headerEnd(in data: Data) -> Int? {
    if let range = data.range(of: Data("\r\n\r\n".utf8)) { return range.upperBound }
    return nil
  }

  private static func map(_ error: Error) -> Error {
    if error is CancellationError || error is TranslateError { return error }
    if let urlError = error as? URLError { return HTTP.userFacing(urlError) }
    let text = (error as NSError).localizedDescription.lowercased()
    if text.contains("cancel") { return CancellationError() }
    if text.contains("timed out") || text.contains("timeout") {
      return TranslateError(message: "请求超时，请检查网络或服务地址", kind: .network)
    }
    return TranslateError(message: "HTTPS 连接失败", kind: .network)
  }
}

private nonisolated struct WireRequest {
  let host: String
  let port: UInt16
  let tls: Bool
  let bytes: Data

  init(_ request: URLRequest) throws {
    guard let url = request.url, let host = url.host(), !host.isEmpty else {
      throw TranslateError(message: "连不上服务地址", kind: .network)
    }
    let tls = url.scheme?.lowercased() == "https"
    self.host = host
    self.port = UInt16(url.port ?? (tls ? 443 : 80))
    self.tls = tls
    let method = request.httpMethod ?? "GET"
    var path = url.path.isEmpty ? "/" : url.path
    if let query = url.query, !query.isEmpty { path += "?\(query)" }
    var hostHeader = host.contains(":") ? "[\(host)]" : host
    if url.port != nil { hostHeader += ":\(port)" }
    var lines = ["\(method) \(path) HTTP/1.1", "Host: \(hostHeader)", "Connection: close"]
    let skip: Set<String> = [
      "host", "connection", "content-length", "transfer-encoding", "proxy-connection",
    ]
    if let fields = request.allHTTPHeaderFields {
      for (name, value) in fields where !skip.contains(name.lowercased()) {
        lines.append("\(name): \(value)")
      }
    }
    let body = request.httpBody ?? Data()
    lines.append("Content-Length: \(body.count)")
    var bytes = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    bytes.append(body)
    self.bytes = bytes
  }
}

private nonisolated struct ResponseParser {
  let status: Int
  let headers: [String: String]
  let remainder: Data
  var chunked: Bool { headers["transfer-encoding"]?.localizedStandardContains("chunked") == true }
  var contentLength: Int? { headers["content-length"].flatMap { Int($0) } }

  func response(url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
  }

  static func parse(_ data: Data) throws -> ResponseParser {
    guard let end = TCPHTTP.headerEnd(in: data) else {
      throw TranslateError(message: "服务没有返回完整响应", kind: .service)
    }
    let head = data.subdata(in: data.startIndex..<data.index(end, offsetBy: -4))
    guard let text = String(data: head, encoding: .utf8) else {
      throw TranslateError(message: "服务返回的内容无法解析", kind: .service)
    }
    var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
    guard let statusLine = lines.first, let status = statusCode(in: statusLine) else {
      throw TranslateError(message: "服务返回的内容无法解析", kind: .service)
    }
    lines.removeFirst()
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let index = line.firstIndex(of: ":") else { continue }
      let name = line[..<index].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    return ResponseParser(status: status, headers: headers, remainder: Data(data[end...]))
  }

  private static func statusCode(in line: String) -> Int? {
    let parts = line.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
      return nil
    }
    return status
  }
}

nonisolated extension AsyncThrowingStream where Element == UInt8 {
  fileprivate var lines: AsyncThrowingStream<String, Error> {
    AsyncThrowingStream<String, any Error> { continuation in
      let task = Task {
        do {
          var buffer = Data()
          for try await byte in self {
            if byte == 10 {
              if buffer.last == 13 { buffer.removeLast() }
              continuation.yield(String(data: buffer, encoding: .utf8) ?? "")
              buffer.removeAll(keepingCapacity: true)
            } else {
              buffer.append(byte)
            }
          }
          if !buffer.isEmpty {
            if buffer.last == 13 { buffer.removeLast() }
            continuation.yield(String(data: buffer, encoding: .utf8) ?? "")
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
