// 非流式的传统翻译接口：百度、有道、Google、DeepL / DeepLX、微软。每家一个 enum，签名部分是纯函数（配单测）。
// 语言码各家不同，按各自文档映射；源语言 nil 表示让服务自动识别。

import Foundation

nonisolated enum Baidu {
  static let limit = 6000

  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    guard let appID = service.secret("appId"), let secret = service.secret("secret") else {
      return Signing.missing("百度翻译的 App ID 和密钥")
    }
    guard request.text.count <= limit else { return Signing.tooLong(limit) }
    return Signing.oneShot {
      let salt = String(Int.random(in: 1_000_000...9_999_999))
      var urlRequest = URLRequest(
        url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      urlRequest.httpBody = Signing.form([
        ("q", request.text), ("from", code(request.from)), ("to", code(request.to)),
        ("appid", appID), ("salt", salt),
        ("sign", sign(appID: appID, text: request.text, salt: salt, secret: secret)),
      ])
      let object = try await HTTP.send(urlRequest)
      if let code = object["error_code"], "\(code)" != "52000" { throw error(code: "\(code)") }
      let results = object["trans_result"] as? [[String: Any]] ?? []
      return results.compactMap { $0["dst"] as? String }.joined(separator: "\n")
    }
  }

  /// 错误码 → 用户看得懂的中文（mac-translate §3；按百度翻译开放平台的错误码表）。密钥类是配置错误（橙色、去设置）
  static func error(code: String) -> TranslateError {
    switch code {
    case "52001": TranslateError(message: "百度翻译请求超时，请重试")
    case "52002": TranslateError(message: "百度翻译系统出错，请重试")
    case "52003", "54001", "90107": .config("App ID 或密钥不对")
    case "54003": TranslateError(message: "请求太频繁，稍后再试")
    case "54004": TranslateError(message: "百度翻译账户余额不足")
    case "58001": TranslateError(message: "百度翻译不支持这个语言方向")
    case "58002": .config("服务已关闭，请到百度翻译开放平台开通")
    default: TranslateError(message: "百度翻译出错（错误码 \(code)）")
    }
  }

  /// sign = md5(appid + q + salt + 密钥)，小写十六进制
  static func sign(appID: String, text: String, salt: String, secret: String) -> String {
    Signing.md5(appID + text + salt + secret)
  }

  static func code(_ lang: Lang?) -> String {
    switch lang {
    case nil: "auto"
    case .zhHans: "zh"
    case .zhHant: "cht"
    case .ja: "jp"
    case .ko: "kor"
    case .fr: "fra"
    case .es: "spa"
    case let lang?: lang.rawValue
    }
  }
}

nonisolated enum Youdao {
  static let limit = 5000

  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    guard let appKey = service.secret("appKey"), let appSecret = service.secret("appSecret") else {
      return Signing.missing("有道翻译的应用 ID 和应用密钥")
    }
    guard request.text.count <= limit else { return Signing.tooLong(limit) }
    return Signing.oneShot {
      let salt = UUID().uuidString
      let time = String(Int(Date.now.timeIntervalSince1970))
      var urlRequest = URLRequest(url: URL(string: "https://openapi.youdao.com/api")!)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      urlRequest.httpBody = Signing.form([
        ("q", request.text), ("from", code(request.from)), ("to", code(request.to)),
        ("appKey", appKey), ("salt", salt), ("signType", "v3"), ("curtime", time),
        (
          "sign",
          sign(appKey: appKey, text: request.text, salt: salt, time: time, secret: appSecret)
        ),
      ])
      let object = try await HTTP.send(urlRequest)
      guard "\(object["errorCode"] ?? "")" == "0" else {
        throw error(code: "\(object["errorCode"] ?? "未知")")
      }
      return (object["translation"] as? [String] ?? []).joined(separator: "\n")
    }
  }

  /// 错误码 → 用户看得懂的中文（按有道智云的错误码表）；应用 ID / 密钥类是配置错误
  static func error(code: String) -> TranslateError {
    switch code {
    case "101", "108", "202": .config("应用 ID 或应用密钥不对")
    case "401": TranslateError(message: "有道翻译账户已欠费")
    case "411": TranslateError(message: "请求太频繁，稍后再试")
    default: TranslateError(message: "有道翻译出错（错误码 \(code)）")
    }
  }

  /// v3：sha256(应用ID + input + salt + curtime + 应用密钥)；input 超过 20 字取「前 10 字 + 字数 + 后 10 字」
  static func sign(appKey: String, text: String, salt: String, time: String, secret: String)
    -> String
  {
    let input = text.count <= 20 ? text : "\(text.prefix(10))\(text.count)\(text.suffix(10))"
    return Signing.sha256(Data((appKey + input + salt + time + secret).utf8))
  }

  static func code(_ lang: Lang?) -> String {
    switch lang {
    case nil: "auto"
    case .zhHans: "zh-CHS"
    case .zhHant: "zh-CHT"
    case let lang?: lang.rawValue
    }
  }
}

