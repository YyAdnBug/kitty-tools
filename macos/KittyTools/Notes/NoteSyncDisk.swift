// 便签同步文件夹的读写（便签未来计划 A1，2026-10-22；文件夹里放什么、一轮该做什么在 NoteSyncFolder，什么时候做在 NoteSyncer）。
// 全在 @concurrent 里（mac-native §3：文件夹可能在卡住的网络盘、没下载完的同步盘上，不能放主线程），只收发 Sendable 的值。
// - 读（read）：标记、每台电脑的 device.json / erased.json / notes/*.md、images/ 的文件名。**每个文件都先看属性再读**：
//   同步盘还没下载到本机的（iCloud 云盘「优化 Mac 存储」挪走的、别的电脑刚写还没下来的：下载状态不是「当前」，或者是
//   旧式的 `.名字.icloud` 占位文件）不读——那个文件这一轮算「读不出来」，顺手请系统去下载（读它会卡到下载完）；太大的不读
//   （便签文件上限 NoteSyncFolder.maxNoteFileBytes，墓碑文件 32 MB，别的 64 KB）。读写都过 NSFileCoordinator（同步盘的
//   守护进程在协调里：不会读到它写了一半的文件）。按「路径 + 文件号 + 改动时间 + 大小」记着上一轮读出来的便签（Cache），
//   没变的不再读、不再解析——几百个文件每轮只读变了的那几个；改动时刻离读的时候不到 2 秒的不记（有的盘时刻只精确到
//   1–2 秒，同一刻里再改一回、大小一样就认不出），读失败的不记（下一轮再读）。标记、自己的 device.json 读不出来要说
//   （Snapshot：开同步时别把没下载完的标记当成没有、新建一个盖掉；一轮里认不出库被退回去了就先不合）。
// - 写（write）：先写临时名再改名（原子写：同步盘不会传上一半的文件；图片尤其——传了一半的那份会被当成「已经有了」）。
//   便签文件、墓碑文件、device.json（名字、第几轮变了才写，**最后写**）、图片两头补齐；要删的删。每一样写不成记下第一个
//   原因，别的照写。文件夹本身不在了就什么都不写（不替它建回来）。
// - 标记（inspect / createMarker）：开同步时看这个文件夹是新的、还是已经有库了（有几台电脑、多少条便签：设置页问一句要不要
//   合在一起）；标记**不覆盖**着写（两台同时开、别处刚传来一个：先到的算）。
// 测试在临时目录里真读真写（不是同步盘，没有下载状态）。

import Foundation

