// 内存探针（第二轮体检第 2 批，2026-10-02；按需开，平时不跑）：在测试宿主里屏外把几样占内存的东西各量一遍，
// 结论写回 PLAN §10「第二轮体检」。第 3 批按第一版量出的数给缩略图缓存设了上限、两张 ⌘Y 大卡改成用时再建，
// 探针跟着改成量改后的样子（改前的数在 PLAN §10 第 2 批）。量的是：
//   ① 剪贴板缩略图缓存（ThumbnailView.icons / previews，三档 72 / 720 / 2400）：三档画过后留多少、两个上限是不是严格的
//   ② 启动器图标缓存（LauncherIcons）③ 识字模型（OCR，.accurate）常驻多少
//   ④ 三块主面板和设置窗「建 + 显示 → 收起 → 清内容 → 放掉窗口」各涨落多少（App 里它们一直留着）；
//     两张 ⌘Y 大卡照 App 的做法开关（TransientPanel：用时再建、收起后自己放掉），放掉后还留多少；
//     剪贴板那张先照改前的做法（面板一直留着、不丢大卡档、不调回收接口）量一组对照
//   ⑤ 截图 / 转 GIF 那样的重活之后堆脏页留多少、malloc_zone_pressure_relief 能还多少。
// 每一步读 task_info(TASK_VM_INFO) 的 phys_footprint（活动监视器的口径），旁边列 footprint 工具的分类（它不用 root 就能看
// 自己的进程）；每项做两遍。窗口都摆在屏幕外（-20000, -20000）、不当 key、不激活本 App、不出声；图片、库、偏好都是临时的
// （临时目录、内存库、临时偏好域），不读写用户的数据目录和钥匙串，跑完删干净。全程约 7 分钟。输出目录写绝对路径：
//   TEST_RUNNER_KITTY_MEMORY_PROBE_DIR=/tmp/kitty-memory xcodebuild -project macos/KittyTools.xcodeproj \
//     -scheme KittyTools test -only-testing:'KittyToolsTests/MemoryProbeTests/measure()'
// 报告追加在 <目录>/report.md（每跑一次一段，段头写时间）。只跑其中几项（在干净的进程里量，排除前面几项的影响）：
// 另加 TEST_RUNNER_KITTY_MEMORY_PROBE_ONLY=thumbnails,icons,ocr,panels,relief 里的几个（逗号分隔）。
//
// 三个坑（都是先量出对不上的数、再用临时实验查出来的，改探针前先看）：
// 1. **缩略图要画出来才算**：ImageIO 的缩略图是懒解码的，取进缓存不画几乎不占内存；画过之后一张在缓存里占 2 份
//    （CG raster data + CoreAnimation 各一份「宽 × 高 × 4」），窗口关了也不还，缓存放手才还。所以第 1 节用真的 ThumbnailView 画。
// 2. **整个探针同步跑在主跑环的一个块里，不是 Swift 并发的任务**：测试是宿主 App 的事件循环里的一次长调用，事件循环不转，
//    AppKit 的自动释放池永远不清——显示过的窗口被自动释放过很多次，放了手也永远不释放（真 App 里事件循环转一圈就清）。
//    所以每个阶段包一个 autoreleasepool、等的时候嵌套跑环（spin）。而嵌套跑环要是在 Swift 并发的任务里跑（主队列正被这个
//    任务占着），主队列上的东西全停：SwiftUI 的 .task、动画组的完成回调（OverlayPanel.zoom / setContentHeight 的回调捏着
//    面板）都不来。从 RunLoop.main.perform 的块里跑就没有这个问题；要等异步操作用 wait。
// 3. malloc_zone_statistics(nil) 的「在用」不能信：ImageIO 放缩略图的 DefaultPurgeableMallocZone 释放了也不减。只看默认 zone。
//
// 和真机的差别（报告里也写）：Debug 构建；窗口在屏外、不是 key（三块主面板走 present(makingKey: false, keepsPlace: true)，
// 两张 ⌘Y 大卡走模型的 toggleQuickLook → zoom / unzoom，接线照 AppDelegate 另写了一份；都是真的 OverlayPanel，只是
// isPinned 恒真：探针跑着时用户在别处点一下不会把它关掉）；翻译浮窗没给
// frameName（真的那块会读写用户偏好里记的位置）；设置窗是照 SettingsWindow 的参数另建的（真的那个会激活本 App、把窗口位置
// 记进用户偏好），不看启动器那一页（它一出现就读浏览器数据、可能弹文件夹授权框）；启动器 ⌘Y 的 Quick Look 预览在测试宿主里
// 连不上系统的预览服务，量到的只是卡片窗口；重活里的截屏和视频帧是合成的（ScreenCaptureKit、AVAssetImageGenerator 没跑）。

import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

/// 输出目录（TEST_RUNNER_KITTY_MEMORY_PROBE_DIR，绝对路径）；没设就不跑
nonisolated private let probeDirectory = ProcessInfo.processInfo.environment[
  "KITTY_MEMORY_PROBE_DIR"
].map { URL(filePath: $0, directoryHint: .isDirectory) }
/// 只跑这几项（TEST_RUNNER_KITTY_MEMORY_PROBE_ONLY，逗号分隔）；没设 = 全跑
nonisolated private let probeOnly = ProcessInfo.processInfo.environment["KITTY_MEMORY_PROBE_ONLY"]
  .map { Set($0.split(separator: ",").map(String.init)) }

/// 屏幕外的位置（同截图自检）：窗口摆在这里，用户看不到
private let offscreen = NSPoint(x: -20000, y: -20000)
nonisolated private let megabyte = 1_048_576

@Suite(.serialized, .enabled(if: probeDirectory != nil))
struct MemoryProbeTests {
  /// 探针本身同步跑在主跑环的一个块里（文件头第 2 个坑），这里只是把它投过去、等它跑完
  @Test func measure() async throws {
    let directory = try #require(probeDirectory)
    let failure: String? = await withCheckedContinuation { continuation in
      RunLoop.main.perform {
        MainActor.assumeIsolated {
          do {
            try Probe(directory: directory).run()
            continuation.resume(returning: nil)
          } catch {
            continuation.resume(returning: "\(error)")
          }
        }
      }
    }
    #expect(failure == nil)
  }
}

private final class Probe {
  private let report: Report
  /// 临时目录（合成图、GIF、服务图标缓存）
  private let scratch: URL
  private let images: ImageStore
  private let suite = "kitty-memory-probe-\(UUID().uuidString)"
  private var shots: [Shot] = []

  init(directory: URL) throws {
    report = try Report(directory: directory)
    scratch = FileManager.default.temporaryDirectory.appending(
      path: "kitty-memory-probe-\(UUID().uuidString)")
    images = ImageStore(directory: scratch.appending(path: "images"))
  }

  func run() throws {
    // 没有看得见的窗口的后台 App 会被系统打盹（定时器被拖慢）：量的这几分钟里不让它打盹
    let activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep, reason: "内存探针")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    try FileManager.default.createDirectory(
      at: images.directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let prefs = UserDefaults(suiteName: suite) else { throw Skip("建不出临时偏好域") }
    defer { prefs.removePersistentDomain(forName: suite) }
    // 不读本机浏览器的图标库、不联网取服务图标、不碰真的图标缓存目录（同截图自检）；量完换回去
    let saved = (SiteIcons.shared.roots, ServiceIcons.shared.directory, ServiceIcons.shared.fetch)
    defer {
      (SiteIcons.shared.roots, ServiceIcons.shared.directory, ServiceIcons.shared.fetch) = saved
    }
    SiteIcons.shared.roots = { [] }
    ServiceIcons.shared.directory = scratch.appending(path: "ServiceIcons")
    ServiceIcons.shared.fetch = { _ in nil }

    report.begin()
    // 中途出错也把量到的和汇总表写出来
    defer { report.finish() }
    // 12 张 3420 × 2224 的合成「整屏截图」（用户那台机器的截图就是这个尺寸）
    shots = try autoreleasepool {
      try (0..<12).map { try Shot.make(index: $0, width: 3420, height: 2224, in: images) }
    }
    report.line(
      "合成图 \(shots.count) 张 3420 × 2224，PNG 每张约 \(kb(shots.map(\.bytes).reduce(0, +) / shots.count))"
    )
    spin(1)
    let idle = report.step("基线（合成图已写盘）")
    spin(2)
    let drift = report.step("空等 2 秒", note: "读数的漂移，下面比它小的差不算数")
    report.line("空等的漂移 \(signed(drift.footprint - idle.footprint))")

    let runs: (String) -> Bool = { probeOnly?.contains($0) ?? true }
    if runs("thumbnails") { try thumbnails() }
    if runs("icons") { icons() }
    if runs("ocr") { recognize() }
    if runs("panels") { try panels(prefs) }
    if runs("relief") { relief() }
  }

  // MARK: - 1. 缩略图缓存

