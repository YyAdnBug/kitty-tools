// 程序坞预览（第九族）的纯函数：两张窗口表怎么并、编号怎么配、坐标换算、缩略图尺寸、全透明判断、「当 key」事件的字节。

import AppKit
import ApplicationServices
import Testing

@testable import KittyTools

@MainActor
struct DockPreviewTests {
  private typealias AXEntry = DockWindows.AXEntry
  private typealias ServerEntry = DockWindows.ServerEntry

  private func ax(
    _ id: CGWindowID?, _ title: String = "窗口", subrole: String = kAXStandardWindowSubrole,
    minimized: Bool = false, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
  ) -> AXEntry {
    AXEntry(id: id, title: title, subrole: subrole, minimized: minimized, frame: frame)
  }

  private func server(
    _ id: CGWindowID, _ title: String = "窗口", layer: Int = 0, alpha: Double = 1,
    frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
    place: WindowServer.Place? = .other
  ) -> ServerEntry {
    ServerEntry(id: id, title: title, layer: layer, alpha: alpha, frame: frame, place: place)
  }

  @Test func mergeKeepsNormalWindowsInOpeningOrderMinimizedLast() {
    let windows = DockWindows.merge(
      ax: [
        ax(30, "三", minimized: true),
        ax(20, "二"),
        ax(10, "一"),
        ax(40, "面板", subrole: kAXFloatingWindowSubrole),
        ax(50, "太小", frame: CGRect(x: 0, y: 0, width: 300, height: 90)),
        ax(nil, "没编号"),
        ax(60, "对话框", subrole: kAXDialogSubrole),
      ],
      server: [], appHidden: false)
    #expect(windows.map(\.id) == [10, 20, 60, 30])
    #expect(windows.map(\.state) == [.shown, .shown, .shown, .minimized])
    #expect(windows.first?.size == CGSize(width: 800, height: 600))
  }

  @Test func mergeMarksHiddenAppButKeepsMinimized() {
    let windows = DockWindows.merge(
      ax: [ax(1), ax(2, minimized: true)], server: [], appHidden: true)
    #expect(windows.map(\.state) == [.hidden, .minimized])
  }

  @Test func mergeAddsOnlyWindowsOnOtherDesktops() {
    let windows = DockWindows.merge(
      ax: [ax(5)],
      server: [
        server(5),  // 辅助功能里已经有了
        server(7, "别的桌面"),
        server(8, "关了还留着", place: .nowhere),
        server(9, "当前桌面上的小东西", place: .current),
        server(11, "菜单", layer: 101),
        server(12, "透明", alpha: 0),
        server(13, "太小", frame: CGRect(x: 0, y: 0, width: 50, height: 50)),
        server(14, "不知道在哪", place: nil),
        server(3, "更早打开的"),
      ],
      appHidden: false)
    #expect(windows.map(\.id) == [3, 5, 7])
    #expect(windows.map(\.state) == [.elsewhere, .shown, .elsewhere])
    #expect(windows.last?.title == "别的桌面")
  }

  @Test func resolveIDsMatchesByTitleAndFrameOnlyWhenUnique() {
    let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
    let other = CGRect(x: 300, y: 20, width: 800, height: 600)
    let ids = DockWindows.resolveIDs(
      [
        ax(99, "有编号", frame: frame),
        ax(nil, "文稿", frame: frame),
        ax(nil, "同名同位置", frame: other),
        ax(nil, "配不上", frame: frame),
        ax(nil, "被认走了", frame: frame),
      ],
      server: [
        server(1, "文稿", frame: frame.offsetBy(dx: 0.4, dy: 0)),
        server(2, "同名同位置", frame: other),
        server(3, "同名同位置", frame: other),
        server(4, "配不上", frame: frame.offsetBy(dx: 5, dy: 0)),
        server(99, "被认走了", frame: frame),
        server(6, "文稿", layer: 3, frame: frame),
      ])
    #expect(ids == [99, 1, nil, nil, nil])
  }

  @Test func axFrameFlipsToAppKitCoordinates() {
    let frame = DockWatcher.appKitFrame(
      origin: CGPoint(x: 100, y: 1050), size: CGSize(width: 60, height: 70), primaryHeight: 1117)
    #expect(frame == CGRect(x: 100, y: -3, width: 60, height: 70))
  }

