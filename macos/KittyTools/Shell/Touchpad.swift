// 触控板触点的私有框架桥（2026-11-28 从启动台的 TouchpadWatcher 拆出来，issue #59）：MultitouchSupport 每一帧的触点
// 交给几个识别器共用一路（启动台的捏合、触控板手势插件）。**只运行时 dlopen / dlsym，不链接、不写进工程设置**；
// 找不到符号或设备就退回（`availability`），别的入口照常。
// 框架在自己的线程调 C 回调：回调里只把这一帧拷成值类型，按顺序交给每个订阅者（`TouchConsumer`，也在框架线程上跑，
// 只许碰它自己 Mutex 里的东西）——**回调里不碰主线程状态**（mac-native §3）。订阅者是一份不可变的快照（`TouchpadBridge`），
// 有人来、有人走时整份换掉；帧数（`framesSeen`）不跟着换。
// 第一个订阅者来了才枚举设备、注册回调；最后一个走了注销 + MTDeviceStop + 放掉设备。有订阅者时听醒来和
// AppleMultitouchDevice 的插 / 拔（IOKit 的服务通知，不轮询），最后一个通知之后 0.3 s 重新枚举、注册，再叫每个订阅者的 `onReset`
// （丢掉做到一半的手势和旧的设备编号）。
// 触点结构体照公开的逆向资料（OpenMultitouchSupport / LaunchNext 的思路，**一行代码都不拷**）；按传感器尺寸只认触控板
// （去掉 Touch Bar、妙控鼠标）和插拔时重新连接的做法照 Trackpad Edges（MIT，Copyright 2026 Jiao77），按本仓库的写法重写。
// ponytail: 布局是逆向来的，系统改了字段顺序要重新核对（HANDTEST 10）。

import AppKit
import Darwin
import IOKit
import Synchronization

/// 一帧里的一个触点：id（同一根手指跨帧不变）、在触控板上的归一化位置（0…1，左下角原点，和框架给的口径一致）、
/// 框架给的状态（0 = 没在跟踪、4 = 按着；别的值照「在面上」算）
nonisolated struct TouchPoint: Equatable, Sendable {
  var id: Int32
  var x: Double
  var y: Double
  var state: Int32
}

/// 一帧触点（时间来自框架的 timestamp，秒）
nonisolated struct TouchFrame: Equatable, Sendable {
  var time: Double
  var touches: [TouchPoint]
}

/// 框架给的触点：框架的数组是 **96 字节一个**。字段顺序照公开的逆向资料：frame、timestamp、identifier、state、
/// fingerId、handId、normalized 位置 + 速度、zTotal、一个 int、angle、majorAxis、minorAxis、absolute 位置 + 速度、
/// 两个 int、zDensity。**整个结构体 stride 必须是 96**——按 56 步进从第二根手指起就全错位了（F6）。
/// ponytail: 布局是逆向来的；系统改了字段顺序要重新核对（HANDTEST 10）。只读 identifier / state / normalized 位置
/// （偏移 16 / 20 / 32 / 36），后面的字段只为把步长占满。
nonisolated struct MTFinger {
  var frame: Int32 = 0  // 0
  var pad0: Int32 = 0  // 4（timestamp 要 8 字节对齐）
  var timestamp: Double = 0  // 8
  var identifier: Int32 = 0  // 16
  var state: Int32 = 0  // 20
  var fingerID: Int32 = 0  // 24
  var handID: Int32 = 0  // 28
  var normalizedX: Float = 0  // 32
  var normalizedY: Float = 0  // 36
  var normalizedVelocityX: Float = 0  // 40
  var normalizedVelocityY: Float = 0  // 44
  var zTotal: Float = 0  // 48
  var field9: Int32 = 0  // 52
  var angle: Float = 0  // 56
  var majorAxis: Float = 0  // 60
  var minorAxis: Float = 0  // 64
  var absoluteX: Float = 0  // 68
  var absoluteY: Float = 0  // 72
  var absoluteVelocityX: Float = 0  // 76
  var absoluteVelocityY: Float = 0  // 80
  var field14: Int32 = 0  // 84
  var field15: Int32 = 0  // 88
  var zDensity: Float = 0  // 92
}

/// 订阅者收帧的那一下：在**框架线程**上调，每一帧都来（空帧也来：全抬起来了）。参数是设备编号（换设备、重新枚举后会变）和这一帧
typealias TouchConsumer = @Sendable (UInt, TouchFrame) -> Void

