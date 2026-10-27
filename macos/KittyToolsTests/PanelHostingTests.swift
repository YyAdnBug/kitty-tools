// 会改大小的面板放 SwiftUI 宿主（第三轮体检 B6，mac-overlay-panel §1 setHostedContent）：浮动便签、便签那叠、常驻缩略图、
// 晾衣绳的面板在内容变化的同时被反复改大小（直接改、带动画改），不崩、窗口大小和最小 / 最大尺寸只由窗口自己定。
// 宿主视图直接当 contentView 时（旧写法，2026-10-27 撤掉修复实测）：那叠的面板几秒内在「更新约束」里抛 NSGenericException、
// 测试宿主直接退出；浮动便签的最小尺寸被 SwiftUI 改掉；常驻缩略图、晾衣绳的最大尺寸被改成 SwiftUI 的。刘海岛 2026-10-26
// 在屏上崩过（Island.makeWindow），普通窗口同理（NotesWindowTests.animatedSwitchingWhileResizingDoesNotCrash）。
// 面板都建在离所有屏幕很远的地方、不当 key；飞行卡片（FlyCard）的落点必须在真屏幕上，这里不建——它的窗口先定好大小
// 再放内容，之后不改大小。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

@MainActor
struct PanelHostingTests {
  private static let far = CGPoint(x: -30000, y: -30000)

  @Test func resizingWhileContentChangesKeepsTheFrame() async throws {
    try #require(
      !NSScreen.screens.contains {
        $0.frame.insetBy(dx: -4000, dy: -4000).contains(Self.far)
      })
    let store = try NoteStore(db: Database(path: ":memory:"))
    for index in 0..<8 { store.create(body: "便签 \(index)\n第二行 第二行\n☐ 任务") }
    let ids = store.active.map(\.id)

    let floatModel = NoteFloatModel(store: store)
    floatModel.send(.float(ids[0]))
    let float = NoteFloatPanel(
      frame: CGRect(origin: Self.far, size: CGSize(width: 460, height: 380)), model: floatModel)

    let deckModel = NoteDeckModel(store: store)
    deckModel.panelSize = CGSize(width: 538, height: 875)
    deckModel.pillCenter = 437
    deckModel.setRevealed(true)
    deckModel.send(.pillEntered(optionDown: false, allowed: true))
    let deck = NoteDeckPanel(
      frame: CGRect(origin: Self.far, size: deckModel.panelSize), model: deckModel, onPointer: {})

    let shelf = ShotShelf()
    let card = ShelfCard(
      recording: URL(filePath: "/tmp/kitty-panel-hosting.mp4"), seconds: 5, poster: nil,
      source: CGRect(origin: Self.far, size: CGSize(width: 200, height: 125)),
      rect: CGRect(origin: Self.far, size: CGSize(width: 200, height: 125)), screen: nil,
      panel: NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: true),
      shelf: shelf)
    card.show(fadingIn: false)

    let root = FileManager.default.temporaryDirectory.appending(
      path: "kitty-panel-hosting-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let line = Clothesline(
      history: try ShotHistory(
        db: Database(path: ":memory:"), directory: root.appending(path: "shots")))
    let rope = line.makePanel()
    rope.setFrame(CGRect(origin: Self.far, size: CGSize(width: 1512, height: 300)), display: false)
    let shots = (0..<6).map { _ in UUID() }

    float.orderFrontRegardless()
    deck.orderFrontRegardless()
    rope.orderFrontRegardless()
    let panels: [NSWindow] = [float, deck, card.panel, rope]
    defer {
      float.orderOut(nil)
      deck.orderOut(nil)
      rope.orderOut(nil)
      shelf.dismiss(card)
    }
    for panel in panels {
      // 宿主包在一个普通容器里，不直接当 contentView
      let content = try #require(panel.contentView)
      #expect(type(of: content) == NSView.self && content.subviews.count == 1, "\(type(of: panel))")
    }

    var random = SeededRandom(seed: 20_261_027)
    var targets = panels.map(\.frame)
    func resize(_ index: Int, animated: Bool) {
      let target = CGRect(
        origin: Self.far,
        size: CGSize(
          width: .random(in: 120...1600, using: &random),
          height: .random(in: 90...900, using: &random)))
      targets[index] = target
      let panel = panels[index]
      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = .random(in: 0.05...0.3, using: &random)
          panel.animator().setFrame(target, display: true)
        }
      } else {
        panel.setFrame(target, display: true)
        #expect(panel.frame == target)
      }
    }
    for _ in 0..<300 {
      switch Int.random(in: 0..<8, using: &random) {
      case 0: floatModel.send(.float(ids.randomElement(using: &random)!))
      case 1:
        withAnimation(.spring) {
          switch Int.random(in: 0..<3, using: &random) {
          case 0: deckModel.send(.tab(ids.randomElement(using: &random)!))
          case 1: deckModel.send(.close)
          default: deckModel.hover(ids.randomElement(using: &random)!, true)
          }
        }
      case 2: withAnimation(.spring) { card.isHovered.toggle() }
      case 3:
        withAnimation(.spring) {
          line.model.setPegged(Array(shots.prefix(.random(in: 0...6, using: &random))))
        }
      default:
        resize(.random(in: 0..<panels.count, using: &random), animated: Bool.random(using: &random))
      }
      try await Task.sleep(for: .milliseconds(16))
    }
    // 带动画的那几下走完
    try await Task.sleep(for: .milliseconds(400))
    // 最小 / 最大尺寸也还是窗口自己设的（宿主当 contentView 时 SwiftUI 会按内容改掉它们）
    let bare = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    for (panel, target) in zip(panels, targets) {
      let name = "\(type(of: panel))"
      #expect(panel.frame == target, "\(name)")
      #expect(
        panel.minSize == (panel === float ? NoteFloatLayout.minSize : bare.minSize), "\(name)")
      #expect(panel.maxSize == bare.maxSize, "\(name) \(panel.maxSize)")
      #expect(
        panel.contentMinSize == (panel === float ? NoteFloatLayout.minSize : bare.contentMinSize),
        "\(name) \(panel.contentMinSize)")
      #expect(panel.contentMaxSize == bare.contentMaxSize, "\(name) \(panel.contentMaxSize)")
    }
  }
}
