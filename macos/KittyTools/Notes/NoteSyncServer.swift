// 连 WebDAV 服务器同步时，本机和服务器之间怎么搬文件（issue #18，2026-11-13；什么时候搬、出错了怎么办在 NoteSyncer）。
// 服务器上那个文件夹和本机同步文件夹的写法一模一样（NoteSyncFolder：标记、devices/<电脑编号>/…、共用的 images/），所以
// 一台连服务器、一台走同步盘也能合在一起。做法是在数据目录里留一份镜像（sync-server/<编号>/），一轮：
//   pull（服务器上变了的拿下来）→ 照文件夹同步合一轮（NoteSyncDisk 读写的就是这份镜像：合并、刹车、退回、图片清理都不改）
//   → push（本机写进镜像的送上去）。
// - **镜像就是同步盘在本机的那一份**：本机写了还没传上去的（自己子文件夹里改过的、images/ 里新放的）留着、下一轮接着传；
//   服务器上变了的（按 ETag；没给 ETag 的按改动时间 + 大小）才 GET，没变的不碰。服务器上没了的：别人的、标记直接删；
//   自己子文件夹和 images/ 里账上记过的（传上去过）也删，账上没有的是还没传上去的、留着。镜像里文件的改动时间设成服务器
//   上的（NoteSyncDisk「刚改过 2 秒内不算数」和「其他电脑上次有改动」按它算）。
// - **这一轮没拿下来的**（超了每轮的请求数）：镜像里有旧的一版就留着（同步盘慢了一样，合并本来就经得起旧的），没有的放一个
//   旧式的 iCloud 占位文件（`.名字.icloud`）——NoteSyncDisk 当成「还没下载」：那一版这一轮不算、状态行说还有几个在下载；
//   有没拿下来的，NoteSyncer 这一轮整个当成没读清楚（不跳过、不清共用图片）。比上限还大的放一个同样大小的空洞文件（不占
//   地方，读的那层当成太大）。
// - **只写自己的**：自己子文件夹里本机改过的（文件号、改动时间、大小和账上记的不一样）PUT，账上有、镜像里没了的 DELETE；
//   共用 images/ 里镜像有、账上没有的上传（先传成点开头的临时名再 MOVE 成正式的，不覆盖：同名就是同一张），账上有、镜像
//   里没了的删（NoteSyncFolder.imagePurge 定的）。先后同 NoteSyncDisk.write：便签、墓碑、图片、一类一类的，**device.json
//   最后**，前面的都传完了才传。传完重新列一下写过的文件夹，记下服务器给的 ETag（下一轮不再拿回来）。
// - **图片不重复下载**：服务器上有、本机图片目录里也有的同名图（同名就是同一张），从本机克隆进镜像（APFS 不占地方）。
// - **请求数**：每轮 GET / PUT / DELETE / MKCOL / MOVE 合起来最多 budget 个（列目录不算，一轮 3 + 2 × 电脑数个），先拿
//   标记、device.json、墓碑、一类一类的，再便签、图片；剩下的下一轮。服务器说请求太多（429 / 503）立刻停，NoteSyncer 退避。
//   ponytail: 按轮限，不按时间窗——各家限额不公开（坚果云网上说每半小时几百到一千多次），撞上了靠退避
// - 账（服务器上每个文件的 ETag、改动时间、大小，和镜像里那份的文件号 + 改动时间 + 大小）存在镜像根上的 `.server.json`。
// 全在 @concurrent 里（mac-native §3：网络、读写镜像都不放主线程），只收发 Sendable 的值。

import Foundation