  /// 缩略图缓存（第 3 批起有上限）：行图标 ThumbnailView.icons 按张数封顶，透镜 + ⌘Y 大卡 ThumbnailView.previews 按 cost 封顶。
  /// 先只取不画看一眼（懒解码：几乎不占），再用真的 ThumbnailView 在屏外窗口里画——72 档 12 张一起（像列表的行图标），
  /// 720 / 2400 档一张一张轮着换（像透镜、⌘Y 大卡跟着 ↑↓ 换图）——关掉窗口看缓存里留多少；接着照 App 放掉大卡时做的
  /// 丢掉大卡档、调回收接口；再验两个上限是不是严格的（连看 30 张透镜、连出 360 个行图标，都比上限多）；最后清空
  private func thumbnails() throws {
    report.heading(
      "1. 缩略图缓存（行图标 ThumbnailView.icons 最多 \(ThumbnailView.iconCount) 张；透镜 + 大卡 "
        + "ThumbnailView.previews 按 cost 最多 \(mb(ThumbnailView.previewBytes))）")
    let (icon, lens, card) = (
      ThumbnailView.iconPixel, ThumbnailView.lensPixel, ThumbnailView.cardPixel
    )
    let tiers = [icon, lens, card]
    let count = shots.count
    let (images, shots) = (images, shots)
    let ids = shots.map(\.id)
    // 验上限用的更多的图：同一批 PNG 的硬链接，各有各的 id（缓存按 id 记）
    let lensIDs = try ids + linked(18)
    let iconIDs = try linked(360)
    Self.clearThumbnails()
    spin()
    let idle = report.step("取之前（缓存是空的）")
    wait {
      for tier in tiers {
        for shot in shots { _ = await ThumbnailView.load(shot.id, images: images, maxPixel: tier) }
      }
    }
    spin()
    let loaded = Reading.now()
    report.row(
      "三档 × \(count) 张都取过一遍、一张没画", loaded,
      note: "footprint 只变了 \(signed(loaded.footprint - idle.footprint))：缩略图到画的时候才解码")
    Self.clearThumbnails()
    spin()
    report.step("清掉缓存")

    // 每档画多大（点）：行图标 24 × 24；透镜里图片高 108；大卡按 QuickLookView 在这块屏上给的尺寸减去页眉页脚和识别文字区
    let first = shots[0]
    var item = ClipItem(kind: .image)
    item.image = .init(width: first.width, height: first.height, byteCount: 0, sha256: "")
    item.ocrText = first.text
    let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    let big = QuickLookView.idealSize(
      for: item, form: nil, within: NSSize(width: visible.width * 0.9, height: visible.height * 0.9)
    )
    let aspect = CGFloat(first.width) / CGFloat(first.height)
    let cells: [Int: CGSize] = [
      icon: CGSize(width: 24, height: 24), lens: CGSize(width: 108 * aspect, height: 108),
      card: CGSize(
        width: big.width - 48, height: big.height - 130 - QuickLookView.ocrHeight - 30),
    ]
    /// 屏外开一个小窗口，用真的 ThumbnailView 把 ids 一批一批画出来（每批 batch 张，画完停 pause 秒）；窗口只活在这个池里，
    /// 出去就真的释放了（文件头第 2 个坑）。preload：先把这一批取进缓存再换图（一批十几张时不用猜要等多久）。
    /// 返回每批画完时比开始多了多少；第一批从换图到 footprint 涨出一份像素用了多久（解码完了，没涨够 = nil）、
    /// 这段时间里主线程最长一次被占了多久（跑环转一圈本该 10 毫秒）
    func draw(
      _ ids: [UUID], tier: Int, batch: Int, pause: Double, preload: Bool = false, label: String
    )
      -> (grown: [Int], firstDraw: Double?, stall: Double)
    {
      let cell = cells[tier] ?? .zero
      var grown: [Int] = []
      var firstDraw: Double?
      var stall = 0.0
      autoreleasepool {
        let gallery = Gallery()
        let window = NSWindow(
          contentRect: NSRect(
            origin: offscreen,
            size: NSSize(width: cell.width * CGFloat(batch), height: cell.height)),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
          rootView: GalleryView(
            gallery: gallery, images: images, maxPixel: tier, cell: cell,
            mode: tier == icon ? .fill : .fit))
        window.orderFrontRegardless()
        spin(0.2)
        let before = Reading.footprint()
        for start in stride(from: 0, to: ids.count, by: batch) {
          let group = Array(ids[start..<min(start + batch, ids.count)])
          if preload {
            wait {
              for id in group { _ = await ThumbnailView.load(id, images: images, maxPixel: tier) }
            }
          }
          let began = Date.now
          gallery.ids = group
          if start == 0 {
            // 第一批：每 10 毫秒看一眼，footprint 比换图前多出一份像素就算解码完了；哪一圈转得久就是主线程被占着
            let expected = first.thumbnailBytes(tier) * group.count
            var mark = began
            while mark.timeIntervalSince(began) < pause {
              spin(0.01)
              let now = Date.now
              stall = max(stall, now.timeIntervalSince(mark))
              mark = now
              if firstDraw == nil, Reading.footprint() - before >= expected {
                firstDraw = now.timeIntervalSince(began)
              }
            }
          } else {
            spin(pause)
          }
          grown.append(Reading.footprint() - before)
        }
        report.step(
          label + "（窗口还开着）", note: "格子 \(Int(cell.width)) × \(Int(cell.height)) 点")
        window.orderOut(nil)
        window.contentView = nil
      }
      spin()
      return (grown, firstDraw, stall)
    }
    /// 逐张（批）画完时比开始多了多少，凑成一串整数 MB
    func series(_ grown: [Int]) -> String {
      grown.map { String(Int((Double($0) / Double(megabyte)).rounded())) }.joined(separator: " ")
    }
    func milliseconds(_ seconds: Double?) -> String {
      seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "没量到"
    }

    let lensCost = ThumbnailView.cost(width: lens, height: Int((Double(lens) / aspect).rounded()))
    let cardCost = ThumbnailView.cost(width: card, height: Int((Double(card) / aspect).rounded()))
    var totals: [Int] = []
    var dropped: [Int] = []
    var relieved: [Int] = []
    var afterDrop: [Int] = []
    var lensFull: [Int] = []
    var iconFull: [Int] = []
    var bothFull: [Int] = []
    var perIcon: [Int] = []
    var cleared: [Int] = []
    var cardDraw: [String] = []
    for round in 1...2 {
      let base = report.step("第 \(round) 遍：画之前（缓存是空的）")
      // 三档各 12 张：行图标一起、透镜和大卡一张一张
      _ = draw(ids, tier: icon, batch: count, pause: 1, label: "72 档：\(count) 张一起画出来")
      var last = Reading.now()
      report.row(
        "关掉窗口（只剩缓存）", last,
        note: "\(count) 张共留 \(kb(last.footprint - base.footprint))（按像素算一张才 "
          + "\(kb(first.thumbnailBytes(icon)))，小到量不准）")
      let lensDrawn = draw(ids, tier: lens, batch: 1, pause: 0.4, label: "720 档：\(count) 张轮流画过")
      var now = Reading.now()
      report.row(
        "关掉窗口（只剩缓存）", now,
        note: "每张留 \(kb((now.footprint - last.footprint) / count))（按 cost 每张 \(kb(lensCost))，"
          + "\(count) 张 \(mb(lensCost * count))，没到上限）；第一张从换图到解码完 "
          + "\(milliseconds(lensDrawn.firstDraw))，主线程最长被占 \(milliseconds(lensDrawn.stall))")
      last = now
      let cardDrawn = draw(ids, tier: card, batch: 1, pause: 0.8, label: "2400 档：\(count) 张轮流画过")
      now = Reading.now()
      cardDraw.append(
        "\(milliseconds(cardDrawn.firstDraw))（主线程最长被占 \(milliseconds(cardDrawn.stall))）")
      report.row(
        "关掉窗口（只剩缓存）", now,
        note: "三档都画过后比画之前多 \(mb(now.footprint - base.footprint))（一张大卡按 cost \(mb(cardCost))，"
          + "连着进 \(count) 张，前面的透镜和大卡被挤掉）；逐张画完时比开始多（MB）：\(series(cardDrawn.grown))；"
          + "第一张从换图到解码完 \(milliseconds(cardDrawn.firstDraw))，主线程最长被占 "
          + milliseconds(cardDrawn.stall))
      totals.append(now.footprint - base.footprint)
      last = now
      // App 在 ⌘Y 大卡放掉时做的两件事，分开量
      ThumbnailView.dropCards()
      steady()
      now = Reading.now()
      dropped.append(last.footprint - now.footprint)
      report.row(
        "丢掉大卡档（ThumbnailView.dropCards）", now, note: "回落 \(mb(last.footprint - now.footprint))")
      last = now
      let took = relieve()
      steady()
      now = Reading.now()
      relieved.append(last.footprint - now.footprint)
      afterDrop.append(now.footprint - base.footprint)
      report.row(
        "调回收接口", now,
        note: "又回落 \(mb(last.footprint - now.footprint))（调用本身 \(took)），比画之前多 "
          + "\(signed(now.footprint - base.footprint))")
      // 上限是不是严格的：透镜连看 30 张（按 cost 只放得下 18 张）
      Self.clearThumbnails()
      steady()
      let empty = report.step("清空两个缓存（验上限之前）")
      let lensSeries = draw(
        lensIDs, tier: lens, batch: 1, pause: 0.4, label: "720 档：连看 \(lensIDs.count) 张")
      now = Reading.now()
      lensFull.append(now.footprint - empty.footprint)
      report.row(
        "关掉窗口（只剩缓存）", now,
        note:
          "比清空后多 \(mb(now.footprint - empty.footprint))（上限 \(mb(ThumbnailView.previewBytes))，放得下 "
          + "\(ThumbnailView.previewBytes / lensCost) 张 = \(mb(ThumbnailView.previewBytes / lensCost * lensCost))）；"
          + "逐张画完时比开始多（MB）：\(series(lensSeries.grown))")
      last = now
      // 行图标连出 360 个（比上限多），一批 12 个
      let iconSeries = draw(
        iconIDs, tier: icon, batch: 12, pause: 0.3, preload: true,
        label: "72 档：连出 \(iconIDs.count) 个（一批 12 个）")
      now = Reading.now()
      iconFull.append(now.footprint - last.footprint)
      bothFull.append(now.footprint - empty.footprint)
      // 到上限之前那一段的斜率：第 5 批到第 25 批（60 → 300 个）
      let slope =
        iconSeries.grown.count > 24 ? (iconSeries.grown[24] - iconSeries.grown[4]) / 240 : 0
      perIcon.append(slope)
      let marks = stride(from: 4, to: iconSeries.grown.count, by: 5).map {
        "\(($0 + 1) * 12) 个 \(mb(iconSeries.grown[$0]))"
      }
      report.row(
        "关掉窗口（只剩缓存）", now,
        note: "行图标共留 \(mb(now.footprint - last.footprint))，60 → 300 个之间每个 \(kb(slope))；画完这些时比开始多："
          + marks.joined(separator: "、") + "；两个缓存都装满后比清空时多 \(mb(now.footprint - empty.footprint))")
      last = now
      Self.clearThumbnails()
      steady()
      now = Reading.now()
      report.row("清空两个缓存后", now, note: "回落 \(mb(last.footprint - now.footprint))")
      let tookAgain = relieve()
      steady()
      let end = Reading.now()
      cleared.append(end.footprint - base.footprint)
      report.row(
        "再调一次回收接口", end,
        note: "又回落 \(mb(now.footprint - end.footprint))（调用本身 \(tookAgain)），比画之前多 "
          + "\(signed(end.footprint - base.footprint))")
    }
    report.line(
      "第 2 批（没设上限）同样画过 \(count) 张三档是 389–392 MB，清缓存回落 374.5 MB；现在三档画过后 \(list(totals))，"
        + "大卡放掉（丢大卡档 + 回收）后比画之前多 \(afterDrop.map(signed).joined(separator: " / "))。"
        + "两个缓存都装满（\(ThumbnailView.previewBytes / lensCost) "
        + "张透镜 + \(ThumbnailView.iconCount) 个行图标）比清空时多 \(list(bothFull))；开着大卡时最多再加解码用的一块"
        + "（约一份大卡的像素，回收接口还得掉）。缓存里没有时一张大卡从换图到解码完 \(cardDraw.joined(separator: " / "))"
        + "（合成图压得小、解得快，真截图会慢）")
    report.summary.append(
      (
        "缩略图缓存：\(count) 张整屏截图三档都画过（第 2 批没设上限时 389–392 MB）", list(totals),
        "丢大卡档 \(list(dropped))，再调回收接口 \(list(relieved))；之后比画之前多 "
          + afterDrop.map(signed).joined(separator: " / "),
        "已设上限（第 3 批）"
      ))
    report.summary.append(
      (
        "缩略图缓存封顶：连看 \(lensIDs.count) 张透镜 / 连出 \(iconIDs.count) 个行图标",
        "透镜 \(list(lensFull))（上限 \(mb(ThumbnailView.previewBytes))）；行图标 \(list(iconFull))"
          + "（上限 \(ThumbnailView.iconCount) 张，每个 \(perIcon.map(kb).joined(separator: " / "))）",
        "清空 + 回收后比画之前多 \(cleared.map(signed).joined(separator: " / "))",
        "两个上限都是严格的（见逐张的数）"
      ))
  }

