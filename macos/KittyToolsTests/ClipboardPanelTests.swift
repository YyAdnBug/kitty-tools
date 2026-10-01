// 剪贴板面板交互（体检第 3 批）的纯逻辑单测：JSON 默认美化与缓存、条目消失后选中挪到下一条、多选随搜索裁剪、
// 右键 / ⌘Y「复制」只复制被点的那条、菜单开着时过滤框的编辑键、⌘K 与右键同一份动作表（分节、子列表、按类型的动作）、
// 共用的菜单过滤（拼音前缀）、钉到屏幕的位置、复制路径、拖出去的剪贴板条目、对话框能否保存、⌘Y 里的纯文本复制、
// 判定「行标题已显示全」的条目在行里真的没被截断（把行画在屏外窗口里比像素）。
// 用内存库 + 临时目录，不碰真实数据；不跑会真的打开网址 / 文件、弹面板的动作。

import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

@testable import KittyTools

struct ClipboardPanelTests {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

  private func makeModel(_ texts: [String]) throws -> (ClipboardPanelModel, ClipboardStore) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try ClipboardStore(
      db: Database(path: ":memory:"), images: ImageStore(directory: directory))
    // 先记的在下面：texts[0] 是最新的一条（列表第一行）
    for (index, text) in texts.enumerated().reversed() {
      var item = ClipItem(kind: .text, copiedAt: Date.now.addingTimeInterval(-Double(index + 1)))
      item.text = text
      store.record(item)
    }
    let model = ClipboardPanelModel(store: store)
    model.writeClipboard = { _ in }
    return (model, store)
  }

  private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: UInt16(code)))
  }

  private func item(_ model: ClipboardPanelModel, _ text: String) throws -> ClipItem {
    try #require(model.store.items.first { $0.text == text })
  }

  /// JSON 默认美化（体检 A10）：换条目不复位，一次呼出里点过「原文」就一直看原文，收起面板（reset）才回到美化；
  /// 美化结果按条目缓存，编辑正文后清掉
  @Test func jsonPrettyByDefault() throws {
    let (model, _) = try makeModel([#"{"b":1,"a":[2]}"#, "普通文本", #"{"x":true}"#])
    let json = try item(model, #"{"b":1,"a":[2]}"#)
    #expect(model.prettyJSON)
    #expect(model.displayText(of: json).contains("\n"))
    model.prettyJSON = false
    model.select(try item(model, "普通文本"))
    model.select(json)
    #expect(!model.prettyJSON && model.displayText(of: json) == #"{"b":1,"a":[2]}"#)
    model.query = "x"
    #expect(!model.prettyJSON)
    model.reset()
    #expect(model.prettyJSON)
    #expect(model.displayText(of: json).hasPrefix("{\n"))
    model.edit(json.id, text: #"{"c":3}"#)
    let edited = try item(model, #"{"c":3}"#)
    #expect(model.displayText(of: edited).contains(#""c" : 3"#))
    #expect(model.actions(for: edited, targets: [edited]).contains { $0.title == "显示原文" })
  }

  /// 条目从列表消失后选中挪到下一条（体检 B7）：连按 ⌘⌫ 删的是第 3、4 条，不会跳回第一条；删最后一条挪到上一条；
  /// 「收藏」范围里 ⌘D 取消收藏、收藏夹筛选里移出同样；⌘Z 后选中回来的那批里最靠前的那条
  @Test func selectionMovesAwayFromRemoved() throws {
    let (model, store) = try makeModel(["1", "2", "3", "4", "5"])
    model.select(try item(model, "3"))
    #expect(model.handleKeyEquivalent(try key(kVK_Delete)))
    #expect(model.selectedItem?.text == "4")
    #expect(model.handleKeyEquivalent(try key(kVK_Delete)))
    #expect(model.selectedItem?.text == "5")
    #expect(store.items.map(\.text) == ["1", "2", "5"])
    model.delete([try item(model, "5").id])
    #expect(model.selectedItem?.text == "2")
    // ⌘Z 撤最近一批（5），选中它
    model.undoDelete()
    #expect(model.selectedItem?.text == "5")
    model.undoDelete()
    #expect(model.selectedItem?.text == "4")
    // 选中的不在删掉的里面：不动
    model.select(try item(model, "1"))
    model.delete([try item(model, "2").id])
    #expect(model.selectedItem?.text == "1")
    // 「收藏」范围里取消收藏：这行消失，选中下一条（现在是 1 4 5）
    #expect(store.items.map(\.text) == ["1", "4", "5"])
    store.toggleFavorite(Set(store.items.map(\.id)))
    model.scope = .favorites
    model.select(try item(model, "4"))
    model.toggleFavorite([try item(model, "4").id])
    #expect(model.selectedItem?.text == "5")
    // 收藏夹筛选里移出收藏夹：同样
    let group = try #require(store.createGroup(named: "工作"))
    model.scope = .all
    model.assign(Set(store.items.map(\.id)), to: group.id)
    model.groupFilter = .group(group.id)
    model.select(try item(model, "1"))
    model.assign([try item(model, "1").id], to: nil)
    #expect(model.selectedItem?.text == "4")
  }

  /// 多选随搜索 / 筛选裁剪（体检 B8）：勾 3 条后输入只命中其中 1 条的词，底栏「已选 1 条」、⌘⌫ 只删这 1 条；
  /// 一条都看不见了就退出多选
  @Test func multiSelectionFollowsFilter() throws {
    let (model, store) = try makeModel(["苹果", "香蕉", "橙子", "葡萄"])
    model.multiSelection = Set(store.items.prefix(3).map(\.id))
    model.query = "香蕉"
    #expect(model.multiSelection == [try item(model, "香蕉").id])
    #expect(model.targets.map(\.text) == ["香蕉"])
    #expect(model.handleKeyEquivalent(try key(kVK_Delete)))
    #expect(store.items.map(\.text) == ["苹果", "橙子", "葡萄"])
    #expect(model.multiSelection.isEmpty)
    model.query = ""
    model.multiSelection = [try item(model, "苹果").id]
    model.query = "葡萄"
    #expect(model.multiSelection.isEmpty)
  }

  /// 右键 / ⌘Y 页脚「复制」只复制被点的那一条，不管勾选了什么（体检 B9）
  @Test func copyTargetsTheClickedItem() throws {
    let (model, store) = try makeModel(["一", "二", "三"])
    var written: [String] = []
    model.writeClipboard = { written.append($0.first?.string(forType: .string) ?? "") }
    model.multiSelection = Set(store.items.prefix(2).map(\.id))
    let third = try item(model, "三")
    try #require(model.actions(for: third, targets: [third]).first { $0.title == "仅复制" }).run()
    #expect(written == ["三"])
    model.copySelection()
    #expect(written.last == "二\n一")
  }

  /// 菜单开着、过滤框里有字时，⌘⌫ ⌘A ⌘V ⌘X ⌘Z 交给过滤框（菜单留着、不删条目）；过滤框空着时 ⌘⌫ 照常删除并关菜单（体检 B10）
  @Test func paletteKeepsEditingKeys() throws {
    let (model, store) = try makeModel(["一", "二"])
    model.palette = .actions
    model.actionQuery = "复制"
    for code in [kVK_Delete, kVK_ANSI_A, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z] {
      #expect(!model.handleKeyEquivalent(try key(code)))
      #expect(model.palette == .actions)
    }
    #expect(store.items.count == 2)
    model.actionQuery = ""
    #expect(model.handleKeyEquivalent(try key(kVK_Delete)))
    #expect(model.palette == nil && store.items.count == 1)
    // 没做的键（⌘V 交还系统）不关菜单
    model.palette = .filters
    #expect(!model.handleKeyEquivalent(try key(kVK_ANSI_V)))
    #expect(model.palette == .filters)
    // 大写锁定开着 ⌘⌫ 也认
    model.palette = nil
    #expect(model.handleKeyEquivalent(try key(kVK_Delete, [.command, .capsLock])))
    #expect(store.items.isEmpty)
  }

  /// 没开菜单时 ← 交还搜索框移光标（只有 ⌘K / 收藏夹列表开着、过滤词为空时 ← 才是回上一级 / 关菜单）
  @Test func moveLeftReachesSearchField() throws {
    let (model, _) = try makeModel(["一"])
    model.query = "abc"
    #expect(!model.handleCommand(#selector(NSResponder.moveLeft(_:))))
    model.query = ""
    #expect(!model.handleCommand(#selector(NSResponder.moveLeft(_:))))
    model.palette = .filters
    #expect(!model.handleCommand(#selector(NSResponder.moveLeft(_:))))
    model.palette = .groups
    #expect(model.handleCommand(#selector(NSResponder.moveLeft(_:))) && model.palette == nil)
  }

  /// 多选底栏「收藏夹…」的列表：勾选清空（取消、删除、Esc）时跟着关，不改去对着单条选中项
  @Test func groupsListClosesWithMultiSelection() throws {
    let (model, store) = try makeModel(["一", "二", "三"])
    store.createGroup(named: "工作")
    model.multiSelection = [try item(model, "一").id, try item(model, "二").id]
    model.palette = .groups
    model.multiSelection.remove(try item(model, "一").id)
    #expect(model.palette == .groups)  // 还勾着一条：照常
    model.multiSelection = []
    #expect(model.palette == nil)
    model.multiSelection = [try item(model, "三").id]
    model.palette = .groups
    model.delete(model.multiSelection)
    #expect(model.multiSelection.isEmpty && model.palette == nil)
  }

  /// ⌘K 与右键同一份动作表（体检 B12）：顺序、名字、分节一致；替代粘贴 / 复制为纯文本只给带格式的；按类型的动作带键位
  /// （翻译 ⌘T、打开链接 / 打开 ⌘O、在访达中显示 ⌘R、复制路径 ⌥⌘C、图片钉到屏幕，体检 B14 D1 D2）
  @Test func actionTable() throws {
    let (model, store) = try makeModel(["看 https://example.com/a 这篇", "纯文本"])
    let link = try item(model, "看 https://example.com/a 这篇")
    model.select(link)
    let menu = model.actions(for: link, targets: [link])
    #expect(model.actions.map(\.title) == menu.map(\.title))
    #expect(
      menu.map(\.title) == [
        "粘贴", "仅复制", "打开链接", "翻译", "放大预览", "收藏", "放进新收藏夹…", "存为片段", "备注…", "编辑内容…", "删除",
      ])
    #expect(menu.map(\.section) == [0, 0, 1, 1, 1, 2, 2, 2, 2, 2, 3])
    #expect(menu.first { $0.title == "打开链接" }?.shortcut == "⌘O")
    #expect(menu.first { $0.title == "翻译" }?.shortcut == "⌘T")
    #expect(menu.last?.isDestructive == true)
    // 带格式的文本才有替代粘贴（「粘贴为纯文本」，开了默认纯文本是「保留格式粘贴」）和「复制为纯文本」
    store.update([link.id]) { $0.richType = .rtf }
    let rich = try item(model, "看 https://example.com/a 这篇")
    #expect(
      model.actions(for: rich, targets: [rich]).prefix(4).map(\.title) == [
        "粘贴", model.alternatePasteTitle, "仅复制", "复制为纯文本",
      ])
    // 编辑正文后「打开链接」跟着变（链接按条目缓存，编辑时清掉，体检 B18）
    model.edit(link.id, text: "没有网址了")
    let edited = try item(model, "没有网址了")
    #expect(!model.actions(for: edited, targets: [edited]).contains { $0.title == "打开链接" })
    // 文件：打开 ⌘O、在访达中显示 ⌘R、复制路径 ⌥⌘C；没有翻译、编辑
    var file = ClipItem(kind: .file)
    file.filePaths = ["/tmp/a.txt", "/tmp/b.txt"]
    store.record(file)
    let files = model.actions(for: file, targets: [file])
    #expect(files.first { $0.title == "打开" }?.shortcut == "⌘O")
    #expect(files.first { $0.title == "在访达中显示" }?.shortcut == "⌘R")
    #expect(files.first { $0.title == "复制路径" }?.shortcut == "⌥⌘C")
    #expect(!files.contains { $0.title == "翻译" || $0.title == "编辑内容…" })
    // 图片：钉到屏幕；多选时只给批量操作（没有备注、放大预览）
    var image = ClipItem(kind: .image)
    image.image = .init(width: 4, height: 2, byteCount: 1, sha256: "p")
    store.record(image)
    #expect(model.actions(for: image, targets: [image]).contains { $0.title == "钉到屏幕" })
    let batch = model.actions(for: image, targets: [file, image])
    #expect(batch.first?.title == "依次粘贴")
    #expect(batch.contains { $0.title == "钉到屏幕" })
    #expect(!batch.contains { $0.title == "备注…" || $0.title == "放大预览" })
  }

  /// ⌘T 翻译单选且可翻译的条目，⌘K 行写 ⌘T（体检 B14）；只勾了一条时对着那一条
  @Test func commandTTranslates() throws {
    let (model, _) = try makeModel(["hello", "world"])
    var translated: [String] = []
    model.openTranslate = { translated.append($0) }
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_T)))
    model.multiSelection = [try item(model, "world").id]
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_T)))
    #expect(translated == ["hello", "world"])
  }

  /// ⌘K 的子列表（体检 C3）：→ / ↩ 进「移到收藏夹」，过滤词只过滤这一级，← / Esc 回到第一级并选中进去的那一行，
  /// 再 Esc 关菜单
  @Test func submenuNavigation() throws {
    let (model, store) = try makeModel(["一"])
    store.createGroup(named: "工作")
    store.createGroup(named: "生活")
    model.palette = .actions
    let index = try #require(model.filteredActions.firstIndex { $0.id == "groups" })
    model.actionSelection = index
    #expect(model.handleCommand(#selector(NSResponder.moveRight(_:))))
    #expect(model.submenuTitle == "移到收藏夹")
    #expect(model.filteredActions.map(\.title) == ["工作", "生活", "新建收藏夹…"])
    model.actionQuery = "sh"  // 拼音首字母
    #expect(model.filteredActions.map(\.title) == ["生活"])
    #expect(!model.handleCommand(#selector(NSResponder.moveLeft(_:))))  // 有过滤词：← 移光标
    model.actionQuery = ""
    #expect(model.handleCommand(#selector(NSResponder.moveLeft(_:))))
    #expect(
      model.submenuTitle == nil && model.palette == .actions && model.actionSelection == index)
    model.runSelectedAction()  // ↩ 也进
    #expect(model.submenuTitle == "移到收藏夹")
    #expect(model.handleCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(model.submenuTitle == nil && model.palette == .actions)
    #expect(model.handleCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(model.palette == nil)
    // 子列表里选收藏夹：执行并关菜单
    model.palette = .actions
    model.actionSelection = index
    model.runSelectedAction()
    model.runSelectedAction()
    #expect(model.palette == nil && store.items[0].groupID == store.groups[0].id)
  }

  /// 三个动作菜单共用的过滤（体检 C4）：标题 / 说明子串（不分大小写、全半角），中文标题的全拼和首字母前缀；保持原顺序
  @Test func menuFilterMatchesPinyin() {
    let items =
      ["翻译", "在访达中显示", "复制路径", "JSON"].map { ActionMenu.Item(title: $0) }
      + [ActionMenu.Item(title: "Safari", detail: "来源 3")]
    let titles = { (query: String) in ActionMenu.filter(items, query: query).map(\.title) }
    #expect(titles("fy") == ["翻译"])
    #expect(titles("fanyi") == ["翻译"])
    #expect(titles("zfd") == ["在访达中显示"])
    #expect(titles("访达") == ["在访达中显示"])
    #expect(titles("ｊｓｏｎ") == ["JSON"])
    #expect(titles("来源") == ["Safari"])
    #expect(titles(" ") == items.map(\.title))
    // 拼音只认前缀：「ssd」不是任何标题的开头
    #expect(titles("ssd").isEmpty)
  }

  /// 菜单高度（体检 C3）：分节线上下各 4 pt + 0.5 pt；超过 8.5 行时截在那一行的一半（有分节线也露出半行，看得出能滚）
  @Test func menuHeightShowsHalfRow() {
    let row: CGFloat = 28
    let plain = (0..<12).map { ActionMenu.Item(title: "\($0)") }
    #expect(ActionMenu.height(plain, maxRows: 8.5) == row * 8.5)
    #expect(ActionMenu.height(Array(plain.prefix(3)), maxRows: 8.5) == row * 3)
    #expect(ActionMenu.height([], maxRows: 8.5) == row)
    let sectioned = (0..<12).map { ActionMenu.Item(title: "\($0)", section: $0 / 3) }
    #expect(ActionMenu.height(Array(sectioned.prefix(6)), maxRows: 8.5) == row * 6 + 8.5)
    // 8 行 + 2 条分节线 = 241 > 238：第 8 行（下标 7）只露一半
    let expected: CGFloat = 28 * 7 + 8.5 * 2 + 14
    #expect(ActionMenu.height(sectioned, maxRows: 8.5) == expected)
    // 8 行后接分节线：第 9 行从 232.5 开始，半行到 246.5 超了 238，截在第 8 行的一半；截出来的高都不超过 8.5 行
    let late = (0..<12).map { ActionMenu.Item(title: "\($0)", section: $0 < 8 ? 0 : 1) }
    #expect(ActionMenu.height(late, maxRows: 8.5) == row * 7 + row / 2)
    for split in 1..<12 {
      let items = (0..<12).map { ActionMenu.Item(title: "\($0)", section: $0 < split ? 0 : 1) }
      #expect(ActionMenu.height(items, maxRows: 8.5, contrast: .increased) <= row * 8.5)
    }
    // 子列表：顶行「‹ 标题」+ 分节线（≤ 37）连同滚动区不比第一级高
    let header = row + 1 + 8
    #expect(ActionMenu.height(plain, maxRows: 8.5, header: true) + header <= row * 8.5)
  }

  /// 钉到屏幕的位置（体检 D1）：像素 ÷ 屏幕倍率 = 点尺寸，放在可见区中央；超过可见区 80% 等比缩小；第 N 张往右下错开 24 pt
  @Test func pinFrame() {
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
    let small = ClipboardPanelModel.pinFrame(
      pixels: CGSize(width: 800, height: 400), scale: 2, visible: visible, index: 0)
    #expect(small == CGRect(x: 520, y: 370, width: 400, height: 200))
    let big = ClipboardPanelModel.pinFrame(
      pixels: CGSize(width: 6000, height: 4000), scale: 2, visible: visible, index: 0)
    #expect(big.width == 1032 && big.height == 688)  // 按高 860 × 0.8 缩
    #expect(abs(big.midX - visible.midX) <= 0.5 && abs(big.midY - visible.midY) <= 0.5)
    let second = ClipboardPanelModel.pinFrame(
      pixels: CGSize(width: 800, height: 400), scale: 2, visible: visible, index: 1)
    #expect(second.origin == CGPoint(x: small.minX + 24, y: small.minY - 24))
  }

  /// ⌥⌘C 复制路径（体检 D2）：多个按换行拼；面板开着时列表不动，收起面板时才记成一条新历史（同 ⌘C）
  @Test func copyPaths() throws {
    let (model, store) = try makeModel([])
    var written: [String] = []
    var changeCount = 0
    model.writeClipboard = {
      written.append($0.first?.string(forType: .string) ?? "")
      changeCount += 1
    }
    model.clipboardChangeCount = { changeCount }
    var file = ClipItem(kind: .file)
    file.filePaths = ["/tmp/a.txt", "/tmp/b c.txt"]
    store.record(file)
    #expect(model.handleKeyEquivalent(try key(kVK_ANSI_C, [.command, .option])))
    #expect(written == ["/tmp/a.txt\n/tmp/b c.txt"])
    #expect(model.toast == .message("已复制路径") && store.items.count == 1)
    model.reset()
    #expect(store.items.first?.text == "/tmp/a.txt\n/tmp/b c.txt")
    // 选中的不是文件：⌥⌘C 交还系统
    #expect(!model.handleKeyEquivalent(try key(kVK_ANSI_C, [.command, .option])))
  }

  /// 拖出去的东西（体检 D3）：拖勾选项之一 = 全部勾选项（多条文本合成一段），拖没勾的行只拖它；图片是 PNG + 临时文件
  /// 「图片 宽×高.png」；全是文件时每个文件一项；拖放不动历史
  @Test func dragItems() throws {
    let (model, store) = try makeModel(["一", "二", "三"])
    let (one, two, three) = (try item(model, "一"), try item(model, "二"), try item(model, "三"))
    model.multiSelection = [one.id, two.id]
    let merged = model.dragItems(for: one)
    #expect(merged.count == 1 && merged[0].string(forType: .string) == "二\n一")
    let single = model.dragItems(for: three)
    #expect(single.count == 1 && single[0].string(forType: .string) == "三")
    model.multiSelection = []
    var image = ClipItem(kind: .image)
    image.image = .init(width: 3, height: 2, byteCount: 4, sha256: "d")
    try Data([1, 2, 3, 4]).write(to: store.images.url(for: image.id))
    store.record(image)
    let dragged = try #require(model.dragItems(for: image).first)
    #expect(dragged.data(forType: .png) == Data([1, 2, 3, 4]))
    let url = try #require(dragged.string(forType: .fileURL).flatMap(URL.init(string:)))
    #expect(url.lastPathComponent == "图片 3×2.png")
    #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
    // 同尺寸的两张一起拖：各有各的文件（名字一样，放在按条目分的子目录里），内容对得上；再拖一次复用，前一个文件还在
    var other = ClipItem(kind: .image)
    other.image = .init(width: 3, height: 2, byteCount: 4, sha256: "e")
    try Data([5, 6, 7, 8]).write(to: store.images.url(for: other.id))
    store.record(other)
    model.multiSelection = [image.id, other.id]
    let pair = model.dragItems(for: other).compactMap {
      $0.string(forType: .fileURL).flatMap(URL.init(string:))
    }
    #expect(pair.count == 2 && Set(pair).count == 2)
    #expect(pair.allSatisfy { $0.lastPathComponent == "图片 3×2.png" })
    #expect(
      try pair.map { try Data(contentsOf: $0) } == [Data([1, 2, 3, 4]), Data([5, 6, 7, 8])])
    #expect(model.dragItems(for: image).compactMap { $0.string(forType: .fileURL) }.count == 2)
    #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
    model.multiSelection = []
    var file = ClipItem(kind: .file)
    file.filePaths = [directory.path(), store.images.url(for: image.id).path()]
    store.record(file)
    #expect(model.dragItems(for: file).count == 2)
    #expect(store.items.first?.id == file.id)  // 拖放不挪历史
  }

  /// 编辑 / 新建片段对话框（体检 C2）：去掉空白后为空、或和原文一样时不能保存
  @Test func dialogCanSave() {
    #expect(!ClipboardPanelModel.canSave("  \n ", initial: ""))
    #expect(!ClipboardPanelModel.canSave("原文", initial: "原文"))
    #expect(ClipboardPanelModel.canSave("原文！", initial: "原文"))
    #expect(ClipboardPanelModel.canSave("新片段", initial: ""))
  }

  /// 新建片段的名称存成备注（搜索能搜到），空名称不动已有备注
  @Test func snippetNameBecomesNote() throws {
    let (model, store) = try makeModel([])
    model.saveSnippet("您好 {cursor}", name: " 开头 ")
    #expect(store.items.first?.isSnippet == true && store.items.first?.note == "开头")
    model.saveSnippet("您好 {cursor}")
    #expect(store.items.first?.note == "开头")
    model.query = "开头"
    #expect(model.visibleItems.count == 1)
  }

  /// ⌘Y 大卡（体检 B11）：打开后新条目进来选中不跳；正文里 ⌘C 只交出选中的纯文本（多段按换行拼）
  @Test func quickLookCopyIsPlainText() throws {
    let (model, store) = try makeModel(["一", "二"])
    model.select(try item(model, "二"))
    model.toggleQuickLook()
    var fresh = ClipItem(kind: .text)
    fresh.text = "大卡里复制的一句"
    store.record(fresh)
    model.itemsChanged()
    #expect(model.selectedItem?.text == "二")
    let textView = CopyPlainTextView(frame: .zero)
    textView.string = "第一行\n第二行"
    var copied: [String] = []
    textView.onCopy = { copied.append($0) }
    textView.setSelectedRange(NSRange(location: 0, length: 3))
    textView.copy(nil)
    textView.selectedRanges = [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)].map
    {
      NSValue(range: $0)
    }
    textView.copy(nil)
    #expect(copied == ["第一行", "第\n第"])
  }

  /// 速查表跟着按键走：剪贴板组里有 ⌘T ⌘O ⌘R ⌥⌘C
  @Test func cheatSheetListsNewKeys() throws {
    let clipboard = try #require(ShortcutsSheet.groups.first { $0.title == "剪贴板" })
    let keys = Set(clipboard.entries.flatMap(\.keys))
    #expect(keys.isSuperset(of: ["⌘T", "⌘O", "⌘R", "⌥⌘C"]))
  }

  /// ClipRowView.showsWholeText 认可的标题，行里真的没被截断（它的宽度预算照着行的布局写，行的布局改了这里先失败）：
  /// 把标题撑到它认可的最宽，按最挤的样子把行画出来（常显的滚动条占掉 16 pt、⌘9 键帽亮着），
  /// 标题那一段的像素和加宽 400 pt 再画一遍的完全一样（截断了末尾会变成「…」）；对照：再窄 40 pt 就不一样。
  /// 屏外窗口，不弹面板、不抢键盘
  @Test func wholeTitleIsNotTruncated() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let images = ImageStore(directory: directory)
    let suite = "kitty-row-test-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    /// 行画成位图后标题那一段（x 从 44 起、宽 title）的像素
    func titlePixels(_ item: ClipItem, width: CGFloat, title: CGFloat) throws -> Data {
      let size = NSSize(width: width, height: ClipRowView.height)
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      let host = NSHostingView(
        rootView: ClipRowView(
          item: item, form: nil, shortcutIndex: 8, showsShortcut: true, isChecked: nil,
          groupName: nil, images: images
        )
        .frame(width: width)
        .defaultAppStorage(prefs))
      window.contentView = host
      window.orderFront(nil)
      defer { window.orderOut(nil) }
      RunLoop.main.run(until: .now.addingTimeInterval(0.3))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let scale = CGFloat(bitmap.pixelsWide) / width
      let crop = CGRect(
        x: 44 * scale, y: 0, width: floor(title * scale), height: CGFloat(bitmap.pixelsHigh))
      let image = try #require(bitmap.cgImage?.cropping(to: crop))
      return try #require(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    let plain = ClipItem(kind: .text)
    var favorite = ClipItem(kind: .text, sourceName: "Google Chrome")
    favorite.favorite = true
    var marked = favorite
    marked.note = String(repeating: "备注", count: 20)
    marked.richType = .rtf
    marked.isSnippet = true
    let rowWidth = ClipboardPanelView.width - 2 * ClipboardPanelView.inset - 16
    for (name, base) in [("没有来源", plain), ("收藏", favorite), ("备注 + 全部标记", marked)] {
      // 先用汉字、再用最窄的字母把标题撑到 showsWholeText 认可的最宽
      var item = base
      var text = ""
      for unit in ["汉", "i"] {
        while true {
          item.text = text + unit
          guard ClipRowView.showsWholeText(item) else { break }
          text += unit
        }
      }
      item.text = text
      #expect(text.count > 15 && ClipRowView.showsWholeText(item), "\(name)")
      let title = (text as NSString).size(
        withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
      ).width
      let wide = try titlePixels(item, width: rowWidth + 400, title: title)
      #expect(try titlePixels(item, width: rowWidth, title: title) == wide, "\(name)：标题被截断了")
      #expect(try titlePixels(item, width: rowWidth - 40, title: title) != wide, "\(name)：对照")
    }
  }
}
