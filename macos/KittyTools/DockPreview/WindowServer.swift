// 程序坞预览要的窗口服务器私有接口（第九族；用户 2026-10-22 拍板 A1「四个都用」，同日又同意加一个查桌面的）。
// 跑起来时才按名字从系统框架里取：不链接、不写进工程设置；哪一个取不到，用到它的函数就返回 nil / false，调用方退回公开做法。
// AltTab、DockDoor 用的是同一组（两家都是 GPL：只照着他们和 yabai / Hammerspoon 公开的声明核对签名，一行代码都不拷）：
//   _AXUIElementGetWindow            辅助功能里的窗口 → 窗口编号（没有公开接口）
//   CGSHWCaptureWindowList           按编号截一扇窗口：别的桌面上的也截得到（公开的 ScreenCaptureKit 截不到，本机 macOS 27.0.1
//                                    实测报错）；当前桌面的也比它直接出缩略图快（数字在 PLAN §10「程序坞预览」），所以一律用这个
//   CGSCopySpacesForWindows          窗口在不在某个桌面上：App 关掉却还留着的窗口（微信的聊天窗口）不在任何桌面，不认它就会
//                                    被当成「在别的桌面」列出来
//   _SLPSSetFrontProcessWithOptions  按编号把那扇窗口的 App 拿到最前（在别的桌面就切过去），再用
//   + SLPSPostEventRecordTo          一条「当 key」的事件让那扇窗口当 key；本 App 从不激活，公开的 activate 受 macOS 14 起的
//                                    协作式激活限制，常被驳回
// 第一次用到时才取符号（CGSMainConnectionID 要在 NSApplication 起来之后调，不然断言崩溃）：用的地方先在主线程调一次
// prepare()，别让第一次落到 @concurrent 的截图线程上。
// 配套两个：CGSMainConnectionID（CGS 接口要的连接号）、GetProcessForPID（已废弃的公开函数，SLPS 要的进程序号；直接调有废弃警告）。
// 全仓库只有这个文件碰这些符号（mac-native §3 的 C API 白名单）。
// ponytail: 掩码、选项位、事件记录的格式都是逆向来的（各处注释里写了出处），系统改了要重新核对：跑 DockPreviewProbeTests、
// 走 HANDTEST「程序坞预览手测」1–3；接口在、行为变了时（截出来全透明、切错窗口）调用方的退路接得住，不会崩。

import AppKit
import ApplicationServices

