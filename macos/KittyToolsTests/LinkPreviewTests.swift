import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct LinkPreviewTests {
  @Test func fetchesOnlyPublicHarmlessLinks() {
    let allowed = [
      "https://github.com/apple/swift", "http://sspai.com/post/73145",
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=x", "https://8.8.8.8/",
      "https://developer.apple.com/documentation/appkit",
    ]
    for link in allowed { #expect(LinkPreview.isFetchable(URL(string: link)!), "\(link)") }
    let blocked = [
      // 不是网页、本机、内网
      "ftp://example.com/a", "file:///etc/hosts", "http://localhost:3000", "http://localhost.:80",
      "http://nas/", "http://printer.local/", "https://jira.corp/browse/A-1",
      "http://192.168.1.1/", "http://10.0.0.8/", "http://172.20.1.1/", "http://127.0.0.1:8080/",
      "http://169.254.1.1/", "http://100.64.0.1/", "http://[::1]/", "http://[fd00::1]/",
      "http://0x7f.0.0.1/", "http://0177.0.0.1/",
      // 带账号密码、一次性令牌（预取会把它们用掉）
      "https://user:pass@example.com/", "https://app.example.com/auth/callback?code=abc",
      "https://example.com/login?next=/", "https://example.com/reset-password/abc",
      "https://example.com/unsubscribe/42", "https://example.com/?token=abc",
      "https://example.com/a/Xk29fJ3kLm9qP0zT7vB2nH6wR4yU8sE1",
    ]
    for link in blocked { #expect(!LinkPreview.isFetchable(URL(string: link)!), "\(link)") }
    // 头图 / 图标只查公网：CDN 的长哈希文件名、签名参数照取（取图片用不掉谁的令牌），内网照拦
    let github = URL(
      string:
        "https://opengraph.githubassets.com/7b3088f1e7c031be5fc601b914e7ee7da958299184067e56e2f7ba1f7f91e3a0/swiftlang/swift"
    )!
    #expect(!LinkPreview.isFetchable(github) && LinkPreview.isPublicHTTP(github))
    #expect(LinkPreview.isPublicHTTP(URL(string: "https://cdn.example.com/a.png?Signature=x")!))
    #expect(!LinkPreview.isPublicHTTP(URL(string: "http://192.168.1.1/a.png")!))
  }

  @Test func parsesOpenGraphAndIcons() throws {
    let base = try #require(URL(string: "https://example.com/posts/1"))
    let html = """
      <html><head>
      <meta charset="utf-8"><title> 备用 标题 </title>
      <meta property="og:title" content="Tom &amp; Jerry&#39;s &#x4F60;好">
      <meta name='og:site_name' content='示例站'>
      <meta content="/img/cover.png" property="og:image">
      <link rel="icon" href="/favicon.svg" type="image/svg+xml">
      <link rel="shortcut icon" href="/favicon-32.png">
      <link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">
      </head><body><meta property="og:image" content="/late.png"></body></html>
      """
    let metadata = LinkPreview.parse(html: html, base: base)
    #expect(metadata.title == "Tom & Jerry's 你好")
    #expect(metadata.siteName == "示例站")
    #expect(metadata.image?.absoluteString == "https://example.com/img/cover.png")
    // apple-touch-icon 优先，SVG 跳过
    #expect(
      metadata.icons.map(\.absoluteString) == [
        "https://cdn.example.com/touch.png", "https://example.com/favicon-32.png",
      ])
    // 同一种里 sizes 声明得大的在前（没写的排在声明了的后面），其余按网页里的顺序（第 13 批，官网图标要大图）
    let sized = LinkPreview.parse(
      html: """
        <link rel="icon" href="/a.ico"><link rel="icon" sizes="32x32" href="/32.png">
        <link rel="icon" sizes="16x16 192x192" href="/192.png">
        <link rel="apple-touch-icon" sizes="76x76" href="/76.png"><link rel="apple-touch-icon" sizes="180x180" href="/180.png">
        """, base: base)
    #expect(
      sized.icons.map(\.path) == ["/180.png", "/76.png", "/192.png", "/32.png", "/a.ico"])
    // 没有 og 标签时用 <title>
    let plain = LinkPreview.parse(html: "<title>\n  Hello\n  World </title>", base: base)
    #expect(plain.title == "Hello World" && plain.image == nil && plain.icons.isEmpty)
  }

  @Test func decodesDeclaredCharset() {
    let gbk = CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    let data = "<meta charset=\"gbk\"><title>中文标题</title>".data(
      using: String.Encoding(rawValue: gbk))!
    #expect(LinkPreview.decode(data, charset: nil).contains("中文标题"))
    #expect(LinkPreview.decode(Data("<title>é</title>".utf8), charset: "utf-8").contains("é"))
    // 标 gb2312 但混着 GBK 才有的字（喆）：按 GB18030 解；收到上限截在半个字上：只解 </head 之前，后面的半个字不影响
    let page = "<meta charset=\"gb2312\"><title>张喆的主页</title></head><body>正文".data(
      using: String.Encoding(rawValue: gbk))!
    #expect(LinkPreview.decode(page.dropLast(1), charset: nil).contains("张喆的主页"))
    #expect(
      LinkPreview.parse(
        html: "<title>A &mdash; B &raquo; C&hellip;</title>", base: URL(string: "https://a.com")!
      )
      .title == "A — B » C…")
  }

  @Test func hostOfLinkText() {
    #expect(LinkPreview.host(ofLink: " https://GitHub.com/a ") == "github.com")
    #expect(LinkPreview.host(ofLink: "sspai.com/post/1") == "sspai.com")
  }

  /// 空闲回收（dropHeroes）：头图的缩略图丢掉、字节留着，标题这些不动；再显示时照字节重解（restoreHero，不联网）。
  /// 没留字节的条目不丢（丢了回不来）
  @Test func heroesDropWhenIdleAndComeBackFromBytes() async throws {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let preview = LinkPreview()
    let kept = try #require(URL(string: "https://example.com/a"))
    let bare = try #require(URL(string: "https://example.com/b"))
    var entry = LinkPreview.Entry()
    entry.metadata.title = "标题"
    entry.image = NSImage(size: NSSize(width: 1, height: 1))
    entry.imageData = png
    entry.isLoading = false
    preview.store(entry, for: kept)
    entry.imageData = nil
    preview.store(entry, for: bare)
    #expect(preview.entry(for: kept)?.isHeroDropped == false)

    preview.dropHeroes()
    #expect(
      preview.entry(for: kept)?.image == nil && preview.entry(for: kept)?.isHeroDropped == true)
    #expect(preview.entry(for: kept)?.metadata.title == "标题")
    #expect(preview.entry(for: bare)?.image != nil)

    await preview.restoreHero(for: kept)
    let restored = try #require(preview.entry(for: kept)?.image)
    #expect(restored.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 40)
    #expect(preview.entry(for: kept)?.isHeroDropped == false)
    // 没丢的再来一次不换图
    await preview.restoreHero(for: kept)
    #expect(preview.entry(for: kept)?.image === restored)
  }

  /// 接线：还挂着的链接卡（收起的面板里第一条正好是链接时就是这样）被空闲回收丢了头图，自己照字节重解回来，
  /// 不用等选中换一条。屏外窗口、临时偏好域；网址是本机的（isFetchable 不放行），卡片自己那条取预览的路不会联网
  @Test func mountedCardRestoresItsDroppedHero() async throws {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let url = try #require(URL(string: "http://localhost/hero-\(UUID().uuidString)"))
    var entry = LinkPreview.Entry()
    entry.image = NSImage(size: NSSize(width: 1, height: 1))
    entry.imageData = bitmap.representation(using: .png, properties: [:])
    entry.isLoading = false
    LinkPreview.shared.store(entry, for: url)
    let suite = "kitty-link-test-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: suite))
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 120),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: LinkCard(url: url, text: url.absoluteString, compact: true)
        .defaultAppStorage(prefs))
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      prefs.removePersistentDomain(forName: suite)
    }
    // 先让卡片挂上（这时没什么要重解的），再丢
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(LinkPreview.shared.entry(for: url)?.image != nil)

    LinkPreview.shared.dropHeroes()
    #expect(LinkPreview.shared.entry(for: url)?.isHeroDropped == true)
    // 按轮数等、不按时间：全量跑时别的测试会把主线程占上几秒，按时间算的期限会在视图有机会更新之前就到
    for _ in 0..<200 where LinkPreview.shared.entry(for: url)?.image == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(LinkPreview.shared.entry(for: url)?.isHeroDropped == false)
  }

  /// 联网冒烟（TEST_RUNNER_KITTY_LIVE_LINK=1 才跑）：真取 GitHub 仓库页的标题、头图（CDN 长哈希路径）和网站图标
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_LINK"] != nil))
  func liveFetchesGitHub() async throws {
    let url = try #require(URL(string: "https://github.com/apple/swift"))
    let clock = ContinuousClock()
    let elapsed = await clock.measure { await LinkPreview.shared.load(url) }
    let entry = try #require(LinkPreview.shared.entry(for: url))
    #expect(entry.metadata.title?.localizedCaseInsensitiveContains("swift") == true)
    #expect(entry.image != nil && entry.icon != nil && !entry.isLoading, "\(elapsed)")
    // 头图的字节留着（空闲回收之后照它重解）
    #expect(entry.imageData?.isEmpty == false)
    print("GitHub 预览用时", elapsed)
  }
}
