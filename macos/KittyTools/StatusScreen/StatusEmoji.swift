// 状态屏告示上的动画表情（PLAN §10「状态屏」Z15a）：清单（id、中文名、顺序）、静止画面（第一帧，按 id 缓存）、
// 解出全部帧和每帧时长、把帧交给一个图层循环播，和两处共用的小视图——StatusEmojiView（告示上的那一个：静止画面垫着，
// 帧来了换成在播的图层）、StatusPresetIcon（列表里一个状态的小图标）。
// 素材是 Microsoft Fluent Emoji Animated（MIT）转成的 HEICS（HEVC 图像序列，带透明通道，256 × 256，37–73 帧，
// 每秒 24 帧），打进包里是平铺的 status-emoji-<id>.heics；转换脚本 macos/status-emoji.swift，
// 出处和许可全文在 Resources/status-emoji-LICENSE.txt。
// 怎么播是实测定的（PLAN §10「表情怎么播」）：帧一次解完（主线程外），交给图层的 CAKeyframeAnimation 按帧换 contents，
// 0.02–1.2% CPU；边解边播（CGAnimateImageAtURLWithBlock）要 4%，TimelineView / 定时器逐帧换图更贵，都不用。
// 解好的帧一个表情 10–19 MB（帧数 × 256 KB；连图层那边的一份，PLAN 里实测是 18–38 MB）：这里不缓存帧，谁要播谁拿着、
// 不播了就放手（状态屏的会话 StatusScreen.frames、设置里那块预览 StatusPreview）。小图标一律用静止画面。

import AppKit
import SwiftUI

enum StatusEmoji {
  /// 可选的 16 个（设置里的图标格子按这个顺序）；name 是旁白读的中文名
  nonisolated static let choices: [(id: String, name: String)] = [
    ("raised-hand", "举手"), ("waving-hand", "挥手"), ("glowing-star", "发光的星"),
    ("alarm-clock", "闹钟"), ("hourglass", "沙漏"), ("hot-beverage", "热饮"), ("zzz", "Zzz"),
    ("sleeping-face", "睡觉"), ("shushing-face", "嘘"), ("busts", "开会"), ("telephone", "电话"),
    ("rocket", "火箭"), ("robot", "机器人"), ("fire", "火"), ("high-voltage", "闪电"),
    ("black-cat", "黑猫"),
  ]
  nonisolated static let ids = choices.map(\.id)
  /// 有人碰键盘鼠标时从屏幕底边冒出来的那双眼睛（Z17a）：不在可选的里面
  nonisolated static let eyes = "eyes"
  /// 颜色很深、在黑底和 HUD 底板上几乎看不见的表情（「开会」的两个人影是深紫色的剪影）：告示上给它垫一团柔和的亮光
  /// （StatusEmojiView）。黑猫是亮一些的紫色，不用垫
  nonisolated static let dim: Set<String> = ["busts"]

  nonisolated static func name(_ id: String) -> String? { choices.first { $0.id == id }?.name }

  /// 包里的那个文件；不是清单里的 id（空、旧的符号名、乱写的）是 nil
  nonisolated static func url(_ id: String) -> URL? {
    guard id == eyes || ids.contains(id) else { return nil }
    return Bundle.main.url(forResource: "status-emoji-" + id, withExtension: "heics")
  }

  // MARK: 静止画面

  /// 静止画面：第一帧，按 id 缓存；没选（空）、不认识的 id 是 nil。一张 256 KB，17 个都用过约 4.4 MB，内存吃紧时
  /// 系统自己清（NSCache）。第一次要现解（约 5 ms 一张）
  static func still(_ id: String) -> CGImage? {
    if let cached = stills.object(forKey: id as NSString) { return cached }
    guard let image = firstFrame(id) else { return nil }
    stills.setObject(image, forKey: id as NSString)
    return image
  }

  /// 菜单项用的小图（16 pt）
  static func menuImage(_ id: String) -> NSImage? {
    still(id).map { NSImage(cgImage: $0, size: NSSize(width: 16, height: 16)) }
  }

  /// 把 16 张静止画面先在主线程外解好：设置里的图标格子一次要画 16 张，在主线程上现解要七八十毫秒
  static func warmStills() async {
    for id in ids where stills.object(forKey: id as NSString) == nil {
      if let image = await decodeFirstFrame(id) { stills.setObject(image, forKey: id as NSString) }
    }
  }

  private static let stills = NSCache<NSString, CGImage>()

  nonisolated private static func firstFrame(_ id: String) -> CGImage? {
    url(id).flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { bitmap($0, 0) }
  }

  @concurrent nonisolated private static func decodeFirstFrame(_ id: String) async -> CGImage? {
    firstFrame(id)
  }

  // MARK: 全部帧

  /// 解好的全部帧和每帧显示多久（秒）
  nonisolated struct Frames: Sendable {
    let images: [CGImage]
    let delays: [Double]

    /// 播一遍多久
    var duration: Double { delays.reduce(0, +) }
    var keyTimes: [Double] { StatusEmoji.keyTimes(delays) }
  }

