// 启动器的直达项（纯函数，配单测）：输入像网址就「在浏览器中打开」，像存在的路径就「打开」，都排在最前。
// 网址：带 http(s):// / mailto:，或 IPv4 / localhost（可带端口），或「域名.后缀[/路径]」：裸域名只认常见后缀白名单
// （免得 install.sh、Package.swift 被当成网址），域名后面紧跟 / 或 :端口 时最后一段是 2–13 个字母就认
// （docs.rs/serde、bun.sh/docs，体检 B34）；「Safari.app」这类不算（修旧版 .app 被当网址、localhost:3000 反而不认，§11 #36）。
// 路径：/ 或 ~ 开头且真实存在；展开 ~，不认 ./ 这类相对路径（修 §11 #27）。

import Foundation

enum DirectItems {
  static let topLevelDomains: Set<String> = [
    "com", "cn", "net", "org", "io", "dev", "me", "co", "tv", "ai", "edu", "gov", "info", "biz",
    // 不收 sh / so / cc 这类同时是常见文件扩展名的后缀（install.sh、libfoo.so 会被当成网址）
    "uk", "jp", "de", "fr", "top", "xyz", "do", "gg", "im", "ly", "to", "tech",
    "site", "online", "app",
  ]

  static func items(for query: String) -> [LauncherItem] {
    if let url = url(from: query) {
      return [
        LauncherItem(
          kind: .url, target: url.absoluteString, title: displayName(of: url),
          subtitle: "在浏览器中打开", names: [],
          // Tab 保留原样（显示名去掉了协议、查询串，补回去会变成另一个网址）
          completion: query.trimmingCharacters(in: .whitespaces))
      ]
    }
    if let path = existingPath(from: query) {
      return [
        LauncherItem(
          kind: .path, target: path, title: (path as NSString).lastPathComponent,
          subtitle: (path as NSString).abbreviatingWithTildeInPath, names: [])
      ]
    }
    return []
  }

  static func url(from query: String) -> URL? {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
    let lower = text.lowercased()
    if ["http://", "https://", "mailto:"].contains(where: lower.hasPrefix) {
      return URL(string: text)
    }
    let host = String(lower.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    let hostName = String(host.split(separator: ":", maxSplits: 1).first ?? "")
    let isIPv4 =
      hostName.split(separator: ".").count == 4
      && hostName.split(separator: ".").allSatisfy { UInt8($0) != nil }
    let isLocalhost = hostName == "localhost"
    let labels = hostName.split(separator: ".", omittingEmptySubsequences: false)
    let suffix = String(labels.last ?? "")
    // 后面跟着路径或端口，说明是在输网址，不是文件名
    let rest = lower.dropFirst(hostName.count)
    let followed =
      rest.first == "/" || rest.first == ":" && rest.dropFirst().first?.isNumber == true
    let isDomain =
      labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
      && (topLevelDomains.contains(suffix)
        || followed && (2...13).contains(suffix.count)
          && suffix.allSatisfy { $0.isASCII && $0.isLetter })
      && hostName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
      // 「Safari.app」这种单独的 App 名不算网址（带 www. 或路径才算）
      && !(labels.last == "app" && labels.count == 2 && host == lower && !lower.hasPrefix("www."))
    guard isIPv4 || isLocalhost || isDomain else { return nil }
    let scheme = isIPv4 || isLocalhost ? "http://" : "https://"
    return URL(string: scheme + text)
  }

  static func existingPath(from query: String) -> String? {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
    let path = (text as NSString).expandingTildeInPath
    return FileManager.default.fileExists(atPath: path) ? path : nil
  }

  /// 记使用、「常用」里显示的标题：去掉协议，保留端口，路径不显示百分号编码
  static func displayName(of url: URL) -> String {
    guard let host = url.host() else { return url.absoluteString }
    let port = url.port.map { ":\($0)" } ?? ""
    let path = url.path(percentEncoded: false)
    return host + port + (path == "/" ? "" : path)
  }
}
