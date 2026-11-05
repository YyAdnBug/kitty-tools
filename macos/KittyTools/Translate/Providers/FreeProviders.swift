// 不用填 key 的两个服务（2026-11-05 拍板 S1 S2）：
// - 系统翻译（AppleTranslation）：Translation 框架，离线、文字不出这台电脑。只有 macOS 26 起才能在视图外面建会话
//   （init(installedSource:target:)，只用已经下载的语言），15 上设置「+」里没有它、列表里有（从别的 Mac 同步过来）时
//   卡片说要 26。源语言「自动」时用检测出来的语言；语言没下载 → 配置类错误，告诉用户去系统设置下载。
// - 有道词典（YoudaoDict）：有道词典网页版的查词接口（一个普通的 GET、不签名、不冒充别的客户端），只查单词和短语：
//   英文词出美 / 英音标、各词性的释义、变形、一个双语例句，中文词出拼音和英文释义，写成和大模型单词卡同一个样子
//   （第一行读音，卡片上就有读音的小喇叭）。非官方接口：哪天改了格式就是「有道词典里没有这个词」，再来修。
//   不是单词的原文不开它的卡片（TranslateCoordinator.start），也不当主结果、不进静默替换（Kind.isDictionary）。

import Foundation
import Translation

nonisolated enum AppleTranslation {
  /// 这台 Mac 能不能用（macOS 26 起）
  static var isAvailable: Bool {
    if #available(macOS 26, *) { true } else { false }
  }

  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    Signing.oneShot {
      guard #available(macOS 26, *) else {
        throw TranslateError.config("系统翻译要 macOS 26 或更新")
      }
      guard let from = request.from ?? Lang.detect(request.text) else {
        throw TranslateError(message: "认不出原文是什么语言，在浮窗顶上选一下源语言")
      }
      let source = Locale.Language(identifier: from.rawValue)
      let target = Locale.Language(identifier: request.to.rawValue)
      switch await LanguageAvailability().status(from: source, to: target) {
      case .installed: break
      case .supported:
        throw TranslateError.config(
          "系统翻译还没下载\(from.title)和\(request.to.title)：到 系统设置 › 通用 › 语言与地区 › 翻译语言 里下载")
      case .unsupported:
        throw TranslateError(message: "系统翻译不支持\(from.title)译\(request.to.title)")
      @unknown default: break
      }
      let session = TranslationSession(installedSource: source, target: target)
      do {
        return try await session.translate(request.text).targetText
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw TranslateError(message: "系统翻译出错：\(error.localizedDescription)")
      }
    }
  }
}

nonisolated enum YoudaoDict {
  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    Signing.oneShot {
      let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
      var components = URLComponents(string: "https://dict.youdao.com/jsonapi")!
      // 只要英汉、汉英和双语例句三节（整份 130 KB，这样 5 KB）
      components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(
          name: "dicts", value: #"{"count":99,"dicts":[["ec","ce","blng_sents_part"]]}"#),
      ]
      var urlRequest = URLRequest(url: components.url!)
      urlRequest.timeoutInterval = 30
      let (data, response) = try await HTTP.perform { [urlRequest] in
        try await HTTP.session(for: urlRequest.url!).data(for: urlRequest)
      }
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      try HTTP.check(response, object ?? [:])
      guard let object, let entry = entry(object) else {
        throw TranslateError(message: "有道词典里没有这个词")
      }
      return entry
    }
  }

  /// 把接口返回的词条写成单词卡的样子（纯函数，配单测）：
  /// 英汉 = 「美 /…/  英 /…/」+ 每个词性一行 + 变形 + 「例：英文 中文」；汉英 = 拼音 + 「n. name；…」。都没有时 nil
  static func entry(_ object: [String: Any]) -> String? {
    var lines: [String] = []
    if let word = ((object["ec"] as? [String: Any])?["word"] as? [[String: Any]])?.first {
      let phonetics = [("美", word["usphone"]), ("英", word["ukphone"])].compactMap { label, value in
        (value as? String).flatMap { $0.isEmpty ? nil : "\(label) /\($0)/" }
      }
      if !phonetics.isEmpty { lines.append(phonetics.joined(separator: "  ")) }
      for tr in word["trs"] as? [[String: Any]] ?? [] {
        if let line = (firstLine(tr)?["i"] as? [Any])?.compactMap({ $0 as? String }).first,
          !line.isEmpty
        {
          lines.append(line)
        }
      }
      let forms = (word["wfs"] as? [[String: Any]] ?? []).compactMap { item -> String? in
        guard let wf = item["wf"] as? [String: Any], let name = wf["name"] as? String,
          let value = wf["value"] as? String
        else { return nil }
        return "\(name) \(value)"
      }
      if lines.count > (phonetics.isEmpty ? 0 : 1), !forms.isEmpty {
        lines.append("变形：" + forms.joined(separator: "；"))
      }
    } else if let word = ((object["ce"] as? [String: Any])?["word"] as? [[String: Any]])?.first {
      if let phone = word["phone"] as? String, !phone.isEmpty { lines.append(phone) }
      for tr in word["trs"] as? [[String: Any]] ?? [] {
        guard let line = firstLine(tr) else { continue }
        // i 是字符串和 {"#text": "name"} 混着的数组
        let text = (line["i"] as? [Any] ?? []).map { item in
          (item as? String) ?? ((item as? [String: Any])?["#text"] as? String) ?? ""
        }.joined().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        let pos = (line["pos"] as? String).map { $0 + " " } ?? ""
        lines.append(pos + text)
      }
    }
    // 只有读音、没有释义的不算查到
    guard lines.contains(where: { !$0.hasPrefix("美 /") && !$0.hasPrefix("英 /") }) else {
      return nil
    }
    if let pair =
      ((object["blng_sents_part"] as? [String: Any])?["sentence-pair"] as? [[String: Any]])?
      .first, let sentence = pair["sentence"] as? String,
      let translation = pair["sentence-translation"] as? String
    {
      lines.append("例：\(sentence) \(translation)")
    }
    return lines.joined(separator: "\n")
  }

  /// trs 里一条的 tr[0].l
  private static func firstLine(_ tr: [String: Any]) -> [String: Any]? {
    ((tr["tr"] as? [[String: Any]])?.first)?["l"] as? [String: Any]
  }
}
