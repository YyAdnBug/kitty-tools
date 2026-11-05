// 提醒的提示音（2026-11-04 用户反馈「能不能自己选铃声、传音频」；对标 Time Out 的休息提示音：系统自带的声音、用户放进
// 个人「声音」文件夹（~/Library/Sounds、/Library/Sounds）的声音自动出现在列表里，另可以选一个音频文件）。
// Reminder.chime 存的是声音的编号：系统 / 个人文件夹里的是声音名（NSSound(named:) 按名字找，不带扩展名），自己选的文件是
// 「file:文件名」——选的时候拷一份进数据目录的 reminder-sounds/（原文件挪走、删掉都不影响）。编号跟着提醒走（导出、同步），
// 文件不跟：别的 Mac 上没有这个声音时响默认的「玻璃」，详情页说一句。编号是不可信输入（导入的文件、同步文件夹里来的）：
// 文件名只认一段、不以点开头、扩展名是认得的音频（isValid），绝不拼出数据目录外的路径。
// 只响一声：自己选的文件最多放 30 秒，点「知道了」「稍后」当场停。没人用的文件在提醒开始运行时清掉（purge）。

import AppKit
import UniformTypeIdentifiers

enum ReminderSound {
  static let folderName = "reminder-sounds"
  nonisolated static let filePrefix = "file:"
  /// 自己选的文件最多多大（拷进数据目录、在主线程上拷）
  static let maxBytes = 20 * 1024 * 1024
  /// 自己选的文件最多放多久（系统声音本来就一两秒）
  static let maxSeconds = 30
  nonisolated static let extensions: Set<String> = [
    "aiff", "aif", "aifc", "wav", "caf", "mp3", "m4a", "aac",
  ]
  /// 打开面板里能选的类型：只给认得的扩展名（.audio 会放进 flac、ogg 这些放不了的）
  static var contentTypes: [UTType] {
    extensions.sorted().compactMap { UTType(filenameExtension: $0) }
  }
  /// 编号最长多少字（声音名、文件名）
  nonisolated static let maxName = 100

  static var folder: URL { AppDelegate.supportDirectory.appending(path: folderName) }

  /// 编号认不认（纯函数，nonisolated：Reminder.sanitized 用）：声音名是一段不带斜杠、不以点开头的字；自己选的文件另要扩展名是认得的音频
  nonisolated static func isValid(_ id: String) -> Bool {
    let name = id.hasPrefix(filePrefix) ? String(id.dropFirst(filePrefix.count)) : id
    guard !name.isEmpty, name.count <= maxName, !name.hasPrefix("."), !name.contains("/"),
      !name.contains(":"), !name.contains("\0")
    else { return false }
    return !id.hasPrefix(filePrefix)
      || extensions.contains((name as NSString).pathExtension.lowercased())
  }

  /// 界面上的叫法：系统的用中文名，别的用文件名（不带扩展名）
  static func title(of id: String) -> String {
    if let chime = Reminder.chimes.first(where: { $0.name == id }) { return chime.title }
    let name = id.hasPrefix(filePrefix) ? String(id.dropFirst(filePrefix.count)) : id
    return (name as NSString).deletingPathExtension
  }

  struct Choice: Hashable {
    let id: String
    let title: String
  }

  /// 个人「声音」文件夹里的（不和系统自带的重名）、自己选过的文件。详情页打开时读一次
  static func choices() -> (library: [Choice], files: [Choice]) {
    let builtIn = Set(Reminder.chimes.map(\.name))
    let libraries = [
      URL.libraryDirectory.appending(path: "Sounds"), URL(filePath: "/Library/Sounds"),
    ]
    var seen = builtIn
    let library = libraries.flatMap(audioFiles).compactMap { url -> Choice? in
      let name = url.deletingPathExtension().lastPathComponent
      guard isValid(name), seen.insert(name).inserted else { return nil }
      return Choice(id: name, title: name)
    }
    let files = audioFiles(in: folder).compactMap { url -> Choice? in
      let id = filePrefix + url.lastPathComponent
      return isValid(id) ? Choice(id: id, title: title(of: id)) : nil
    }
    return (library.sorted { $0.title < $1.title }, files.sorted { $0.title < $1.title })
  }