/// C 回调：`int (*)(MTDeviceRef, MTFinger *, int count, double timestamp, int frame)`。
/// 触点数组在 C 侧只当裸指针收下，进回调再 `assumingMemoryBound` 成 MTFinger（Swift 的 struct 不能直接进 @convention(c) 签名）
typealias MTContactCallback =
  @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
private typealias MTRegisterCallbackFn =
  @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Void
/// 传感器面的宽高（单位 0.01 mm）
private typealias MTDeviceDimensionsFn =
  @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>)
  -> Int32

/// 交给框架线程的那一份订阅者：不可变，订阅者变了整份换掉。
/// **必须 `nonisolated`**：工程默认 MainActor 隔离，不写的话它会被推成 @MainActor，框架线程一调进来就被 Swift 6 的隔离检查
/// 当场 trap（G1：系统手势一关、一碰触控板就崩）
nonisolated final class TouchpadBridge: Sendable {
  let consumers: [TouchConsumer]

  init(consumers: [TouchConsumer]) {
    self.consumers = consumers
  }

  func feed(device: UInt, frame: TouchFrame) {
    for consumer in consumers { consumer(device, frame) }
  }
}

/// 现在的那一份订阅者和收到的帧数（C 回调拿不到上下文，只能走这个全局）：框架线程读、主线程换，用 Mutex 护住引用，
/// 不会出现「刚读出引用、主线程就放掉」的 use-after-free（F25）。帧数只增、换订阅者不清零（启动台跟手时看它涨没涨）
nonisolated private struct Delivery {
  var bridge: TouchpadBridge?
  var frames = 0
}

nonisolated private let delivery = Mutex(Delivery())

/// 回调的本体是一个普通的 nonisolated 函数：C 函数指针的字面量里**不写任何闭包**（字面量在默认 MainActor 隔离下会被
/// 推成 MainActor，里面的闭包到了框架线程上一执行就 trap，G1）
nonisolated private func handleContactFrame(
  _ device: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, _ count: Int32,
  _ timestamp: Double
) -> Int32 {
  guard let device,
    let bridge = delivery.withLock({ state -> TouchpadBridge? in
      if state.bridge != nil { state.frames += 1 }
      return state.bridge
    })
  else { return 0 }
  // 空帧也交：全抬起来要让识别器重置（F25）
  let touches = data.map { Touchpad.touches(from: $0, count: Int(count)) } ?? []
  bridge.feed(
    device: UInt(bitPattern: device), frame: TouchFrame(time: timestamp, touches: touches))
  return 0
}

nonisolated private let contactCallback: MTContactCallback = { device, data, count, timestamp, _ in
  handleContactFrame(device, data, count, timestamp)
}

/// 订阅者表（按加入的先后）。起停只看它：第一个来了起设备，最后一个走了停，中间来来去去只换快照（纯的，单测直接喂）
struct TouchpadSubscribers {
  enum Change: Equatable {
    /// 第一个订阅者：枚举设备、注册回调、开始听插拔
    case start
    /// 只换交给框架线程的那份快照，设备不动（G8：别把正在捏的那一下清掉）
    case swap
    /// 最后一个走了：全部停掉
    case stop
    case none
  }

  private(set) var entries: [(key: String, consumer: TouchConsumer, onReset: () -> Void)] = []

  var consumers: [TouchConsumer] { entries.map { $0.consumer } }
  var resets: [() -> Void] { entries.map { $0.onReset } }
  var isEmpty: Bool { entries.isEmpty }

  /// 同一个 key 再来一次 = 换掉它的回调，位置不变
  mutating func subscribe(
    _ key: String, consumer: @escaping TouchConsumer, onReset: @escaping () -> Void
  ) -> Change {
    if let index = entries.firstIndex(where: { $0.key == key }) {
      entries[index] = (key, consumer, onReset)
      return .swap
    }
    entries.append((key, consumer, onReset))
    return entries.count == 1 ? .start : .swap
  }

  mutating func unsubscribe(_ key: String) -> Change {
    guard let index = entries.firstIndex(where: { $0.key == key }) else { return .none }
    entries.remove(at: index)
    return entries.isEmpty ? .stop : .swap
  }
}

/// 触控板触点的监听：全 App 一个（`shared`），几个识别器各订一份
@MainActor
final class Touchpad {
  enum Availability: Equatable {
    case unknown, available, unavailable
  }