  /// 再要 count 张图：前面那批 PNG 的硬链接，各有各的 id（缓存按 id 记，内容一样不要紧）
  private func linked(_ count: Int) throws -> [UUID] {
    try (0..<count).map { index in
      let id = UUID()
      try FileManager.default.linkItem(
        at: images.url(for: shots[index % shots.count].id), to: images.url(for: id))
      return id
    }
  }

  /// 清空缩略图的两个缓存
  private static func clearThumbnails() {
    ThumbnailView.icons.removeAllObjects()
    ThumbnailView.previews.removeAllObjects()
  }

  // MARK: - 2. 图标缓存

  /// LauncherIcons 取本机约 200 个 App 图标 + 几十种文件类型图标、按行里的大小画出来，再清掉缓存，各差多少
  private func icons() {
    report.heading("2. 启动器图标缓存（LauncherIcons.cache：NSCache，没设上限）")
    // 启动器扫的那几个目录里的 App，不够 200 个再从 CoreServices 里补
    var paths = AppCatalog.scan().filter { $0.kind == .app }.map(\.target)
    let core = "/System/Library/CoreServices"
    let extra = ((try? FileManager.default.contentsOfDirectory(atPath: core)) ?? [])
      .filter { $0.hasSuffix(".app") }.sorted().map { core + "/" + $0 }
    for path in extra where paths.count < 200 && !paths.contains(path) { paths.append(path) }
    let types = [
      "pdf", "png", "jpg", "gif", "heic", "svg", "txt", "md", "rtf", "html", "css", "js", "json",
      "xml", "yaml", "csv", "zip", "dmg", "pkg", "mp4", "mov", "mp3", "m4a", "wav", "key",
      "numbers", "pages", "docx", "xlsx", "pptx", "swift", "py", "sh", "c", "h", "log", "plist",
      "sqlite", "ttf", "epub",
    ].compactMap { UTType(filenameExtension: $0) }
    let count = paths.count + types.count
    var grown: [Int] = []
    var drops: [Int] = []
    for round in 1...2 {
      LauncherIcons.cache.removeAllObjects()
      spin()
      let base = report.step("第 \(round) 遍：取之前（缓存是空的）")
      // 取到的图标只在这个池里拿着：出去之后只有缓存捏着它们
      autoreleasepool {
        let fetched =
          paths.compactMap { LauncherIcons.icon(for: $0) }
          + types.map { LauncherIcons.icon(for: $0) }
        // 像启动器的行那样画成 24 pt @2x：NSImage 这时才解出那个尺寸的一张
        guard
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        bitmap.size = NSSize(width: 24, height: 24)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for image in fetched { image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24)) }
        NSGraphicsContext.restoreGraphicsState()
      }
      spin()
      let drawn = Reading.now()
      let grew = drawn.footprint - base.footprint
      grown.append(grew)
      report.row(
        "取 \(paths.count) 个 App + \(types.count) 种类型的图标，各画一遍（24 pt @2x，同启动器的行）", drawn,
        note: "\(count) 个共涨 \(mb(grew))，每个 \(kb(grew / max(count, 1)))")
      LauncherIcons.cache.removeAllObjects()
      spin()
      let cleared = Reading.now()
      drops.append(drawn.footprint - cleared.footprint)
      report.row("清掉缓存后", cleared, note: "回落 \(mb(drawn.footprint - cleared.footprint))")
    }
    report.summary.append(
      (
        "启动器图标缓存（\(count) 个）", list(grown), list(drops),
        (drops.max() ?? 0) >= 10 * megabyte ? "值得管" : "不用管（总共几兆，清掉也还不回来）"
      ))
  }

  // MARK: - 3. 识字

  /// 识一张整屏截图前后的差、闲 10 秒后的差（两次：第一次带着加载模型）
  private func recognize() {
    report.heading("3. 识字（OCR.recognizeText：RecognizeTextRequest .accurate，同剪贴板）")
    let url = images.url(for: shots[0].id)
    let base = report.step("识字之前")
    var after = base
    for round in 1...2 {
      let start = Date.now
      let text = wait { await OCR.recognizeText(in: url) }
      let seconds = Date.now.timeIntervalSince(start)
      spin(0.3)
      let done = Reading.now()
      report.row(
        "第 \(round) 次识完", done,
        note: String(format: "用了 %.2f s，识出 %d 个字", seconds, text?.count ?? -1)
          + "，比识字之前多 \(mb(done.footprint - base.footprint))")
      spin(10)
      after = Reading.now()
      report.row("闲 10 秒后", after, note: "比识字之前多 \(mb(after.footprint - base.footprint))")
    }
    report.summary.append(
      (
        "识字模型（识过一次就常驻）", mb(after.footprint - base.footprint), "放进子进程后约全部",
        "后面单独一批做（子进程）"
      ))
  }

  // MARK: - 4. 面板

  /// 一块面板的一轮要的东西
  private struct Stage {
    var window: NSWindow?
    /// 屏外显示（不当 key、不激活）
    var show: () -> Void
    /// 真面板收起 / 关闭时做的事（orderOut + onHide 里那些）
    var hide: () -> Void
    /// 显示之后还要量的（设置窗把几页都点一遍）：每个一行
    var extras: [(label: String, run: () -> Void)] = []
    /// 这一轮的模型：窗口放掉之后才放（真 App 里模型一直在）
    var models: [AnyObject] = []

    /// 放掉窗口和捏着它的闭包，模型留着
    mutating func releaseWindow() {
      window = nil
      show = {}
      hide = {}
      extras = []
    }
  }

  /// 面板用过、量完要清掉的缓存
  private enum Cache {
    case thumbnails
    case icons

    func clear() {
      switch self {
      case .thumbnails: Probe.clearThumbnails()
      case .icons: LauncherIcons.cache.removeAllObjects()
      }
    }
  }

  /// 三块主面板和设置窗各两轮：建 → 显示 → 收起 → contentView = nil → 放掉窗口，每步读数（App 里它们一直留着）；
  /// 两张 ⌘Y 大卡各四轮，照 App 现在的做法（card）
  private func panels(_ prefs: UserDefaults) throws {
    report.heading("4. 面板（三块主面板和设置窗：建 + 显示 → 收起 → 清内容 → 放掉窗口；两张 ⌘Y 大卡：照 App 的做法开关）")
    report.line(
      "「显示后」的备注里：图层 = 窗口图层树里带内容的图层数和按尺寸估的字节（确认屏外的窗口真的画出来了）；"
        + "「放掉窗口后」的备注里写窗口对象和 SwiftUI 宿主视图真的释放了没有")
    let (images, shots) = (images, shots)
    let store = try Self.makeStore(images: images, shots: shots)
    guard let picture = store.items.first(where: { $0.kind == .image }) else {
      throw Skip("临时库里没有图片条目")
    }
    let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    let limit = NSSize(width: screen.width * 0.9, height: screen.height * 0.9)

    // 热身：进程里第一块 SwiftUI 面板带着框架自己的一次性开销（字体、符号、材质…），别算到剪贴板面板头上
    rounds("热身（一块只有一行字的 OverlayPanel）", count: 1) {
      let panel = OverlayPanel(
        size: NSSize(width: 400, height: 300), autoHide: .clickOutside, isPinned: { true },
        content: Text("热身").frame(maxWidth: .infinity, maxHeight: .infinity))
      return Stage(
        window: panel, show: { Self.present(panel) }, hide: { [weak panel] in panel?.hide() })
    }

    rounds("剪贴板面板（720 宽，40 条，选中一张图片、透镜开着）", cache: .thumbnails) {
      let model = ClipboardPanelModel(store: store)
      model.select(picture)
      let panel = OverlayPanel(
        size: NSSize(
          width: ClipboardPanelView.width,
          height: ClipboardPanelView.height(for: model, showsLens: true, banner: false)),
        topAnchored: true, autoHide: .clickOutside, isPinned: { true },
        content: ClipboardPanelView(model: model).defaultAppStorage(prefs))
      panel.onHide = { [unowned model] in model.reset() }
      model.hidePanel = { [weak panel] in panel?.hide() }
      model.resize = { [weak panel] in panel?.setContentHeight($0, animated: true) }
      return Stage(
        window: panel, show: { Self.present(panel) }, hide: { [weak panel] in panel?.hide() },
        models: [model])
    }

    let apps = AppCatalog.scan()
    rounds("启动器面板（查「s」，8.5 行结果带 App 图标）", cache: .icons) {
      let model = LauncherModel(
        usage: try LauncherUsage(db: Database(path: ":memory:")), apps: apps)
      model.boundHotKey = { $0.defaultHotKey }
      model.prepareForShow()
      model.query = "s"
      let panel = OverlayPanel(
        size: NSSize(width: 720, height: LauncherPanelView.height(for: model)),
        topAnchored: true, autoHide: .clickOutside, isPinned: { true },
        content: LauncherPanelView(model: model).defaultAppStorage(prefs))
      panel.onHide = { [unowned model] in model.didHide() }
      model.hidePanel = { [weak panel] in panel?.hide() }
      model.resize = { [weak panel] in panel?.setContentHeight($0, animated: true) }
      return Stage(
        window: panel, show: { Self.present(panel) }, hide: { [weak panel] in panel?.hide() },
        models: [model])
    }

    let services = TranslateServiceStore(services: [
      .zhipu, .builtin(.google), .builtin(.deepl),
    ])
    let history = try HistoryStore(db: Database(path: ":memory:"))
    rounds("翻译浮窗（420 宽，三张出完字的结果卡）") {
      let coordinator = TranslateCoordinator(services: services, history: history)
      let speaker = Speaker()
      coordinator.beginInput()
      coordinator.sourceText = Self.english
      coordinator.translatedSource = coordinator.sourceText
      coordinator.detected = .en
      coordinator.target = .zhHans
      coordinator.cards = services.services.map { .init(service: $0, state: .done(Self.chinese)) }
      weak var created: OverlayPanel?
      // 没给 frameName：真的那块会读写用户偏好里记的窗口位置
      let panel = OverlayPanel(
        size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 200),
        autoHide: .resignKey, isPinned: { true },
        content: TranslatePanelView(
          coordinator: coordinator, speaker: speaker,
          resize: { height in
            // 同 AppDelegate：最矮 220，最高到屏幕可见区的 85%
            let height = min(max(height, 220), screen.height * 0.85)
            created?.setContentHeight(height, animated: false)
          }
        ).defaultAppStorage(prefs))
      created = panel
      panel.onHide = { [unowned coordinator, unowned speaker] in
        coordinator.cancel()
        speaker.stop()
      }
      return Stage(
        window: panel, show: { Self.present(panel) }, hide: { [weak panel] in panel?.hide() },
        models: [coordinator, speaker])
    }

    // 两张 ⌘Y 大卡照 App 现在的做法量（第 3 批）：TransientPanel 拿着，用时再建，收起后过一会儿自己放掉；
    // 开关走模型的 toggleQuickLook（同按 ⌘Y），接线照 AppDelegate，只是起止位置在屏幕外、isPinned 恒真。
    // 剪贴板那张先照改前的做法量一遍当对照：面板一直留着（lingering 给一小时 = 不放）、不丢大卡档、不调回收接口
    let source = NSRect(x: offscreen.x, y: offscreen.y, width: 708, height: 110)
    // 同 AppDelegate.quickLookFrame：图片放不下时等比缩进屏幕可见区的 90%
    let clipSize = QuickLookView.idealSize(for: picture, form: nil, within: limit)
    weak var keptTransient: TransientPanel?
    weak var keptPanel: OverlayPanel?
    weak var keptModel: ClipboardPanelModel?
    func clipboardCard(releases: Bool) {
      let model = ClipboardPanelModel(store: store)
      let make = { [unowned model] in
        let card = OverlayPanel(
          size: NSSize(width: 820, height: 640), autoHide: .clickOutside, isPinned: { true },
          content: QuickLookView(model: model) { _ in }.defaultAppStorage(prefs))
        card.becomesKeyOnlyIfNeeded = true
        card.onHide = { [unowned model] in model.quickLookDidHide() }
        return card
      }
      let clipCard =
        releases
        ? TransientPanel(
          onRelease: {
            ThumbnailView.dropCards()
            Memory.relieve()
          }, make: make)
        : TransientPanel(lingering: .seconds(3600), make: make)
      model.openQuickLook = { [unowned model] in
        model.showsQuickLookContent = true
        clipCard.open().zoom(from: source, to: NSRect(origin: offscreen, size: clipSize))
      }
      model.closeQuickLook = { animated in
        guard let card = clipCard.panel else { return }
        if animated { card.unzoom(to: source) } else { card.hide() }
      }
      card(
        releases
          ? "剪贴板 ⌘Y 大卡（一张 3420 × 2224 的图，2400 档，带识别文字；放掉时丢大卡档 + 调回收接口）"
          : "对照：剪贴板 ⌘Y 大卡照改前的做法（同一张图；面板一直留着，不丢大卡档、不调回收接口）",
        transient: clipCard, releases: releases, cache: .thumbnails,
        toggle: {
          // 没选中条目时 toggleQuickLook 会响提示音：每轮先选中（reset 会清掉选中）
          if model.selectedItem?.id != picture.id { model.select(picture) }
          model.toggleQuickLook()
        }, hideWithOwner: { model.reset() })
      if !releases { (keptTransient, keptPanel, keptModel) = (clipCard, clipCard.panel, model) }
      // 模型的这两个闭包拿着 TransientPanel、面板的内容又拿着模型：断开，出了这个函数对照那块面板才放得掉
      model.openQuickLook = {}
      model.closeQuickLook = { _ in }
    }
    // 对照那块面板是出了函数才放手的：包一个池，放手时自动释放的东西（宿主视图）出池就清（文件头第 2 个坑）
    autoreleasepool { clipboardCard(releases: false) }
    // 窗口的图层存储是窗口服务器那边过一两秒才还的
    spin(1.5)
    steady()
    report.step(
      "对照用的面板也放掉之后",
      note: "TransientPanel " + (keptTransient == nil ? "释放了" : "**还在**") + "，面板"
        + (keptPanel == nil ? "释放了" : "**还在**") + "，模型" + (keptModel == nil ? "释放了" : "**还在**"))
    // 对照没调过回收接口，解码用的那块还留着：先还掉，下面每一轮的「打开之前」才是干净的
    let took = relieve()
    steady()
    report.step("调一次回收接口", note: "把对照留下的还掉（调用本身 \(took)）")
    clipboardCard(releases: true)

    let fileModel = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: Array(apps.prefix(8)))
    fileModel.boundHotKey = { $0.defaultHotKey }
    fileModel.query = "open 截图"
    if let request = fileModel.fileRequest {
      fileModel.showFiles(
        [
          FileSearch.Hit(
            path: images.url(for: shots[1].id).path, name: "截图.png",
            contentType: UTType.png.identifier, date: .now)
        ], for: request)
    }
    // 选中的不是文件时 toggleQuickLook 会响提示音：先确认
    if fileModel.quickLookURL == nil {
      report.line("没量：启动器没选中文件（启动器 ⌘Y 快速查看）")
    } else {
      let fileSize = NSSize(width: 900, height: 680)
      let fileCard = TransientPanel { [unowned fileModel] in
        let card = OverlayPanel(
          size: fileSize, autoHide: .clickOutside, isPinned: { true },
          content: LauncherQuickLookView(model: fileModel))
        card.becomesKeyOnlyIfNeeded = true
        card.onHide = { [unowned fileModel] in fileModel.quickLookDidHide() }
        return card
      }
      fileModel.openQuickLook = {
        fileCard.open().zoom(from: source, to: NSRect(origin: offscreen, size: fileSize))
      }
      fileModel.closeQuickLook = { animated in
        guard let card = fileCard.panel else { return }
        if animated { card.unzoom(to: source) } else { card.hide() }
      }
      card(
        "启动器 ⌘Y 快速查看（900 × 680，Quick Look 看一张 PNG；预览服务连不上，只有卡片窗口；放掉时不调回收接口）",
        transient: fileCard, releases: true, cache: nil, toggle: { fileModel.toggleQuickLook() },
        hideWithOwner: {
          // 同 LauncherModel.didHide 里那两句（didHide 本身还会动别的状态）
          fileModel.closeQuickLook(false)
          fileModel.quickLookDidHide()
        })
    }

    let hotKeys = HotKeyCenter()
    let speaker = Speaker()
    rounds("设置窗（780 × 600，先看通用页，再把另外五页点一遍）") {
      let navigation = SettingsNavigation(defaults: nil)
      let root = SettingsRoot(navigation: navigation) { page in
        switch page {
        case .general: AnyView(GeneralTab())
        case .clipboard: AnyView(ClipboardTab(store: store))
        case .launcher: AnyView(EmptyView())
        case .screenshot: AnyView(ScreenshotTab())
        case .translate:
          AnyView(TranslateTab(services: services, history: history, speaker: speaker))
        case .hotkeys: AnyView(HotkeysTab(center: hotKeys))
        case .about: AnyView(AboutTab(updater: Updater()))
        }
      } onboarding: {
        AnyView(EmptyView())
      }
      // 照 SettingsWindow.init 的参数建（不用它本身：show() 会激活本 App，窗口位置会记进用户偏好）
      let hosting = NSHostingController(rootView: root.defaultAppStorage(prefs))
      hosting.sceneBridgingOptions = [.title, .toolbars]
      let window = ParkedWindow(contentViewController: hosting)
      window.title = navigation.page.title
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.toolbarStyle = .unified
      window.isReleasedWhenClosed = false
      window.collectionBehavior = [.fullScreenAuxiliary]
      window.setContentSize(NSSize(width: 780, height: 600))
      let pages: [SettingsPage] = [.clipboard, .translate, .screenshot, .hotkeys, .about, .general]
      return Stage(
        window: window,
        show: {
          window.setFrameOrigin(offscreen)
          window.orderFrontRegardless()
        }, hide: { [weak window] in window?.close() },
        extras: [
          (
            "另外五页都点一遍、回到通用页",
            {
              for page in pages {
                navigation.page = page
                spin(0.6)
              }
            }
          )
        ], models: [navigation])
    }
  }

  /// 一块面板量 count 轮（每轮一个新实例；App 里这几块是一直留着的，这里量的是「要是放掉能省多少」）。
  /// cache：它用过、量完要清掉的缓存。每个阶段一个自动释放池（像真 App 里事件循环转了一圈，文件头第 2 个坑）
  private func rounds(
    _ name: String, count: Int = 2, cache: Cache? = nil, make: () throws -> Stage
  ) {
    report.line("**\(name)**")
    var shown: [Int] = []
    var kept: [Int] = []
    var freedContent: [Int] = []
    var freedWindow: [Int] = []
    var freedCache: [Int] = []
    for index in 1...count {
      spin()
      let base = report.step("第 \(index) 轮：建之前")
      var last = base
      var stage: Stage?
      weak var window: NSWindow?
      weak var host: NSView?
      /// 清掉它用过的缓存，记一行
      func clearCache() {
        guard let cache else { return }
        autoreleasepool {
          cache.clear()
          steady()
        }
        let now = Reading.now()
        freedCache.append(last.footprint - now.footprint)
        report.row("清掉它用过的缓存", now, note: "回落 \(mb(last.footprint - now.footprint))")
        last = now
      }
      // 建 + 显示
      let built = autoreleasepool { () -> Bool in
        do {
          stage = try make()
        } catch {
          report.line("没量：\(error)")
          return false
        }
        window = stage?.window
        spin()
        report.step("建好（还没显示）")
        stage?.show()
        guard window.map(Self.isParked) == true else {
          window?.orderOut(nil)
          report.line("没量：系统把窗口挪回了屏幕上，马上收掉了")
          return false
        }
        // 打开的头一两秒带着解码大图、窗口变大的临时占用（自己会退）：每 50 毫秒读一次记下最高的，等稳了再读
        var peak = Reading.footprint()
        for _ in 0..<30 {
          spin(0.05)
          peak = max(peak, Reading.footprint())
        }
        steady()
        host = Self.hostingView(in: window?.contentView)
        let census = window.map(Self.layers(of:)) ?? (count: 0, bytes: 0, big: [])
        let frame = window?.frame.size ?? .zero
        let unseen = window?.occlusionState.contains(.visible) == false
        last = Reading.now()
        shown.append(last.footprint - base.footprint)
        report.row(
          "显示后（稳下来）", last,
          note:
            "比建之前多 \(mb(last.footprint - base.footprint))（打开过程中最高 \(mb(peak - base.footprint))）；"
            + "图层 \(census.count) 个带内容、估 \(mb(census.bytes))；"
            + "\(Int(frame.width)) × \(Int(frame.height)) 点" + (unseen ? "，系统当它看不见（屏外）" : ""))
        for extra in stage?.extras ?? [] {
          extra.run()
          steady()
          last = Reading.now()
          report.row(extra.label, last, note: "比建之前多 \(mb(last.footprint - base.footprint))")
        }
        return true
      }
      guard built else { return }
      // 收起
      autoreleasepool {
        stage?.hide()
        spin()
        steady()
      }
      last = Reading.now()
      kept.append(last.footprint - base.footprint)
      report.row("收起后", last, note: "还比建之前多 \(mb(last.footprint - base.footprint))")
      // 只清内容：窗口对象还留着
      let hidden = last
      autoreleasepool {
        window?.contentViewController = nil
        window?.contentView = nil
        steady()
      }
      last = Reading.now()
      freedContent.append(hidden.footprint - last.footprint)
      report.row(
        "contentView = nil 后", last,
        note: "回落 \(mb(hidden.footprint - last.footprint))；SwiftUI 宿主视图"
          + (host == nil ? "释放了" : "**还在**（面板自己还捏着它）"))
      // 放掉窗口。它的图层存储是窗口服务器那边过一两秒才还的：多等一会儿再等稳
      autoreleasepool { stage?.releaseWindow() }
      spin(1.5)
      steady()
      last = Reading.now()
      freedWindow.append(hidden.footprint - last.footprint)
      report.row(
        "放掉窗口后", last,
        note: "清内容 + 放窗口共回落 \(mb(hidden.footprint - last.footprint))；窗口对象"
          + (window == nil ? "释放了" : "**还在**") + "，SwiftUI 宿主视图"
          + (host == nil ? "释放了" : "**还在**"))
      clearCache()
      autoreleasepool { stage = nil }
      steady()
      let end = Reading.now()
      report.row("放掉模型后", end, note: "比建之前多 \(signed(end.footprint - base.footprint))")
    }
    guard count > 1 else { return }
    report.summary.append(
      (
        name, "显示后 +\(list(shown))；收起后还留 \(list(kept))",
        "只清内容 \(list(freedContent))；清内容 + 放窗口 \(list(freedWindow))"
          + (cache == nil ? "" : "；清缓存 \(list(freedCache))"),
        (freedWindow.max() ?? 0) >= 10 * megabyte ? "收起后放掉窗口" : "不用清（放窗口省不到 10 MB）"
      ))
  }

  /// 一张 ⌘Y 大卡照 App 的做法量四轮：toggle 打开（用时再建 + zoom）→ 稳下来 → 收起（单数轮 toggle 缩回去，同再按 ⌘Y；
  /// 双数轮 hideWithOwner，同跟着主面板收起）→ 还没放掉时读一次 → 等它自己放掉（TransientPanel 的 lingering，放掉时做
  /// onRelease）→ 再手动调一次回收接口，看 App 自己那一下漏了多少。最后一轮收起后马上又打开一次：应该接着用同一块。
  /// 打开到收起包在一个自动释放池里、赶在放掉之前出池（文件头第 2 个坑：池里的引用不清，放了手窗口也不释放）。
  /// releases = false：对照，transient 不会放（改前的做法），收起后隔 3 秒、再 3 秒各读一次，看留着的面板占多少
  private func card(
    _ name: String, transient: TransientPanel, releases: Bool, cache: Cache?, toggle: () -> Void,
    hideWithOwner: () -> Void
  ) {
    report.line("**\(name)**")
    var shown: [Int] = []
    var peaks: [Int] = []
    var lingering: [Int] = []
    var kept: [Int] = []
    var missed: [Int] = []
    var builds: [String] = []
    for round in 1...4 {
      spin()
      let base = report.step(
        "第 \(round) 轮：打开之前"
          + (transient.panel == nil ? "（面板没建）" : releases ? "（**面板还在**）" : "（面板留着）"))
      weak var window: NSWindow?
      weak var host: NSView?
      let opened = autoreleasepool { () -> Bool in
        let start = Date.now
        toggle()
        builds.append(String(format: "%.0f ms", Date.now.timeIntervalSince(start) * 1000))
        window = transient.panel
        guard let panel = transient.panel, Self.isParked(panel) else {
          transient.panel?.orderOut(nil)
          report.line("没量：面板没开出来，或者被系统挪回了屏幕上")
          return false
        }
        // 打开的头一两秒带着解码大图、窗口变大的临时占用（自己会退）：每 50 毫秒读一次记下最高的，等稳了再读
        var peak = Reading.footprint()
        for _ in 0..<30 {
          spin(0.05)
          peak = max(peak, Reading.footprint())
        }
        steady()
        host = Self.hostingView(in: panel.contentView)
        let census = Self.layers(of: panel)
        let now = Reading.now()
        shown.append(now.footprint - base.footprint)
        peaks.append(peak - base.footprint)
        report.row(
          "打开后（稳下来）", now,
          note:
            "比打开之前多 \(mb(now.footprint - base.footprint))（打开过程中最高 \(mb(peak - base.footprint))）；"
            + "建面板 + zoom 那一下 \(builds.last ?? "")；\(Int(panel.frame.width)) × \(Int(panel.frame.height)) 点；"
            + "图层 \(census.count) 个带内容、估 \(mb(census.bytes))，大块："
            + census.big.joined(separator: "、"))
        if round == 4 {
          // 收起后马上又打开：还没到放掉的时候，应该是同一块面板、缓存里的图还在
          toggle()
          spin(0.5)
          let again = Date.now
          toggle()
          let reopening = String(format: "%.0f ms", Date.now.timeIntervalSince(again) * 1000)
          let reused = transient.panel === panel
          var peak = Reading.footprint()
          for _ in 0..<20 {
            spin(0.05)
            peak = max(peak, Reading.footprint())
          }
          report.step(
            "缩回去 0.5 秒后又打开",
            note: (reused ? "接着用同一块面板" : "**换了一块面板**")
              + "，再打开那一下 \(reopening)"
              + "，这一秒里最高比打开之前多 \(mb(peak - base.footprint))")
        }
        if round % 2 == 1 {
          toggle()
          spin(0.4)
        } else {
          hideWithOwner()
        }
        return true
      }
      guard opened else { return }
      spin(0.3)
      var now = Reading.now()
      lingering.append(now.footprint - base.footprint)
      report.row(
        round % 2 == 1 ? "缩回去之后（还没放掉）" : "直接收起之后（还没放掉）", now,
        note: "还比打开之前多 \(mb(now.footprint - base.footprint))；面板"
          + (transient.panel == nil ? "**已经放掉了**" : "还留着"))
      guard releases else {
        spin(3)
        report.step("3 秒后（面板一直留着）")
        spin(3)
        steady()
        now = Reading.now()
        kept.append(now.footprint - base.footprint)
        report.row("再过 3 秒", now, note: "还比打开之前多 \(signed(now.footprint - base.footprint))")
        continue
      }
      // 等它自己放掉；窗口的图层存储是窗口服务器那边过一两秒才还的：多等一会儿再等稳
      let start = Date.now
      while transient.panel != nil, Date.now.timeIntervalSince(start) < 10 { spin(0.1) }
      let waited = Date.now.timeIntervalSince(start)
      spin(1.5)
      steady()
      now = Reading.now()
      kept.append(now.footprint - base.footprint)
      report.row(
        "自己放掉之后（App 现在的做法）", now,
        note: "还比打开之前多 \(signed(now.footprint - base.footprint))；读完上一行又过了 "
          + String(format: "%.1f s", waited) + " 放掉；窗口对象"
          + (window == nil ? "释放了" : "**还在**") + "，SwiftUI 宿主视图"
          + (host == nil ? "释放了" : "**还在**"))
      let last = now
      let took = relieve()
      steady()
      now = Reading.now()
      missed.append(last.footprint - now.footprint)
      report.row(
        "再手动调一次回收接口", now,
        note: "又回落 \(mb(last.footprint - now.footprint))（调用本身 \(took)），比打开之前多 "
          + "\(signed(now.footprint - base.footprint))")
    }
    if let cache {
      let last = Reading.now()
      autoreleasepool {
        cache.clear()
        steady()
      }
      let now = Reading.now()
      report.row("清掉它用过的缓存", now, note: "回落 \(mb(last.footprint - now.footprint))")
    }
    guard releases else {
      report.summary.append(
        (
          name,
          "打开后 +\(list(shown))（过程中最高 +\(list(peaks))）；打开那一下 \(builds.joined(separator: " / "))",
          "收起 6 秒后还比各轮打开之前多 \(kept.map(signed).joined(separator: " / "))（后几轮的「之前」已经带着前面留下的）",
          "改前的做法，只当对照"
        ))
      return
    }
    report.summary.append(
      (
        name,
        "打开后 +\(list(shown))（过程中最高 +\(list(peaks))）；收起后还没放掉时 +\(list(lingering))；"
          + "建面板 + zoom \(builds.joined(separator: " / "))",
        "自己放掉后还比打开之前多 \(kept.map(signed).joined(separator: " / "))；再手动调一次回收接口 \(list(missed))",
        (kept.max() ?? 0) < 10 * megabyte ? "已改成用时再建、收起后放掉（第 3 批）" : "**放掉后还留 10 MB 以上，查**"
      ))
  }

  /// 屏外显示一块 OverlayPanel：摆到屏幕外，不抢键盘（走真的 present，只是不重新摆位、不当 key）
  private static func present(_ panel: OverlayPanel) {
    panel.setFrameOrigin(offscreen)
    panel.present(makingKey: false, keepsPlace: true)
  }

  /// 窗口在所有屏幕外面
  private static func isParked(_ window: NSWindow) -> Bool {
    NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }
  }

  /// 窗口图层树里带内容的图层：个数和按尺寸估的字节（位图按它自己的行宽，其余按 宽 × 高 × 倍率² × 4），
  /// 再列出 4 MB 以上的大块（像素尺寸、内容的类型、是谁的图层）
  private static func layers(of window: NSWindow) -> (count: Int, bytes: Int, big: [String]) {
    var count = 0
    var bytes = 0
    var big: [String] = []
    func visit(_ layer: CALayer) {
      if let contents = layer.contents {
        count += 1
        let size: Int
        let pixels: String
        if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
          // swift-format-ignore: NeverForceUnwrap
          let image = contents as! CGImage
          size = image.bytesPerRow * image.height
          pixels = "\(image.width)×\(image.height) 位图"
        } else {
          let scale = layer.contentsScale
          let (width, height) = (Int(layer.bounds.width * scale), Int(layer.bounds.height * scale))
          size = width * height * 4
          let kind = CFCopyTypeIDDescription(CFGetTypeID(contents as CFTypeRef)) as String? ?? "?"
          pixels = "\(width)×\(height) \(kind)"
        }
        bytes += size
        if size >= 4 * megabyte {
          let owner = layer.delegate.map { String(describing: type(of: $0)) }
          big.append("\(pixels)（\(owner ?? String(describing: type(of: layer)))）")
        }
      }
      layer.sublayers?.forEach(visit)
    }
    if let root = (window.contentView?.superview ?? window.contentView)?.layer { visit(root) }
    return (count, bytes, big)
  }

  /// 视图树里的 SwiftUI 宿主视图（NSHostingView<…>）
  private static func hostingView(in view: NSView?) -> NSView? {
    guard let view else { return nil }
    if String(describing: type(of: view)).contains("HostingView") { return view }
    for child in view.subviews {
      if let found = hostingView(in: child) { return found }
    }
    return nil
  }

  /// 临时的剪贴板库：28 条文本（长短、代码、JSON）、4 条文件、12 张图片，按时间穿插。图片都当收藏（不受用户设的
  /// 「图片最多占用」影响）、识别文字给好（不触发识字）
  private static func makeStore(images: ImageStore, shots: [Shot]) throws -> ClipboardStore {
    let store = try ClipboardStore(db: Database(path: ":memory:"), images: images)
    var items: [ClipItem] = []
    for index in 0..<28 {
      var item = ClipItem(
        kind: .text, sourceName: index % 2 == 0 ? "备忘录" : "Xcode",
        sourceBundleID: index % 2 == 0 ? "com.apple.Notes" : "com.apple.dt.Xcode")
      item.text =
        switch index % 4 {
        case 0: "第 \(index) 条：" + chinese
        case 1: "struct Row\(index): View {\n  var body: some View { Text(\"row \(index)\") }\n}"
        case 2: "{\"index\": \(index), \"name\": \"kitty\", \"tags\": [1, 2, 3]}"
        default: "短文本 \(index)"
        }
      items.append(item)
    }
    for (index, paths) in [
      ["/System/Applications/Notes.app"],
      ["/System/Applications/Calculator.app", "/System/Applications/TextEdit.app"],
      ["/System/Applications/Preview.app"], ["/System/Library/CoreServices/Finder.app"],
    ].enumerated() {
      var item = ClipItem(kind: .file, sourceName: "访达", sourceBundleID: "com.apple.finder")
      item.filePaths = paths
      items.insert(item, at: index * 7)
    }
    for (index, shot) in shots.enumerated() {
      var item = ClipItem(
        id: shot.id, kind: .image, sourceName: "微信", sourceBundleID: "com.tencent.xinWeChat")
      item.image = .init(
        width: shot.width, height: shot.height, byteCount: shot.bytes, sha256: "probe-\(index)")
      item.ocrText = shot.text
      item.favorite = true
      items.insert(item, at: index * 3)
    }
    // 下标小的最新：最后入库
    for (index, var item) in items.enumerated().reversed() {
      item.copiedAt = .now.addingTimeInterval(-Double(index) * 60)
      store.record(item)
    }
    return store
  }

  private static let english =
    "SwiftUI lets you describe your interface declaratively: say what it should look like for a "
    + "state, and the framework keeps it up to date."
  private static let chinese =
    "SwiftUI 用声明式的方式描述界面：你只需要写出界面在某个状态下应该是什么样子，状态一变，框架就会自动更新对应的视图。"
    + "视图是轻量的值类型，组合起来很便宜，所以可以放心地把大界面拆成许多小视图。"
    + "布局由父视图提议尺寸、子视图自己决定大小，再由父视图摆放位置，三步走完。"

  // MARK: - 5. 回收接口

  /// 先看前面几项跑完之后的陈年脏页能还多少；再做三轮和截图 / 转 GIF 相当的重活，看峰值、放掉之后、调回收接口之后
  private func relief() {
    report.heading("5. 回收接口（malloc_zone_pressure_relief(nil, 0)）")
    let images = images
    let sources = shots.prefix(4).map { images.url(for: $0.id) }
    let gif = scratch.appending(path: "probe.gif")
    let work: @Sendable () async -> Void = {
      await heavyWork(sources: sources, images: images, gif: gif)
    }
    spin()
    let before = report.step("前面几项都跑完了、什么都没留着")
    let took = relieve()
    spin()
    let after = Reading.now()
    report.row(
      "调一次回收接口", after, note: "回落 \(mb(before.footprint - after.footprint))（调用本身 \(took)）")
    var leftovers: [Int] = []
    var relieved: [Int] = []
    for round in 1...3 {
      let base = report.step("第 \(round) 轮重活之前")
      let start = Date.now
      let peak = wait { await Self.peak(during: work) }
      let seconds = Date.now.timeIntervalSince(start)
      spin(1)
      let done = Reading.now()
      leftovers.append(done.footprint - base.footprint)
      report.row(
        "重活做完、全放掉 1 秒后", done,
        note: String(format: "用了 %.1f s，", seconds)
          + "峰值 \(mb(peak))（比之前高 \(mb(peak - base.footprint))），放掉后还比之前多 \(signed(done.footprint - base.footprint))"
      )
      spin(3)
      let waited = Reading.now()
      report.row("再等 3 秒", waited, note: "自己又回落 \(mb(done.footprint - waited.footprint))")
      let took = relieve()
      spin()
      let relief = Reading.now()
      relieved.append(waited.footprint - relief.footprint)
      report.row(
        "调回收接口", relief,
        note: "回落 \(mb(waited.footprint - relief.footprint))（调用本身 \(took)），"
          + "比重活之前多 \(signed(relief.footprint - base.footprint))")
    }
    report.line(
      "重活 = 连着 4 张 5120 × 2880 的「截图」（解码源图 → 画进新位图 → ScreenshotOutput.png 编码 → ImageStore.save "
        + "写盘 + SHA256 → 再整张解码一次）+ 一段 90 帧 960 × 540 的 GIF（逐帧加，每帧自己的调色板，同 VideoExport）")
    report.summary.append(
      (
        "回收接口：跑完前面几项后调一次", "—", mb(before.footprint - after.footprint),
        before.footprint - after.footprint >= 10 * megabyte ? "留着（闲时调）" : "省不到 10 MB"
      ))
    report.summary.append(
      (
        "回收接口：重活（截图 × 4 + GIF）之后", "重活后多 \(list(leftovers))", list(relieved),
        (relieved.max() ?? 0) >= 10 * megabyte ? "留着（重活之后调）" : "不用（重活自己还得干净，省不到 10 MB）"
      ))
  }

  /// 跑 work 的同时每 2 ms 读一次 footprint，返回这段时间里的最高值
  nonisolated private static func peak(during work: @escaping @Sendable () async -> Void) async
    -> Int
  {
    await withTaskGroup(of: Int?.self) { group in
      group.addTask {
        await work()
        return nil
      }
      group.addTask {
        var peak = Reading.footprint()
        while !Task.isCancelled {
          peak = max(peak, Reading.footprint())
          try? await Task.sleep(for: .milliseconds(2))
        }
        return peak
      }
      var peak = 0
      for await value in group {
        if let value { peak = value } else { group.cancelAll() }
      }
      return peak
    }
  }
}

