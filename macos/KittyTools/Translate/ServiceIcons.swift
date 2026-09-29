// 翻译服务的官网图标（第 13 批，mac-whisker §6 翻译「服务身份」）：内置 logo 表（AIVendor）认不出的自建 AI 服务，
// 按服务地址推出官网（opencode.ai/zen/go → https://opencode.ai/，api.foo.com → https://foo.com/），用剪贴板链接预览
// 那套下载器取网站图标（LinkPreview.siteIcon：apple-touch-icon 优先、限大小、超时、公网检查、临时会话），缩到长边 128
// 存进 Application Support 下的 ServiceIcons/<官网主机>.png。懒取：设置页或翻译卡片要显示这个服务时才取，取的时候是字母色块、
// 到了淡入；有缓存就不再取，满 7 天后显示时在后台重取一次（失败留着旧图）；本次运行里每个主机只试一次，取不到（断网、
// 网站没有图标）就一直是色块、不报错，下次启动再试。本机 / 内网 / IP 地址不取（Ollama 走内置 logo）。
// 不加设置开关：只访问用户自己配置的服务所在的官网（mac-translate §2）。

import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

@Observable final class ServiceIcons {
  static let shared = ServiceIcons()

  /// 取到的图标：四角有透明的垫白底留 14%，满版带底色的直接裁圆角（同内置 logo）
  struct Icon {
    let image: NSImage
    let onPlate: Bool
  }

  /// 取到新图就加一：ServiceTile 读它，图到了跟着重画（下面几个缓存本身不被观察）
  private(set) var revision = 0
  /// 磁盘缓存目录；截图自检换成临时目录
  @ObservationIgnored var directory = URL.applicationSupportDirectory
    .appending(path: Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")
    .appending(path: "ServiceIcons")
  /// 取官网图标（联网）；截图自检换成不联网的
  @ObservationIgnored var fetch: @MainActor (URL) async -> CGImage? = {
    await LinkPreview.shared.siteIcon($0, maxPixel: ServiceIcons.maxPixel)
  }
  @ObservationIgnored private var memory: [String: Icon] = [:]
  /// 查过磁盘、没有缓存的主机（取到了再移出去）
  @ObservationIgnored private var missing = Set<String>()
  /// 本次运行里取过的主机（成功失败都算，不重取）
  @ObservationIgnored private var tried = Set<String>()

  static let maxPixel = 128
  static let refreshAge: TimeInterval = 7 * 86_400

  /// 这个官网主机的图标（ServiceTile 在 body 里调）：内存 → 磁盘缓存（读一次记住）→ nil
  func icon(for host: String) -> Icon? {
    _ = revision
    if let icon = memory[host] { return icon }
    guard !missing.contains(host), let icon = Self.read(file(for: host)) else {
      missing.insert(host)
      return nil
    }
    memory[host] = icon
    return icon
  }

  /// 显示时调（ServiceTile 的 .task）：没有缓存或缓存满 7 天才取；本次运行里每个主机只取一次
  func load(_ host: String) async {
    guard !tried.contains(host) else { return }
    let file = file(for: host)
    if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate, Date.now.timeIntervalSince(modified) < Self.refreshAge
    {
      return
    }
    tried.insert(host)
    guard let site = URL(string: "https://\(host)/"), let image = await fetch(site) else { return }
    if let data = await Self.png(image) {
      // 写不进缓存也照样显示，下次启动再取
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: file, options: .atomic)
    }
    remember(image, for: host)
  }

  /// 放一张到内存里（取到时；截图自检直接摆状态也用它）
  func remember(_ image: CGImage, for host: String) {
    memory[host] = Icon(
      image: NSImage(cgImage: image, size: .zero), onPlate: Self.hasTransparentCorners(image))
    missing.remove(host)
    tried.insert(host)
    revision += 1
  }

  /// 磁盘缓存文件：<目录>/<官网主机>.png
  func file(for host: String) -> URL { directory.appending(path: host + ".png") }

  private static func read(_ file: URL) -> Icon? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return Icon(image: NSImage(cgImage: image, size: .zero), onPlate: hasTransparentCorners(image))
  }

  /// PNG 编码（白名单第 1 类：图片编码）
  @concurrent nonisolated private static func png(_ image: CGImage) async -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}

// MARK: 纯函数（配单测）

extension ServiceIcons {
  /// 服务的官网：只给内置 logo 表认不出的自建 AI 服务（Azure 除外），地址的主机取可注册域名 → https://它/；
  /// 本机 / 内网 / IP 地址没有（nil，用色块）
  nonisolated static func site(for service: TranslateService) -> URL? {
    guard service.kind == .ai, service.aiProtocol != .azure, AIVendor(service: service) == nil,
      let url = AIService.endpoint(service.baseURL ?? "", service.aiProtocol ?? .openai),
      let host = url.host(percentEncoded: false), let domain = registrableDomain(host)
    else { return nil }
    return URL(string: "https://\(domain)/")
  }

  /// 可注册域名：去掉 api. 这类子域，取最后两段（com.cn、co.uk 这类两段的公共后缀取三段）。
  /// IP、localhost、单段主机名、内网后缀（`LinkPreview.isPublicHTTP` 不放行的）没有。
  /// ponytail: 两段的公共后缀只列了常见的几个，不是完整的公共后缀表；遇到没列的会少取一段、取到后缀那家的图标
  /// （或取不到用色块），要准再内置公共后缀表
  nonisolated static func registrableDomain(_ host: String) -> String? {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let labels = host.split(separator: ".").map(String.init)
    guard let url = URL(string: "https://\(host)/"), LinkPreview.isPublicHTTP(url),
      let top = labels.last, !top.allSatisfy(\.isNumber)
    else { return nil }
    let count = secondLevelSuffixes.contains(labels.suffix(2).joined(separator: ".")) ? 3 : 2
    guard labels.count >= count else { return nil }
    return labels.suffix(count).joined(separator: ".")
  }

  private nonisolated static let secondLevelSuffixes: Set = [
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn", "com.hk", "com.tw", "co.uk",
    "org.uk", "co.jp", "ne.jp", "or.jp", "co.kr", "com.au", "com.sg", "com.br", "co.in",
  ]

  /// 四角有一个不是实的（alpha < 50%）就算透明底：垫白底留 14%；四角都实 = 满版带底色，直接裁圆角
  nonisolated static func hasTransparentCorners(_ image: CGImage) -> Bool {
    let (width, height) = (image.width, image.height)
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return true }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return true }
    let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    return corners.contains { x, y in pixels[(y * width + x) * 4 + 3] < 128 }
  }
}
