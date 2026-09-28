// 需要请求签名的云厂商翻译：火山引擎（HMAC-SHA256，类 SigV4）、腾讯云（TC3-HMAC-SHA256）。
// 签名是纯函数、时间由参数传入，单测用独立实现算出的结果校验。

import Foundation

nonisolated enum Volcengine {
  static let host = "open.volcengineapi.com"
  static let query = "Action=TranslateText&Version=2020-06-01"

  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    guard let accessKey = service.secret("accessKey"), let secretKey = service.secret("secretKey")
    else { return Signing.missing("火山引擎的 Access Key 和 Secret Key") }
    return Signing.oneShot {
      var json: [String: Any] = ["TargetLanguage": code(request.to), "TextList": [request.text]]
      if let from = request.from { json["SourceLanguage"] = code(from) }
      let body = try JSONSerialization.data(withJSONObject: json)
      var urlRequest = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
      urlRequest.httpMethod = "POST"
      urlRequest.timeoutInterval = 30
      urlRequest.httpBody = body
      for (name, value) in headers(
        accessKey: accessKey, secretKey: secretKey, body: body, date: .now)
      {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
      let object = try await HTTP.send(urlRequest)
      if let error = (object["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any],
        let message = error["Message"] as? String
      {
        // 签名、Access Key 类是配置错误（橙色、去设置）
        let code = error["Code"] as? String ?? ""
        let isKey = ["Signature", "AccessKey", "Auth"].contains { code.contains($0) }
        throw TranslateError(
          message: "火山翻译错误：\(message.prefix(160))", kind: isKey ? .config : .service)
      }
      let list = object["TranslationList"] as? [[String: Any]]
      return list?.first?["Translation"] as? String ?? ""
    }
  }

  /// 签名：规范请求（4 个头）→ 待签字符串 → 用 Secret Key 逐级派生（日期 → 区域 → 服务 → request）
  static func headers(accessKey: String, secretKey: String, body: Data, date: Date) -> [String:
    String]
  {
    let region = "cn-north-1"
    let service = "translate"
    let xDate = date.formatted(
      Date.VerbatimFormatStyle(
        format:
          "\(year: .padded(4))\(month: .twoDigits)\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)Z",
        timeZone: .gmt, calendar: Calendar(identifier: .gregorian)))
    let shortDate = String(xDate.prefix(8))
    let bodyHash = Signing.sha256(body)
    let signedHeaders = "content-type;host;x-content-sha256;x-date"
    let canonicalRequest = [
      "POST", "/", query,
      "content-type:application/json\nhost:\(host)\nx-content-sha256:\(bodyHash)\nx-date:\(xDate)\n",
      signedHeaders, bodyHash,
    ].joined(separator: "\n")
    let scope = "\(shortDate)/\(region)/\(service)/request"
    let stringToSign = [
      "HMAC-SHA256", xDate, scope, Signing.sha256(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    var key = Data(secretKey.utf8)
    for part in [shortDate, region, service, "request"] { key = Signing.hmac(key, part) }
    let signature = Signing.hex(Signing.hmac(key, stringToSign))
    return [
      "Authorization":
        "HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
      "Content-Type": "application/json", "Host": host, "X-Content-Sha256": bodyHash,
      "X-Date": xDate,
    ]
  }

  static func code(_ lang: Lang) -> String {
    switch lang {
    case .zhHans: "zh"
    case .zhHant: "zh-Hant"
    default: lang.rawValue
    }
  }
}

nonisolated enum Tencent {
  static let host = "tmt.tencentcloudapi.com"

  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    guard let secretID = service.secret("secretId"), let secretKey = service.secret("secretKey")
    else {
      return Signing.missing("腾讯云的 SecretId 和 SecretKey")
    }
    return Signing.oneShot {
      let json: [String: Any] = [
        "SourceText": request.text, "Source": request.from.map(code) ?? "auto",
        "Target": code(request.to), "ProjectId": 0,
      ]
      let body = try JSONSerialization.data(withJSONObject: json)
      var urlRequest = URLRequest(url: URL(string: "https://\(host)")!)
      urlRequest.httpMethod = "POST"
      urlRequest.timeoutInterval = 30
      urlRequest.httpBody = body
      let timestamp = Int(Date.now.timeIntervalSince1970)
      for (name, value) in headers(
        secretID: secretID, secretKey: secretKey, body: body, timestamp: timestamp)
      {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
      let object = try await HTTP.send(urlRequest)
      let response = object["Response"] as? [String: Any] ?? [:]
      if let error = response["Error"] as? [String: Any] {
        // AuthFailure.* 是 SecretId / SecretKey 的问题：配置错误
        throw TranslateError(
          message: "腾讯翻译错误：\((error["Message"] as? String ?? "未知").prefix(160))",
          kind: (error["Code"] as? String ?? "").hasPrefix("AuthFailure") ? .config : .service)
      }
      return response["TargetText"] as? String ?? ""
    }
  }

  /// TC3-HMAC-SHA256：签名头 content-type;host；密钥派生 "TC3"+SecretKey → 日期(UTC) → tmt → tc3_request
  static func headers(secretID: String, secretKey: String, body: Data, timestamp: Int) -> [String:
    String]
  {
    let contentType = "application/json; charset=utf-8"
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(
      Date.VerbatimFormatStyle(
        format: "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)))
    let canonicalRequest = [
      "POST", "/", "", "content-type:\(contentType)\nhost:\(host)\n", "content-type;host",
      Signing.sha256(body),
    ].joined(separator: "\n")
    let scope = "\(date)/tmt/tc3_request"
    let stringToSign = [
      "TC3-HMAC-SHA256", String(timestamp), scope, Signing.sha256(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    var key = Data(("TC3" + secretKey).utf8)
    for part in [date, "tmt", "tc3_request"] { key = Signing.hmac(key, part) }
    let signature = Signing.hex(Signing.hmac(key, stringToSign))
    return [
      "Authorization":
        "TC3-HMAC-SHA256 Credential=\(secretID)/\(scope), SignedHeaders=content-type;host, Signature=\(signature)",
      "Content-Type": contentType, "Host": host, "X-TC-Action": "TextTranslate",
      "X-TC-Timestamp": String(timestamp), "X-TC-Version": "2018-03-21",
      "X-TC-Region": "ap-beijing",
    ]
  }

  static func code(_ lang: Lang) -> String {
    switch lang {
    case .zhHans: "zh"
    case .zhHant: "zh-TW"
    default: lang.rawValue
    }
  }
}