/// 缩略图一节的小画廊：屏外窗口里用真的 ThumbnailView 把 ids 画出来（每张一个 cell 大的格子），ids 换了就换图
@Observable private final class Gallery {
  var ids: [UUID] = []
}

private struct GalleryView: View {
  let gallery: Gallery
  let images: ImageStore
  let maxPixel: Int
  let cell: CGSize
  let mode: ContentMode

  var body: some View {
    HStack(spacing: 0) {
      ForEach(gallery.ids, id: \.self) { id in
        ThumbnailView(id: id, images: images, maxPixel: maxPixel, contentMode: mode)
          .frame(width: cell.width, height: cell.height)
          .clipped()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// 没量成的原因（报告里写一句）
private struct Skip: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// 不让系统把带标题栏的窗口挪回屏幕里（设置窗的替身要待在屏幕外）
private final class ParkedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

// MARK: - 读数

/// 此刻的内存读数（字节）
nonisolated private struct Reading: Sendable {
  /// task_info(TASK_VM_INFO) 的 phys_footprint：活动监视器「内存」那一列的口径
  var footprint = 0
  /// 默认 malloc zone 正在用的字节；MALLOC 脏页比它多出来的大致 = 用完没还给系统的（另含 purgeable zone 里画过的缩略图）
  var heapInUse = 0
  /// footprint 工具的分类（Dirty 列）；工具没跑成是空的
  var categories: [String: Int] = [:]

  var malloc: Int { sum("MALLOC") }
  var coreAnimation: Int { sum("CoreAnimation") }
  var raster: Int { sum("CG raster data") + sum("CG image") }
  var surfaces: Int { sum("IOSurface") + sum("IOAccelerator") }

  private func sum(_ prefix: String) -> Int {
    categories.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
  }

  static func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
  }

  /// 只看默认 zone（文件头第 3 个坑）
  static func heapInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &stats)
    return stats.size_in_use
  }

  /// 和上一次读数比，变了 1 MB 以上的分类（「CoreAnimation +14.3、MALLOC_LARGE −14.3」），大的在前
  func changes(since earlier: Reading) -> String {
    var deltas: [(name: String, bytes: Int)] = []
    for name in Set(categories.keys).union(earlier.categories.keys) {
      let bytes = (categories[name] ?? 0) - (earlier.categories[name] ?? 0)
      if abs(bytes) >= megabyte { deltas.append((name, bytes)) }
    }
    deltas.sort { abs($0.bytes) > abs($1.bytes) }
    return deltas.map { delta in
      let amount = String(format: "%.1f", Double(abs(delta.bytes)) / Double(megabyte))
      return delta.name + (delta.bytes >= 0 ? " +" : " −") + amount
    }
    .joined(separator: "、")
  }

  /// 读一次：让 footprint 工具按分类拆（同一个口径，零点一秒左右），再读自己的 footprint 和堆——自己的数放在工具
  /// 跑完之后读，先读的话两边对的不是同一刻
  static func now() -> Reading {
    let categories = categories()
    return Reading(footprint: footprint(), heapInUse: heapInUse(), categories: categories)
  }

  /// footprint 工具的分类（Dirty 列，字节）；工具没跑成是空的
  private static func categories() -> [String: Int] {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/footprint")
    process.arguments = ["-f", "bytes", "-p", String(getpid())]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [:] }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    var categories: [String: Int] = [:]
    for line in output.split(separator: "\n") {
      guard let match = line.wholeMatch(of: /\s*(\d+) B\s+\d+ B\s+\d+ B\s+\d+\s+(.+?)\s*/),
        match.2 != "TOTAL"
      else { continue }
      categories[String(match.2)] = Int(match.1)
    }
    return categories
  }
}

