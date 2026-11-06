// 截图的文件输出：PNG 编码（写 DPI，Retina 截图在预览里、粘贴后都按原来的大小显示）、⌘S 快速保存、另存为。
// 只出 PNG（修旧版 JPEG 透明变黑、WebP 无视质量，§11 #45）；重名追加序号，不覆盖（§11 #46）。
// 快速保存的目录 = 设置 › 截图「快速保存到」选的文件夹 → 系统截屏的存储位置 → 桌面（不存在的跳过）。
// 「另存为」不改它（体检 A28）：存储面板自己记住上次访问的文件夹。
// 拷贝成 PNG 文件（设置 › 截图「截图拷贝为」，2026-11-06）：文件在拖出目录里（copyFile），剪贴板里只有这个文件。

import AppKit
import UniformTypeIdentifiers

enum ScreenshotOutput {
  /// 截图拷贝进剪贴板的是什么：图像，或者拖出目录里的这个 PNG 文件（设置 › 截图「截图拷贝为」）
  enum Copied {
    case image
    case file(URL)

    /// 刘海岛的小字：拷成文件时写文件名
    var detail: String? {
      guard case .file(let url) = self else { return nil }
      return url.lastPathComponent
    }
  }

  /// 拷贝成文件时的那一份：拖出目录（ShotShelf.dragDirectory）里一个新的子文件夹，各放各的不撞名；name 给了用给的
  /// （历史里存过的借存的文件名），没给照快速保存起「截图 日期 时间.png」。**用的时候不删**：对方可能过一会儿才粘
  /// （跨电脑的剪贴板工具粘的那一刻才来读），启动时清空、换日时删一天以前的（ShotShelf.purgeStaleDragFiles）。
  /// 写盘在主线程外（ShotHistory.write）；写不成给 nil，调用方改放图像
  static func copyFile(_ png: Data, name: String?) async -> URL? {
    let folder = ShotShelf.dragDirectory.appending(path: UUID().uuidString)
    let url = name.map { folder.appending(path: $0) } ?? availableURL(in: folder)
    return await ShotHistory.write(png, to: url) ? url : nil
  }

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

  /// 快速保存那一项的叫法（截图家族同一个，体检 B41；截图历史窗口也是，第四轮体检 U13）：存储到「桌面」——访达里的名字，
  /// 不写 Desktop
  static var saveTitle: String { "存储到「\(saveFolderName)」" }

  /// 快速保存的文件夹在访达里的名字（「桌面」）：多选时「存储 3 项到「桌面」」也用它
  static var saveFolderName: String { FileManager.default.displayName(atPath: saveDirectory.path) }

  /// saved：设置里选的文件夹（没选过 = nil）。已不存在的目录（拔掉的移动硬盘等）跳过，往下退。
  /// 要查文件夹在不在（可能在卡住的网络盘上）：快速保存在主线程外调它（quickSave）
  nonisolated static func directory(saved: String?) -> URL {
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

  /// 「截图 2026-09-24 22.46.10.png」；已有同名文件就追加「 2」「 3」…。录屏传「录屏」「mp4」（同一个快速保存目录）。
  /// 纯函数（只查文件是否存在），配单测
  nonisolated static func availableURL(
    in directory: URL, date: Date = .now, prefix: String = "截图", ext: String = "png"
  ) -> URL {
    let stamp = date.formatted(
      Date.VerbatimFormatStyle(
        format:
          "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian)))
    let base = "\(prefix) \(stamp)"
    var url = directory.appending(path: "\(base).\(ext)")
    var index = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = directory.appending(path: "\(base) \(index).\(ext)")
      index += 1
    }
    return url
  }

  /// ⌘S：存进快速保存目录（首次写桌面 / 下载等目录时系统会问一次文件夹访问授权）。
  /// 看保存目录在不在、起名、写盘一起在主线程外（第四轮体检 F4：用户另选的文件夹可能在卡住的网络盘上，mac-native §3）。
  /// 不覆盖（.withoutOverwriting）：同一秒里连存两张，后一张起到了同一个名字的话写的时候报错，重新起名（最多试几次）
  @discardableResult
  @concurrent nonisolated static func quickSave(_ png: Data) async throws -> URL {
    let folder = directory(
      saved: UserDefaults.standard.string(forKey: Prefs.screenshotSaveDirectory))
    for attempt in 1...5 {
      let url = availableURL(in: folder)
      do {
        try png.write(to: url, options: .withoutOverwriting)
        return url
      } catch CocoaError.fileWriteFileExists where attempt < 5 {
        continue
      }
    }
    throw CocoaError(.fileWriteFileExists)
  }

  /// 写文件（截图的快速保存、另存为，第四轮体检 F4）：用户选的文件夹可能在网络盘上，不在主线程写
  @concurrent nonisolated static func write(_ data: Data, to url: URL, options: Data.WritingOptions)
    async throws
  {
    try data.write(to: url, options: options)
  }

  /// 没有写权限（文件夹授权被拒、只读的文件夹）：岛上给「去授权」「更改保存位置」（第四轮体检 U7）。纯函数，配单测
  nonisolated static func isPermissionDenied(_ error: any Error) -> Bool {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain,
      [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue]
        .contains(error.code)
    {
      return true
    }
    if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) {
      return true
    }
    return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionDenied) ?? false
  }

  /// 另存为：遮罩已收起。激活本 App、面板提到最前、存完把前台还给原来的 App 都在 FilePanel 里。不设 directoryURL：
  /// 存储面板按 App 记住上次访问的文件夹（系统行为）；选的文件夹也不记成快速保存的目录（体检 A28，同 ⌘⇧5）。
  /// 用不模态的 begin 而不是 runModal：runModal 在主 actor 的任务里会卡住其它主线程任务（流式译文、截图热键）。
  /// 返回存到的文件（取消时为 nil）
  @discardableResult
  static func saveAs(_ png: Data) async throws -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = availableURL(in: saveDirectory).lastPathComponent
    // 本 App 不在前台（截图遮罩、钉图都不激活）：激活、提到最前、关掉后还回去都在 FilePanel 里
    let response = await FilePanel.begin(panel)
    guard response == .OK, let url = panel.url else { return nil }
    try await write(png, to: url, options: .atomic)
    return url
  }
}
