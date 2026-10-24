// 设置 › 通用「同步」（2026-10-23 全局同步拍板 A1：从 设置 › 便签 挪过来，整个 App 的同步都在这一节。执行在 NoteSyncer）。
// 没开时一行「选择文件夹…」；开着时文件夹、状态、停止 / 立即同步，「同步的内容」每类一个勾（A3，这台电脑自己的），其他 Mac。

import AppKit
import SwiftUI

/// 没开时一行「选择文件夹…」（打开面板先指到 iCloud 云盘）；选的文件夹里已经有别的 Mac 的便签，先问一句合不合在一起。
/// 开着时：文件夹（悬停看路径）+「停止同步」+「立即同步」（刹车时换成「继续同步」），说明是状态（上次同步、还在下载几个），
/// 出了问题橙字说为什么、能怎么办；下面一行列出别的 Mac 和它们上次有改动的时刻。**这一节不去碰那个文件夹**（可能在卡住的
/// 网络盘上）：名字取路径最后一段，读写都在 NoteSyncer / NoteSyncDisk 的主线程外
struct SyncSection: View {
  let syncer: NoteSyncer
  /// 几部分跟着的功能开着没有（关着的那部分不同步：勾下面说一声）
  @AppStorage(Feature.notes.prefsKey) private var notesOn = true
  @AppStorage(Feature.clipboard.prefsKey) private var clipboardOn = true
  @AppStorage(Feature.translate.prefsKey) private var translateOn = true
  @AppStorage(Feature.launcher.prefsKey) private var launcherOn = true
  @AppStorage(Feature.statusScreen.prefsKey) private var statusScreenOn = true
  /// 开同步没成的原因（橙字）
  @State private var problem: String?
  /// 面板开着、正在看文件夹、正在开
  @State private var isBusy = false
  /// 正在看选的文件夹、正在开（卡住的网络盘上可能要等一会儿：副标题说一声）
  @State private var looking = false
  /// 每分钟走一下：「上次同步：3 分钟前」自己往前走（便签关着时没有新的一轮来刷新）
  @State private var tick = Date.now
  /// 要不要和文件夹里的合在一起（确认框开着时有值）
  @State private var joining: Joining?

  struct Joining {
    var folder: URL
    var devices: Int
    var notes: Int
  }

  var body: some View {
    Section {
      if let folder = syncer.folder {
        folderRow(folder)
        part(
          SyncRecords.Kind.settings.rawValue, title: SyncRecords.Kind.settings.title,
          detail: "各页的设置、全局快捷键和功能开关；启动台、录音的麦克风、菜单栏图标这些跟着这台 Mac 的不同步")
        part(
          NoteSyncer.notesPart, title: "便签", detail: "连同正文里的图片", feature: "便签",
          isOn: notesOn)
        part(
          SyncRecords.Kind.clips.rawValue, title: SyncRecords.Kind.clips.title,
          detail: "文字的片段、收藏和收藏夹；图片和文件的收藏不同步", feature: "剪贴板", isOn: clipboardOn)
        part(
          SyncRecords.Kind.vocabulary.rawValue, title: SyncRecords.Kind.vocabulary.title,
          detail: "翻译里收藏的词句", feature: "翻译", isOn: translateOn)
        part(
          SyncRecords.Kind.engines.rawValue, title: SyncRecords.Kind.engines.title,
          detail: "启动器里的网页搜索和快捷链接", feature: "启动器", isOn: launcherOn)
        part(
          SyncRecords.Kind.services.rawValue, title: SyncRecords.Kind.services.title,
          detail: "哪几个服务、顺序和设置；密钥不同步，别的 Mac 上要自己填一次", feature: "翻译",
          isOn: translateOn)
        part(
          SyncRecords.Kind.statuses.rawValue, title: SyncRecords.Kind.statuses.title,
          detail: "状态屏里自己写的那几个状态", feature: "状态屏", isOn: statusScreenOn)
        part(
          SyncRecords.Kind.launcher.rawValue, title: SyncRecords.Kind.launcher.title,
          detail: "空搜索框里收藏的那几个；这台没装的 App 不显示，装上就回来", feature: "启动器",
          isOn: launcherOn)
        LabeledContent {
          EmptyView()
        } label: {
          Text("其他 Mac")
          Text(peersLine)
        }
      } else {
        offRow
      }
    } header: {
      Text("同步")
    } footer: {
      SectionFootnote(
        "勾上的几类在几台 Mac 之间保持一样，取消一类只是不再同步它。同步文件夹里放的是不加密的文本文件和图片，能打开这个文件夹的人都看得到。每台 Mac 只往自己的那份里写、读所有 Mac 的，改动一般几十秒到几分钟传过去（看同步盘多快）。两台都改了同一条时，后改的留下（便签的另一版放进「最近删除」）；别处删掉的片段、收藏和生词，这台 Mac 上只是不再收藏；一轮要删的太多会先停下来问。停止同步后，文件夹里的东西留着，这台 Mac 上的也不动。"
      )
    }
  }