// MARK: - 报告

/// 一步一行攒在内存里，每节结束追加进 <目录>/report.md；同时打到标准输出（xcodebuild 的输出里也看得到）
private final class Report {
  private let file: URL
  private var text = ""
  private var inTable = false
  private var last: Reading?
  /// 汇总表：项 / 现在占 / 能省 / 建议
  var summary: [(item: String, now: String, saving: String, verdict: String)] = []

  init(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    file = directory.appending(path: "report.md")
  }

  /// 这一次的段头：时间、机器、屏幕、范围
  func begin() {
    let screen =
      NSScreen.main.map {
        "\(Int($0.frame.width)) × \(Int($0.frame.height)) 点 × \($0.backingScaleFactor)"
      } ?? "没有屏幕"
    let stamp = Date.now.formatted(date: .numeric, time: .standard)
    text +=
      "\n## 内存探针 \(stamp)（pid \(getpid())）\n\n"
      + "- \(ProcessInfo.processInfo.operatingSystemVersionString)，主屏 \(screen)，Debug 构建的测试宿主；"
      + "数都是 MB（1 MB = 1048576 字节），footprint = task_info(TASK_VM_INFO).phys_footprint；"
      + "MALLOC 脏页、CoreAnimation、CG raster、IOSurface 等是 footprint 工具的分类，堆在用是默认 malloc zone 在用的字节\n"
      + "- 范围：\(probeOnly.map { $0.sorted().joined(separator: "、") } ?? "全部五项")\n"
  }