nonisolated enum Google {
  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    guard let key = service.secret() else { return Signing.missing("Google 的 API Key") }
    return Signing.oneShot {
      var components = URLComponents(
        string: "https://translation.googleapis.com/language/translate/v2")!
      components.queryItems = [URLQueryItem(name: "key", value: key)]
      var json: [String: Any] = ["q": request.text, "target": code(request.to), "format": "text"]
      if let from = request.from { json["source"] = code(from) }
      let object = try await HTTP.send(HTTP.request(components.url!, headers: [:], json: json))
      let translations = (object["data"] as? [String: Any])?["translations"] as? [[String: Any]]
      return translations?.first?["translatedText"] as? String ?? ""
    }
  }

  static func code(_ lang: Lang) -> String {
    switch lang {
    case .zhHans: "zh-CN"
    case .zhHant: "zh-TW"
    default: lang.rawValue
    }
  }
}

nonisolated enum DeepL {
  /// 自建 DeepLX 的地址（没写协议的补 http://）；没填、不成网址是 nil。发请求和导入设置前列出主机
  /// （SettingsArchive.customHosts）用同一个，免得列出来的和真正连的不是一个地方
  static func deepLXURL(_ service: TranslateService) -> URL? {
    guard let raw = service.baseURL?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
      return nil
    }
    return URL(string: raw.contains("://") ? raw : "http://" + raw)
  }

  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    if service.usesDeepLX == true {
      guard let url = deepLXURL(service) else { return Signing.missing("DeepLX 地址") }
      return Signing.oneShot {
        let json: [String: Any] = [
          "text": request.text, "source_lang": request.from.map(sourceCode) ?? "auto",
          "target_lang": targetCode(request.to),
        ]
        let object = try await HTTP.send(HTTP.request(url, headers: [:], json: json))
        return object["data"] as? String ?? ""
      }
    }
    guard let key = service.secret("authKey") else { return Signing.missing("DeepL 的 Auth Key") }
    return Signing.oneShot {
      // 免费版 key 以 :fx 结尾，走 api-free 域名
      let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
      var json: [String: Any] = ["text": [request.text], "target_lang": targetCode(request.to)]
      if let from = request.from { json["source_lang"] = sourceCode(from) }
      let object = try await HTTP.send(
        HTTP.request(
          URL(string: "https://\(host)/v2/translate")!,
          headers: ["Authorization": "DeepL-Auth-Key \(key)"], json: json))
      return (object["translations"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }
  }

  /// 源语言只接受基础码（简繁都是 ZH，葡语 PT）
  static func sourceCode(_ lang: Lang) -> String {
    switch lang {
    case .zhHans, .zhHant: "ZH"
    default: lang.rawValue.uppercased()
    }
  }

  /// 目标语言要带变体：ZH-HANS / ZH-HANT、EN-US、PT-BR（旧版用基础码，繁体丢失、EN/PT 已被弃用）
  static func targetCode(_ lang: Lang) -> String {
    switch lang {
    case .zhHans: "ZH-HANS"
    case .zhHant: "ZH-HANT"
    case .en: "EN-US"
    case .pt: "PT-BR"
    default: lang.rawValue.uppercased()
    }
  }
}

nonisolated enum Microsoft {
  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    let key = service.secret("subscriptionKey")
    let region = service.region?.trimmingCharacters(in: .whitespaces) ?? ""
    return Signing.oneShot {
      var components: URLComponents
      var headers = ["Content-Type": "application/json"]
      if let key {
        components = URLComponents(
          string: "https://api.cognitive.microsofttranslator.com/translate")!
        components.queryItems = [URLQueryItem(name: "api-version", value: "3.0")]
        headers["Ocp-Apim-Subscription-Key"] = key
        if !region.isEmpty { headers["Ocp-Apim-Subscription-Region"] = region }
      } else {
        // 没填 key：Edge 浏览器翻译的免登录接口。旧的 edge.microsoft.com/translate/auth 换 token 流程
        // 2026-08 起返回 404（旧版因此失效），现在直接调 translatetext
        components = URLComponents(string: "https://edge.microsoft.com/translate/translatetext")!
        components.queryItems = [URLQueryItem(name: "isEnterpriseClient", value: "false")]
      }
      components.queryItems?.append(URLQueryItem(name: "to", value: code(request.to)))
      if let from = request.from {
        components.queryItems?.append(URLQueryItem(name: "from", value: code(from)))
      }
      var urlRequest = URLRequest(url: components.url!)
      urlRequest.httpMethod = "POST"
      urlRequest.timeoutInterval = 30
      for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
      // 两个接口的请求体不同：认知服务是 [{"Text": ...}]，Edge 接口是字符串数组；返回结构相同
      let body: Any = key == nil ? [request.text] : [["Text": request.text]]
      urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await HTTP.session(for: components.url!).data(for: urlRequest)
      let object = try? JSONSerialization.jsonObject(with: data)
      try HTTP.check(response, object as? [String: Any] ?? [:])
      let first = (object as? [[String: Any]])?.first
      return ((first?["translations"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }
  }

  static func code(_ lang: Lang) -> String {
    switch lang {
    case .zhHans: "zh-Hans"
    case .zhHant: "zh-Hant"
    default: lang.rawValue
    }
  }
}
