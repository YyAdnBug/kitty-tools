// 翻译服务的网络请求：JSON POST、SSE 流式读取、面向用户的中文错误信息。
// 红线：错误信息和日志里不出现请求 URL、请求头和密钥。

import Foundation

nonisolated struct TranslateError: LocalizedError, Sendable {
  let message: String
  /// HTTP 状态码（400 / 422 时调用方会降级重试）
  var status: Int?

  var errorDescription: String? { message }

  static let emptyResult = TranslateError(message: "服务没有返回译文（输出额度可能被思考过程占满，可换非推理模型）")
}

nonisolated enum HTTP {
  /// 本机 / 局域网上的大模型可能很慢，给更长的空闲超时
  static func session(for url: URL) -> URLSession {
    isLocalNetwork(url) ? localSession : URLSession.shared
  }

  private static let localSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 180
    return URLSession(configuration: configuration)
  }()

  static func request(_ url: URL, headers: [String: String], json: [String: Any]) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = isLocalNetwork(url) ? 180 : 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try? JSONSerialization.data(withJSONObject: json)
    return request
  }

  /// 一次性请求，返回解析好的 JSON
  static func send(_ request: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await perform {
      try await session(for: request.url!).data(for: request)
    }
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    try check(response, object)
    return object
  }

  /// SSE：逐行给出 `data:` 之后的内容（遇到 [DONE] 结束）
  static func events(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
    let (bytes, response) = try await perform {
      try await session(for: request.url!).bytes(for: request)
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      var body = Data()
      for try await byte in bytes.prefix(64 * 1024) { body.append(byte) }
      try check(response, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await line in bytes.lines {
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
    }
  }

  /// 2xx 也可能在 JSON 里带 error 字段
  static func check(_ response: URLResponse, _ object: [String: Any]) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let serverMessage = message(in: object)
    guard (200..<300).contains(status), serverMessage == nil else {
      throw TranslateError(
        message: describe(status: status, serverMessage: serverMessage), status: status)
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
      case 429: "请求太频繁或额度已用完"
      case 500...: "服务暂时不可用（\(status)）"
      default: "请求失败（\(status)）"
      }
    guard let serverMessage, !serverMessage.isEmpty else { return base }
    return "\(base)：\(serverMessage.prefix(160))"
  }

  private static func perform<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch { throw userFacing(error) }
  }

  static func userFacing(_ error: Error) -> Error {
    guard let urlError = error as? URLError else { return error }
    if urlError.code == .cancelled { return CancellationError() }
    let message =
      switch urlError.code {
      case .timedOut: "请求超时，请检查网络或服务地址"
      case .notConnectedToInternet, .networkConnectionLost: "网络不可用"
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "连不上服务地址"
      case .secureConnectionFailed, .serverCertificateUntrusted: "HTTPS 连接失败（证书问题）"
      default: "网络错误（\(urlError.code.rawValue)）"
      }
    return TranslateError(message: message)
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
}