  func heading(_ title: String) {
    flush()
    text += "\n### \(title)\n\n"
    inTable = false
    last = nil
  }

  func line(_ line: String) {
    if inTable { text += "\n" }
    inTable = false
    text += "- \(line)\n"
  }

  func row(_ label: String, _ reading: Reading, note: String = "") {
    if !inTable {
      text +=
        "\n| 步骤 | footprint | 比上一行 | MALLOC 脏页 | 堆在用 | CoreAnimation | CG raster | IOSurface 等 | 备注〔变了 1 MB 以上的分类〕 |\n"
        + "|---|---:|---:|---:|---:|---:|---:|---:|---|\n"
      inTable = true
    }
    let parts =
      reading.categories.isEmpty
      ? ["–", mb(reading.heapInUse), "–", "–", "–"]
      : [
        mb(reading.malloc), mb(reading.heapInUse), mb(reading.coreAnimation), mb(reading.raster),
        mb(reading.surfaces),
      ]
    let delta = last.map { signed(reading.footprint - $0.footprint) } ?? ""
    let changes = last.map { reading.changes(since: $0) } ?? ""
    let remark = [note, changes.isEmpty ? "" : "〔\(changes)〕"].filter { !$0.isEmpty }
      .joined(separator: " ")
    text +=
      "| \(label) | \(mb(reading.footprint)) | \(delta) | " + parts.joined(separator: " | ")
      + " | \(remark) |\n"
    last = reading
  }

