// 启动器网址 / 书签 / 历史 / 网页搜索行、设置 › 网页搜索列表的网站图标（体检 D6，mac-whisker §6 启动器）。不联网：
// 先读本机 Chromium 系浏览器的 Favicons 库（装着、书签开关开着的那几家，第 12 批起不只 Chrome；开关都关掉后缓存里的
// 也不用；克隆到临时目录、只读打开、读完删），再用剪贴板链接预览已经取到的（LinkPreview.favicons），都没有就是原来的
// 家族色块。ponytail: Safari（Favicon Cache 目录，要完全磁盘访问权限）、Firefox（favicons.sqlite）的图标库不读，
// 用它们的人靠剪贴板链接预览取到的和家族色块；要读再按各自格式加。按主机缓存进 NSCache；没找到的记下来，库的修改时间
// 变了才再查。只给看得见的行查：行出现时报上主机名，同一轮布局里报上来的攒成一批查一次。
// 样式照翻译服务的 ServiceTile：白底方块、tile 圆角、发丝线描边、图标四周留 14%。

import AppKit
import Observation
import SwiftUI

@Observable final class SiteIcons {
  static let shared = SiteIcons()

  /// 查到一批就加一：行读它，图标到了跟着重画（NSCache 本身不会通知）
  private(set) var revision = 0
  /// 从哪几家的数据目录读（装着、书签开关开着的 Chromium 系）；截图自检换成空的，不读本机浏览器
  @ObservationIgnored var roots: () -> [URL] = {
    Browsers.bookmarkBrowsers().filter { $0.format == .chromium }.map { Browsers.root(of: $0) }
  }
  @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
  /// 库里查过、没有的主机：库的修改时间变了才再查
  @ObservationIgnored private var missing = Set<String>()
  @ObservationIgnored private var pending = Set<String>()
  @ObservationIgnored private var isFlushScheduled = false
  @ObservationIgnored private var signature: [Date?] = []

  /// 一批最多查几个主机（只有一个库时；几个库按库数摊，剩下的下一轮接着查）
  static let batchLimit = 12

  /// 这个主机的网站图标：浏览器库里的（local = 有 Chromium 系的书签开关开着；都关掉后缓存里的也不用，不等重启）→
  /// 链接预览取到的（链接预览开关关着时不用，同剪贴板）→ nil（行上用家族色块）
  func icon(for host: String, local: Bool) -> NSImage? {
    _ = revision
    if local, let image = cache.object(forKey: host as NSString) { return image }
    guard UserDefaults.standard.bool(forKey: Prefs.clipboardLinkPreview) else { return nil }
    return LinkPreview.shared.favicons[host]
  }

  /// 截图自检摆状态用：直接放一张
  func remember(_ image: NSImage, for host: String) {
    cache.setObject(image, forKey: host as NSString)
    revision += 1
  }

  /// 行出现时报上来：没缓存、没查过的攒起来，这一轮布局结束后一起查
  func request(_ host: String) {
    guard cache.object(forKey: host as NSString) == nil else { return }
    let roots = roots()
    guard !roots.isEmpty else { return }
    // 查过没有的：库变了（修改时间，只 stat）才再查
    if missing.contains(host) {
      let signature = Self.signature(in: roots)
      guard signature != self.signature else { return }
      missing.removeAll()
      self.signature = signature
    }
    pending.insert(host)
    guard !isFlushScheduled else { return }
    isFlushScheduled = true
    Task { flush() }
  }