nonisolated enum WindowServer {
  /// 窗口在哪：当前看着的桌面（几块屏各有一个）、别的桌面、哪个桌面都不在（关掉却还留着的、隐藏起来的）
  enum Place: Equatable { case current, other, nowhere }

  /// 辅助功能里的窗口 → 窗口编号；接口不在或问不到时 nil
  static func windowID(of element: AXUIElement) -> CGWindowID? {
    guard let getWindow = symbols.getWindow else { return nil }
    var id: CGWindowID = 0
    return getWindow(element, &id) == .success && id != 0 ? id : nil
  }

  /// 在主线程（NSApplication 起来之后）先把符号取好
  static func prepare() { _ = symbols }

  /// 截窗口的私有接口在不在（不在时当前桌面上的退回 ScreenCaptureKit）
  static var canCapture: Bool { symbols.connection != nil && symbols.capture != nil }

  /// 窗口在哪个桌面；接口不在时 nil（调用方当「不知道」，别的桌面上的就不列）
  static func place(of id: CGWindowID) -> Place? {
    guard let connection = symbols.connection, let copySpaces = symbols.copySpaces else {
      return nil
    }
    func spaces(_ mask: Int32) -> Int {
      let list = copySpaces(connection, mask, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
      return (list as? [NSNumber])?.count ?? 0
    }
    // 掩码：1 当前桌面、2 别的桌面、4 用户的桌面（不含系统自己的）；5 = 当前的、7 = 全部（AltTab 同样这么问）
    return place(current: spaces(0x5), all: spaces(0x7))
  }

  /// 两次问到的桌面个数 → 在哪。纯函数，配单测
  static func place(current: Int, all: Int) -> Place {
    current > 0 ? .current : all > 0 ? .other : .nowhere
  }

  /// 整扇窗口的图，一点一像素（不带阴影）；截不到或接口不在时 nil。同步调用，要在主线程外调（WindowShots）
  static func capture(_ id: CGWindowID) -> CGImage? {
    guard let connection = symbols.connection, let capture = symbols.capture else { return nil }
    var number = id
    // 选项：1<<11 不按全局裁切形状、1<<19 完整尺寸（开着台前调度时不被缩小变形；屏幕外的部分照样截不到）、
    // 1<<9 名义分辨率（1x：缩略图够用，像素只有 2x 的四分之一）
    let images = capture(connection, &number, 1, (1 << 11) | (1 << 19) | (1 << 9))?
      .takeRetainedValue()
    return (images as? [CGImage])?.first
  }

  /// 把那扇窗口拿到最前并当 key（在别的桌面就切过去）。接口不在或没成功时 false，调用方退回 NSRunningApplication.activate
  static func bringToFront(pid: pid_t, window id: CGWindowID) -> Bool {
    guard let processForPID = symbols.processForPID, let setFront = symbols.setFront,
      let post = symbols.post
    else { return false }
    var process = ProcessSerialNumber()
    guard processForPID(pid, &process) == noErr else { return false }
    // 0x200：当成用户自己点的（kCPSUserGenerated），系统照常切桌面、播切换动画
    guard setFront(&process, id, 0x200) == .success else { return false }
    var event = keyWindowEvent(id)
    _ = post(&process, &event)
    return true
  }

  /// 「让这扇窗口当 key」的事件记录。格式是 Hammerspoon issue #370 里公开的逆向结果（yabai 的写法），按 AltTab 后来踩过的坑改了
  /// 三处：① 缓冲区开 0x100、全部清零（记录本身 0xf8，macOS 14.7.4 起系统编码时会读过记录末尾，读到堆上的垃圾就闪退，
  /// paneru #123）；② 只发「按下」不发「松开」（一对才算一次点击：有的 App 把坐标纠成 (0, 0)，就点到了左上角的按钮，
  /// AltTab #5381；只按下照样能当 key，AltTab 在 macOS 26.5 实测）；③ 点的位置在窗口右下方很远处（不填 NaN；离窗口边一两点
  /// 会落进拉伸区，macOS 27 上窗口被拉大，AltTab #5900）。事件按窗口编号投递，不看坐标。
  /// 0x04 记录长度 0xf8、0x08 事件类型 1（左键按下）、0x20 起 16 字节窗口内坐标（两个 Double）、0x3a 是 0x10、
  /// 0x3c 起 4 字节窗口编号（小端）。纯函数，配单测
  static func keyWindowEvent(_ id: CGWindowID) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x100)
    bytes[0x04] = 0xf8
    bytes[0x08] = 0x01
    for (offset, value) in [(0x20, 300_000.0), (0x28, 300_000.0)] {
      withUnsafeBytes(of: value.bitPattern.littleEndian) {
        bytes.replaceSubrange(offset..<offset + 8, with: $0)
      }
    }
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: id.littleEndian) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
    return bytes
  }

  /// 这几个接口在不在（设置页、探针看；哪个不在就退回哪条公开做法）
  static var missing: [String] {
    let all: [(String, Bool)] = [
      ("_AXUIElementGetWindow", symbols.getWindow != nil),
      ("CGSMainConnectionID", symbols.connection != nil),
      ("CGSHWCaptureWindowList", symbols.capture != nil),
      ("CGSCopySpacesForWindows", symbols.copySpaces != nil),
      ("GetProcessForPID", symbols.processForPID != nil),
      ("_SLPSSetFrontProcessWithOptions", symbols.setFront != nil),
      ("SLPSPostEventRecordTo", symbols.post != nil),
    ]
    return all.filter { !$0.1 }.map(\.0)
  }

  // MARK: 符号

  private typealias GetWindow =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) ->
    AXError
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias CaptureList =
    @convention(c) (
      Int32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32
    ) -> Unmanaged<CFArray>?
  private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
  private typealias ProcessForPID =
    @convention(c) (
      pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus
  private typealias SetFront =
    @convention(c) (
      UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
  private typealias PostEvent =
    @convention(c) (
      UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError

  private struct Symbols {
    let getWindow: GetWindow?
    /// 连接号本身（不是函数）：取一次就够，整个进程同一个
    let connection: Int32?
    let capture: CaptureList?
    let copySpaces: CopySpaces?
    let processForPID: ProcessForPID?
    let setFront: SetFront?
    let post: PostEvent?
  }

  /// 第一次用时取一次（静态常量的初始化本身线程安全）；框架句柄不关，进程里本来就加载着
  private static let symbols: Symbols = {
    func load<T>(_ path: String, _ name: String, as type: T.Type) -> T? {
      guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) else {
        return nil
      }
      return unsafeBitCast(symbol, to: type)
    }
    let services = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    let graphics = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    return Symbols(
      getWindow: load(services, "_AXUIElementGetWindow", as: GetWindow.self),
      connection: load(graphics, "CGSMainConnectionID", as: MainConnection.self).map { $0() },
      capture: load(graphics, "CGSHWCaptureWindowList", as: CaptureList.self),
      copySpaces: load(graphics, "CGSCopySpacesForWindows", as: CopySpaces.self),
      processForPID: load(services, "GetProcessForPID", as: ProcessForPID.self),
      setFront: load(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFront.self),
      post: load(skyLight, "SLPSPostEventRecordTo", as: PostEvent.self))
  }()
}
