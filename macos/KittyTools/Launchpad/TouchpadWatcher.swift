// 触控板捏合的私有框架桥（SPEC §5.6，R7）。**只运行时 dlopen / dlsym，不链接、不写进工程设置**；找不到符号或设备
// 就退回（设置里那一行写明「这台 Mac 上用不了」，别的入口照常）。
// 框架在自己的线程调 C 回调：回调里只把这一帧拷成值类型交给 Mutex 里的识别器（每个设备一个），识别出结果再
// DispatchQueue.main.async 回主线程——**回调里不碰主线程状态**（mac-native §3）。
// 只在功能开着、系统的捏合关着时注册回调；停的时候注销 + MTDeviceStop + 放掉设备。
// 触点结构体照公开的逆向资料（OpenMultitouchSupport / LaunchNext 的思路，**一行代码都不拷**）：64 位下
// frame / timestamp / identifier / state / fingerId / handId / normalized(pos + vel) / zTotal / …；
// 我们只读 identifier、state 和 normalized.pos。ponytail: 布局是逆向来的，系统改了字段顺序要重新核对（HANDTEST 10）。

import AppKit
import Darwin
import Synchronization

/// 框架给的触点（只声明我们读的字段，前面留出同布局的占位）
nonisolated struct MTFinger {
  var frame: Int32 = 0
  var timestamp: Double = 0
  var identifier: Int32 = 0
  var state: Int32 = 0
  var fingerID: Int32 = 0
  var handID: Int32 = 0
  var normalizedX: Float = 0
  var normalizedY: Float = 0
  var velocityX: Float = 0
  var velocityY: Float = 0
  var zTotal: Float = 0
}

/// C 回调：`int (*)(MTDeviceRef, MTFinger *, int count, double timestamp, int frame)`。
/// 触点数组在 C 侧只当裸指针收下，进回调再 `assumingMemoryBound` 成 MTFinger（Swift 的 struct 不能直接进 @convention(c) 签名）
private typealias MTContactCallback =
  @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
private typealias MTRegisterCallbackFn =
  @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTUnregisterCallbackFn =
  @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

/// 回调在框架线程上跑：这里只碰识别器（Mutex 里）和把结果派回主线程
private final class TouchpadBridge: @unchecked Sendable {
  private let recognizers = Mutex<[UInt: PinchRecognizer]>([:])
  private let sensitivity: PinchRecognizer.Sensitivity
  let onGesture: @Sendable (PinchRecognizer.Gesture) -> Void

  init(
    sensitivity: PinchRecognizer.Sensitivity,
    onGesture: @escaping @Sendable (PinchRecognizer.Gesture) -> Void
  ) {
    self.sensitivity = sensitivity
    self.onGesture = onGesture
  }

  func feed(device: UInt, frame: TouchFrame) {
    let gesture = recognizers.withLock { table -> PinchRecognizer.Gesture? in
      var recognizer = table[device] ?? PinchRecognizer(sensitivity: sensitivity)
      let result = recognizer.feed(frame)
      table[device] = recognizer
      return result
    }
    if let gesture { onGesture(gesture) }
  }

  func forget(device: UInt) {
    _ = recognizers.withLock { $0.removeValue(forKey: device) }
  }
}

/// 现在的桥（C 回调拿不到上下文，只能走这个全局；只在主线程注册 / 注销）
nonisolated(unsafe) private var activeBridge: TouchpadBridge?

private let contactCallback: MTContactCallback = { device, data, count, timestamp, _ in
  guard let device, let data, count > 0, let bridge = activeBridge else { return 0 }
  let fingers = data.assumingMemoryBound(to: MTFinger.self)
  var touches: [TouchPoint] = []
  touches.reserveCapacity(Int(count))
  for index in 0..<Int(count) {
    let finger = fingers[index]
    touches.append(
      TouchPoint(
        id: finger.identifier, x: Double(finger.normalizedX), y: Double(finger.normalizedY),
        state: finger.state))
  }
  bridge.feed(
    device: UInt(bitPattern: device), frame: TouchFrame(time: timestamp, touches: touches))
  return 0
}