  /// 在主线程查：克隆（约 1 ms）+ 按主机走 page_url 索引，每个主机最多看 4 条映射。
  /// ponytail: 本机 18 MB 的库、刚克隆的冷缓存下 8 个主机约 12 ms（不限映射条数时 linux.do 一个主机有 9 千条映射、
  /// 8 个主机要 105 ms）。几家 / 几个配置的库时，没找到的主机要把每个库都查一遍，所以一批的主机数按库数摊
  /// （batchLimit / 库数，至少 2 个），每轮的耗时和只读一个库时差不多，剩下的留到下一轮；哪个库的修改时间变了，
  /// 查过没有的全部重查。库多到这样还卡，再挪到 Subprocess 跑 sqlite3、没找到的按库分别记
  private func flush() {
    isFlushScheduled = false
    let roots = roots()
    let files = Self.files(in: roots)
    let hosts = Array(pending.prefix(max(2, Self.batchLimit / max(files.count, 1))))
    pending.subtract(hosts)
    defer {
      revision += 1
      if !pending.isEmpty {
        isFlushScheduled = true
        Task { flush() }
      }
    }
    guard !roots.isEmpty, !hosts.isEmpty else { return }
    let signature = files.map(Browsers.modified)
    if signature != self.signature {
      missing.removeAll()
      self.signature = signature
    }
    var found: [String: Data] = [:]
    for file in files where found.count < hosts.count {
      guard let copy = try? Browsers.clone(file) else { continue }
      defer { Browsers.discard(copy) }
      guard let database = try? Database(path: copy.path, readOnly: true) else { continue }
      found.merge(Self.lookup(hosts.filter { found[$0] == nil }, in: database)) { old, _ in old }
    }
    for host in hosts {
      if let data = found[host], let image = NSImage(data: data) {
        cache.setObject(image, forKey: host as NSString)
      } else {
        missing.insert(host)
      }
    }
  }

  /// 这几家各配置的 Favicons 库
  private static func files(in roots: [URL]) -> [URL] {
    roots.flatMap { Browsers.profileFiles(named: ["Favicons"], in: $0) }
  }

  /// 各库的修改时间
  private static func signature(in roots: [URL]) -> [Date?] {
    files(in: roots).map(Browsers.modified)
  }

  /// Favicons 库里每个主机最大的一张图（纯查询，单测用假库）：先按主机本身，没有再试加 / 去掉 www.；
  /// http / https 两种开头都算。只看每种开头的前 4 条映射（同一网站的页面几乎都是同一个图标）
  static func lookup(_ hosts: [String], in database: Database) -> [String: Data] {
    let sql = """
      SELECT image_data FROM favicon_bitmaps WHERE id = (
        SELECT id FROM favicon_bitmaps WHERE icon_id IN (
          SELECT * FROM (SELECT icon_id FROM icon_mapping WHERE page_url >= ?1 AND page_url < ?2 LIMIT 4)
          UNION SELECT * FROM (SELECT icon_id FROM icon_mapping WHERE page_url >= ?3 AND page_url < ?4 LIMIT 4))
        ORDER BY width DESC LIMIT 1)
      """
    var result: [String: Data] = [:]
    for host in hosts {
      let other = host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host
      for candidate in [host, other] {
        // 「https://主机/」到「https://主机0」（'0' 紧跟在 '/' 后面）：这个主机下的全部页面
        let ranges = ["https://", "http://"].flatMap {
          [$0 + candidate + "/", $0 + candidate + "0"]
        }
        if let data = (try? database.query(sql, ranges) { $0.blob(0) })?.first ?? nil,
          !data.isEmpty
        {
          result[host] = data
          break
        }
      }
    }
    return result
  }

  /// 网址的主机（小写）；不是 http(s) 的（maps:、系统设置、路径）没有
  static func host(of url: String) -> String? {
    guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased()) else {
      return nil
    }
    return url.host(percentEncoded: false)?.lowercased()
  }
}

/// 网站图标：有就是白底方块里的图标，没有就是传进来的家族色块（并报上主机名去查）
struct SiteIcon: View {
  let host: String
  let fallback: KindTile
  /// 书签开关（开着的浏览器 id）：开关一变行就重画（设置页里网页搜索列表和开关同页）
  @AppStorage(Prefs.launcherBrowserBookmarks) private var bookmarkIDs = Prefs.defaultBookmarkIDs

  var body: some View {
    if let image = SiteIcons.shared.icon(for: host, local: Browsers.readsFavicons(bookmarkIDs)) {
      SiteIconTile(image: image, size: fallback.size)
    } else {
      fallback.task(id: host) { SiteIcons.shared.request(host) }
    }
  }
}

/// 白底方块 + 发丝线（同 ServiceTile）：网站图标多是透明底的深色字形，直接放在深色面板上会看不清
struct SiteIconTile: View {
  let image: NSImage
  var size: CGFloat = 24

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(size), style: .continuous)
    Image(nsImage: image)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .padding(size * 0.14)
      .frame(width: size, height: size)
      .background(Color.white)
      .clipShape(shape)
      .overlay(shape.hairlineBorder())
      .accessibilityHidden(true)
  }
}