  static let shared = Touchpad()

  /// 最近一次枚举的结果：有起得来的触控板 = available；框架 / 符号 / 设备都没有，或者全都起不来 = unavailable
  private(set) var availability: Availability = .unknown

  private var subscribers = TouchpadSubscribers()
  private var devices: [UnsafeMutableRawPointer] = []
  /// MTDeviceCreateList 给的数组：设备裸指针只在它活着时有效，枚举完也要拿着（F6）
  private var deviceList: CFMutableArray?
  private var wakeObserver: NSObjectProtocol?
  private var notifyPort: IONotificationPortRef?
  private var iterators: [io_iterator_t] = []
  private var pendingRestart: Task<Void, Never>?

  private init() {}

  /// 订一份：`consumer` 在框架线程上收每一帧，只许碰它自己 Mutex 里的东西；`onReset` 在主线程上、每次重新枚举设备之后调
  /// （醒来、插拔），丢掉做到一半的手势和旧的设备编号。同一个 key 再订一次只换回调、不重起设备（G8）
  func subscribe(
    _ key: String, consumer: @escaping TouchConsumer, onReset: @escaping () -> Void
  ) {
    let change = subscribers.subscribe(key, consumer: consumer, onReset: onReset)
    publish()
    if change == .start {
      listen()
      startDevices()
    }
  }

  /// 退订（不调它的 `onReset`：调用方自己收拾）。最后一个走了：注销回调、停设备、不再听插拔
  func unsubscribe(_ key: String) {
    guard subscribers.unsubscribe(key) == .stop else {
      publish()
      return
    }
    stopListening()
    publish()
    stopDevices()
  }

  /// 收到的帧数（只增；启动台跟手时看它涨没涨，按需实录探针也读它）
  nonisolated static var framesSeen: Int { delivery.withLock { $0.frames } }

  /// 单测用：装一份订阅者（nil = 拆掉）。不注册回调、不碰框架（G1 的单测在后台线程上直接调回调）
  nonisolated static func installBridgeForTesting(_ bridge: TouchpadBridge?) {
    delivery.withLock { $0.bridge = bridge }
  }

  /// 单测用：交给框架的那个 C 回调本身
  nonisolated static var contactCallbackForTesting: MTContactCallback { contactCallback }

  /// 私有框架和要用的几个函数在不在（设置页据此说「这台 Mac 上用不了」）
  static var libraryAvailable: Bool { symbols != nil }

  /// 按传感器尺寸认触控板（单位 0.01 mm）：至少 30 mm 高、横着的。Touch Bar 太矮，妙控鼠标的面是竖着的
  nonisolated static func isTrackpad(width: Int32, height: Int32) -> Bool {
    height >= 3_000 && width > height
  }

  /// 回调里那段拷贝抽出来给单测：缓冲区按框架的 96 字节步长，只读 identifier / state / normalized 位置
  nonisolated static func touches(from data: UnsafeMutableRawPointer, count: Int) -> [TouchPoint] {
    let fingers = data.assumingMemoryBound(to: MTFinger.self)
    guard count > 0 else { return [] }
    return (0..<count).map { index in
      let finger = fingers[index]
      return TouchPoint(
        id: finger.identifier, x: Double(finger.normalizedX), y: Double(finger.normalizedY),
        state: finger.state)
    }
  }

  private func publish() {
    let bridge = subscribers.isEmpty ? nil : TouchpadBridge(consumers: subscribers.consumers)
    delivery.withLock { $0.bridge = bridge }
  }

  private func startDevices() {
    // 结构体步长不对就别注册：读出来的触点是错位的，不如退回「这台 Mac 上用不了」（F6）
    guard let symbols = Self.symbols, MemoryLayout<MTFinger>.stride == 96,
      let list = symbols.createList()?.takeRetainedValue()
    else {
      availability = .unavailable
      return
    }
    deviceList = list
    for index in 0..<CFArrayGetCount(list) {
      guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
      let device = UnsafeMutableRawPointer(mutating: raw)
      // 量不了尺寸（符号没了）就都收，同拆出来之前
      if let dimensions = symbols.dimensions {
        var width: Int32 = 0
        var height: Int32 = 0
        _ = dimensions(device, &width, &height)
        guard Self.isTrackpad(width: width, height: height) else { continue }
      }
      symbols.register(device, contactCallback)
      guard symbols.start(device, 0) == 0 else {
        symbols.unregister(device, contactCallback)
        continue
      }
      devices.append(device)
    }
    availability = devices.isEmpty ? .unavailable : .available
  }