/// 触控板捏合的监听（Launchpad 拿着；只在功能开着、系统的捏合关着时 start）
@MainActor
final class TouchpadWatcher {
  enum Availability: Equatable {
    case unknown, available, unavailable
  }

  private(set) var availability: Availability = .unknown
  /// 识别出捏合 / 张开（已经在主线程）
  var onGesture: ((PinchRecognizer.Gesture) -> Void)?

  private var devices: [UnsafeMutableRawPointer] = []
  private var symbols: Symbols?
  private var bridge: TouchpadBridge?
  private var isStarted = false

  private struct Symbols {
    let register: MTRegisterCallbackFn
    let unregister: MTUnregisterCallbackFn
    let start: MTDeviceStartFn
    let stop: MTDeviceStopFn
  }

  /// 私有框架在不在（设置页据此说「这台 Mac 上用不了」；只 dlopen 一次）
  static let libraryAvailable: Bool = {
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_LAZY)
    else { return false }
    defer { dlclose(handle) }
    return dlsym(handle, "MTDeviceCreateList") != nil
      && dlsym(handle, "MTRegisterContactFrameCallback") != nil
      && dlsym(handle, "MTDeviceStart") != nil
  }()

  /// 开着监听（重复调用只换灵敏度）
  func start(sensitivity: PinchRecognizer.Sensitivity) {
    if isStarted {
      bridge = nil
      stopDevices()
    }
    guard let loaded = loadSymbols() else {
      availability = .unavailable
      return
    }
    symbols = loaded.symbols
    guard let list = loaded.createList()?.takeRetainedValue() else {
      availability = .unavailable
      return
    }
    let count = CFArrayGetCount(list)
    var found: [UnsafeMutableRawPointer] = []
    for index in 0..<count {
      guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
      found.append(UnsafeMutableRawPointer(mutating: raw))
    }
    guard !found.isEmpty else {
      availability = .unavailable
      return
    }
    devices = found
    bridge = TouchpadBridge(sensitivity: sensitivity) { [weak self] gesture in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.onGesture?(gesture) }
      }
    }
    activeBridge = bridge
    for device in devices {
      loaded.symbols.register(device, contactCallback)
      loaded.symbols.start(device, 0)
    }
    isStarted = true
    availability = .available
  }

  /// 关掉：注销回调、停设备、放掉桥（回调里再进来也不会认）
  func stop() {
    guard isStarted else {
      activeBridge = nil
      return
    }
    if let symbols {
      for device in devices {
        symbols.unregister(device, contactCallback)
        symbols.stop(device)
        bridge?.forget(device: UInt(bitPattern: device))
      }
    }
    devices = []
    activeBridge = nil
    bridge = nil
    symbols = nil
    isStarted = false
  }

  private func stopDevices() {
    if let symbols {
      for device in devices {
        symbols.unregister(device, contactCallback)
        symbols.stop(device)
      }
    }
    devices = []
    activeBridge = nil
    isStarted = false
  }

  private func loadSymbols() -> (
    symbols: Symbols, createList: MTDeviceCreateListFn
  )? {
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_LAZY)
    else { return nil }
    guard let listSymbol = dlsym(handle, "MTDeviceCreateList"),
      let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallback"),
      let unregisterSymbol = dlsym(handle, "MTUnregisterContactFrameCallback"),
      let startSymbol = dlsym(handle, "MTDeviceStart"),
      let stopSymbol = dlsym(handle, "MTDeviceStop")
    else { return nil }
    return (
      Symbols(
        register: unsafeBitCast(registerSymbol, to: MTRegisterCallbackFn.self),
        unregister: unsafeBitCast(unregisterSymbol, to: MTUnregisterCallbackFn.self),
        start: unsafeBitCast(startSymbol, to: MTDeviceStartFn.self),
        stop: unsafeBitCast(stopSymbol, to: MTDeviceStopFn.self)),
      unsafeBitCast(listSymbol, to: MTDeviceCreateListFn.self)
    )
  }
}