nonisolated enum NoteSyncDisk {
  /// 墓碑文件、别的小文件最大多少
  static let maxErasedBytes = 32 << 20
  static let maxSmallBytes = 64 << 10

  /// 上一轮读出来的便签文件：路径 → 文件号、改动时间、大小、读出来的便签（解不出来是 nil）
  struct Cache: Sendable {
    struct Entry: Sendable {
      var file: UInt64?
      var modified: Date
      var size: Int
      var note: Note?
    }
    var files: [String: Entry] = [:]
  }

  /// 一台别的电脑：叫什么、它的文件最后一次变的时刻（设置页列出来）
  struct Peer: Equatable, Sendable {
    var id: String
    var name: String?
    var seen: Date?
  }

  /// 读一遍的结果
  struct Snapshot: Sendable {
    /// 文件夹不在（没登录 iCloud、移动硬盘没插、被删了）
    var missing = false
    var folder = NoteSyncFolder.Folder()
    /// 标记有、但读不出来（还在下载、写坏了）——folder.marker 是 nil，可不是「没有标记」
    var markerUnreadable = false
    /// device.json 有、但读不出来的电脑（编号）
    var unreadableInfo: Set<String> = []
    var cache = Cache()
    var peers: [Peer] = []
    /// 这一轮请系统去下载了几个（状态行说「还在下载」）
    var downloading = 0
  }

  // MARK: 读

  @concurrent static func read(folder root: URL, cache old: Cache) async -> Snapshot {
    var snapshot = Snapshot()
    guard isDirectory(root) else {
      snapshot.missing = true
      return snapshot
    }
    switch small(root.appending(path: NoteSyncFolder.markerName), as: NoteSyncFolder.Marker.self) {
    case .absent: break
    case .unreadable: snapshot.markerUnreadable = true
    case .read(let marker): snapshot.folder.marker = marker
    }
    let devices = root.appending(path: NoteSyncFolder.devicesName)
    for name in listing(devices) where isDeviceName(name) {
      let folder = devices.appending(path: name)
      guard isDirectory(folder) else { continue }
      var device = NoteSyncFolder.Device()
      var seen: Date?
      func saw(_ url: URL) {
        if let date = attributes(url)?.modified { seen = max(seen ?? date, date) }
      }
      let info = folder.appending(path: NoteSyncFolder.deviceInfoName)
      switch small(info, as: NoteSyncFolder.DeviceInfo.self) {
      case .absent: break
      case .unreadable: snapshot.unreadableInfo.insert(name)
      case .read(let described):
        device.name = described.name
        device.epoch = described.epoch
      }
      saw(info)
      let erased = folder.appending(path: NoteSyncFolder.erasedName)
      switch state(of: erased, limit: maxErasedBytes) {
      case .absent: device.erased = .read([:])
      case .notHere:
        device.erased = .unreadable
        snapshot.downloading += 1
      case .tooLarge: device.erased = .unreadable
      case .here:
        saw(erased)
        device.erased =
          coordinatedRead(erased).map(NoteSyncFolder.tombstones(from:)) ?? .unreadable
      }
      let notes = folder.appending(path: NoteSyncFolder.notesName)
      for file in listing(notes) {
        // 旧式的占位文件（`.名字.icloud`）：那一条还没下载
        if file.hasPrefix("."), file.hasSuffix(".icloud") {
          let real = String(file.dropFirst().dropLast(".icloud".count))
          if let id = NoteSyncFolder.noteID(ofFileNamed: real) {
            device.unreadable.insert(id)
            startDownloading(notes.appending(path: real))
            snapshot.downloading += 1
          }
          continue
        }
        guard let id = NoteSyncFolder.noteID(ofFileNamed: file) else { continue }
        let url = notes.appending(path: file)
        switch state(of: url, limit: NoteSyncFolder.maxNoteFileBytes) {
        case .absent: continue
        case .notHere:
          device.unreadable.insert(id)
          snapshot.downloading += 1
        case .tooLarge:
          device.unreadable.insert(id)
        case .here(let attributes):
          if attributes.modified > (seen ?? .distantPast) { seen = attributes.modified }
          var entry: Cache.Entry?
          if let cached = old.files[url.path], cached.file == attributes.file,
            cached.modified == attributes.modified, cached.size == attributes.size
          {
            entry = cached
          } else if let data = coordinatedRead(url) {
            let note = String(data: data, encoding: .utf8).flatMap {
              NoteSyncFolder.note(from: $0, fileID: id)
            }
            entry = Cache.Entry(
              file: attributes.file, modified: attributes.modified, size: attributes.size,
              note: note)
          }
          if let entry, Date.now.timeIntervalSince(attributes.modified) > 2 {
            snapshot.cache.files[url.path] = entry
          }
          if let note = entry?.note {
            device.notes[id] = note
          } else {
            device.unreadable.insert(id)
          }
        }
      }
      snapshot.folder.devices[name] = device
      snapshot.peers.append(Peer(id: name, name: device.name, seen: seen))
    }
    snapshot.folder.images = Set(
      listing(root.appending(path: NoteSyncFolder.imagesName)).filter {
        NoteImageStore.identifier(ofFileNamed: $0) != nil
      })
    return snapshot
  }

  /// 电脑编号（子文件夹名）像不像：字母数字和减号，1–64 个
  static func isDeviceName(_ name: String) -> Bool {
    (1...64).contains(name.count)
      && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
  }

  /// 一个文件现在是什么状态
  private enum FileState {
    case absent
    /// 同步盘里有、本机还没下载（已经请系统去下载了）
    case notHere
    case tooLarge
    case here(Attributes)
  }

  private struct Attributes {
    /// 文件号（inode：原子写、同步盘换进新的一版都会变）
    var file: UInt64?
    var modified: Date
    var size: Int
  }

  private static func state(of url: URL, limit: Int) -> FileState {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey,
      .ubiquitousItemDownloadingStatusKey, .fileIdentifierKey,
    ]
    guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
      // 旧式的占位文件（`.名字.icloud`）：文件有，还没下载
      let placeholder = url.deletingLastPathComponent().appending(
        path: ".\(url.lastPathComponent).icloud")
      guard FileManager.default.fileExists(atPath: placeholder.path) else { return .absent }
      startDownloading(url)
      return .notHere
    }
    if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus,
      status != .current
    {
      startDownloading(url)
      return .notHere
    }
    let size = values.fileSize ?? 0
    guard size <= limit else { return .tooLarge }
    return .here(
      Attributes(
        file: values.fileIdentifier, modified: values.contentModificationDate ?? .distantPast,
        size: size))
  }

  private static func attributes(_ url: URL) -> Attributes? {
    guard case .here(let attributes) = state(of: url, limit: .max) else { return nil }
    return attributes
  }

  private static func startDownloading(_ url: URL) {
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
  }

  /// 一个小 JSON 文件（标记、device.json）读成什么样：不在 / 有但读不出来（还在下载、太大、写坏了）/ 读到了
  private enum Small<Value> {
    case absent
    case unreadable
    case read(Value)
  }

  private static func small<Value: Decodable>(_ url: URL, as _: Value.Type) -> Small<Value> {
    switch state(of: url, limit: maxSmallBytes) {
    case .absent: return .absent
    case .notHere, .tooLarge: return .unreadable
    case .here:
      guard let data = coordinatedRead(url),
        let value = try? JSONDecoder().decode(Value.self, from: data)
      else { return .unreadable }
      return .read(value)
    }
  }

  private static func listing(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// 协调着读一个文件（同步盘的守护进程在写它时等它写完）
  private static func coordinatedRead(_ url: URL) -> Data? {
    var data: Data?
    var error: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: .withoutChanges, error: &error
    ) { data = try? Data(contentsOf: $0) }
    return data
  }

  // MARK: 写

  /// 写一遍的结果
  struct Written: Sendable {
    /// 写成了的便签（编号）、删掉了的、拿下来的图片
    var wrote: Set<String> = []
    var deleted: Set<String> = []
    var downloaded: [NoteImages.Image] = []
    /// 第一个没写成的原因
    var problem: String?
  }

  /// 照 NoteSyncFolder.publish 的计划写：便签文件、要删的、墓碑文件、图片两头补齐，**最后**是 device.json（名字、epoch
  /// 变了才写：前面的都写成了它才是这一轮的，NoteSyncer）。images 是本机的图片目录
  @concurrent static func write(
    _ plan: NoteSyncFolder.Publish, folder root: URL, device: String, name: String,
    epoch: Int, images: URL?
  ) async -> Written {
    var result = Written()
    func note(_ error: Error) {
      if result.problem == nil { result.problem = error.localizedDescription }
    }
    // 读完到写之间文件夹没了（拔了盘、被删了）：不替它建回来（建回来的空文件夹下一轮是「不是那个文件夹」）
    guard isDirectory(root) else {
      result.problem = "同步文件夹不在了"
      return result
    }
    let mine = root.appending(path: NoteSyncFolder.devicesName).appending(path: device)
    let notes = mine.appending(path: NoteSyncFolder.notesName)
    do {
      try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    } catch {
      note(error)
      return result
    }
    for item in plan.writes {
      let url = notes.appending(path: NoteSyncFolder.fileName(of: item.id))
      do {
        try coordinatedWrite(Data(NoteSyncFolder.text(of: item).utf8), to: url)
        result.wrote.insert(item.id)
      } catch {
        note(error)
      }
    }
    for id in plan.deletes {
      let url = notes.appending(path: NoteSyncFolder.fileName(of: id))
      do {
        try coordinatedDelete(url)
        result.deleted.insert(id)
      } catch {
        note(error)
      }
    }
    if let erased = plan.erased {
      do {
        try coordinatedWrite(
          NoteSyncFolder.data(of: erased), to: mine.appending(path: NoteSyncFolder.erasedName))
      } catch {
        note(error)
      }
    }
    let shared = root.appending(path: NoteSyncFolder.imagesName)
    if let images, !plan.uploads.isEmpty || !plan.downloads.isEmpty {
      for image in plan.uploads {
        let name = "\(image.id.uuidString).\(image.ext)"
        do {
          try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
          try copy(images.appending(path: name), to: shared.appending(path: name))
        } catch {
          note(error)
        }
      }
      for image in plan.downloads {
        let name = "\(image.id.uuidString).\(image.ext)"
        let source = shared.appending(path: name)
        guard case .here = state(of: source, limit: NoteImageStore.maxFileBytes) else { continue }
        do {
          try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
          try copy(source, to: images.appending(path: name))
          result.downloaded.append(image)
        } catch {
          note(error)
        }
      }
    }
    guard result.problem == nil else { return result }
    let info = mine.appending(path: NoteSyncFolder.deviceInfoName)
    let described = NoteSyncFolder.DeviceInfo(name: name, epoch: epoch)
    if case .read(let current) = small(info, as: NoteSyncFolder.DeviceInfo.self),
      current == described
    {
      return result
    }
    if let data = try? NoteSyncFolder.encoder.encode(described) {
      do { try coordinatedWrite(data, to: info) } catch { note(error) }
    }
    return result
  }

  /// 协调着、原子地写一个文件（先写临时名再改名：Data.write(.atomic)）
  private static func coordinatedWrite(_ data: Data, to url: URL) throws {
    var failure: Error?
    var error: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: .forReplacing, error: &error
    ) { target in
      do { try data.write(to: target, options: .atomic) } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
  }

  private static func coordinatedDelete(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    var failure: Error?
    var error: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: .forDeleting, error: &error
    ) { target in
      do { try FileManager.default.removeItem(at: target) } catch { failure = error }
    }
    if let failure = failure ?? error { throw failure }
  }

  /// 拷一张图：先拷成同目录里的临时名，再改成正式的名字（目标已经有了就不动：同名就是同一张——改名时撞上别处刚放好的
  /// 也算成了）。ponytail: 拷到一半整个 App 崩了，临时文件（点开头，读的时候不认）留在共用的 images/ 里，要清再加
  private static func copy(_ source: URL, to target: URL) throws {
    guard !FileManager.default.fileExists(atPath: target.path) else { return }
    let temporary = target.deletingLastPathComponent().appending(
      path: ".\(UUID().uuidString).partial")
    var failure: Error?
    var error: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: source, options: .withoutChanges, writingItemAt: target,
      options: .forReplacing, error: &error
    ) { from, to in
      do {
        try FileManager.default.copyItem(at: from, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: to)
      } catch {
        try? FileManager.default.removeItem(at: temporary)
        if !FileManager.default.fileExists(atPath: to.path) { failure = error }
      }
    }
    if let failure = failure ?? error { throw failure }
  }

  // MARK: 标记

  /// 选了一个文件夹，开同步之前看一眼：有没有标记（已经有库了）、有几台别的电脑、多少条便签
  struct Inspection: Equatable, Sendable {
    var exists = false
    var marker: NoteSyncFolder.Marker?
    /// 标记有、但读不出来（还在下载、写坏了）：不能当成新文件夹
    var markerUnreadable = false
    /// 别的电脑几台、它们一共多少条便签（按编号去重：每台的子文件夹里都是全套，含最近删除里的）
    var devices = 0
    var notes = 0
    /// 除了点开头的（.DS_Store 这些）什么都没有：旧式的 iCloud 占位（`.名字.icloud`）是还没下载的文件，不算空
    var empty = true
  }

  @concurrent static func inspect(folder root: URL, device: String) async -> Inspection {
    var result = Inspection(exists: isDirectory(root))
    guard result.exists else { return result }
    result.empty = listing(root).allSatisfy { $0.hasPrefix(".") && !$0.hasSuffix(".icloud") }
    switch small(root.appending(path: NoteSyncFolder.markerName), as: NoteSyncFolder.Marker.self) {
    case .absent: break
    case .unreadable: result.markerUnreadable = true
    case .read(let marker): result.marker = marker
    }
    let devices = root.appending(path: NoteSyncFolder.devicesName)
    var ids: Set<String> = []
    for name in listing(devices) where isDeviceName(name) && name != device {
      result.devices += 1
      for file in listing(devices.appending(path: name).appending(path: NoteSyncFolder.notesName)) {
        // 旧式占位 `.编号.md.icloud` 也算一条
        let real =
          file.hasPrefix(".") && file.hasSuffix(".icloud")
          ? String(file.dropFirst().dropLast(".icloud".count)) : file
        if let id = NoteSyncFolder.noteID(ofFileNamed: real) { ids.insert(id) }
      }
    }
    result.notes = ids.count
    return result
  }

  /// 新的库：在文件夹根上写标记。**不覆盖**：已经有了（别处刚写了一个、刚传下来）就不写、返回原因（标记几十个字节，
  /// 在协调里一次写完，不用先写临时名）
  @concurrent static func createMarker(in root: URL, library: String) async -> String? {
    var failure: Error?
    var error: NSError?
    do {
      let data = try NoteSyncFolder.encoder.encode(NoteSyncFolder.Marker(library: library))
      NSFileCoordinator(filePresenter: nil).coordinate(
        writingItemAt: root.appending(path: NoteSyncFolder.markerName), options: [], error: &error
      ) { target in
        do { try data.write(to: target, options: .withoutOverwriting) } catch { failure = error }
      }
    } catch {
      failure = error
    }
    return (failure ?? error)?.localizedDescription
  }

  /// 这台电脑在设置里叫什么（「电脑名称」）
  @concurrent static func computerName() async -> String {
    Host.current().localizedName ?? "Mac"
  }
}