  /// 读一次数、记一行
  @discardableResult
  func step(_ label: String, note: String = "") -> Reading {
    let reading = Reading.now()
    row(label, reading, note: note)
    return reading
  }

  /// 汇总表 + 落盘
  func finish() {
    flush()
    text += "\n### 6. 汇总\n\n| 项 | 现在占 | 能省 | 建议 |\n|---|---|---|---|\n"
    for entry in summary {
      text += "| \(entry.item) | \(entry.now) | \(entry.saving) | \(entry.verdict) |\n"
    }
    text +=
      "\n- 几个数并排的是各轮（遍）的；面板那几行「现在占」是比建之前多的，「能省」是收起之后再做那一步回落的；"
      + "建议只按「单块能省 10 MB 以上才值得」这一条机械地判，取舍写在 PLAN §10\n"
    flush()
  }

  func flush() {
    guard !text.isEmpty else { return }
    print(text)
    if !FileManager.default.fileExists(atPath: file.path) {
      try? "# 内存探针报告\n".write(to: file, atomically: true, encoding: .utf8)
    }
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(Data(text.utf8))
      try? handle.close()
    }
    text = ""
  }
}

// MARK: - 合成图和重活

/// 一张合成的「整屏截图」：浅色底、顶上一条渐变、一扇带标题栏的窗口、四十行中英文、几块色块；PNG 写进图片库
private struct Shot {
  let id: UUID
  let width: Int
  let height: Int
  let bytes: Int
  /// 画上去的字（当识别文字用）
  let text: String