  private static func audioFiles(in directory: URL) -> [URL] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return urls.filter { extensions.contains($0.pathExtension.lowercased()) }
  }

  /// 编号对应的声音；这台 Mac 上没有就是 nil
  static func sound(for id: String) -> NSSound? {
    guard isValid(id) else { return nil }
    guard id.hasPrefix(filePrefix) else { return NSSound(named: id) }
    let url = folder.appending(path: String(id.dropFirst(filePrefix.count)))
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return NSSound(contentsOf: url, byReference: true)
  }

  // MARK: 放

  private static var playing: NSSound?
  private static var previewing = false
  private static var cutoff: Task<Void, Never>?

  /// 放一声（换掉正在放的）：没有这个声音就放默认的；最多 30 秒。preview = 详情页里试听（离开页面时停的只是它）
  static func play(_ id: String, preview: Bool = false) {
    stop()
    guard let sound = sound(for: id) ?? NSSound(named: Reminder.defaultChime) else { return }
    playing = sound
    previewing = preview
    sound.play()
    cutoff = Task {
      try? await Task.sleep(for: .seconds(maxSeconds))
      if !Task.isCancelled, playing === sound { stop() }
    }
  }

  static func stop() {
    cutoff?.cancel()
    cutoff = nil
    playing?.stop()
    playing = nil
    previewing = false
  }

  static func stopPreview() {
    if previewing { stop() }
  }

  // MARK: 自己选的文件

  enum ImportError: Error {
    case tooLarge, unreadable, copyFailed

    var message: String {
      switch self {
      case .tooLarge: "文件太大，选一个 20 MB 以内的短音频"
      case .unreadable: "放不了这个文件，换一个 mp3、m4a、wav 或 aiff"
      case .copyFailed: "没能存下这个文件"
      }
    }
  }

  /// 把选的文件拷进 reminder-sounds/，返回编号。同名的已经在了：内容一样就用它，不一样就在名字后面加数字。
  /// ponytail: 在主线程上拷（20 MB 以内，同一块盘上是克隆，几毫秒）；选的是卡住的网络盘上的文件会卡一下，真遇到再挪到后台
  static func importFile(_ source: URL, into directory: URL = folder) throws(ImportError) -> String
  {
    let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= maxBytes else { throw .tooLarge }
    let ext = source.pathExtension.lowercased()
    guard size > 0, extensions.contains(ext), NSSound(contentsOf: source, byReference: false) != nil
    else { throw .unreadable }
    let manager = FileManager.default
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .copyFailed
    }
    let stem = String(
      source.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: ":", with: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(60))
    let base = stem.isEmpty ? "提示音" : stem
    for index in 1...99 {
      let name = (index == 1 ? base : "\(base) \(index)") + "." + ext
      let target = directory.appending(path: name)
      if manager.fileExists(atPath: target.path) {
        // 盘不分大小写时 bell.mp3 撞上的是 Bell.mp3：编号用盘上真实的名字（不然清理按名字比会把它当成没人用）
        if manager.contentsEqual(atPath: target.path, andPath: source.path) {
          return filePrefix + ((try? target.resourceValues(forKeys: [.nameKey]).name) ?? name)
        }
        continue
      }
      do {
        try manager.copyItem(at: source, to: target)
      } catch {
        throw .copyFailed
      }
      return filePrefix + name
    }
    throw .copyFailed
  }

  /// 清掉没有提醒在用的文件（提醒开始运行时）：换了声音、删了提醒留下的拷贝
  static func purge(keeping ids: Set<String>, in directory: URL = folder) {
    for url in audioFiles(in: directory) where !ids.contains(filePrefix + url.lastPathComponent) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
