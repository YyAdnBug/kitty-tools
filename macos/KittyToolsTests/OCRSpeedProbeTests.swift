// 识字速度探针（2026-11-26「截图翻译识字变慢」，按需开，平时不跑）：同一个测试宿主进程里冷识、热识、放掉模型后再识、
// 实况文本各要多久，每一步前后数一下系统编好的识字模型缓存（~/Library/Caches/<宿主 bundle id>/com.apple.e5rt.e5bundlecache）
// 里有几个文件。前后对比用同一种构建：
//   TEST_RUNNER_KITTY_OCR_SPEED_PROBE=1 xcodebuild … test SWIFT_OPTIMIZATION_LEVEL=-O \
//     -only-testing:'KittyToolsTests/OCRSpeedProbeTests/measure()'
// 三种值：1 = 只量（measure）；purge = measure 中途照系统的紧急清理删一遍缓存文件；devices（跑 devices()）= 删掉后指定
// CPU / GPU 各识一次。purge / devices 会删 Dev 版自己编好的模型（ocr-ready 标记还在），之后 Dev 版和单测第一次识字都要
// 现场重编半分钟（helperRecognizesInSubprocess 跟着变慢）。结果 grep「ocr-speed」；缓存空着时整次要一两分钟。

import AppKit
import CoreML
import CoreText
import Foundation
import Testing
import Vision
import VisionKit

@testable import KittyTools

struct OCRSpeedProbeTests {
  /// devices 和 measure 不同时跑（并行时一个删缓存、一个在计时）
  nonisolated static let enabled =
    ProcessInfo.processInfo.environment["KITTY_OCR_SPEED_PROBE"].map {
      ["1", "purge"].contains($0)
    }
    ?? false

  @Test(.enabled(if: enabled), .timeLimit(.minutes(10))) func measure() async throws {
    let image = try #require(Self.textImage())
    log("cache at start: \(Self.cacheState())")
    func vision(_ label: String) async {
      let (count, seconds) = await Self.timed { await OCR.recognizeLines(in: image)?.count ?? -1 }
      log("vision \(label): \(count) lines \(Self.ms(seconds)); cache \(Self.cacheState())")
    }
    func release() async {
      let released = await OCR.releaseModel()
      log("releaseModel=\(released); cache \(Self.cacheState())")
    }
    await vision("cold")
    await vision("warm")
    await release()
    await vision("after release, cache intact")
    // 磁盘快满时系统的紧急清理（CacheDelete 的 CriticalPurge）会删掉编好的模型（2026-11-26 正式版实测几分钟一次）。
    // KITTY_OCR_SPEED_PROBE=purge 时照样删一遍宿主（Dev 版）自己的这份，看模型还在内存里 / 放掉之后各要多久
    if ProcessInfo.processInfo.environment["KITTY_OCR_SPEED_PROBE"] == "purge" {
      log("purged \(Self.purgeCache()) files")
      await vision("loaded, cache purged")
      await release()
      await vision("after release, cache purged")
      await vision("warm again")
    }
    for label in ["cold", "warm"] {
      let (count, seconds) = await Self.timed {
        (try? await LiveText.analysis(of: image)?.transcript.count) ?? -1
      }
      log("live text \(label): \(count) chars \(Self.ms(seconds))")
    }
  }

  /// KITTY_OCR_SPEED_PROBE=devices：清掉编好的模型后，指定 CPU / GPU 识各要多久、会不会也去现场编，最后才走默认（ANE）
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["KITTY_OCR_SPEED_PROBE"] == "devices"),
    .timeLimit(.minutes(10)))
  func devices() async throws {
    let image = try #require(Self.textImage())
    func request(_ pick: ((MLComputeDevice) -> Bool)?) -> RecognizeTextRequest {
      var request = RecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.automaticallyDetectsLanguage = true
      request.recognitionLanguages = []
      if let pick {
        for (stage, devices) in request.supportedComputeStageDevices {
          request.setComputeDevice(devices.first(where: pick), for: stage)
        }
      }
      return request
    }
    func run(_ label: String, _ pick: ((MLComputeDevice) -> Bool)?) async {
      let (count, seconds) = await Self.timed {
        (try? await request(pick).perform(on: image).count) ?? -1
      }
      log("\(label): \(count) lines \(Self.ms(seconds)); cache \(Self.cacheState())")
    }
    let cpu: (MLComputeDevice) -> Bool = { if case .cpu = $0 { true } else { false } }
    let gpu: (MLComputeDevice) -> Bool = { if case .gpu = $0 { true } else { false } }
    log("devices \(request(nil).supportedComputeStageDevices)")
    await run("default warm-up", nil)
    await run("default warm", nil)
    await run("cpu (cache intact) 1", cpu)
    await run("cpu (cache intact) 2", cpu)
    log("purged \(Self.purgeCache()) files")
    await run("cpu (cache purged) 1", cpu)
    await run("cpu (cache purged) 2", cpu)
    await run("gpu (cache purged) 1", gpu)
    await run("gpu (cache purged) 2", gpu)
    await run("default (cache purged)", nil)
    await run("default warm", nil)
  }

  private func log(_ text: String) { print("ocr-speed \(text)") }

  static func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

  static func timed<T>(_ work: () async -> T) async -> (T, Double) {
    let start = ContinuousClock.now
    let value = await work()
    let elapsed = ContinuousClock.now - start
    return (
      value, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    )
  }

  /// 宿主自己编好的模型缓存（Vision 的私有布局，只在探针里看）
  static var cacheRoot: URL? {
    guard let id = Bundle.main.bundleIdentifier,
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return caches.appending(path: "\(id)/com.apple.e5rt.e5bundlecache")
  }

  static func cacheFiles() -> [(url: URL, bytes: Int)] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let root = cacheRoot,
      let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
    else { return [] }
    return
      items.compactMap { item in
        guard let url = item as? URL,
          let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
        else { return nil }
        return (url, values.fileSize ?? 0)
      }
  }

  /// 编好的模型缓存里普通文件的个数和总大小
  static func cacheState() -> String {
    let files = cacheFiles()
    return "\(files.count) files \(files.reduce(0) { $0 + $1.bytes } / 1024) KB"
  }

  /// 同系统的紧急清理：只删文件、留目录
  static func purgeCache() -> Int {
    cacheFiles().filter { (try? FileManager.default.removeItem(at: $0.url)) != nil }.count
  }

  /// 白底黑字中英混排、大小字都有，像一块截图选区（1200 × 600 像素）
  static func textImage() -> CGImage? {
    let width = 1200
    let height = 600
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let lines: [(String, CGFloat)] = [
      ("截图翻译：框选一块文字，识别后送去翻译", 30),
      ("The quick brown fox jumps over the lazy dog 0123456789.", 24),
      ("设置 › 截图 › 高级：空闲时释放识字模型，下次识字要重新加载。", 20),
      ("Release the OCR model when idle to save memory between uses.", 18),
      ("小字：系统第一次识字要先把模型编好，存在缓存目录里，以后就快了。", 14),
      ("Small print: compiled models live in the app's cache directory.", 13),
      ("更小的字 11 号：中英混排 mixed text, 标点「」、（）。", 11),
    ]
    var y = CGFloat(height) - 50
    for (text, size) in lines {
      let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
      context.textPosition = CGPoint(x: 24, y: y)
      CTLineDraw(line, context)
      y -= size * 2.4
    }
    return context.makeImage()
  }
}