  /// 长边缩到 maxPixel 的缩略图解码后的字节（宽 × 高 × 4）
  func thumbnailBytes(_ maxPixel: Int) -> Int {
    let scale = min(1, Double(maxPixel) / Double(max(width, height)))
    return Int((Double(width) * scale).rounded()) * Int((Double(height) * scale).rounded()) * 4
  }

  static func make(index: Int, width: Int, height: Int, in images: ImageStore) throws -> Shot {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { throw Skip("建不出位图") }
    let lines = (0..<40).map { row in
      row % 3 == 0
        ? "第 \(index + 1) 张截图的第 \(row + 1) 行：透镜指令条的设计说明，选中哪条哪条就在原地展开成预览"
        : "Line \(row + 1) of shot \(index + 1): the quick brown fox jumps over the lazy dog, 0123456789"
    }
    let hue = CGFloat(index % 12) / 12
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(hue: hue, saturation: 0.08, brightness: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGradient(
      starting: NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1),
      ending: NSColor(
        hue: (hue + 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.6,
        alpha: 1)
    )?.draw(in: NSRect(x: 0, y: height - 220, width: width, height: 220), angle: 20)
    let window = NSRect(x: 160, y: 120, width: width - 320, height: height - 460)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: window, xRadius: 24, yRadius: 24).fill()
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: window.minX, y: window.maxY - 84, width: window.width, height: 84).fill()
    for (row, line) in lines.enumerated() {
      NSAttributedString(
        string: line,
        attributes: [
          .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ]
      ).draw(at: NSPoint(x: window.minX + 60, y: window.maxY - 150 - CGFloat(row) * 40))
    }
    for block in 0..<5 {
      NSColor(
        hue: (hue + CGFloat(block) * 0.13).truncatingRemainder(dividingBy: 1), saturation: 0.7,
        brightness: 0.85, alpha: 1
      ).setFill()
      NSRect(
        x: window.maxX - 700, y: window.minY + 80 + CGFloat(block) * 290, width: 560, height: 240
      ).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw Skip("PNG 编码失败")
    }
    let id = UUID()
    try png.write(to: images.url(for: id))
    return Shot(
      id: id, width: width, height: height, bytes: png.count,
      text: lines.joined(separator: "\n"))
  }
}

/// 和截图 / 转 GIF 相当的重活（后台跑，同真路径）：连着 4 张 5120 × 2880 的「截图」各走一遍 解码源图 → 画进新位图
/// （同 Annotation.render）→ PNG 编码（ScreenshotOutput.png）→ 写盘 + SHA256（ImageStore.save）→ 再整张解码
/// （同「钉到屏幕」）；再编一段 90 帧 960 × 540 的 GIF（参数同 VideoExport.gif）。做完什么都不留
@concurrent nonisolated private func heavyWork(sources: [URL], images: ImageStore, gif: URL) async {
  for source in sources {
    guard let shot = scaled(source, width: 5120, height: 2880),
      let png = await ScreenshotOutput.png(shot, scale: 2)
    else { continue }
    let id = UUID()
    _ = await images.save(png, isPNG: true, id: id)
    _ = await images.thumbnail(for: id, maxPixel: 5120)
    images.delete(id)
  }
  guard let base = sources.first.flatMap({ scaled($0, width: 960, height: 540) }),
    let destination = CGImageDestinationCreateWithURL(
      gif as CFURL, UTType.gif.identifier as CFString, 90, nil)
  else { return }
  CGImageDestinationSetProperties(
    destination,
    [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false,
      ]
    ] as CFDictionary)
  for frame in 0..<90 {
    guard let image = shifted(base, by: frame * 8) else { continue }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1.0 / 15]]
        as CFDictionary)
  }
  CGImageDestinationFinalize(destination)
  try? FileManager.default.removeItem(at: gif)
}

/// 把一张图整张解码、画进 width × height 的新位图
nonisolated private func scaled(_ url: URL, width: Int, height: Int) -> CGImage? {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let context = bitmapContext(width: width, height: height)
  else { return nil }
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()
}

/// GIF 的一帧：底图横移 offset 像素，再盖一块跟着动的色块（每帧都不一样）
nonisolated private func shifted(_ base: CGImage, by offset: Int) -> CGImage? {
  guard let context = bitmapContext(width: base.width, height: base.height) else { return nil }
  let x = CGFloat(offset % base.width)
  let size = CGSize(width: base.width, height: base.height)
  context.draw(base, in: CGRect(origin: CGPoint(x: -x, y: 0), size: size))
  context.draw(base, in: CGRect(origin: CGPoint(x: size.width - x, y: 0), size: size))
  context.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.5, alpha: 1))
  context.fill(CGRect(x: x, y: 200, width: 120, height: 120))
  return context.makeImage()
}

nonisolated private func bitmapContext(width: Int, height: Int) -> CGContext? {
  CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

// MARK: - 小工具

/// 等一会儿：嵌套跑环，让图层事务、SwiftUI 的更新、任务、动画回调都走完；包在自动释放池里，这段时间里 AppKit 自动释放的
/// 东西出来就清掉（像真 App 的事件循环转了一圈，文件头第 2 个坑）
private func spin(_ seconds: Double = 0.5) {
  autoreleasepool { RunLoop.main.run(until: .now.addingTimeInterval(seconds)) }
}

/// 调一次 malloc_zone_pressure_relief(nil, 0)（所有 zone、能还多少还多少），返回调用本身用了多久
private func relieve() -> String {
  let start = Date.now
  _ = malloc_zone_pressure_relief(nil, 0)
  return String(format: "%.1f ms", Date.now.timeIntervalSince(start) * 1000)
}

/// 等读数稳下来：每 0.25 秒读一次，连着 0.75 秒相差不到 0.3 MB 就算稳了，最多等 8 秒。窗口放手之后图层的存储、
/// ⌘Y 大卡刚打开时解码的临时占用都是过一会儿才退的，固定等一秒会把这一步的回落记到下一步头上（第 5 遍实测）
private func steady() {
  var last = Reading.footprint()
  var calm = 0
  for _ in 0..<32 where calm < 3 {
    spin(0.25)
    let now = Reading.footprint()
    calm = abs(now - last) < megabyte * 3 / 10 ? calm + 1 : 0
    last = now
  }
}

/// 同步等一个异步操作做完（探针跑在跑环的块里、不占主队列，嵌套跑环时任务照常跑）
@discardableResult
private func wait<T>(_ operation: @escaping () async -> T) -> T {
  var result: T?
  Task { result = await operation() }
  while true {
    if let result { return result }
    spin(0.02)
  }
}

nonisolated private func mb(_ bytes: Int) -> String {
  String(format: "%.1f MB", Double(bytes) / Double(megabyte))
}

nonisolated private func kb(_ bytes: Int) -> String {
  bytes >= megabyte ? mb(bytes) : String(format: "%.0f KB", Double(bytes) / 1024)
}

nonisolated private func signed(_ bytes: Int) -> String {
  (bytes >= 0 ? "+" : "−") + mb(abs(bytes))
}

/// 几轮的数并排：「12.3 MB / 11.9 MB」
nonisolated private func list(_ values: [Int]) -> String {
  values.map(mb).joined(separator: " / ")
}
