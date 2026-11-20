import AppKit
import Testing

@testable import KittyTools

// 第五轮体检 N1：单击窗口截下时的透明圆角 + 阴影（WindowShot）。不碰 ScreenCaptureKit：「单独截的那扇窗口」是这里画的
// 一张圆角图，截不到的是一个交回 nil 的任务。
@MainActor struct WindowShotTests {
  static let space = CGColorSpace(name: CGColorSpace.sRGB)!

  /// width × height 像素的图：fill 整块填色，radius > 0 时画成圆角矩形（四角透明）；band 是盖在中间一条半透明的（侧栏那种）
  static func image(
    width: Int, height: Int, fill: CGColor, radius: CGFloat = 0, band: CGColor? = nil
  ) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(fill)
    context.fillPath()
    if let band {
      context.clear(CGRect(x: width / 2 - 10, y: 0, width: 20, height: height))
      context.setFillColor(band)
      context.fill(CGRect(x: width / 2 - 10, y: 0, width: 20, height: height))
    }
    return context.makeImage()!
  }

  /// (x, y) 那个像素（y 从上往下数）的 RGBA，0–255（预乘）
  static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(
        image,
        in: CGRect(
          x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width),
          height: CGFloat(image.height)))
    }
    return bytes
  }

  static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
  static let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

  /// 冻结帧里那一块：200 × 100 像素的红，选区 100 × 50 点（每点 2 像素）
  static func capture(annotations: [Annotation] = []) -> RegionSelector.Capture {
    let frozen = image(width: 200, height: 100, fill: red)
    return RegionSelector.Capture(
      image: frozen, frame: CGRect(x: 10, y: 20, width: 100, height: 50), action: .copy,
      original: frozen, annotations: annotations)
  }

  // 量窗口的圆角（悬停 / 选中窗口的框照它画）：圆弧半径 20 像素的量出 20（±1），实心角 0，半透明的照样量得出，
  // 几乎透明、太小的量不出
  @Test func measuresCornerRadius() throws {
    let measured = try #require(
      WindowShot.cornerRadius(of: Self.image(width: 300, height: 200, fill: Self.green, radius: 20))
    )
    #expect(abs(measured - 20) < 1)
    let big = try #require(
      WindowShot.cornerRadius(of: Self.image(width: 600, height: 400, fill: Self.red, radius: 33)))
    #expect(abs(big - 33) < 1)
    #expect(WindowShot.cornerRadius(of: Self.image(width: 300, height: 200, fill: Self.green)) == 0)
    let translucent = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.4)
    let faint = try #require(
      WindowShot.cornerRadius(
        of: Self.image(width: 300, height: 200, fill: translucent, radius: 20)))
    #expect(abs(faint - 20) < 1)
    let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
    #expect(WindowShot.cornerRadius(of: Self.image(width: 300, height: 200, fill: clear)) == nil)
    #expect(WindowShot.cornerRadius(of: Self.image(width: 6, height: 6, fill: Self.green)) == nil)
  }

  // 换上透明圆角带阴影的那一张：画面是冻结帧（红），单独截的（绿）只借形状；四周留出阴影的边、frame 跟着往外扩
  // （像素 / 点不变），四角透明
  @Test func composesTransparentCornersAndShadow() throws {
    let live = Self.image(width: 200, height: 100, fill: Self.green, radius: 20)
    let shot = try #require(WindowShot.compose(Self.capture(), window: live))
    let pad = WindowShot.padding(scale: 2)
    #expect(shot.image.width == 200 + Int(pad.left + pad.right))
    #expect(shot.image.height == 100 + Int(pad.top + pad.bottom))
    #expect(shot.scale == 2)
    #expect(shot.frame.minX == 10 - WindowShot.margins.left)
    #expect(shot.frame.minY == 20 - WindowShot.margins.bottom)
    #expect(shot.window == nil && shot.isWindow)
    // 窗口正中：框选时看到的（冻结帧），不是单独截的
    #expect(Self.pixel(shot.image, Int(pad.left) + 100, Int(pad.top) + 50) == [255, 0, 0, 255])
    // 窗口矩形的左上角在圆角外面：透明（只剩一点阴影），不是冻结帧里的红
    let corner = Self.pixel(shot.image, Int(pad.left), Int(pad.top))
    #expect(corner[3] < 160)
    #expect(corner[0] < 40)
    // 整张图的左上角在阴影外面：全透明；正下方有阴影
    #expect(Self.pixel(shot.image, 0, 0)[3] < 8)
    let below = Self.pixel(shot.image, Int(pad.left) + 100, Int(pad.top) + 100 + 30)
    #expect(below[3] > 20 && below[0] < 40)
    // 历史存的原图也是带阴影的那张；没画标注时就是同一张
    #expect(shot.original === shot.image)
  }

  // 冻结时别的 App 的窗口挡住的那几块：换成单独截的（窗口自己的画面），别处照旧是冻结帧
  @Test func coveredPartsUseTheWindowItself() throws {
    let live = Self.image(width: 200, height: 100, fill: Self.green, radius: 20)
    let covered = [CGRect(x: 50, y: 0, width: 50, height: 50)]  // 点，相对选区左下角：右半边
    let shot = try #require(WindowShot.compose(Self.capture(), window: live, covered: covered))
    let pad = WindowShot.padding(scale: 2)
    #expect(Self.pixel(shot.image, Int(pad.left) + 150, Int(pad.top) + 50) == [0, 255, 0, 255])
    #expect(Self.pixel(shot.image, Int(pad.left) + 40, Int(pad.top) + 50) == [255, 0, 0, 255])
    // 画了打码：挡住的那几块也不换（码是按冻结那一刻看到的摆的）；标注挪进留边
    let mosaic = Annotation(shape: .mosaic(CGRect(x: 10, y: 10, width: 20, height: 10)))
    let redacted = try #require(
      WindowShot.compose(Self.capture(annotations: [mosaic]), window: live, covered: covered))
    #expect(Self.pixel(redacted.image, Int(pad.left) + 150, Int(pad.top) + 50) == [255, 0, 0, 255])
    #expect(
      redacted.annotations.first?.offset(by: CGSize(width: -48, height: -64)).shape
        == mosaic.shape)
  }

  // 冻结时排在前面、别的进程的窗口盖住的那几块（相对那扇窗口，连同它投下的影子那一圈）；同一个 App 的子窗口、不知道归谁的不算
  @Test func coveredRegions() {
    let target = CGRect(x: 100, y: 100, width: 400, height: 300)
    let windows = [
      CGRect(x: 0, y: 0, width: 150, height: 150),  // 别的 App，压住左下角
      CGRect(x: 300, y: 300, width: 100, height: 50),  // 同一个 App 的弹出菜单
      CGRect(x: 450, y: 350, width: 100, height: 100),  // 不知道归谁
      target,
      CGRect(x: 0, y: 0, width: 800, height: 600),  // 排在后面的
    ]
    let owners: [[pid_t]] = [[11], [22], [], [22], [33]]
    // 左下角那扇 (0, 0, 150, 150) 往外扩出影子（左右 48、上 30、下 64）后压住目标的 (100, 100)–(198, 180)
    #expect(
      WindowShot.covered(3, windows: windows, owners: owners) == [
        CGRect(x: 0, y: 0, width: 98, height: 80)
      ])
    #expect(WindowShot.covered(3, windows: windows, owners: []).isEmpty)
  }

  // 半透明的侧栏这类：形状里当实心，画面是冻结帧
  @Test func translucentPartsStayOpaque() throws {
    let live = Self.image(
      width: 200, height: 100, fill: Self.green, radius: 20,
      band: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.4))
    let shot = try #require(WindowShot.compose(Self.capture(), window: live))
    let pad = WindowShot.padding(scale: 2)
    #expect(Self.pixel(shot.image, Int(pad.left) + 100, Int(pad.top) + 50) == [255, 0, 0, 255])
  }

  // 尺寸和冻结时对不上（窗口这几秒变了大小）、截出来几乎全透明（受保护的内容）：不换
  @Test func unusableSnapshotsFallBack() {
    let wide = Self.image(width: 260, height: 100, fill: Self.green, radius: 20)
    #expect(WindowShot.compose(Self.capture(), window: wide) == nil)
    let clear = Self.image(width: 200, height: 100, fill: CGColor(gray: 0, alpha: 0))
    #expect(WindowShot.isMostlyClear(clear))
    #expect(WindowShot.compose(Self.capture(), window: clear) == nil)
    #expect(
      !WindowShot.isMostlyClear(Self.image(width: 200, height: 100, fill: Self.green, radius: 20)))
  }

  // 截不到（窗口没了、系统服务不答）：交回矩形裁切
  @Test func missingWindowKeepsRectangle() async {
    var capture = Self.capture()
    capture.window = WindowShot.Pending(shot: Task { nil })
    let dressed = await WindowShot.dress(capture)
    #expect(dressed.window == nil && !dressed.isWindow)
    #expect(dressed.image === capture.image)
    #expect(dressed.frame == capture.frame)
  }

  // 延时截图的秒数：只认 5 / 10，导入、同步来的别的数按 5
  @Test func delaySecondsAreValidated() {
    let name = "kitty-test-delay-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(Prefs.screenshotDelaySeconds(defaults) == 5)
    defaults.set(10, forKey: Prefs.screenshotDelay)
    #expect(Prefs.screenshotDelaySeconds(defaults) == 10)
    defaults.set(3, forKey: Prefs.screenshotDelay)
    #expect(Prefs.screenshotDelaySeconds(defaults) == 5)
    #expect(
      ShotCountdown.announcement(10, escapes: true)
        != ShotCountdown.announcement(10, escapes: false))
  }
}
