// 脚本命令头部写的图片图标（2026-11-07；第二轮拍板 B1 B2 加了 https 网址、深色主题的图标和出错原因，PLAN §10「脚本命令」）：
// 同文件夹 / 绝对路径的图片第一次要画时在主线程外读（最多 2 MB）；https 网址第一次要画时在后台下载一次（必须是图片、不超过 1 MB；
// http 不认），存进数据目录的 script-icons/（按网址的 SHA-256 起名），以后直接读缓存、不再联网——网址改了才是另一张。
// 读不出来、下不下来的记下原因（「命令和别名」那一行写橙字），这次运行里不再试。画图标的 ScriptIconView 也在这里（启动器的行、
// 设置的表共用）：emoji 直接画、SF 符号放进命令家族紫的色块、图片读到了换上，深色主题有 iconDark 的用它。
// ponytail: 缓存不清理（图标少、每张不过 1 MB）；真攒多了再按最近用到的删。

import AppKit
import CryptoKit
import ImageIO
import SwiftUI

@Observable final class ScriptIcons {
  static let shared = ScriptIcons()
  private(set) var images: [String: NSImage] = [:]
  private(set) var failures: [String: String] = [:]
  @ObservationIgnored private var requested: Set<String> = []

  nonisolated static let localLimit = 2 << 20
  nonisolated static let remoteLimit = 1 << 20

  nonisolated enum Failure: Error, Equatable, Sendable {
    case missing(String)
    case tooBig
    case notImage
    case download

    var text: String {
      switch self {
      case .missing(let name): "图标找不到：\(name)"
      case .tooBig: "图标太大（本地最多 2 MB，网址最多 1 MB）"
      case .notImage: "图标不是图片"
      case .download: "图标下载不下来：网址不对或没联网"
      }
    }
  }

  /// 网址图标的缓存：数据目录的 script-icons/
  nonisolated static var cacheFolder: URL {
    AppDelegate.supportDirectory.appending(path: "script-icons", directoryHint: .isDirectory)
  }

  /// 图片 / 网址图标按什么记（emoji、符号不用读）
  nonisolated static func key(_ icon: ScriptCommand.Icon) -> String? {
    switch icon {
    case .image(let path): path
    case .remote(let url): url
    case .emoji, .symbol: nil
    }
  }

  /// 要画的图：没读到之前是 nil，读到了换上
  func image(for icon: ScriptCommand.Icon) -> NSImage? {
    guard let key = Self.key(icon) else { return nil }
    load(icon, key: key)
    return images[key]
  }

  /// 读不出来、下不下来的原因
  func failure(for icon: ScriptCommand.Icon) -> String? {
    guard let key = Self.key(icon) else { return nil }
    load(icon, key: key)
    return failures[key]
  }

  private func load(_ icon: ScriptCommand.Icon, key: String) {
    guard requested.insert(key).inserted else { return }
    Task {
      let result: Result<Data, Failure> =
        switch icon {
        case .image(let path): await Self.readLocal(path)
        case .remote(let url): await Self.fetch(url, cache: Self.cacheFolder)
        case .emoji, .symbol: .failure(.notImage)
        }
      switch result {
      case .success(let data):
        if let image = NSImage(data: data) {
          images[key] = image
        } else {
          failures[key] = Failure.notImage.text
        }
      case .failure(let failure): failures[key] = failure.text
      }
    }
  }

  /// 本地图片：在不在、多大、是不是图片
  @concurrent static func readLocal(_ path: String) async -> Result<Data, Failure> {
    let url = URL(filePath: path)
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
      return .failure(.missing((path as NSString).lastPathComponent))
    }
    guard size <= localLimit else { return .failure(.tooBig) }
    guard let data = try? Data(contentsOf: url) else {
      return .failure(.missing((path as NSString).lastPathComponent))
    }
    return isImage(data) ? .success(data) : .failure(.notImage)
  }

  /// 网址图标：缓存里有就用缓存；没有就下载一次（https、10 秒、不超过 1 MB、是图片）存进缓存
  @concurrent static func fetch(_ address: String, cache: URL) async -> Result<Data, Failure> {
    let file = cache.appending(path: cacheName(address))
    if let data = try? Data(contentsOf: file), isImage(data) { return .success(data) }
    guard let url = URL(string: address), url.scheme?.lowercased() == "https" else {
      return .failure(.download)
    }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return .failure(.download) }
    guard data.count <= remoteLimit else { return .failure(.tooBig) }
    guard isImage(data) else { return .failure(.notImage) }
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
    return .success(data)
  }

  /// 缓存的文件名：网址的 SHA-256（不把网址原样当文件名）
  nonisolated static func cacheName(_ address: String) -> String {
    SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func isImage(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return CGImageSourceGetCount(source) > 0
  }
}

/// 脚本命令的图标（启动器的行 24 pt、设置的表 20 pt）：emoji 直接画；SF 符号放进命令家族紫的色块（同系统命令）；图片 / 网址在主线程外
/// 读到再换上；深色主题有 dark 的用它。符号名不认识、图片还没读到或读不出来时用 fallback（默认的 terminal 色块）
struct ScriptIconView<Fallback: View>: View {
  let icon: ScriptCommand.Icon
  var dark: ScriptCommand.Icon?
  var size: CGFloat = 24
  let fallback: Fallback
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    switch scheme == .dark ? dark ?? icon : icon {
    case .emoji(let emoji):
      Text(emoji)
        .font(.system(size: size * 0.8))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    case .symbol(let name)
    where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil:
      KindTile(symbol: name, color: Style.Family.command, size: size)
    case let shown:
      if let image = ScriptIcons.shared.image(for: shown) {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
          .frame(width: size, height: size)
      } else {
        fallback
      }
    }
  }
}
