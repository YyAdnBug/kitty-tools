// 触控板触点的监听（Shell/Touchpad）：订阅者表的起停判断、交给框架线程的那份快照（几个订阅者、换快照时帧数接着数）、
// 按尺寸认触控板，和 G1（框架线程上调 C 回调不 trap）。**不注册真的回调、不读真触点**：只在后台线程上直接调那个 C 回调、
// 装造好的快照；真的读得到是按需探针 LaunchpadLiveTouchTests。
// 串行跑：装快照的那几条改的是同一个全局。

import Foundation
import Synchronization
import Testing

@testable import KittyTools

@Suite(.serialized)
@MainActor
struct TouchpadTests {
  /// 第一个订阅者来了才起设备、最后一个走了才停；中间来来去去（包括同一个 key 再订一次）只换快照
  @Test func subscribersStartOnFirstAndStopOnLast() {
    let first = Collector()
    let second = Collector()
    var table = TouchpadSubscribers()
    #expect(table.subscribe("a", consumer: first.consumer, onReset: {}) == .start)
    #expect(table.subscribe("b", consumer: second.consumer, onReset: {}) == .swap)
    // 同一个 key 再来：换掉回调、位置不变、不重起（G8）
    var resets: [String] = []
    #expect(
      table.subscribe("a", consumer: second.consumer, onReset: { resets.append("a") }) == .swap)
    #expect(table.entries.map { $0.key } == ["a", "b"])
    for consumer in table.consumers { consumer(7, TouchFrame(time: 0, touches: [])) }
    #expect(first.frames.withLock { $0.count } == 0)
    #expect(second.frames.withLock { $0.count } == 2)
    for reset in table.resets { reset() }
    #expect(resets == ["a"])
    #expect(table.unsubscribe("nobody") == .none)
    #expect(table.unsubscribe("a") == .swap)
    #expect(table.entries.map { $0.key } == ["b"])
    #expect(table.unsubscribe("b") == .stop)
    #expect(table.isEmpty)
    #expect(table.subscribe("b", consumer: second.consumer, onReset: {}) == .start)
  }

  /// 传感器尺寸（0.01 mm）：触控板是横着的、至少 30 mm 高；Touch Bar 太矮、妙控鼠标是竖着的、量不出来的是 0
  @Test func onlyTrackpadSizedSurfacesAreAccepted() {
    #expect(Touchpad.isTrackpad(width: 16_000, height: 10_000))  // 内置触控板
    #expect(Touchpad.isTrackpad(width: 16_000, height: 11_500))  // 妙控板
    #expect(Touchpad.isTrackpad(width: 6_000, height: 3_000))
    #expect(!Touchpad.isTrackpad(width: 25_000, height: 800))  // Touch Bar
    #expect(!Touchpad.isTrackpad(width: 5_500, height: 9_500))  // 妙控鼠标
    #expect(!Touchpad.isTrackpad(width: 5_000, height: 5_000))
    #expect(!Touchpad.isTrackpad(width: 6_000, height: 2_999))
    #expect(!Touchpad.isTrackpad(width: 0, height: 0))
  }

  /// G1：框架是在它自己的线程上调回调的。在后台线程上直接调那个 C 回调、经启动台捏合真正用的那个收帧闭包，不能 trap
  /// （修之前整个测试进程会崩）
  @Test func contactCallbackRunsOnABackgroundThread() async {
    let tracker = PinchTracker(sensitivity: .standard) { _ in }
    let collector = Collector()
    Touchpad.installBridgeForTesting(
      TouchpadBridge(consumers: [
        TouchpadWatcher.consumer(feeding: tracker), collector.consumer,
      ]))
    defer { Touchpad.installBridgeForTesting(nil) }
    let before = Touchpad.framesSeen
    let callback = Touchpad.contactCallbackForTesting
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4 * 96, alignment: 8)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 4 * 96)
        let device = UnsafeMutableRawPointer(bitPattern: 0x10)
        _ = callback(device, buffer, 4, 1, 1)
        // 全抬起来的空帧也要能进
        _ = callback(device, nil, 0, 1.01, 2)
        buffer.deallocate()
        continuation.resume()
      }
    }
    #expect(Touchpad.framesSeen - before == 2)
    #expect(collector.frames.withLock { $0.map(\.touches.count) } == [4, 0])
  }

  /// 每一帧按顺序交给快照里的每个订阅者（设备编号 = 设备指针）；换快照后帧数接着数，拆掉以后谁都不收、也不数
  @Test func everySubscriberGetsEveryFrameAndTheCountSurvivesSwaps() {
    let first = Collector()
    let second = Collector()
    let before = Touchpad.framesSeen
    let callback = Touchpad.contactCallbackForTesting
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 2 * 96, alignment: 8)
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 2 * 96)
    defer { buffer.deallocate() }
    for index in 0..<2 {
      buffer.storeBytes(of: Int32(20 + index), toByteOffset: index * 96 + 16, as: Int32.self)
      buffer.storeBytes(of: Int32(4), toByteOffset: index * 96 + 20, as: Int32.self)
    }
    let device = UnsafeMutableRawPointer(bitPattern: 0x20)
    Touchpad.installBridgeForTesting(TouchpadBridge(consumers: [first.consumer, second.consumer]))
    defer { Touchpad.installBridgeForTesting(nil) }
    _ = callback(device, buffer, 2, 2, 1)
    Touchpad.installBridgeForTesting(TouchpadBridge(consumers: [second.consumer]))
    _ = callback(device, nil, 0, 2.01, 2)
    Touchpad.installBridgeForTesting(nil)
    _ = callback(device, buffer, 2, 2.02, 3)
    #expect(Touchpad.framesSeen - before == 2)
    #expect(first.frames.withLock { $0.map(\.time) } == [2])
    #expect(second.frames.withLock { $0.map(\.time) } == [2, 2.01])
    #expect(second.frames.withLock { $0.first?.touches.map(\.id) } == [20, 21])
    #expect(second.devices.withLock { Set($0) } == [0x20])
  }
}

/// 订阅者在（可能是后台的）框架线程上记下收到的帧（Mutex 不能直接被逃逸闭包捕获，包一层）
nonisolated private final class Collector: Sendable {
  let frames = Mutex<[TouchFrame]>([])
  let devices = Mutex<[UInt]>([])

  var consumer: TouchConsumer {
    { [self] device, frame in
      frames.withLock { $0.append(frame) }
      devices.withLock { $0.append(device) }
    }
  }
}
