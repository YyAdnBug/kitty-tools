// 剪贴板采集读大图的开销探针（第四轮体检 F4②；按需开，默认跳过）：`TEST_RUNNER_KITTY_CLIPBOARD_PROBE=1` 才跑，几秒。
// 不碰系统剪贴板（也就不进剪贴板历史）：在一块自己起名的剪贴板上放一张约 40 MP 的图（ImageStore.maxPixels 的上限），
// 量主线程上 data(forType:) 读 .png、.tiff 各要多久——ClipboardWatcher.poll 就是这样整份读出来再判大小的。写入方两种：
// 本进程（数据可能就留在本进程里）、另起一个进程（osascript，读的时候要从剪贴板服务整份拉过来，接近别的 App 复制的情形）；
// 另看只放了 TIFF 时 types 里有没有 PNG、读 .png 会不会现场转一份。通用剪贴板（iPhone 传来的）是读的那一刻才去拉，
// 这里量不到，只能真机看。结果 grep「clipboard-probe」。

import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor
struct ClipboardProbeTests {
  nonisolated private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["KITTY_CLIPBOARD_PROBE"] == "1"
  }

  /// 约 40 MP（7680 × 5200）、像照片一样压不太小的图：渐变上叠一层噪声（整行噪声错位复用，Debug 构建里也快）
  private func photo() throws -> CGImage {
    let (width, height) = (7680, 5200)
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    var noise = [UInt8](repeating: 0, count: width * 4 + 4096)
    var seed: UInt32 = 0x1234_5678
    for index in noise.indices {
      seed ^= seed << 13
      seed ^= seed >> 17
      seed ^= seed << 5
      noise[index] = UInt8(truncatingIfNeeded: seed)
    }
    noise.withUnsafeBufferPointer { source in
      for row in 0..<height {
        let offset = (row * 97) % 4096
        (bytes + row * width * 4).update(from: source.baseAddress! + offset, count: width * 4)
      }
    }
    let gradient = try #require(
      CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
          CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 0.85),
          CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 0.85),
        ] as CFArray,
        locations: [0, 1]))
    context.drawLinearGradient(
      gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    return try #require(context.makeImage())
  }

  private func encode(_ image: CGImage, as type: UTType) throws -> Data {
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// 读一次要多久（毫秒）和读到多少字节
  private func read(_ pasteboard: NSPasteboard, _ type: NSPasteboard.PasteboardType) -> (
    ms: Double, bytes: Int
  ) {
    let clock = ContinuousClock()
    var bytes = 0
    let elapsed = clock.measure { bytes = pasteboard.data(forType: type)?.count ?? -1 }
    return (elapsed / .milliseconds(1), bytes)
  }

  /// 另起一个进程往这块剪贴板写（写完它就退出，数据留在剪贴板服务里）
  private func writeFromAnotherProcess(name: String, files: [(URL, UTType)]) throws {
    let writes = files.map {
      "pb.setDataForType($.NSData.dataWithContentsOfFile($('\($0.0.path)')), $('\($0.1.identifier)'));"
    }.joined()
    let script =
      "ObjC.import('AppKit'); var pb = $.NSPasteboard.pasteboardWithName($('\(name)')); pb.clearContents; "
      + writes
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", script]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  @Test(.enabled(if: ClipboardProbeTests.isEnabled)) func measure() throws {
    let name = "com.yy.kitty-tools.clipboard-probe-\(UUID().uuidString)"
    let pasteboard = NSPasteboard(name: .init(name))
    let folder = FileManager.default.temporaryDirectory.appending(path: name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      pasteboard.releaseGlobally()
      try? FileManager.default.removeItem(at: folder)
    }
    let image = try photo()
    let png = try encode(image, as: .png)
    let tiff = try encode(image, as: .tiff)
    let mb = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    print(
      "clipboard-probe 图 \(image.width)×\(image.height)，PNG \(mb(png.count))，TIFF \(mb(tiff.count))"
    )

    // 本进程写、本进程读
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    pasteboard.setData(tiff, forType: .tiff)
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
      let first = read(pasteboard, type)
      let second = read(pasteboard, type)
      print(
        "clipboard-probe 本进程写 \(type.rawValue)：第一次 \(String(format: "%.0f", first.ms)) ms"
          + "（\(mb(first.bytes))），第二次 \(String(format: "%.0f", second.ms)) ms")
    }

    // 别的进程写（PNG + TIFF 都有）：读 watcher 读之前那几样，再读图
    let pngFile = folder.appending(path: "probe.png")
    let tiffFile = folder.appending(path: "probe.tiff")
    try png.write(to: pngFile)
    try tiff.write(to: tiffFile)
    try writeFromAnotherProcess(name: name, files: [(pngFile, .png), (tiffFile, .tiff)])
    let clock = ContinuousClock()
    let before = clock.measure {
      _ = pasteboard.types
      _ = pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      _ = pasteboard.string(forType: .string)
    }
    print("clipboard-probe 别的进程写：读图之前的 types / 文件 / 文字共 \(before)")
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
      let first = read(pasteboard, type)
      let second = read(pasteboard, type)
      print(
        "clipboard-probe 别的进程写 \(type.rawValue)：第一次 \(String(format: "%.0f", first.ms)) ms"
          + "（\(mb(first.bytes))），第二次 \(String(format: "%.0f", second.ms)) ms")
    }

    // 别的进程只写了 TIFF：types 里有没有 PNG（有的话读 .png 是现场转出来的）
    try writeFromAnotherProcess(name: name, files: [(tiffFile, .tiff)])
    let types = (pasteboard.types ?? []).map(\.rawValue)
    let pngRead = read(pasteboard, .png)
    let tiffRead = read(pasteboard, .tiff)
    print(
      "clipboard-probe 只写 TIFF：types = \(types)；读 .png \(String(format: "%.0f", pngRead.ms)) ms"
        + "（\(pngRead.bytes < 0 ? "没有" : mb(pngRead.bytes))），读 .tiff \(String(format: "%.0f", tiffRead.ms)) ms"
    )
  }
}
