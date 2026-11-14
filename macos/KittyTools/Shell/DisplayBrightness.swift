// 内建屏的亮度读写（2026-11-14，刘海岛完善 D2：亮度键换成刘海岛上的提示，MediaKeys 用）。
// **私有框架** DisplayServices（用户 2026-11-14 拍板页 D2「全部按推荐」同意用；公开接口调不了亮度），dlopen / dlsym，
// 取不到、没有内建屏（合盖只用外接屏）、它调不了就是 nil / 什么都不做——那时亮度键照旧交给系统。只管内建屏。
// 在拦截的那条线程上调（主线程卡住时亮度键照样管用），所以 nonisolated；只是几个 C 调用。
// 2026-11-14 macOS 27.0.1 实测（macos/build/research/island-polish-2026-11-13/hud-probe/README.md）：读写都返回 0、管用；
// 环境光自动调节会让读数自己漂，所以每按一下都现读、不记上一次的值。

import CoreGraphics
import Foundation

nonisolated enum DisplayBrightness {
  private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
  private typealias Set = @convention(c) (UInt32, Float) -> Int32
  private typealias Can = @convention(c) (UInt32) -> Bool

  /// 三个函数各取一次（C 函数指针是 Sendable 的，能当静态常量；dlopen 的句柄不行）
  private static let get: Get? = function("DisplayServicesGetBrightness")
  private static let set: Set? = function("DisplayServicesSetBrightness")
  private static let can: Can? = function("DisplayServicesCanChangeBrightness")

  private static func function<T>(_ name: String) -> T? {
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
      let symbol = dlsym(handle, name)
    else { return nil }
    return unsafeBitCast(symbol, to: T.self)
  }

  /// 内建屏（MacBook 自己那块）；没有（合盖只用外接屏、台式机）是 nil。不用「主屏」：主屏可以是外接显示器
  private static var builtIn: CGDirectDisplayID? {
    var count: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
  }

  /// 内建屏现在的亮度 0…1；取不到函数、没有内建屏、它调不了是 nil
  static func read() -> Double? {
    guard let display = builtIn, let get else { return nil }
    if let can, !can(display) { return nil }
    var value: Float = 0
    guard get(display, &value) == 0, value.isFinite else { return nil }
    return Double(min(max(value, 0), 1))
  }

  /// 设内建屏的亮度（夹进 0…1）；成了没有
  @discardableResult static func set(_ value: Double) -> Bool {
    guard value.isFinite, let display = builtIn, let set else { return false }
    return set(display, Float(min(max(value, 0), 1))) == 0
  }
}