  @Test func fittedNeverUpscalesAndKeepsRatio() {
    let box = CGSize(width: 520, height: 280)
    #expect(
      WindowShots.fitted(CGSize(width: 1710, height: 991), in: box)
        == CGSize(width: 483, height: 280))
    #expect(
      WindowShots.fitted(CGSize(width: 3000, height: 400), in: box)
        == CGSize(width: 520, height: 69))
    #expect(
      WindowShots.fitted(CGSize(width: 200, height: 100), in: box)
        == CGSize(width: 200, height: 100))
    #expect(
      WindowShots.fitted(CGSize(width: 100_000, height: 1), in: box)
        == CGSize(width: 520, height: 1))
    #expect(WindowShots.fitted(.zero, in: box) == .zero)
  }

  @Test func scaledShrinksAndBlankDetectsTransparency() throws {
    func image(width: Int, height: Int, opaque: Bool) throws -> CGImage {
      let context = try #require(
        CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
      if opaque {
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      }
      return try #require(context.makeImage())
    }
    let big = try image(width: 1600, height: 1000, opaque: true)
    let small = try #require(WindowShots.scaled(big, toFit: CGSize(width: 520, height: 280)))
    #expect(small.width == 448 && small.height == 280)
    #expect(!WindowShots.isBlank(small))
    #expect(WindowShots.isBlank(try image(width: 300, height: 200, opaque: false)))
    let gray = try #require(
      CGContext(
        data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
      )?.makeImage())
    let shrunk = try #require(
      WindowShots.scaled(gray, toFit: CGSize(width: 520, height: 280)), "灰度图也缩得了（换成 sRGB 画）")
    #expect(shrunk.width == 420 && shrunk.height == 280)
    let tiny = try image(width: 100, height: 50, opaque: true)
    #expect(WindowShots.scaled(tiny, toFit: CGSize(width: 520, height: 280)) === tiny)
  }

  @Test func cacheKeepsTheNewestTwenty() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
    let image = try #require(context.makeImage())
    let shots = WindowShots()
    for id in CGWindowID(1)...25 { shots.remember(image, for: id) }
    shots.remember(image, for: 10)  // 已经在里面的换图不挪位置、不多占
    #expect((1...5).allSatisfy { shots.cached(CGWindowID($0)) == nil })
    #expect((6...25).allSatisfy { shots.cached(CGWindowID($0)) != nil })
    shots.clear()
    #expect(shots.cached(25) == nil)
  }

  @Test func keyWindowEventLayout() {
    let event = WindowServer.keyWindowEvent(0x0102_0304)
    #expect(event.count == 0x100, "缓冲区比记录多出一截、全清零：系统编码时会读过记录末尾")
    #expect(event[0x04] == 0xf8)
    #expect(event[0x08] == 0x01, "只发按下：一对按下 + 松开会在目标 App 里点出一次真的点击")
    let point = event[0x20..<0x30].withUnsafeBytes {
      (
        $0.loadUnaligned(fromByteOffset: 0, as: Double.self),
        $0.loadUnaligned(fromByteOffset: 8, as: Double.self)
      )
    }
    #expect(point == (300_000, 300_000), "点在窗口右下方很远：不填 NaN，也不贴着窗口边")
    #expect(event[0x3a] == 0x10)
    #expect(Array(event[0x3c..<0x40]) == [0x04, 0x03, 0x02, 0x01])
    let set: Set<Int> = Set([0x04, 0x08, 0x3a]).union(0x20..<0x30).union(0x3c..<0x40)
    #expect(event.indices.filter { !set.contains($0) }.allSatisfy { event[$0] == 0 })
  }

  @Test func placeFromSpaceCounts() {
    #expect(WindowServer.place(current: 1, all: 1) == .current)
    #expect(WindowServer.place(current: 0, all: 1) == .other)
    #expect(WindowServer.place(current: 0, all: 0) == .nowhere)
  }

  @Test func mergeDropsDuplicateIDsAndSheetsOnOtherDesktops() {
    let document = CGRect(x: 100, y: 100, width: 900, height: 700)
    let windows = DockWindows.merge(
      ax: [ax(4, "一"), ax(4, "同号的另一扇")],
      server: [
        server(20, "文稿", frame: document),
        server(21, "", frame: CGRect(x: 300, y: 130, width: 500, height: 300)),  // 贴在文稿上的表单
        server(22, "小窗口", frame: CGRect(x: 300, y: 130, width: 500, height: 300)),
        server(23, "", frame: CGRect(x: 2000, y: 100, width: 400, height: 300)),  // 没标题、不套在谁里面
      ],
      appHidden: false)
    #expect(windows.map(\.id) == [4, 20, 22, 23])
    #expect(windows.first?.title == "一")
  }
}
