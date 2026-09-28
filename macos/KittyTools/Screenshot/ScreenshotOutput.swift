// 截图的文件输出：PNG 编码（写 DPI，Retina 截图在预览里、粘贴后都按原来的大小显示）、⌘S 快速保存、另存为。
// 只出 PNG（修旧版 JPEG 透明变黑、WebP 无视质量，§11 #45）；重名追加序号，不覆盖（§11 #46）。
// 快速保存的目录 = 设置 › 截图「快速保存到」选的文件夹 → 系统截屏的存储位置 → 桌面（不存在的跳过）。
// 「另存为」不改它（体检 A28）：存储面板自己记住上次访问的文件夹。

import AppKit
import UniformTypeIdentifiers

enum ScreenshotOutput {
  /// 编码成 PNG（白名单第 1 类，@concurrent）。scale 是像素 / 点，写成 DPI（2x → 144）
  @concurrent nonisolated static func png(_ image: CGImage, scale: CGFloat) async -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    let dpi = 72 * scale
    CGImageDestinationAddImage(
      destination, image,
      [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  static var saveDirectory: URL {
    directory(saved: UserDefaults.standard.string(forKey: Prefs.screenshotSaveDirectory))
  }

  /// saved：设置里选的文件夹（没选过 = nil）。已不存在的目录（拔掉的移动硬盘等）跳过，往下退
  static func directory(saved: String?) -> URL {
    let candidates = [
      saved,
      UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location").map {
        ($0 as NSString).expandingTildeInPath
      },
    ]
    for case let path? in candidates {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return URL(filePath: path, directoryHint: .isDirectory)
      }
    }
    return .desktopDirectory
  }

  /// 「截图 2026-09-24 22.46.10.png」；已有同名文件就追加「 2」「 3」…。纯函数（只查文件是否存在），配单测
  static func availableURL(in directory: URL, date: Date = .now) -> URL {
    let stamp = date.formatted(
      Date.VerbatimFormatStyle(
        format:
          "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian)))
    let base = "截图 \(stamp)"
    var url = directory.appending(path: "\(base).png")
    var index = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = directory.appending(path: "\(base) \(index).png")
      index += 1
    }
    return url
  }

  /// ⌘S：存进快速保存目录（首次写桌面 / 下载等目录时系统会问一次文件夹访问授权）
  @discardableResult
  static func quickSave(_ png: Data) throws -> URL {
    let url = availableURL(in: saveDirectory)
    try png.write(to: url, options: .withoutOverwriting)
    return url
  }

  /// 另存为：遮罩已收起。先激活本 App（面板才拿得到键盘），存完把前台还给原来的 App。不设 directoryURL：
  /// 存储面板按 App 记住上次访问的文件夹（系统行为）；选的文件夹也不记成快速保存的目录（体检 A28，同 ⌘⇧5）。
  /// 用不模态的 begin 而不是 runModal：runModal 在主 actor 的任务里会卡住其它主线程任务（流式译文、截图热键）。
  /// 返回存到的文件（取消时为 nil）
  @discardableResult
  static func saveAs(_ png: Data) async throws -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = availableURL(in: saveDirectory).lastPathComponent
    let previous = NSWorkspace.shared.frontmostApplication
    NSApp.activate()
    // macOS 14 起 activate() 是协作式的，前台 App 不让出时退回旧 API（同设置窗）
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    defer { previous?.activate() }
    let response = await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    guard response == .OK, let url = panel.url else { return nil }
    try png.write(to: url, options: .atomic)
    return url
  }
}