  private func stopDevices() {
    if let symbols = Self.symbols {
      for device in devices {
        symbols.unregister(device, contactCallback)
        symbols.stop(device)
      }
    }
    devices = []
    deviceList = nil
  }

  /// 重新枚举、注册，再叫每个订阅者收拾（它们可能在 onReset 里重订自己：只换快照）。
  /// 起来的设备比之前少时 2 s 后再试一次（只一次）：醒来那一下内置触控板可能还没就绪（量出 0 × 0、或 start 不成），它不会再发
  /// 插拔通知，不补一次的话要等下一次睡醒（评审，同 G24）。真拔掉了的多试这一次也没坏处
  private func restart(retry: Bool = true) {
    guard !subscribers.isEmpty else { return }
    let before = devices.count
    stopDevices()
    startDevices()
    for reset in subscribers.resets { reset() }
    guard retry, devices.count < before else { return }
    pendingRestart = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.restart(retry: false)
    }
  }

  /// 插拔时 first-match / terminated 常常连着来、醒来时设备一个个回来：最后一个之后 0.3 s 才重起一次
  private func restartSoon() {
    pendingRestart?.cancel()
    pendingRestart = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.restart()
    }
  }

  /// 醒来（设备可能已经失效，F25）和 AppleMultitouchDevice 插 / 拔（妙控板后来才连上、拔掉了）。
  /// IOKit 的通知端口挂在主线程的 run loop 上
  private func listen() {
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.restartSoon() }
    }
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    notifyPort = port
    CFRunLoopAddSource(
      CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
      .commonModes)
    for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
      var iterator: io_iterator_t = 0
      // 匹配字典会被这个调用拿走一份引用，不另外释放
      guard
        IOServiceAddMatchingNotification(
          port, type, IOServiceMatching("AppleMultitouchDevice"),
          { _, iterator in Touchpad.devicesChanged(iterator) }, nil, &iterator) == KERN_SUCCESS
      else { continue }
      Self.drain(iterator)  // 先把已有的取空，通知才会开始来
      iterators.append(iterator)
    }
  }

  private func stopListening() {
    pendingRestart?.cancel()
    pendingRestart = nil
    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
      self.wakeObserver = nil
    }
    for iterator in iterators { IOObjectRelease(iterator) }
    iterators = []
    if let notifyPort { IONotificationPortDestroy(notifyPort) }
    notifyPort = nil
  }

  /// IOKit 的回调（主线程 run loop 上）：取空迭代器，有变化才排一次重起
  nonisolated private static func devicesChanged(_ iterator: io_iterator_t) {
    guard drain(iterator) > 0 else { return }
    MainActor.assumeIsolated { Touchpad.shared.restartSoon() }
  }

  @discardableResult
  nonisolated private static func drain(_ iterator: io_iterator_t) -> Int {
    var count = 0
    while case let service = IOIteratorNext(iterator), service != 0 {
      IOObjectRelease(service)
      count += 1
    }
    return count
  }

  private struct Symbols {
    let createList: MTDeviceCreateListFn
    let register: MTRegisterCallbackFn
    let unregister: MTRegisterCallbackFn
    let start: MTDeviceStartFn
    let stop: MTDeviceStopFn
    /// 可能没有：没有就不按尺寸筛
    let dimensions: MTDeviceDimensionsFn?
  }

  /// 只 dlopen 一次、不 dlclose（设备开着时函数指针要一直有效）
  private static let symbols: Symbols? = {
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
    else {
      dlclose(handle)
      return nil
    }
    return Symbols(
      createList: unsafeBitCast(listSymbol, to: MTDeviceCreateListFn.self),
      register: unsafeBitCast(registerSymbol, to: MTRegisterCallbackFn.self),
      unregister: unsafeBitCast(unregisterSymbol, to: MTRegisterCallbackFn.self),
      start: unsafeBitCast(startSymbol, to: MTDeviceStartFn.self),
      stop: unsafeBitCast(stopSymbol, to: MTDeviceStopFn.self),
      dimensions: dlsym(handle, "MTDeviceGetSensorSurfaceDimensions").map {
        unsafeBitCast($0, to: MTDeviceDimensionsFn.self)
      })
  }()
}
