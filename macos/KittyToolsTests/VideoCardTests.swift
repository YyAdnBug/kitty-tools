// 常驻缩略图的视频卡（录屏第 3 批，拍板 R11-a）：右键菜单 / VoiceOver 动作（没有存储、钉图，有打开、移到废纸篓；截图卡不变）、
// 旁白名字带时长；「拷贝」拷的是文件（Paster 写文件 URL）并记一条文件条目进剪贴板历史（C8-a，注入内存库，不碰真实历史库和
// 真实剪贴板）；文件被移走时什么都不拷。录音卡（录音第 5 批）是同一种卡片：菜单、拷贝同视频卡，旁白「录音，…」。
// 第 7 批：只有视频卡有「转成 GIF」（录音卡、截图卡没有）；转成的 GIF 卡操作同视频卡、没有「转成 GIF」。
// 卡片窗口只建不显示。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct VideoCardTests {
  private static let rect = CGRect(x: -20000, y: -20000, width: 200, height: 125)

  private func card(_ url: URL, shelf: ShotShelf = ShotShelf()) -> ShelfCard {
    ShelfCard(
      recording: url, seconds: 83, poster: nil, source: Self.rect, rect: Self.rect, screen: nil,
      panel: NSPanel(), shelf: shelf)
  }

  @Test func menuHasNoSaveOrPinButTrash() throws {
    let video = card(URL(filePath: "/tmp/录屏 a.mp4"))
    // 第 7 批：「转成 GIF」紧跟「拷贝」；第二轮体检 R1：后面再跟「压缩」
    #expect(video.menu == [[.copy, .gif, .compress, .open, .reveal], [.trash], [.close]])
    #expect(
      video.menu.flatMap { $0 }.map(\.title) == [
        "拷贝", "转成 GIF", "压缩", "打开", "在访达中显示", "移到废纸篓", "关闭",
      ])
    #expect(video.canCompress)
    // 压缩出来的那张视频卡：能转 GIF，不能再压
    let compressed = ShelfCard(
      file: .video(URL(filePath: "/tmp/录屏 a 压缩版.mp4"), seconds: 83), poster: nil,
      source: Self.rect, rect: Self.rect, screen: nil, panel: NSPanel(), shelf: ShotShelf(),
      isCompressed: true)
    #expect(compressed.menu == [[.copy, .gif, .open, .reveal], [.trash], [.close]])
    #expect(!compressed.canCompress && compressed.accessibilityName == "录屏，1 分 23 秒")
    #expect(video.accessibilityName == "录屏，1 分 23 秒")
    #expect(video.badge.folder == FileManager.default.displayName(atPath: "/tmp"))
    // 截图卡的菜单不变：拷贝 / 存储 / 钉图 /（存过的）在访达中显示 ｜ 关闭，没有移到废纸篓
    let image = try #require(
      CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    for (badge, menu) in [
      (FlyCard.Badge.copied, [[ShelfCard.Command.copy, .save, .pin], [.close]]),
      (.saved(URL(filePath: "/nonexistent/a.png")), [[.copy, .save, .pin, .reveal], [.close]]),
    ] {
      let shot = ShelfCard(
        image: image, png: Data(), scale: 2, source: Self.rect, rect: Self.rect, badge: badge,
        screen: nil, panel: NSPanel(), shelf: ShotShelf())
      #expect(shot.menu == menu)
      #expect(shot.accessibilityName == "截图缩略图")
    }
  }

  /// 拷贝 = 文件 URL 进剪贴板 + 一条文件条目进历史（再拷一次只挪到最前）；文件被移走了就不拷
  @Test func copyWritesFileURLAndRecordsFileEntry() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-video-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "录屏 2026-09-30 10.00.00.mp4")
    try Data([0]).write(to: file)
    let store = try ClipboardStore(
      db: Database(path: ":memory:"), images: ImageStore(directory: folder))
    let shelf = ShotShelf()
    var written: [NSPasteboardItem] = []
    // AppDelegate 接的是 Paster.write(files:) + recordFiles；这里不写真实剪贴板，只看要写的东西
    shelf.copyFile = { url in
      written = Paster.items(files: [url])
      store.recordFiles([url])
    }
    let video = card(file, shelf: shelf)
    video.perform(.copy)
    video.perform(.copy)
    #expect(written.count == 1)
    let url = try #require(written.first?.string(forType: .fileURL).flatMap(URL.init(string:)))
    #expect(url.standardizedFileURL == file.standardizedFileURL)
    #expect(store.items.count == 1)
    #expect(store.items.first?.kind == .file)
    #expect(store.items.first?.filePaths == [file.path])
    // 从历史里取出来粘贴也是同一个文件 URL
    #expect(
      store.pasteboardItems(for: try #require(store.items.first)).first?.string(forType: .fileURL)
        == file.absoluteString)

    try FileManager.default.removeItem(at: file)
    written = []
    video.perform(.copy)
    #expect(written.isEmpty)
    #expect(store.items.count == 1)
  }

  /// 录音卡（录音第 5 批）：同一种卡片的另一种内容——菜单、拷贝（写文件、记文件条目）同视频卡，旁白名字「录音，1 分 23 秒」
  @Test func audioCardWorksLikeVideoCard() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-audio-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "录音 2026-09-30 10.00.00.m4a")
    try Data([0]).write(to: file)
    let shelf = ShotShelf()
    var copied: [URL] = []
    shelf.copyFile = { copied.append($0) }
    let audio = ShelfCard(
      recording: file, seconds: 83, audio: true, poster: nil, source: Self.rect, rect: Self.rect,
      screen: nil, panel: NSPanel(), shelf: shelf)
    #expect(audio.kind == .audio(file, seconds: 83))
    #expect(audio.kind.recording?.medium == .audio)
    #expect(audio.menu == [[.copy, .open, .reveal], [.trash], [.close]])  // 没有「转成 GIF」
    #expect(audio.accessibilityName == "录音，1 分 23 秒")
    #expect(audio.badge.folder == FileManager.default.displayName(atPath: folder.path))
    audio.perform(.copy)
    #expect(copied == [file])
    // 视频卡的 kind 还是 .video
    #expect(card(file).kind.recording?.medium == .screen)
  }

  /// GIF 卡（第 7 批）：第一帧当图、左下「GIF」胶囊；菜单同视频卡但没有「转成 GIF」，拷贝拷的是 .gif 文件，旁白「GIF 动图」
  @Test func gifCardWorksLikeVideoCardWithoutGIF() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-gifcard-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "录屏 2026-09-30 10.00.00.gif")
    try Data([0]).write(to: file)
    let shelf = ShotShelf()
    var copied: [URL] = []
    shelf.copyFile = { copied.append($0) }
    let gif = ShelfCard(
      file: .gif(file), poster: nil, source: Self.rect, rect: Self.rect, screen: nil,
      panel: NSPanel(), shelf: shelf)
    #expect(gif.kind.file == file && gif.kind.recording == nil)
    #expect(gif.menu == [[.copy, .open, .reveal], [.trash], [.close]])
    #expect(!gif.canCompress)
    #expect(gif.accessibilityName == "GIF 动图")
    #expect(gif.badge.folder == FileManager.default.displayName(atPath: folder.path))
    #expect(gif.fileURL == file)
    gif.perform(.copy)
    #expect(copied == [file])
  }
}
