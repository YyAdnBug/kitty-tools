// 各家翻译接口签名用的摘要工具（CryptoKit）与一次性请求包装（非流式服务也统一成 AsyncThrowingStream）。

import CryptoKit
import Foundation

nonisolated enum Signing {
  /// 小写十六进制（同逐个字节 String(format: "%02x") 拼起来；那样一个字节要格式化一回，同步一轮几千个哈希时是大头）
  static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    var digits: [UInt8] = []
    digits.reserveCapacity(digest.underestimatedCount * 2)
    func digit(_ nibble: UInt8) -> UInt8 { nibble < 10 ? 0x30 + nibble : 0x57 + nibble }
    for byte in digest {
      digits.append(digit(byte >> 4))
      digits.append(digit(byte & 0x0F))
    }
    return String(decoding: digits, as: UTF8.self)
  }

  static func md5(_ text: String) -> String { hex(Insecure.MD5.hash(data: Data(text.utf8))) }

  static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

  static func hmac(_ key: Data, _ message: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
  }

  /// application/x-www-form-urlencoded（值里的 & = + 等都要编码）
  static func form(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body = fields.map { name, value in
      "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }
    return Data(body.joined(separator: "&").utf8)
  }

  /// 非流式服务：一次请求出完整译文，包装成只产出一次的流
  static func oneShot(_ body: @escaping @Sendable () async throws -> String)
    -> AsyncThrowingStream<String, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let text = try await body().trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { throw TranslateError.emptyResult }
          continuation.yield(text)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func missing(_ what: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish(throwing: TranslateError.config("请先在设置里填写\(what)")) }
  }

  static func tooLong(_ limit: Int) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream {
      $0.finish(throwing: TranslateError(message: "原文超过这个服务的长度上限（\(limit) 字）"))
    }
  }
}
