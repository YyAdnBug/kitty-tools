import AppKit
import Carbon.HIToolbox
import Testing
import VisionKit

@testable import KittyTools

// 钉图上选字（2026-11-17 拍板 C1–C5）：系统的实况文本认出钉图里的字（识别在系统服务里，测试宿主照样能用，约 0.2–0.6 s）；
// ⌘A 全选、⌘C 拷贝选中的字（交给 PinBoard.textOutput，不碰真的剪贴板），Esc 先清选区、再按才关；右键菜单按有没有选中的字换，
// 选中时多出翻译 / 搜索 / 查询（第 3 批）。
// 拖动 / 双击 / 滚轮在字上和空白处归谁是系统选字层的行为，探针实测过（macos/build/research/pin-text-2026-11-17），合成鼠标事件
// 会进钉图的 performDrag 跟踪循环，这里不测，见 HANDTEST
@MainActor @Suite(.serialized)
struct PinTextTests {
  /// 白底黑字两行（700 × 200 pt，2 倍）
  static let image: CGImage = {
    let size = CGSize(width: 700, height: 200)
    let context = CGContext(
      data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: 2, y: 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSColor.white.setFill()
    CGRect(origin: .zero, size: size).fill()
    for (index, line) in ["Copy this line from a pin", "截图钉在桌面上之后直接拖选文字"].enumerated() {
      NSAttributedString(
        string: line,
        attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]
      ).draw(at: CGPoint(x: 24, y: 130 - CGFloat(index) * 60))
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
  }()

  private func key(
    _ view: NSView, _ code: Int, _ characters: String, flags: NSEvent.ModifierFlags = []
  ) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: UInt16(code))!
    view.keyDown(with: event)
  }

  private func menu(_ view: NSView) throws -> NSMenu {
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    return try #require(view.menu(for: event))
  }

  private func menuTitles(_ view: NSView) throws -> [String] {
    try menu(view).items.filter { !$0.isSeparatorItem }.map(\.title)
  }

  /// 用户在 Dev 版里自己关过「钉图上的字可以直接选」（持久域盖过注册的默认值）时不跑
  @Test(
    .enabled(
      if: ImageAnalyzer.isSupported
        && UserDefaults.standard.object(forKey: Prefs.pinSelectsText) as? Bool != false))
  func selectCopyAndClear() async throws {
    // 测试宿主不走 AppDelegate 的启动，「钉图上的字可以直接选」的默认值要自己注册（只写注册域，不落盘）
    Prefs.registerDefaults()
    let board = PinBoard()
    var copied: [String] = []
    var others: [(PinBoard.TextAction, String)] = []
    board.textOutput = { action, text in
      if action == .copy { copied.append(text) } else { others.append((action, text)) }
    }
    board.pin(Self.image, frame: CGRect(x: -20000, y: -20000, width: 700, height: 200))
    defer { board.closeAll() }
    let panel = try #require(board.panels.first)
    panel.finishPopIn()  // 屏外的窗口 display link 不走，回弹停不下来
    let view = try #require(panel.contentView)
    // 认字之前：菜单和原来一样
    #expect(try menuTitles(view).first == "拷贝")
    #expect(try !menuTitles(view).contains("全选文字"))

    await panel.prepareText()
    #expect(try menuTitles(view).first == "全选文字")
    #expect(panel.selectedText == nil)
    key(view, kVK_ANSI_C, "c", flags: .command)  // 没选中：⌘C 是拷贝整张图，不拷字
    #expect(copied.isEmpty)

    key(view, kVK_ANSI_A, "a", flags: .command)
    let selected = try #require(panel.selectedText)
    #expect(selected.contains("Copy this line"))
    // 选中了字：⌘C 那项是拷贝字，整张图那项改叫「拷贝图像」；翻译、查询的标题带着选中的字的开头（12 个字 + …）
    let excerpt = String(selected.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(12)) + "…"
    let translates = Feature.translate.isOn  // 跟本机的功能开关、启动器的搜索引擎
    let engine = Feature.launcher.isOn ? WebSearch.primary() : nil
    let titles = try menuTitles(view)
    #expect(
      Array(titles.prefix(while: { $0 != "拷贝图像" }))
        == ["拷贝"] + (translates ? ["翻译「\(excerpt)」"] : [])
        + (engine.map { ["用 \($0.displayName) 搜索"] } ?? []) + ["全选文字"])  // 两行：没有查询
    key(view, kVK_ANSI_C, "c", flags: .command)
    #expect(copied == [selected])
    // 翻译、搜索交给 textOutput（查询弹系统词典的小窗，这里不点）
    for item in try menu(view).items
    where item.title.hasPrefix("翻译「") || item.title.hasPrefix("用 ") {
      NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }
    #expect(
      others.map(\.0)
        == (translates ? [PinBoard.TextAction.translate] : []) + (engine == nil ? [] : [.search]))
    #expect(others.allSatisfy { $0.1 == selected })
    // 查询只给一行、40 个字以内
    #expect(PinBoard.looksUp("apple") && PinBoard.looksUp(String(repeating: "字", count: 40)))
    #expect(!PinBoard.looksUp("") && !PinBoard.looksUp(String(repeating: "字", count: 41)))
    #expect(!PinBoard.looksUp("two\nlines"))

    // Esc 先清选区，钉图还在；再按才关
    key(view, kVK_Escape, "\u{1b}")
    #expect(panel.selectedText == nil && board.panels.count == 1)
    key(view, kVK_Escape, "\u{1b}")
    #expect(board.panels.isEmpty)
  }
}