  // MARK: 没开

  private var offRow: some View {
    LabeledContent {
      Button("选择文件夹…", action: choose)
        .disabled(isBusy)
    } label: {
      Text("在几台 Mac 之间同步")
      Text(
        looking ? "正在看这个文件夹…" : "选一个几台 Mac 都看得到的空文件夹，比如在 iCloud 云盘里新建一个；每台 Mac 选同一个")
      if let problem {
        Text(problem).foregroundStyle(Color(nsColor: .systemOrange))
      }
    }
    .confirmationDialog(
      "和这个文件夹里的便签合在一起？",
      isPresented: Binding {
        joining != nil
      } set: {
        if !$0 { joining = nil }
      },
      presenting: joining
    ) { joining in
      Button("合在一起") { start(joining.folder) }
    } message: { joining in
      Text(
        (joining.notes > 0
          ? "这个文件夹里已经有 \(joining.devices) 台 Mac 在同步，有 \(joining.notes) 条便签（含「最近删除」里的）。"
          : "这个文件夹里已经有 \(joining.devices) 台 Mac 在同步。")
          + "合在一起后，这台 Mac 上的便签、片段、收藏、生词和状态屏的状态和它们的会出现在每台 Mac 上（同样的不重复）；设置、快捷键、功能开关（连同内置的网页搜索、翻译服务）换成已经在同步的那几台的——剪贴板的保留天数、「不记录」的 App 也跟着换，超出新保留天数的历史会清掉。之后同一条两边都改过的，后改的留下。"
      )
    }
  }