  /// 每帧时长 → CAKeyframeAnimation 离散模式的 keyTimes（纯函数）：比帧数多一个，从 0 到 1，
  /// 第 i 帧从 keyTimes[i] 显示到 keyTimes[i + 1]
  nonisolated static func keyTimes(_ delays: [Double]) -> [Double] {
    let total = delays.reduce(0, +)
    guard total > 0 else { return [] }
    var elapsed = 0.0
    return [0]
      + delays.map { delay in
        elapsed += delay
        return elapsed / total
      }
  }

  /// 解出一个表情的全部帧（mac-native §3 @concurrent 第 1 类：图片解码；73 帧约 0.3 s）。不到两帧、文件不在是 nil；
  /// 中途被取消（退出了、换了表情）也是 nil，不解完
  @concurrent nonisolated static func decode(_ id: String) async -> Frames? {
    guard let url = url(id), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }
    var images: [CGImage] = []
    var delays: [Double] = []
    for index in 0..<CGImageSourceGetCount(source) {
      guard !Task.isCancelled else { return nil }
      guard let image = bitmap(source, index) else { continue }
      images.append(image)
      delays.append(delay(source, index))
    }
    return images.count > 1 ? Frames(images: images, delays: delays) : nil
  }

  /// 第 index 帧解成一张现成的位图（预乘透明度的 BGRA，图层直接能用）。ImageIO 给的图是「用到再解」的，HEICS 的帧还每画
  /// 一次重解一次（实测：73 帧第一遍画 0.31 s，再画一遍还是 0.31 s，带 ShouldCacheImmediately 也一样）——所以当场画进
  /// 位图，播的时候只是换一张现成的图
  nonisolated private static func bitmap(_ source: CGImageSource, _ index: Int) -> CGImage? {
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  /// 这一帧显示多久：文件里写着的（转换脚本原样留下的，都是 0.041 s）；没写就按每秒 24 帧
  nonisolated private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    let heics = properties?[kCGImagePropertyHEICSDictionary] as? [CFString: Any]
    let seconds =
      heics?[kCGImagePropertyHEICSUnclampedDelayTime] as? Double
      ?? heics?[kCGImagePropertyHEICSDelayTime] as? Double ?? 0
    return seconds > 0 ? seconds : 1.0 / 24
  }

  // MARK: 播

  static let animationKey = "statusEmoji"

  /// 让图层从第一帧起循环播这些帧：按帧换 contents 的离散关键帧动画，图层自己的 contents 不动（动画一拿掉就什么都
  /// 不显示）。已经在播同一份就不动，不从头来
  static func play(_ frames: Frames, on layer: CALayer) {
    let playing = layer.animation(forKey: animationKey) as? CAKeyframeAnimation
    guard playing?.values?.first as AnyObject? !== frames.images.first else { return }
    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = frames.images
    animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
    animation.calculationMode = .discrete
    animation.duration = frames.duration
    animation.repeatCount = .infinity
    layer.add(animation, forKey: animationKey)
  }
}

/// 告示上的一个表情（大小由用的地方定）：静止画面垫着——帧还没解好、动画关着、屏外截图里看到的就是它；帧来了换成在播的
/// 图层，从第一帧开始，和静止画面是同一张，接得上。在播时静止画面藏起来：不藏的话帧的透明处会透出下面的第一帧
struct StatusEmojiView: View {
  let id: String
  var frames: StatusEmoji.Frames?

  var body: some View {
    ZStack {
      if let still = StatusEmoji.still(id) {
        Image(decorative: still, scale: 1)
          .resizable()
          .interpolation(.high)
          .opacity(frames == nil ? 1 : 0)
      }
      if let frames { EmojiPlayer(frames: frames) }
    }
    .background {
      // 深色的表情垫一团亮光才看得见（只画一次的小渐变，比表情大一圈）
      if StatusEmoji.dim.contains(id) {
        GeometryReader { proxy in
          let side = min(proxy.size.width, proxy.size.height)
          RadialGradient(
            colors: [.white.opacity(0.3), .white.opacity(0)], center: .center, startRadius: 0,
            endRadius: side * 0.7
          )
          .frame(width: side * 1.5, height: side * 1.5)
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
      }
    }
  }
}

/// 在播的那一层：一个只有图层的视图。视图一拆动画就拿掉，帧跟着放手
private struct EmojiPlayer: NSViewRepresentable {
  let frames: StatusEmoji.Frames

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.contentsGravity = .resizeAspect
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    if let layer = view.layer { StatusEmoji.play(frames, on: layer) }
  }

  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    view.layer?.removeAnimation(forKey: StatusEmoji.animationKey)
  }
}

/// 列表里一个状态的小图标（设置的列表行和详情页页头、启动器的状态行）：选了表情的是表情的静止画面，没选的是家族色块里
/// 「只有几行字」的符号
struct StatusPresetIcon: View {
  /// StatusPreset.symbol：表情 id，空 = 没选
  let symbol: String
  var size: CGFloat = 24

  var body: some View {
    if let still = StatusEmoji.still(symbol) {
      Image(decorative: still, scale: 1)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
    } else {
      KindTile(symbol: StatusPreset.plainSymbol, color: Style.Family.statusScreen, size: size)
    }
  }
}
