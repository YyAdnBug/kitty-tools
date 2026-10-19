// 触控板捏合的私有框架桥（SPEC §5.6，R7）。**只运行时 dlopen / dlsym，不链接、不写进工程设置**；找不到符号或设备
// 就退回（设置里那一行写明「这台 Mac 上用不了」，别的入口照常）。
// 框架在自己的线程调 C 回调：回调里只把这一帧拷成值类型交给 Mutex 里的识别器（每个设备一个）；跟着的那一下的进度
// 每帧写进桥的 `progress`（Mutex，主线程的屏幕刷新回调每帧来取），开始 / 松手 / 取消三件事才 DispatchQueue.main.async
// 回主线程（2026-10-19 起跟手，GESTURE.md A7：每帧都派一次的话，触控板约 8 ms 一帧、屏幕 60 / 120 Hz，节奏对不上会抖）——
// **回调里不碰主线程状态**（mac-native §3）。
// 只在功能开着、系统的捏合关着时注册回调；停的时候注销 + MTDeviceStop + 放掉设备。
// 触点结构体照公开的逆向资料（OpenMultitouchSupport / LaunchNext 的思路，**一行代码都不拷**）：64 位下
// frame / timestamp / identifier / state / fingerId / handId / normalized(pos + vel) / zTotal / …；
// 我们只读 identifier、state 和 normalized.pos。ponytail: 布局是逆向来的，系统改了字段顺序要重新核对（HANDTEST 10）。

import AppKit
import Darwin
import Synchronization

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

/// C 回调：`int (*)(MTDeviceRef, MTFinger *, int count, double timestamp, int frame)`。
/// 触点数组在 C 侧只当裸指针收下，进回调再 `assumingMemoryBound` 成 MTFinger（Swift 的 struct 不能直接进 @convention(c) 签名）
typealias MTContactCallback =
  @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
private typealias MTRegisterCallbackFn =
  @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTUnregisterCallbackFn =
  @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

/// 回调在框架线程上跑：这里只碰识别器（Mutex 里）、写最新进度、把三件事派回主线程。
/// **必须 `nonisolated`**：工程默认 MainActor 隔离，不写的话这个类和它的方法会被推成 @MainActor，框架线程一调进来
/// 就被 Swift 6 的隔离检查当场 trap（G1：第 3 批起就有，系统手势一关、一碰触控板就崩）。
nonisolated final class TouchpadBridge: Sendable {
  private let recognizers = Mutex<[UInt: PinchRecognizer]>([:])
  /// 按需实录探针用：真收到多少帧（只增，不参与识别）
  let frames = Mutex<Int>(0)
  /// 正在跟的那一下最新的进度（0…1）：框架线程每帧写、主线程的屏幕刷新回调每帧读。只在跟着的时候写，
  /// 开始那一帧先写进度再派「开始」，主线程收到「开始」时这里已经是这一下的了
  let progress = Mutex<Double>(0)
  private let sensitivity: PinchRecognizer.Sensitivity
  private let fingers: PinchFingers
  let onEvent: @Sendable (PinchRecognizer.Event) -> Void

  init(
    sensitivity: PinchRecognizer.Sensitivity, fingers: PinchFingers = .four,
    onEvent: @escaping @Sendable (PinchRecognizer.Event) -> Void
  ) {
    self.sensitivity = sensitivity
    self.fingers = fingers
    self.onEvent = onEvent
  }

  func feed(device: UInt, frame: TouchFrame) {
    frames.withLock { $0 += 1 }
    let (event, current) = recognizers.withLock { table -> (PinchRecognizer.Event?, Double?) in
      var recognizer =
        table[device] ?? PinchRecognizer(sensitivity: sensitivity, fingers: fingers)
      let result = recognizer.feed(frame)
      table[device] = recognizer
      return (result, recognizer.progress)
    }
    if let current { progress.withLock { $0 = current } }
    if let event { onEvent(event) }
  }

  func forget(device: UInt) {
    _ = recognizers.withLock { $0.removeValue(forKey: device) }
  }
}

/// 现在的桥（C 回调拿不到上下文，只能走这个全局）：框架线程读、主线程换，用 Mutex 护住引用，
/// 不会出现「刚读出引用、主线程就放掉」的 use-after-free（F25）
nonisolated private let activeBridge = Mutex<TouchpadBridge?>(nil)

/// 回调的本体是一个普通的 nonisolated 函数：C 函数指针的字面量里**不写任何闭包**（字面量在默认 MainActor 隔离下会被
/// 推成 MainActor，里面的闭包到了框架线程上一执行就 trap，G1）
nonisolated private func handleContactFrame(
  _ device: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, _ count: Int32,
  _ timestamp: Double
) -> Int32 {
  guard let device, let bridge = activeBridge.withLock({ $0 }) else { return 0 }
  // 空帧也喂：全抬起来要让识别器重置（F25）
  let touches = data.map { TouchpadWatcher.touches(from: $0, count: Int(count)) } ?? []
  bridge.feed(
    device: UInt(bitPattern: device), frame: TouchFrame(time: timestamp, touches: touches))
  return 0
}

nonisolated private let contactCallback: MTContactCallback = { device, data, count, timestamp, _ in
  handleContactFrame(device, data, count, timestamp)
}

/// 触控板捏合的监听（Launchpad 拿着；只在功能开着、系统的捏合关着时 start）
@MainActor
final class TouchpadWatcher {
  enum Availability: Equatable {
    case unknown, available, unavailable
  }