  /// 选文件夹：先看一眼（主线程外），已经有别的 Mac 在用就先问，不然直接开。面板是设置窗上的表单（开着时点不到
  /// 便签的开关、换不了页：不然关掉便签之后还会把同步起起来，换了页这一节的状态也丢了）
  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    if FileManager.default.fileExists(atPath: Self.iCloudDrive.path) {
      panel.directoryURL = Self.iCloudDrive
    }
    panel.message = "选一个几台 Mac 都看得到的空文件夹（比如在 iCloud 云盘里新建一个「Kitty Tools 便签」），每台 Mac 选同一个"
    panel.prompt = "用这个文件夹同步"
    problem = nil
    isBusy = true
    let chosen: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let folder = panel.url else {
        isBusy = false
        return
      }
      looking = true
      Task {
        let seen = await NoteSyncDisk.inspect(folder: folder, device: syncer.store.deviceID)
        looking = false
        isBusy = false
        // 有别的 Mac 的便签才问（更新的格式不问：开的时候直接说先更新）
        if let marker = seen.marker, marker.format <= NoteSyncFolder.format, seen.devices > 0 {
          joining = Joining(folder: folder, devices: seen.devices, notes: seen.notes)
        } else {
          start(folder)
        }
      }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: chosen)
    } else {
      panel.begin(completionHandler: chosen)
    }
  }

  private func start(_ folder: URL) {
    isBusy = true
    looking = true
    Task {
      problem = await syncer.enable(folder: folder).map(Self.clause)
      looking = false
      isBusy = false
      if problem == nil { syncer.start() }
    }
  }

  // MARK: 开着

  private func folderRow(_ folder: URL) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        Label(folder.lastPathComponent, systemImage: "folder")
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .help(Self.shown(folder))
        Button("停止同步") { syncer.disable() }
          .buttonStyle(.plain)
          .foregroundStyle(Style.brandInk)
          .pointerStyle(.link)
          .help("文件夹里的东西留着，这台 Mac 上的便签不动")
        if case .waiting = syncer.status {
          Button("继续同步") { syncer.confirmTrashing() }
        } else {
          // 不停用：一轮没完时按它排在后面（停用的话每 20 秒闪一下灰）
          Button("立即同步") { syncer.syncNow() }
        }
      }
    } label: {
      Text("同步文件夹")
      Text(statusLine)
      if let trouble {
        Text(trouble).foregroundStyle(Color(nsColor: .systemOrange))
      }
    }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        tick = .now
      }
    }
  }

  /// 「同步的内容」里的一类：勾上才同步；它跟着的功能关着时说一声（勾着也先不同步）
  private func part(
    _ name: String, title: String, detail: String, feature: String = "", isOn featureOn: Bool = true
  ) -> some View {
    Toggle(
      isOn: Binding {
        syncer.syncs(name)
      } set: {
        syncer.setSyncs(name, $0)
      }
    ) {
      Text(title)
      Text(featureOn ? detail : "\(feature)关着，先不同步；在上面「功能」里打开就接着同步")
    }
  }

  /// 状态：上次同步的时刻（第一轮还没完时说正在同步）、还在下载几个
  private var statusLine: String {
    var line: String
    if let lastSync = syncer.lastSync {
      line = "上次同步：\(Self.ago(lastSync, now: tick))"
    } else if syncer.status == .syncing {
      line = "正在同步…"
    } else {
      line = "还没同步过"
    }
    if syncer.downloading > 0 { line += "；还有 \(syncer.downloading) 个文件在下载" }
    return line
  }

  /// 停了、等确认：为什么、能怎么办（橙字）
  private var trouble: String? {
    switch syncer.status {
    case .off, .syncing, .idle: nil
    case .waiting(let trashing):
      "这一轮要删掉 \(trashing) 条（便签是放进「最近删除」），先停下来等你确认"
    case .stopped(let problem):
      switch problem {
      case .missingFolder: "找不到同步文件夹：没接上、被挪走或删了，找到了自己接着同步"
      case .notTheFolder: "同步文件夹里的同步记录被换掉或删了：先停止同步，再选一个新的空文件夹（每台 Mac 都换过去）"
      case .newerFormat: "文件夹里有更新版本的 Kitty Tools 写的东西，先更新这台 Mac 上的 Kitty Tools"
      case .unreadable(let name):
        "\(name.map { "「\($0)」" } ?? "另一台 Mac ")那份同步记录还读不出来（多半是还没下载完），读到了自己接着同步"
      case .downloading: "同步文件夹里有文件还没下载到这台 Mac，下载完自己接着同步"
      case .failed(let reason): "上一轮没同步成：\(Self.clause(reason))"
      }
    }
  }

  private var peersLine: String {
    guard !syncer.peers.isEmpty else {
      // 第一轮还没合完（或者合之前就停了）时不知道有没有
      return syncer.lastSync == nil
        ? "同步一轮之后列在这里" : "还没有——在另一台 Mac 的 设置 › 通用 里选同一个文件夹"
    }
    return syncer.peers.map { peer in
      let name = peer.name ?? "没写名字的一台"
      return peer.seen.map { "\(name)（\(Self.ago($0, now: tick))有改动）" } ?? name
    }.joined(separator: "、")
  }

  /// 「刚刚」「3 分钟前」「昨天」
  private static func ago(_ date: Date, now: Date) -> String {
    let now = max(now, .now)
    return now.timeIntervalSince(date) < 60
      ? "刚刚" : date.formatted(.relative(presentation: .named, unitsStyle: .wide))
  }

  /// 系统给的原因（localizedDescription）带句号：行副标题一句话不加
  private static func clause(_ text: String) -> String {
    text.trimmingCharacters(in: ["。", "."])
  }

  /// iCloud 云盘在本机的位置（选文件夹的面板先指到这里）
  static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser.appending(
    path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)

  /// 悬停时给人看的路径：iCloud 云盘里的写成「iCloud 云盘/…」，家目录写成 ~
  static func shown(_ folder: URL) -> String {
    let drive = iCloudDrive.path(percentEncoded: false)
    let path = folder.path(percentEncoded: false)
    if path.hasPrefix(drive) {
      return "iCloud 云盘/" + path.dropFirst(drive.count).trimmingCharacters(in: ["/"])
    }
    return (path as NSString).abbreviatingWithTildeInPath
  }
}
