// 示例便签（Notes/NoteSample.swift）：什么时候放、写什么。偏好用临时的域，便签库在内存里。

import Foundation
import Testing

@testable import KittyTools

struct NoteSampleTests {
  private func prefs() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "NoteSampleTests-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  /// 放过了就什么都不做；库里已经有便签只记不放；一条都没有才放——屏幕边缘的总开关关着时这次不放也不记
  @Test func stepByStateOfTheLibrary() {
    typealias Sample = NoteSample
    #expect(Sample.step(wasAdded: true, isDeckEnabled: true, count: 0) == .skip)
    #expect(Sample.step(wasAdded: true, isDeckEnabled: true, count: 3) == .skip)
    #expect(Sample.step(wasAdded: false, isDeckEnabled: true, count: 3) == .mark)
    #expect(Sample.step(wasAdded: false, isDeckEnabled: false, count: 3) == .mark)
    #expect(Sample.step(wasAdded: false, isDeckEnabled: true, count: 0) == .add)
    #expect(Sample.step(wasAdded: false, isDeckEnabled: false, count: 0) == .skip)
  }

  /// 正文：第一行是标题（标题留空）；哪条边、快捷键按当时的写；没设快捷键那一行换成从菜单栏、启动器走
  @Test func bodyFollowsEdgeAndHotKey() {
    let right = NoteSample.body(edge: .right, hotKey: "⌥N")
    #expect(
      right == """
        欢迎使用便签
        鼠标靠到屏幕右边缘，这一叠就会展开，点一张标签打开它。
        ☐ 按 ⌥N 随手记一条
        ☐ 拖动标签调整顺序
        ☐ 点图钉固定，点别处时它也不收
        用不着这条了，点「⋯」里的「删除」。
        """)
    let left = NoteSample.body(edge: .left, hotKey: "⌃⌥J")
    #expect(left.contains("鼠标靠到屏幕左边缘") && left.contains("☐ 按 ⌃⌥J 随手记一条"))
    let unbound = NoteSample.body(edge: .right, hotKey: nil)
    #expect(unbound.contains("☐ 在菜单栏或启动器里选「快速记一条」随手记") && !unbound.contains("按 "))
    // 标签上、列表里显示的是第一行；摘要不带任务符号
    let note = Note(id: "a", body: right, createdAt: .now, modifiedAt: .now)
    #expect(note.displayTitle == "欢迎使用便签" && !note.preview.contains("☐"))
    #expect(right.utf8.count < Note.maxBodyBytes)
  }

  /// 全新的库：放一条（标题空着、第一种纸色、没固定没归档），记下放过了；删掉之后不再放，换了新库也不再放
  @Test func addedOnceToAnEmptyLibrary() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try NoteStore(db: Database(path: ":memory:"))
    #expect(NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: "⌥N"))
    let note = try #require(store.active.first)
    #expect(store.notes.count == 1 && note.title.isEmpty && note.color == 0 && !note.isPinned)
    #expect(note.body == NoteSample.body(edge: .right, hotKey: "⌥N"))
    #expect(defaults.bool(forKey: Prefs.notesSampleAdded))
    #expect(!NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: "⌥N"))
    store.erase(note.id)
    #expect(
      !NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: "⌥N") && store.notes.isEmpty)
    // 便签库「重新开始」换了新库：标记还在，不再放
    let fresh = try NoteStore(db: Database(path: ":memory:"))
    #expect(
      !NoteSample.addIfFirst(to: fresh, defaults: defaults, hotKey: "⌥N") && fresh.notes.isEmpty)
  }

  /// 那一叠设在左边：示例里写左边
  @Test func sampleNamesTheConfiguredEdge() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(NoteDeckOptions.Edge.left.rawValue, forKey: Prefs.notesDeckEdge)
    let store = try NoteStore(db: Database(path: ":memory:"))
    #expect(NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: nil))
    #expect(store.active.first?.body == NoteSample.body(edge: .left, hotKey: nil))
  }

  /// 库里已经有便签（哪怕只在归档、最近删除里）：不放，只记下——以后删光了也不再放
  @Test func existingNotesOnlyMark() throws {
    let cases: [(NoteStore, String) -> Void] = [
      { _, _ in },
      { $0.setArchived(true, of: $1) },
      { $0.delete($1) },
    ]
    for prepare in cases {
      let (defaults, suite) = try prefs()
      defer { defaults.removePersistentDomain(forName: suite) }
      let store = try NoteStore(db: Database(path: ":memory:"))
      let id = store.create(body: "自己的便签").id
      prepare(store, id)
      #expect(!NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: "⌥N"))
      #expect(store.notes.count == 1 && defaults.bool(forKey: Prefs.notesSampleAdded))
      store.erase(id)
      #expect(
        !NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: "⌥N") && store.notes.isEmpty)
    }
  }

  /// 屏幕边缘的总开关关着：这次不放也不记；打开之后、库还空着的那次再放
  @Test func waitsWhileTheDeckIsOff() throws {
    let (defaults, suite) = try prefs()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: Prefs.notesDeckEnabled)
    let store = try NoteStore(db: Database(path: ":memory:"))
    #expect(!NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: "⌥N"))
    #expect(store.notes.isEmpty && !defaults.bool(forKey: Prefs.notesSampleAdded))
    defaults.set(true, forKey: Prefs.notesDeckEnabled)
    #expect(
      NoteSample.addIfFirst(to: store, defaults: defaults, hotKey: "⌥N") && store.notes.count == 1)
  }
}