  private(set) var availability: Availability = .unknown
  /// 开始 / 松手 / 取消（已经在主线程）；每帧的进度看 `pinchProgress`
  var onPinch: ((PinchRecognizer.Event) -> Void)?

  private var devices: [UnsafeMutableRawPointer] = []
  /// MTDeviceCreateList 给的数组：设备裸指针只在它活着时有效，start() 返回后也要拿着（F6）
  private var deviceList: CFMutableArray?
  private var symbols: Symbols?
  private var sensitivity: PinchRecognizer.Sensitivity = .standard
  private var fingers: PinchFingers = .four
  private var wakeObserver: NSObjectProtocol?
  /// 每次 start / stop 换一代：派回主线程的旧手势看到代号变了就不回调（F25）
  private var generation = 0
  private var bridge: TouchpadBridge?
  private var isStarted = false
  /// 调用方要它开着（start 过、还没 stop）：唤醒后重新注册时按它判断，不按「上次起成功没有」——
  /// 唤醒那一下设备还没就绪、start 失败了，下一次唤醒照样再试（G24）
  private var wantsRunning = false

  /// 正在跟的那一下最新的进度（屏幕刷新回调每帧读；没起监听时 0）
  var pinchProgress: Double { bridge?.progress.withLock { $0 } ?? 0 }

  /// 按需实录探针（命令行 `TEST_RUNNER_KITTY_LIVE_TOUCH=1`，测试进程里读到的是 `KITTY_LIVE_TOUCH`）用的计数；正常路径不读
  nonisolated static var framesSeen: Int {
    activeBridge.withLock { bridge in bridge.map { $0.frames.withLock { $0 } } ?? 0 }
  }

  /// 单测用：装一个桥（nil = 拆掉）。不注册回调、不碰框架（G1 的单测在后台线程上直接调回调）
  nonisolated static func installBridgeForTesting(_ bridge: TouchpadBridge?) {
    activeBridge.withLock { $0 = bridge }
  }

  /// 单测用：交给框架的那个 C 回调本身
  nonisolated static var contactCallbackForTesting: MTContactCallback { contactCallback }

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

  /// 开着监听。已经开着、灵敏度和手指数也没变时什么都不做（G8：别的窗口变 key、导入设置都会走到这里，
  /// 每次整套注销重注册会把正在捏的那一下的识别器清掉）；`force` 只给唤醒后的重新注册用
  func start(
    sensitivity: PinchRecognizer.Sensitivity, fingers: PinchFingers = .four, force: Bool = false
  ) {
    wantsRunning = true
    observeWake()
    if isStarted, !force, sensitivity == self.sensitivity, fingers == self.fingers { return }
    self.sensitivity = sensitivity
    self.fingers = fingers
    if isStarted {
      abandonGesture()
      bridge = nil
      activeBridge.withLock { $0 = nil }
      stopDevices()
      deviceList = nil
      isStarted = false
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
    deviceList = list
    // 结构体步长不对就别注册：读出来的触点是错位的，不如退回「这台 Mac 上用不了」（F6）
    guard MemoryLayout<MTFinger>.stride == 96 else {
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
    generation += 1
    let bridge = TouchpadBridge(
      sensitivity: sensitivity, fingers: fingers,
      onEvent: Self.forwarder(to: self, generation: generation))
    self.bridge = bridge
    activeBridge.withLock { $0 = bridge }
    for device in devices {
      loaded.symbols.register(device, contactCallback)
      loaded.symbols.start(device, 0)
    }
    isStarted = true
    availability = .available
  }

  /// 识别结果派回主线程的那一下：在 nonisolated 的上下文里建，闭包不会被推成 MainActor
  /// （它是在框架线程上被调的，G1）
  nonisolated private static func forwarder(
    to watcher: TouchpadWatcher, generation: Int
  ) -> @Sendable (PinchRecognizer.Event) -> Void {
    { [weak watcher] event in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let watcher, watcher.isStarted, watcher.generation == generation else { return }
          watcher.onPinch?(event)
        }
      }
    }
  }

  /// 睡眠唤醒后设备可能已经失效：重新枚举、注册（F25；真机验）。按「调用方要它开着」判断（G24）
  private func observeWake() {
    guard wakeObserver == nil else { return }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.wantsRunning else { return }
        self.start(sensitivity: self.sensitivity, fingers: self.fingers, force: true)
      }
    }
  }

  /// 关掉：注销回调、停设备、放掉桥（回调里再进来也不会认）
  func stop() {
    wantsRunning = false
    abandonGesture()
    generation += 1
    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
      self.wakeObserver = nil
    }
    guard isStarted else {
      activeBridge.withLock { $0 = nil }
      deviceList = nil
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
    activeBridge.withLock { $0 = nil }
    bridge = nil
    symbols = nil
    deviceList = nil
    isStarted = false
  }

  /// 正在跟的那一下等不到松手了（停监听、重新注册之后旧的事件都不认）：两种各报一次取消，总控只认它正在跟的那种——
  /// 不然捏到一半的面板一直半透明地挂着、不收鼠标也不拿键盘
  private func abandonGesture() {
    onPinch?(.cancelled(.pinch))
    onPinch?(.cancelled(.spread))
  }

  private func stopDevices() {
    if let symbols {
      for device in devices {
        symbols.unregister(device, contactCallback)
        symbols.stop(device)
      }
    }
    devices = []
    activeBridge.withLock { $0 = nil }
    deviceList = nil
    isStarted = false
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
