import Foundation
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

  /// 联网冒烟（TEST_RUNNER_KITTY_LIVE_LINK=1 才跑）：真取 GitHub 仓库页的标题、头图（CDN 长哈希路径）和网站图标
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_LINK"] != nil))
  func liveFetchesGitHub() async throws {
    let url = try #require(URL(string: "https://github.com/apple/swift"))
    let clock = ContinuousClock()
    let elapsed = await clock.measure { await LinkPreview.shared.load(url) }
    let entry = try #require(LinkPreview.shared.entry(for: url))
    #expect(entry.metadata.title?.localizedCaseInsensitiveContains("swift") == true)
    #expect(entry.image != nil && entry.icon != nil && !entry.isLoading, "\(elapsed)")
    print("GitHub 预览用时", elapsed)
  }
}
