// 便签第 8 批 R14 的屏外量测（按需开，平时不跑）：1 MB、每行都有颜色的正文 vs 没颜色的同一篇，打一个字、挪一次光标；
// 300 条便签（50 张图）导出成 Markdown、再导回来的耗时。
//   TEST_RUNNER_KITTY_NOTES_COLOR_PROBE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test -only-testing:'KittyToolsTests/NoteBatch8ProbeTests/measure()'
// 量的是 Debug；要 -O 的数就在同一条命令后面加 SWIFT_OPTIMIZATION_LEVEL=-O（会另建一份）。结果 grep「notes-probe batch8」。

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

struct NoteBatch8ProbeTests {
  private static func ms(_ duration: Duration) -> Double {
    Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
  }

  private static func median(_ times: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let samples = (0..<times).map { _ in ms(clock.measure(body)) }.sorted()
    return samples[samples.count / 2]
  }

  private static func line(_ index: Int) -> String {
    "第 \(index) 行普通的一行字，中英混排 mixed text with several words，再长一点。"
  }

  private static func body(colored: Bool, lines: Int) -> String {
    (0..<lines).map { index in
      colored ? "[\(line(index))]{red}" : line(index)
    }.joined(separator: "\n")
  }

  private final class Rig {
    let window: NSWindow
    let scroll = NSScrollView()
    let editor = NoteTextView.make()

    init(_ text: String, markdown: Bool) throws {
      window = NSWindow(
        contentRect: CGRect(x: -30000, y: -30000, width: 640, height: 420),
        styleMask: [.borderless], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      scroll.hasVerticalScroller = true
      scroll.documentView = editor
      window.contentView = scroll
      editor.eagerStyleLength = max(text.utf16.count, 1)
      editor.setPaper(
        NotePaper.all[0], fontSize: 15, markdown: markdown, spacing: .standard)
      editor.setText(text)
      window.makeFirstResponder(editor)
      // 屏外的窗口不当 key，直接告诉编辑器「窗口是 key」（同 NoteTextViewTests）：标记在光标行露出来，
      // 挪光标 / 打字走的是真 App 里同一条路（否则 hasShownMarkers 一直是 false、outdated 被跳过，量出来偏快）
      editor.keyChanged(true)
      scroll.layoutSubtreeIfNeeded()
      if let container = editor.textContainer {
        editor.layoutManager?.ensureLayout(for: container)
      }
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_NOTES_COLOR_PROBE"] != nil))
  func measure() async throws {
    let lines = 9000
    let colored = Self.body(colored: true, lines: lines)
    let plain = Self.body(colored: false, lines: lines)
    print(
      "notes-probe batch8 colored \(colored.utf8.count) bytes / plain \(plain.utf8.count) bytes")

    for (name, text, markdown) in [
      ("color-on", colored, true), ("plain-on", plain, true),
      ("color-off", colored, false), ("plain-off", plain, false),
    ] {
      let rig = try Rig(text, markdown: markdown)
      let length = rig.editor.textStorage?.length ?? 0
      var caret = 0
      let move = Self.median(30) {
        caret = (caret + 97) % max(length - 1, 1)
        rig.editor.setSelectedRange(NSRange(location: caret, length: 0))
      }
      rig.editor.setSelectedRange(NSRange(location: 0, length: 0))
      let type = Self.median(10) {
        rig.editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
      }
      print(
        "notes-probe batch8 \(name) type \(String(format: "%.2f", type)) ms move \(String(format: "%.2f", move)) ms"
      )
    }

    // 300 条便签、50 张图：导出 + 导回
    let root = FileManager.default.temporaryDirectory.appending(
      path: "kitty-notes-batch8-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let imageDirectory = root.appending(path: "notes-images", directoryHint: .isDirectory)
    let parent = root.appending(path: "导出", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var imageIDs: [UUID] = []
    for _ in 0..<50 {
      let id = UUID()
      imageIDs.append(id)
      try NoteImageFixture.data(type: .png, width: 40, height: 30)
        .write(to: imageDirectory.appending(path: "\(id.uuidString).png"))
    }
    let now = Date.now
    let notes = (0..<300).map { index in
      var body = "第 \(index) 条便签\n☐ 任务\n[红]{red} 字\n```\n代码\n```"
      if index < 50 {
        body += "\n![image|80](kitty-note-image://\(imageIDs[index].uuidString).png)"
      }
      return Note(
        id: UUID().uuidString, title: "第 \(index) 条", body: body,
        createdAt: now, modifiedAt: now, order: Double(index))
    }
    let exportStart = ContinuousClock.now
    let exported = await NoteMarkdownFiles.export(
      notes: notes, imageDirectory: imageDirectory, to: parent, now: now)
    let exportTime = Self.ms(exportStart.duration(to: .now))
    let folder = try #require(exported.folder)
    let files = NoteMarkdownFiles.markdownFiles(in: folder).map {
      NoteMarkdownFiles.Source(url: $0, root: folder)
    }
    let importStart = ContinuousClock.now
    let imported = await NoteMarkdownFiles.importNotes(
      sources: files, imageDirectory: imageDirectory)
    let importTime = Self.ms(importStart.duration(to: .now))
    print(
      "notes-probe batch8 export \(String(format: "%.0f", exportTime)) ms (\(exported.count) notes, \(exported.missingImages) missing) import \(String(format: "%.0f", importTime)) ms (\(imported.notes.count) notes, \(imported.skipped) skipped)"
    )
  }
}
