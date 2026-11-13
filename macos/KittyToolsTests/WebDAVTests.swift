// WebDAV 客户端的纯函数（Storage/WebDAV.swift，issue #18）：设置里填的地址拼成文件夹网址、几家服务器回的 multistatus
// （前缀不同、href 是路径还是整个网址、中文名、404 的那组属性不算）认出自己和子项、HTTP 日期、状态码对应的出错。

import Foundation
import Testing

@testable import KittyTools

struct WebDAVTests {
  /// 地址 + 文件夹：补上结尾的 /、中文和空格编码、只认 http(s)、地址里的账号和查询串扔掉
  @Test func folderURL() {
    #expect(
      WebDAV.folder(address: "https://dav.example.com/dav", path: "Kitty Tools 同步")?.absoluteString
        == "https://dav.example.com/dav/Kitty%20Tools%20%E5%90%8C%E6%AD%A5/")
    #expect(
      WebDAV.folder(address: " https://dav.example.com/dav/ ", path: "/a//b/")?.absoluteString
        == "https://dav.example.com/dav/a/b/")
    #expect(
      WebDAV.folder(address: "HTTP://u:p@nas.local:5005/?x=1#y", path: "")?.absoluteString
        == "http://nas.local:5005/")
    #expect(WebDAV.folder(address: "ftp://example.com", path: "a") == nil)
    #expect(WebDAV.folder(address: "dav.example.com", path: "a") == nil)
    #expect(WebDAV.folder(address: "", path: "a") == nil)
  }

  /// 子项的网址：一段一段编码，文件夹带 /
  @Test func itemURL() throws {
    let dav = WebDAV(
      account: .init(
        folder: try #require(URL(string: "https://h/dav/%E5%90%8C/")), user: "u", password: "p"))
    #expect(
      dav.url(["devices", "A-1", "notes"], folder: true).absoluteString
        == "https://h/dav/%E5%90%8C/devices/A-1/notes/")
    #expect(
      dav.url(["images", "x y.png"]).absoluteString == "https://h/dav/%E5%90%8C/images/x%20y.png")
    #expect(dav.url([], folder: true).absoluteString == "https://h/dav/%E5%90%8C/")
  }

  /// 一种写法：前缀 D:、href 是编码过的绝对路径（自己那项在最前），文件夹靠 collection 认，404 那组里的属性不算
  @Test func parsesApacheStyle() throws {
    let xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
      <D:response xmlns:lp1="DAV:"><D:href>/dav/%E5%90%8C%E6%AD%A5/</D:href>
      <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      <D:response><D:href>/dav/%E5%90%8C%E6%AD%A5/kitty-notes-sync.json</D:href>
      <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>58</D:getcontentlength>
      <D:getlastmodified>Wed, 13 Nov 2026 03:30:46 GMT</D:getlastmodified>
      <D:getetag>"3a-5f2"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
      <D:propstat><D:prop><D:getetag>"假的"</D:getetag><D:getcontentlength>999</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
      <D:response><D:href>/dav/%E5%90%8C%E6%AD%A5/devices/</D:href>
      <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      </D:multistatus>
      """
    let items = try #require(parse(xml, folder: "https://h/dav/%E5%90%8C%E6%AD%A5/"))
    #expect(items.map(\.name) == ["kitty-notes-sync.json", "devices"])
    #expect(items[0].etag == "\"3a-5f2\"" && items[0].size == 58 && !items[0].isFolder)
    #expect(items[0].modified == Date(timeIntervalSince1970: 1_794_540_646))
    #expect(items[1].isFolder)
  }

  /// 另一种写法：小写 d: 前缀、属性带别的命名空间、href 是整个网址、自己那项的路径和请求的不一样（隔着改路径的代理）
  @Test func parsesAbsoluteHrefsBehindProxy() throws {
    let xml = """
      <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>https://h/remote.php/dav/files/u/%E5%90%8C%E6%AD%A5/</d:href>
      <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><oc:size>9</oc:size></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>https://h/remote.php/dav/files/u/%E5%90%8C%E6%AD%A5/images/</d:href>
      <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      </d:multistatus>
      """
    let items = try #require(parse(xml, folder: "https://h/dav/%E5%90%8C%E6%AD%A5/"))
    #expect(items.map(\.name) == ["images"] && items[0].isFolder)
  }

  /// 不是 multistatus（登录页、乱码）：解不出来
  @Test func rejectsGarbage() {
    #expect(parse("<html><body>登录", folder: "https://h/") == nil)
  }

  /// HTTP 日期：RFC 1123 那种，别的写法认不出来是 nil
  @Test func httpDate() {
    #expect(WebDAV.date("Thu, 01 Jan 1970 00:00:10 GMT") == Date(timeIntervalSince1970: 10))
    #expect(WebDAV.date("2026-11-13T03:30:46Z") == nil)
  }

  /// 状态码 → 出错：请求太多带上服务器说的等多久
  @Test func failures() throws {
    let url = try #require(URL(string: "https://h/"))
    func failure(_ code: Int, _ headers: [String: String] = [:]) throws -> WebDAV.Failure {
      WebDAV.failure(
        try #require(
          HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)))
    }
    #expect(try failure(503, ["Retry-After": "120"]) == .busy(retryAfter: 120))
    #expect(try failure(429) == .busy(retryAfter: nil))
    #expect(try failure(401) == .unauthorized)
    #expect(try failure(507) == .full)
    #expect(try failure(500) == .status(500))
    #expect(WebDAV.failure(URLError(.notConnectedToInternet)) == .offline("没联网"))
    #expect(WebDAV.failure(URLError(.serverCertificateUntrusted)).message.contains("证书"))
  }

  /// 走一遍真的解析（用 list 的那条路：解析 + 认出自己）
  private func parse(_ xml: String, folder: String) -> [WebDAV.Item]? {
    WebDAV.parseListing(Data(xml.utf8), of: URL(string: folder)!)
  }
}