nonisolated enum NoteSyncServer {
  /// 每轮最多几个 GET / PUT / DELETE / MKCOL / MOVE（文件头）
  static let budget = 40
  /// 账存在镜像根上的这个文件里（点开头：NoteSyncDisk 不认）
  static let ledgerName = ".server.json"

  /// 镜像里一个文件的样子：和账上记的一样 = 本机没动过
  struct Local: Codable, Equatable, Sendable {
    var file: UInt64?
    var modified: Date
    var size: Int
  }

  /// 账上的一个文件：服务器上的样子（刚传上去、还没重新列到的，ETag 和改动时间是 nil），和拿下来 / 传上去时镜像里那份的样子
  struct Entry: Codable, Equatable, Sendable {
    var etag: String? = nil
    var modified: Date? = nil
    var size: Int
    var local: Local?
  }

  struct Ledger: Codable, Equatable, Sendable {
    /// 服务器上的文件夹 + 用户名：换了就从头记
    var server = ""
    /// 路径（「devices/编号/notes/编号.md」）→ 那个文件
    var files: [String: Entry] = [:]
  }

  /// pull 的结果
  struct Pulled: Sendable {
    var failure: WebDAV.Failure?
    /// 服务器上同步的那个文件夹不在了
    var missing = false
    /// 这一轮还能发几个请求（push 用）
    var left = 0
    /// 服务器上变了、这一轮没拿下来的（状态行「还有几个在下载」）
    var waiting = 0
    /// 服务器上已经有的文件夹（路径，根是 ""）：push 只建没有的
    var folders: Set<String> = []
  }

  /// push 的结果
  struct Pushed: Sendable {
    var failure: WebDAV.Failure?
    /// 这一轮没传上去的（状态行「还有几个等着传上去」）
    var waiting = 0
  }

  // MARK: 认得的文件

  /// 镜像里认得的文件：大小上限、拿的先后（小的先）。认不出的（.DS_Store、别人的临时文件……）不拿、不删。
  /// 名字只认规范写法、一字不差（电脑编号、便签编号、图片编号都是大写）：镜像在默认不分大小写的 APFS 上，服务器上只差大小写的
  /// 两个名字会落到镜像里同一个文件上，一轮拿这个、一轮拿那个。两边自己写的都是大写，小写的只会是别的程序写的
  static func known(_ path: String) -> (limit: Int, order: Int)? {
    let parts = path.split(separator: "/").map(String.init)
    switch parts.count {
    case 1 where parts[0] == NoteSyncFolder.markerName:
      return (NoteSyncDisk.maxSmallBytes, 0)
    case 2 where parts[0] == NoteSyncFolder.imagesName:
      guard let id = NoteImageStore.identifier(ofFileNamed: parts[1]),
        parts[1].hasPrefix(id.uuidString + ".")
      else { return nil }
      return (NoteImageStore.maxFileBytes, 5)
    case 3 where parts[0] == NoteSyncFolder.devicesName && isDevice(parts[1]):
      if parts[2] == NoteSyncFolder.deviceInfoName { return (NoteSyncDisk.maxSmallBytes, 1) }
      if parts[2] == NoteSyncFolder.erasedName { return (NoteSyncDisk.maxErasedBytes, 2) }
      if SyncRecords.Kind.allCases.contains(where: { $0.fileName == parts[2] }) {
        return (NoteSyncDisk.maxErasedBytes, 3)
      }
      return nil
    case 4
    where parts[0] == NoteSyncFolder.devicesName && isDevice(parts[1])
      && parts[2] == NoteSyncFolder.notesName:
      guard let id = NoteSyncFolder.noteID(ofFileNamed: parts[3]), parts[3] == "\(id).md" else {
        return nil
      }
      return (NoteSyncFolder.maxNoteFileBytes, 4)
    default:
      return nil
    }
  }

  /// 电脑编号的规范写法：不带小写字母（known 的说明）
  static func isDevice(_ name: String) -> Bool {
    NoteSyncDisk.isDeviceName(name) && !name.contains(where: \.isLowercase)
  }

  /// 服务器上的这个文件和账上记的是不是同一版
  static func matches(_ entry: Entry, _ item: WebDAV.Item) -> Bool {
    if let etag = item.etag, let known = entry.etag { return etag == known }
    return item.modified != nil && entry.modified == item.modified && entry.size == item.size
  }

  private static func identity(_ account: WebDAV.Account) -> String {
    "\(account.folder.absoluteString) \(account.user)"
  }

  private static func isOwn(_ path: String, device: String) -> Bool {
    path.hasPrefix("\(NoteSyncFolder.devicesName)/\(device)/")
  }

  private static func isImage(_ path: String) -> Bool {
    path.hasPrefix("\(NoteSyncFolder.imagesName)/")
  }

  // MARK: 拿下来

  @concurrent static func pull(
    _ account: WebDAV.Account, session: URLSession, mirror: URL, device me: String,
    images: URL?, budget: Int
  ) async -> Pulled {
    let dav = WebDAV(account: account, session: session)
    var result = Pulled(left: budget)
    var ledger = readLedger(mirror, account: account)
    try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)

    // 1. 列：标记、devices/ 下每台的子文件夹和它的 notes/、images/
    var remote: [String: WebDAV.Item] = [:]
    do {
      guard let top = try await dav.list([]) else {
        result.missing = true
        return result
      }
      result.folders.insert("")
      func add(_ item: WebDAV.Item, in folder: [String]) {
        let path = (folder + [item.name]).joined(separator: "/")
        if !item.isFolder, known(path) != nil { remote[path] = item }
      }
      for item in top { add(item, in: []) }
      if top.contains(where: { $0.isFolder && $0.name == NoteSyncFolder.devicesName }) {
        let devices = [NoteSyncFolder.devicesName]
        result.folders.insert(devices[0])
        for device in try await dav.list(devices) ?? []
        where device.isFolder && isDevice(device.name) {
          let folder = devices + [device.name]
          guard let items = try await dav.list(folder) else { continue }
          result.folders.insert(folder.joined(separator: "/"))
          for item in items { add(item, in: folder) }
          if items.contains(where: { $0.isFolder && $0.name == NoteSyncFolder.notesName }) {
            let notes = folder + [NoteSyncFolder.notesName]
            result.folders.insert(notes.joined(separator: "/"))
            for item in try await dav.list(notes) ?? [] { add(item, in: notes) }
          }
        }
      }
      if top.contains(where: { $0.isFolder && $0.name == NoteSyncFolder.imagesName }) {
        result.folders.insert(NoteSyncFolder.imagesName)
        for item in try await dav.list([NoteSyncFolder.imagesName]) ?? [] {
          add(item, in: [NoteSyncFolder.imagesName])
        }
      }
    } catch {
      result.failure = error
      return result
    }

    // 2. 服务器上没了的：别人的直接删；自己的、图片，账上记过（传上去过）的删，没记过的是还没传上去的
    let (files, placeholders) = mirrorFiles(mirror)
    for path in files where remote[path] == nil {
      let pending = (isOwn(path, device: me) || isImage(path)) && ledger.files[path] == nil
      if !pending {
        try? FileManager.default.removeItem(at: mirror.appending(path: path))
        ledger.files[path] = nil
      }
    }
    for path in placeholders where remote[path] == nil || files.contains(path) {
      try? FileManager.default.removeItem(at: placeholder(mirror.appending(path: path)))
    }
    for path in Array(ledger.files.keys) where remote[path] == nil && !files.contains(path) {
      ledger.files[path] = nil
    }

    // 3. 服务器上变了的：要拿的排好队（太大的放空洞文件，本机有的图克隆进来）
    var wanted: [(path: String, item: WebDAV.Item, order: Int)] = []
    for (path, item) in remote {
      guard let (limit, order) = known(path) else { continue }
      let url = mirror.appending(path: path)
      let here = FileManager.default.fileExists(atPath: url.path)
      if let entry = ledger.files[path], matches(entry, item) {
        // 没变：镜像里有（本机可能改过、等着传）、或者本机删了等着删（自己的、图片）都不动
        if here || isOwn(path, device: me) || isImage(path) { continue }
      }
      if item.size > limit {
        hollow(url, size: item.size)
        ledger.files[path] = Entry(
          etag: item.etag, modified: item.modified, size: item.size, local: local(url))
        continue
      }
      // 图片同名就是同一张：镜像里已经有（本机刚放进去、还没传上去）就认下，本机图片目录里有就克隆进来
      if isImage(path),
        here
          || images.map({
            clone($0.appending(path: url.lastPathComponent), to: url, modified: item.modified)
          }) == true
      {
        ledger.files[path] = Entry(
          etag: item.etag, modified: item.modified, size: item.size, local: local(url))
        continue
      }
      wanted.append((path, item, order))
    }
    wanted.sort { ($0.order, $0.path) < ($1.order, $1.path) }

    // 4. 拿，到这一轮的请求数为止；剩下的有旧的留旧的，没有的放占位
    for (index, want) in wanted.enumerated() {
      let url = mirror.appending(path: want.path)
      guard result.left > 0 else {
        result.waiting = wanted.count - index
        for rest in wanted[index...] {
          let url = mirror.appending(path: rest.path)
          if !FileManager.default.fileExists(atPath: url.path) { mark(url) }
        }
        break
      }
      result.left -= 1
      do {
        // 列完到拿之间被删了：下一轮再说
        guard let data = try await dav.get(want.path.split(separator: "/").map(String.init))
        else { continue }
        try save(data, to: url, modified: want.item.modified)
        try? FileManager.default.removeItem(at: placeholder(url))
        ledger.files[want.path] = Entry(
          etag: want.item.etag, modified: want.item.modified, size: data.count, local: local(url))
      } catch let failure as WebDAV.Failure {
        result.failure = failure
        result.waiting = wanted.count - index
        break
      } catch {
        // 镜像写不进去（盘满了）：当这一轮没连上一样停，说原因
        result.failure = .offline(error.localizedDescription)
        break
      }
    }
    writeLedger(ledger, mirror)
    return result
  }

  // MARK: 送上去

  @concurrent static func push(
    _ account: WebDAV.Account, session: URLSession, mirror: URL, device me: String, budget: Int,
    folders existing: Set<String>
  ) async -> Pushed {
    let dav = WebDAV(account: account, session: session)
    var ledger = readLedger(mirror, account: account)
    var folders = existing
    var result = Pushed()
    var left = budget
    var touched: Set<String> = []
    let (files, placeholders) = mirrorFiles(mirror)

    // 要做的：自己子文件夹里改过的 PUT、没了的 DELETE；images/ 里新的上传、没了的删。先后同 NoteSyncDisk.write
    enum Step {
      case put
      case delete
      case upload
    }
    func rank(_ path: String) -> Int {
      let name = (path as NSString).lastPathComponent
      if isImage(path) { return 2 }
      if name == NoteSyncFolder.deviceInfoName { return 4 }
      if name == NoteSyncFolder.erasedName { return 1 }
      return known(path)?.order == 4 ? 0 : 3
    }
    var steps: [(rank: Int, path: String, step: Step)] = []
    for path in files {
      let entry = ledger.files[path]
      if isOwn(path, device: me) {
        if entry == nil || entry?.local != local(mirror.appending(path: path)) {
          steps.append((rank(path), path, .put))
        }
      } else if isImage(path), entry == nil {
        steps.append((rank(path), path, .upload))
      }
    }
    for (path, _) in ledger.files
    where (isOwn(path, device: me) || isImage(path)) && !files.contains(path)
      && !placeholders.contains(path)
    {
      steps.append((rank(path), path, .delete))
    }
    steps.sort { ($0.rank, $0.path) < ($1.rank, $1.path) }

    /// 建好放它的文件夹（devices/、devices/编号/、…/notes/、images/：服务器上没有的才建）
    func prepare(_ path: String) async throws(WebDAV.Failure) -> Bool {
      let parts = path.split(separator: "/").map(String.init).dropLast()
      for depth in parts.indices {
        let folder = parts[...depth].joined(separator: "/")
        guard !folders.contains(folder) else { continue }
        guard left > 0 else { return false }
        left -= 1
        try await dav.makeFolder(Array(parts[...depth]))
        folders.insert(folder)
      }
      return true
    }

    // 排好的先后走，哪一步没钱了、出错了就停：device.json 排在最后，到得了它就是前面的都传完了
    for (index, item) in steps.enumerated() {
      let parts = item.path.split(separator: "/").map(String.init)
      let url = mirror.appending(path: item.path)
      let cost: Int
      if case .upload = item.step { cost = 2 } else { cost = 1 }
      do {
        guard try await prepare(item.path), left >= cost else {
          result.waiting = steps.count - index
          break
        }
        left -= cost
        switch item.step {
        case .put:
          let sent = local(url)
          try await dav.put(file: url, to: parts)
          ledger.files[item.path] = Entry(size: sent?.size ?? 0, local: sent)
          touched.insert(parts.dropLast().joined(separator: "/"))
        case .delete:
          try await dav.delete(parts)
          ledger.files[item.path] = nil
        case .upload:
          let sent = local(url)
          try await upload(url, to: parts, dav: dav)
          ledger.files[item.path] = Entry(size: sent?.size ?? 0, local: sent)
          touched.insert(NoteSyncFolder.imagesName)
        }
      } catch {
        result.failure = error
        result.waiting = steps.count - index
        break
      }
    }

    // 传过的文件夹重新列一下，记下服务器上的 ETag、改动时间（下一轮认得是自己传的这一版，不再拿回来）
    for folder in touched.sorted() {
      let parts = folder.split(separator: "/").map(String.init)
      guard let items = try? await dav.list(parts) else { continue }
      for item in items where !item.isFolder {
        let path = (parts + [item.name]).joined(separator: "/")
        guard var entry = ledger.files[path], entry.etag == nil, entry.modified == nil else {
          continue
        }
        entry.etag = item.etag
        entry.modified = item.modified
        entry.size = item.size
        ledger.files[path] = entry
      }
    }
    writeLedger(ledger, mirror)
    return result
  }

  /// 传一张图：先传成点开头的临时名，再 MOVE 成正式的名字、不覆盖（已经有了：同名就是同一张，删掉临时的）。
  /// ponytail: 服务器不支持 MOVE 时直接 PUT 正式的名字（传到一半断了会留下半张，别的电脑当它是好的）；传了临时名后整个
  /// App 退了，临时文件（点开头，没人认）留在 images/ 里
  private static func upload(_ url: URL, to parts: [String], dav: WebDAV)
    async throws(WebDAV.Failure)
  {
    let temporary = Array(parts.dropLast()) + [".kitty-\(UUID().uuidString).partial"]
    try await dav.put(file: url, to: temporary)
    do {
      try await dav.move(temporary, to: parts)
    } catch .exists {
      try await dav.delete(temporary)
    } catch .status(let code) where code == 405 || code == 501 {
      try await dav.delete(temporary)
      do { try await dav.put(file: url, to: parts, ifAbsent: true) } catch .exists {}
    }
  }

  // MARK: 开同步时

  /// 连服务器、开同步之前看一眼（同 NoteSyncDisk.inspect）：文件夹在不在、空不空、有没有标记、几台别的电脑、多少条便签
  @concurrent static func inspect(_ account: WebDAV.Account, session: URLSession, device: String)
    async -> Result<NoteSyncDisk.Inspection, WebDAV.Failure>
  {
    let dav = WebDAV(account: account, session: session)
    var result = NoteSyncDisk.Inspection()
    do {
      guard let top = try await dav.list([]) else { return .success(result) }
      result.exists = true
      result.empty = top.allSatisfy { $0.name.hasPrefix(".") }
      if top.contains(where: { !$0.isFolder && $0.name == NoteSyncFolder.markerName }) {
        let data = try await dav.get([NoteSyncFolder.markerName])
        if let data, data.count <= NoteSyncDisk.maxSmallBytes,
          let marker = try? JSONDecoder().decode(NoteSyncFolder.Marker.self, from: data)
        {
          result.marker = marker
        } else {
          result.markerUnreadable = data != nil
        }
      }
      guard top.contains(where: { $0.isFolder && $0.name == NoteSyncFolder.devicesName }) else {
        return .success(result)
      }
      var ids: Set<String> = []
      for other in try await dav.list([NoteSyncFolder.devicesName]) ?? []
      where other.isFolder && isDevice(other.name) && other.name != device {
        result.devices += 1
        let notes = [NoteSyncFolder.devicesName, other.name, NoteSyncFolder.notesName]
        for file in (try? await dav.list(notes)) ?? [] {
          if let id = NoteSyncFolder.noteID(ofFileNamed: file.name) { ids.insert(id) }
        }
      }
      result.notes = ids.count
      return .success(result)
    } catch {
      return .failure(error)
    }
  }

  /// 服务器上还没有这个文件夹：建好（连同没有的上级）
  @concurrent static func makeFolder(_ account: WebDAV.Account, session: URLSession) async
    -> WebDAV.Failure?
  {
    let dav = WebDAV(account: account, session: session)
    do {
      try await dav.makeFolders()
      return nil
    } catch {
      return error
    }
  }

  /// 新的库：写标记，不覆盖（别处刚写了一个：.exists）
  @concurrent static func createMarker(
    _ account: WebDAV.Account, session: URLSession, library: String
  ) async -> WebDAV.Failure? {
    let dav = WebDAV(account: account, session: session)
    do {
      let data = try NoteSyncFolder.encoder.encode(NoteSyncFolder.Marker(library: library))
      try await dav.put(data, to: [NoteSyncFolder.markerName], ifAbsent: true)
      return nil
    } catch let failure as WebDAV.Failure {
      return failure
    } catch {
      return .invalid
    }
  }

  /// 设置里「测试连接」：连得上、账号对、文件夹在的话写一个点开头的小文件再删掉
  enum Test: Equatable, Sendable {
    /// 能读能写
    case ready
    /// 连上了，服务器上还没有这个文件夹（连接时建好）
    case missing
  }

  @concurrent static func test(_ account: WebDAV.Account, session: URLSession) async
    -> Result<Test, WebDAV.Failure>
  {
    let dav = WebDAV(account: account, session: session)
    do {
      guard try await dav.list([]) != nil else { return .success(.missing) }
      let probe = [".kitty-test-\(UUID().uuidString)"]
      try await dav.put(Data("Kitty Tools".utf8), to: probe)
      try await dav.delete(probe)
      return .success(.ready)
    } catch {
      return .failure(error)
    }
  }

  /// 不用了的镜像（停止同步、换了服务器）：整个删掉，keeping 那个留着
  @concurrent static func removeMirrors(in parent: URL, keeping: URL?) async {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    for name in names where name != keeping?.lastPathComponent {
      try? FileManager.default.removeItem(at: parent.appending(path: name))
    }
  }

  // MARK: 镜像

  /// 镜像里认得的文件：真的、占位的（都按路径）
  private static func mirrorFiles(_ mirror: URL) -> (files: Set<String>, placeholders: Set<String>)
  {
    var files: Set<String> = []
    var placeholders: Set<String> = []
    func scan(_ folder: [String]) -> [String] {
      let url = folder.isEmpty ? mirror : mirror.appending(path: folder.joined(separator: "/"))
      let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
      for name in names {
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
          let path = (folder + [String(name.dropFirst().dropLast(".icloud".count))])
            .joined(separator: "/")
          if known(path) != nil { placeholders.insert(path) }
        } else {
          let path = (folder + [name]).joined(separator: "/")
          if known(path) != nil { files.insert(path) }
        }
      }
      return names
    }
    _ = scan([])
    _ = scan([NoteSyncFolder.imagesName])
    for device in scan([NoteSyncFolder.devicesName]) where isDevice(device) {
      _ = scan([NoteSyncFolder.devicesName, device])
      _ = scan([NoteSyncFolder.devicesName, device, NoteSyncFolder.notesName])
    }
    return (files, placeholders)
  }

  static func local(_ url: URL) -> Local? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .fileIdentifierKey, .contentModificationDateKey, .fileSizeKey,
      ]), values.isRegularFile == true
    else { return nil }
    return Local(
      file: values.fileIdentifier, modified: values.contentModificationDate ?? .distantPast,
      size: values.fileSize ?? 0)
  }

  private static func placeholder(_ url: URL) -> URL {
    url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
  }

  /// 还没拿下来：放个占位（NoteSyncDisk 当成同步盘还没下载的那种）
  private static func mark(_ url: URL) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: placeholder(url).path, contents: nil)
  }

  /// 比上限还大：放一个同样大小的空洞文件（不占地方；读的那层只看大小，当成太大、读不出来）
  private static func hollow(_ url: URL, size: Int) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    try? handle.truncate(atOffset: UInt64(size))
    try? handle.close()
  }

  private static func save(_ data: Data, to url: URL, modified: Date?) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    if let modified {
      try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
  }

  /// 本机图片目录里有这张：克隆进镜像（拷不成返回 false，照常去拿）
  private static func clone(_ source: URL, to url: URL, modified: Date?) -> Bool {
    guard FileManager.default.fileExists(atPath: source.path) else { return false }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: url)
      try FileManager.default.copyItem(at: source, to: url)
      if let modified {
        try? FileManager.default.setAttributes(
          [.modificationDate: modified], ofItemAtPath: url.path)
      }
      try? FileManager.default.removeItem(at: placeholder(url))
      return true
    } catch {
      return false
    }
  }

  private static func readLedger(_ mirror: URL, account: WebDAV.Account) -> Ledger {
    let fresh = Ledger(server: identity(account))
    guard let data = try? Data(contentsOf: mirror.appending(path: ledgerName)),
      let ledger = try? JSONDecoder().decode(Ledger.self, from: data),
      ledger.server == fresh.server
    else { return fresh }
    return ledger
  }

  private static func writeLedger(_ ledger: Ledger, _ mirror: URL) {
    guard let data = try? JSONEncoder().encode(ledger) else { return }
    try? data.write(to: mirror.appending(path: ledgerName), options: .atomic)
  }
}
