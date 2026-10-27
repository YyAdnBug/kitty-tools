// 程序坞预览（第九族）的纯函数：两张窗口表怎么并、编号怎么配、坐标换算、缩略图尺寸、全透明判断、缩略图缓存（新鲜的不再截）、
// 「当 key」事件的字节；关掉功能时面板放掉（只建不显示）。

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
    func window(_ id: CGWindowID) -> DockWindow {
      DockWindow(id: id, title: "文稿", state: .shown, size: CGSize(width: 800, height: 600))
    }
    let box = CGSize(width: 520, height: 280)
    for id in CGWindowID(1)...25 { shots.remember(image, for: window(id), box: box) }
    shots.remember(image, for: window(10), box: box)  // 已经在里面的换图不挪位置、不多占
    #expect((1...5).allSatisfy { shots.cached(CGWindowID($0)) == nil })
    #expect((6...25).allSatisfy { shots.cached(CGWindowID($0)) != nil })
    shots.clear()
    #expect(shots.cached(25) == nil)
  }

  /// 来回划过同一个 App（第三轮体检 P5）：2 秒内截过、标题大小没变、框不比上次大的直接用，不再截
  @Test func freshShotIsReusedForAFewSeconds() throws {
    let context = try #require(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
    let image = try #require(context.makeImage())
    let shots = WindowShots()
    let window = DockWindow(
      id: 7, title: "文稿", state: .shown, size: CGSize(width: 800, height: 600))
    let box = CGSize(width: 520, height: 280)
    shots.remember(image, for: window, box: box, at: 100)
    #expect(shots.fresh(window, maxPixels: box, now: 101.9) === image)
    #expect(shots.fresh(window, maxPixels: CGSize(width: 260, height: 140), now: 101) === image)
    #expect(
      shots.fresh(window, maxPixels: CGSize(width: 1040, height: 280), now: 101) == nil, "框变大了")
    #expect(shots.fresh(window, maxPixels: box, now: 100 + WindowShots.freshness) == nil, "过时了")
    let renamed = DockWindow(id: 7, title: "文稿 2", state: .shown, size: window.size)
    let resized = DockWindow(
      id: 7, title: "文稿", state: .shown, size: CGSize(width: 900, height: 600))
    #expect(shots.fresh(renamed, maxPixels: box, now: 101) == nil)
    #expect(shots.fresh(resized, maxPixels: box, now: 101) == nil)
    #expect(shots.cached(7) === image, "不新鲜的照样先顶上")
  }

  /// 关掉程序坞预览（R10）：弹过的面板跟着放掉，不留到退出
  @Test func stopReleasesThePanel() {
    let preview = DockPreview()
    weak var panel: NSPanel?
    autoreleasepool { panel = preview.makePanel() }
    #expect(panel != nil)
    autoreleasepool { preview.stop() }
    #expect(panel == nil)
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

  // MARK: 面板的排法（DockPreviewLayout）

  private let page = CGSize(width: 1600, height: 1000)

  @Test func thumbKeepsRatioWithinWidthBounds() {
    #expect(DockPreviewLayout.thumb(for: page, height: 140) == CGSize(width: 224, height: 140))
    #expect(
      DockPreviewLayout.thumb(for: CGSize(width: 3000, height: 600), height: 140).width == 260,
      "很宽的窗口夹到 260")
    #expect(
      DockPreviewLayout.thumb(for: CGSize(width: 300, height: 1200), height: 140).width == 80,
      "很瘦的夹到 80")
    #expect(
      DockPreviewLayout.thumb(for: CGSize(width: 3000, height: 600), height: 90).width == 167,
      "缩小时上下限跟着等比缩")
  }

  @Test func planFitsInOneRowAtFullSize() {
    let plan = DockPreviewLayout.plan(
      [page, CGSize(width: 800, height: 800)], edge: .bottom, along: 1500, across: 800)
    #expect(plan.thumbs == [CGSize(width: 224, height: 140), CGSize(width: 140, height: 140)])
    #expect(plan.lines == [0..<2])
    // 两张卡：(224 + 12) + (140 + 12) + 间距 4；高 140 + 4 + 15 + 12；再加面板四周 10、顶上一行 26
    #expect(plan.content == CGSize(width: 392, height: 171))
    #expect(plan.panel == CGSize(width: 412, height: 217))
    let compact = DockPreviewLayout.plan(
      [page], edge: .bottom, along: 1500, across: 800, compact: true)
    #expect(compact.thumbs == [DockPreviewLayout.compactThumb], "没有屏幕录制授权：图标位，不按窗口比例")
    #expect(
      compact.panel == CGSize(width: 172, height: 107 + 26 + 20 + DockPreviewLayout.noteHeight))
  }

  @Test func planShrinksBeforeWrapping() {
    // 一排 6 张放进 1200：缩到高 113（宽 181）正好放下（1198），再高一点就放不下
    let plan = DockPreviewLayout.plan(
      Array(repeating: page, count: 6), edge: .bottom, along: 1200, across: 800)
    #expect(plan.thumbs[0] == CGSize(width: 181, height: 113))
    #expect(plan.lines == [0..<6])
    #expect(plan.panel.width == 1198)
  }

  @Test func planWrapsIntoLinesAndDropsWhatDoesNotFit() {
    // 缩到下限 90 还放不下：每排 7 张（156 × 7 + 4 × 6 = 1116 ≤ 1180），20 张排 3 排
    let many = Array(repeating: page, count: 20)
    let plan = DockPreviewLayout.plan(many, edge: .bottom, along: 1200, across: 900)
    #expect(plan.thumbs.count == 20 && plan.thumbs[0] == CGSize(width: 144, height: 90))
    #expect(plan.lines == [0..<7, 7..<14, 14..<20])
    #expect(plan.content == CGSize(width: 1116, height: 121 * 3 + 8))
    #expect(plan.panel == CGSize(width: 1136, height: 371 + 26 + 20))
    // 往屏幕里只放得下两排：第三排那 6 扇不列
    let short = DockPreviewLayout.plan(many, edge: .bottom, along: 1200, across: 300)
    #expect(short.lines == [0..<7, 7..<14])
    #expect(short.thumbs.count == 14)
    #expect(short.panel.height <= 300)
    // 一张都放不下也自己占一排，不会死循环
    let narrow = DockPreviewLayout.plan(
      [page, page], edge: .bottom, along: 50, across: 900)
    #expect(narrow.lines == [0..<1, 1..<2])
  }

  @Test func sideDockStacksVerticallyAndWrapsIntoColumns() {
    let plan = DockPreviewLayout.plan(
      [page, CGSize(width: 800, height: 800)], edge: .left, along: 900, across: 600)
    #expect(plan.lines == [0..<2])
    #expect(plan.content == CGSize(width: 236, height: 171 * 2 + 4))
    #expect(plan.panel == CGSize(width: 256, height: 392), "两张卡 346 + 顶上一行 26 + 上下 20")
    let columns = DockPreviewLayout.plan(
      Array(repeating: page, count: 6), edge: .left, along: 500, across: 1000)
    #expect(columns.lines == [0..<3, 3..<6], "竖着放不下：每列 3 张，往屏幕里排两列")
    #expect(columns.content == CGSize(width: 156 * 2 + 4, height: 121 * 3 + 8))
    #expect(columns.panel == CGSize(width: 336, height: 371 + 26 + 20))
  }

  @Test func panelIsAtLeastAsWideAsTheDockLabel() {
    // 「DeepSeek Harness」14 点字约 123 点宽，提示气泡约 149，面板再各多 4 点
    let label = DockPreviewLayout.labelWidth("DeepSeek Harness")
    #expect(label >= 155 && label <= 162)
    let narrow = DockPreviewLayout.plan(
      [CGSize(width: 300, height: 1200)], edge: .bottom, along: 1500, across: 800,
      minimumWidth: 300)
    #expect(narrow.panel.width == 300, "一张瘦窗口的卡片只有 112 宽：撑到提示那么宽")
    #expect(narrow.content.width == 92, "卡片本身不变，在面板里居中")
    let wide = DockPreviewLayout.plan(
      [page, page], edge: .bottom, along: 1500, across: 800, minimumWidth: 300)
    #expect(wide.panel.width == 496, "比提示宽的不动（236 × 2 + 4 + 20）")
    let cramped = DockPreviewLayout.plan(
      [CGSize(width: 300, height: 1200)], edge: .bottom, along: 200, across: 800,
      minimumWidth: 300)
    #expect(cramped.panel.width == 200, "不超过这一边能用的长度")
  }

  @Test func originHugsTheIconAndStaysOnScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)
    let panel = CGSize(width: 400, height: 200)
    let item = CGRect(x: 700, y: 4, width: 60, height: 60)
    #expect(
      DockPreviewLayout.origin(
        panel: panel, item: item, edge: .bottom, screen: screen, visible: visible)
        == CGPoint(x: 530, y: 58), "压进图标框 6 点（盖住程序坞的名字提示）")
    let nearLeft = CGRect(x: 10, y: 4, width: 60, height: 60)
    #expect(
      DockPreviewLayout.origin(
        panel: panel, item: nearLeft, edge: .bottom, screen: screen, visible: visible
      ).x == 8)
    let side = CGRect(x: 0, y: 900, width: 60, height: 60)
    #expect(
      DockPreviewLayout.origin(
        panel: panel, item: side, edge: .left, screen: screen, visible: visible)
        == CGPoint(x: 54, y: 741))
    let right = CGRect(x: 1452, y: 400, width: 60, height: 60)
    #expect(
      DockPreviewLayout.origin(
        panel: panel, item: right, edge: .right, screen: screen, visible: visible)
        == CGPoint(x: 1058, y: 330))
  }

  @Test func roomAlongAndAcross() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)
    let bottom = DockPreviewLayout.room(
      item: CGRect(x: 700, y: 4, width: 60, height: 60), edge: .bottom, screen: screen,
      visible: visible)
    #expect(bottom.along == 1496 && bottom.across == 883)
    let left = DockPreviewLayout.room(
      item: CGRect(x: 0, y: 400, width: 60, height: 60), edge: .left, screen: screen,
      visible: visible)
    #expect(left.along == 863 && left.across == 1450)
    let right = DockPreviewLayout.room(
      item: CGRect(x: 1452, y: 400, width: 60, height: 60), edge: .right, screen: screen,
      visible: visible)
    #expect(right.across == 1450, "图标左沿 1452 + 压进去的 6 − 屏幕边 8")
  }

  @Test func screenIsTheOneHoldingTheIconOrTheNearest() {
    let screens = [
      CGRect(x: 0, y: 0, width: 1512, height: 982),
      CGRect(x: 1512, y: 0, width: 1920, height: 1080),
    ]
    #expect(
      DockPreviewLayout.screenIndex(for: CGRect(x: 2000, y: 4, width: 60, height: 60), in: screens)
        == 1)
    #expect(
      DockPreviewLayout.screenIndex(
        for: CGRect(x: 2000, y: -70, width: 60, height: 60), in: screens)
        == 1, "自动隐藏的程序坞还在屏幕外：挑最近的，不退回主屏")
    #expect(
      DockPreviewLayout.screenIndex(for: CGRect(x: -90, y: 400, width: 60, height: 60), in: screens)
        == 0)
    #expect(DockPreviewLayout.screenIndex(for: .zero, in: []) == nil)
  }

  @Test func keepsOpenOverPanelIconAndTheGapBetween() {
    let panel = CGRect(x: 530, y: 90, width: 400, height: 200)
    let item = CGRect(x: 700, y: 4, width: 60, height: 60)
    func keeps(_ x: CGFloat, _ y: CGFloat) -> Bool {
      DockPreviewLayout.keepsOpen(
        mouse: CGPoint(x: x, y: y), panel: panel, item: item, edge: .bottom)
    }
    #expect(keeps(600, 150), "面板上")
    #expect(keeps(730, 30), "图标上")
    #expect(keeps(730, 75), "图标和面板之间那道缝")
    #expect(!keeps(600, 75), "缝的两边不算")
    #expect(!keeps(100, 500), "桌面上")
    // 顺着程序坞划到旁边的图标、还在等着换过去：那个图标上也算在附近，面板不收
    let next = CGRect(x: 770, y: 4, width: 60, height: 60)
    #expect(
      DockPreviewLayout.keepsOpen(
        mouse: CGPoint(x: 800, y: 30), panel: panel, item: item, edge: .bottom, pending: next))
    #expect(
      !DockPreviewLayout.keepsOpen(
        mouse: CGPoint(x: 800, y: 30), panel: panel, item: item, edge: .bottom))
    let sidePanel = CGRect(x: 90, y: 300, width: 300, height: 400)
    let sideItem = CGRect(x: 0, y: 450, width: 60, height: 60)
    #expect(
      DockPreviewLayout.keepsOpen(
        mouse: CGPoint(x: 75, y: 480), panel: sidePanel, item: sideItem, edge: .left))
    #expect(
      !DockPreviewLayout.keepsOpen(
        mouse: CGPoint(x: 75, y: 300), panel: sidePanel, item: sideItem, edge: .left))
  }

  @Test func lingerHidesOnlyAfterStayingAway() {
    var linger = DockPreviewLayout.Linger()
    // 依次喂（在不在附近，此刻），看每一步该不该收
    let steps: [(Bool, TimeInterval)] = [
      (false, 0), (false, 0.2), (false, 0.31), (true, 0.4), (false, 0.5), (false, 0.79),
      (false, 0.81),
    ]
    let hides = steps.map { linger.update(inside: $0.0, now: $0.1) }
    #expect(hides == [false, false, true, false, false, false, true], "回来就重新算")
  }

  @Test func missingInterfacesExplainedInPlainWords() {
    #expect(
      WindowServer.consequences(of: [
        "CGSCopySpacesForWindows", "SLPSPostEventRecordTo", "_SLPSSetFrontProcessWithOptions",
      ]) == ["别的桌面上的窗口不列", "点缩略图可能切不到那一扇"])
    #expect(WindowServer.consequences(of: []).isEmpty)
  }

  @Test func edgeFromDockOrientation() {
    #expect(DockPreviewLayout.Edge(orientation: "left") == .left)
    #expect(DockPreviewLayout.Edge(orientation: "right") == .right)
    #expect(DockPreviewLayout.Edge(orientation: "bottom") == .bottom)
    #expect(DockPreviewLayout.Edge(orientation: nil) == .bottom)
  }
}
