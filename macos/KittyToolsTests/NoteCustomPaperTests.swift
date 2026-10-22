// 自定义纸色（便签未来计划第 2 批，拍板 B1 / B2；Notes/NotePaper.swift 的推导、Notes/Note.swift 的写法）单测：
// - 推导：8 张预设浅纸进去出来一模一样；按色相 × 彩度 × 亮度的网格（同原型 derive2.py）扫一遍，现有的门槛
//   （paperTable、tabTint、任务方框、六种文字颜色）对每一张推出来的纸都成立；挑的是浅色时原样；名字。
// - 写法：内存里一个整数、落盘拆成「最接近的预设 + 色值」；库加了可空的 tint 列、版本不升；**模拟已发布的 0.5.0**
//   （只认原来那几列、夹 0–7、写明列名的 upsert）读写同一个库：看到最接近的那种，改正文不丢色值，换了颜色就按它换的；
//   导出文件和 Markdown 文件头的往返、旧文件、写坏的色值。
// - 界面（第 3 批）：颜色菜单的三节（预设、自定义的、「其他颜色…」）、最近用过（临时偏好域）、挑的正好是预设浅纸、
//   取色面板边拖边变的慢落盘、点取色面板不算点别处、那叠和全部便签窗口的「其他颜色…」交给取色面板（换成记账的闭包，
//   **不真的打开系统取色面板**——它会出现在屏幕上）。
// 全用内存库和临时值，不碰用户的数据目录和偏好。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct NoteCustomPaperTests {
  private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

  // MARK: 门槛（对任意一张纸）

  /// ink 以 opacity 叠在 paper 上（0xRRGGBB）
  private static func mix(_ ink: Int, _ paper: Int, _ opacity: Double) -> Int {
    [16, 8, 0].reduce(0) { hex, shift in
      let value =
        Double(ink >> shift & 0xFF) * opacity + Double(paper >> shift & 0xFF) * (1 - opacity)
      return hex | Int(value.rounded()) << shift
    }
  }

  /// 这张纸过不了的门槛（空 = 全过）。和锁预设的几条测试同一组数：NotesWindowTests.paperTable、
  /// NoteDeckTests.tabTintKeepsInkReadable、NoteTaskBoxTests、NoteBatch8Tests.colorsAreReadableOnEveryPaper
  static func problems(of paper: NotePaper) -> [String] {
    let contrast = NoteTaskBox.contrast
    var found: [String] = []
    for (tone, name, isDark) in [(paper.light, "浅", false), (paper.dark, "深", true)] {
      if contrast(tone.ink, tone.paper) < 7 { found.append("\(name) 墨") }
      if contrast(mix(tone.ink, tone.paper, NotePaper.secondaryOpacity), tone.paper) < 4.5 {
        found.append("\(name) 次要")
      }
      if contrast(tone.strip, tone.paper) < 1.5 { found.append("\(name) 色条") }
      if contrast(tone.ink, mix(tone.ink, tone.paper, NotePaper.codeFillOpacity)) < 7 {
        found.append("\(name) 代码")
      }
      if contrast(tone.ink, mix(tone.strip, tone.paper, NotePaper.tabTint)) < 4.5 {
        found.append("\(name) 标签")
      }
      if contrast(mix(tone.ink, tone.paper, NoteTaskBox.strokeOpacity), tone.paper) < 3 {
        found.append("\(name) 方框描边")
      }
      let done = NoteTaskBox.mark(on: tone.strip, ink: paper.light.ink)
      if contrast(done, tone.strip) < 3 { found.append("\(name) 对勾") }
      let red = isDark ? NoteColor.red.dark : NoteColor.red.light
      if contrast(NoteTaskBox.mark(on: red, ink: paper.light.ink), red) < 3 {
        found.append("\(name) 感叹号")
      }
      for color in NoteColor.allCases
      where contrast(isDark ? color.dark : color.light, tone.paper) < 4.5 {
        found.append("\(name) 文字颜色 \(color.name)")
      }
    }
    if NoteTaskBox.luminance(paper.light.paper) <= 0.6 { found.append("浅纸太暗") }
    if NoteTaskBox.luminance(paper.dark.paper) >= 0.08 { found.append("深纸太亮") }
    // 同一个色相：两套的色条在 HSB 里的色相差 ≤ 25°（灰的两边都是 0）
    let hue = { (hex: Int) in srgb(hex).hueComponent * 360 }
    let gap = abs(hue(paper.light.strip) - hue(paper.dark.strip))
    if min(gap, 360 - gap) > 25 { found.append("色相差 \(Int(gap))") }
    return found
  }

  // MARK: 推导

  /// 8 张预设：浅纸进去出来一模一样，也认得出自己是哪一种；预设本身也过同一组门槛（这组门槛和锁预设的测试是一回事）
  @Test func presetsDeriveToThemselves() {
    for (index, preset) in NotePaper.all.enumerated() {
      let derived = NotePaper.derived(rgb: preset.light.paper)
      #expect(derived.light.paper == preset.light.paper, "\(preset.name)")
      #expect(NotePaper.nearestPreset(rgb: preset.light.paper) == index, "\(preset.name)")
      #expect(Self.problems(of: preset).isEmpty, "\(preset.name) \(Self.problems(of: preset))")
    }
  }

  /// 网格（色相每 2°、8 档彩度、6 档亮度，含纯黑纯白、出了 sRGB 收回来的）：每一张推出来的纸都过全部门槛。
  /// 挑的本来就是一张合格的浅纸时一个色值都不改（所见即所得）
  @Test func everyCustomPaperPassesTheThresholds() {
    var failures: [String] = []
    var kept = 0
    var count = 0
    for hue in stride(from: 0.0, to: 360, by: 2) {
      for chroma in [0, 0.02, 0.05, 0.08, 0.12, 0.16, 0.2, 0.3] {
        for lightness in [0.3, 0.6, 0.85, 0.9, 0.95, 0.98] {
          let picked = PaperMath.gamut(lightness, chroma, hue)
          let paper = NotePaper.derived(rgb: picked)
          count += 1
          if paper.light.paper == picked { kept += 1 }
          let problems = Self.problems(of: paper)
          if !problems.isEmpty, failures.count < 20 {
            failures.append(String(format: "#%06X %@", picked, problems.joined(separator: "、")))
          }
        }
      }
    }
    #expect(count == 8640)
    #expect(failures.isEmpty, "\(failures)")
    // 原型里是 3834：浅色、不太艳的那一大片原样
    #expect(kept > 3000, "原样的 \(kept)")
    for extreme in [0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF]
    {
      let paper = NotePaper.derived(rgb: extreme)
      #expect(Self.problems(of: paper).isEmpty, "#\(String(format: "%06X", extreme))")
    }
  }

  /// 挑的是浅色、不太艳：浅纸就是它；太深的往浅里提，色相不变
  @Test func lightPicksAreKeptAndDarkOnesLifted() {
    for pick in [0xFFE0F0, 0xE0F0FF, 0xF2F2E6, 0xFFF3C4] {
      #expect(NotePaper.derived(rgb: pick).light.paper == pick, "\(String(format: "#%06X", pick))")
    }
    let navy = 0x203040
    let lifted = NotePaper.derived(rgb: navy).light.paper
    #expect(NoteTaskBox.luminance(lifted) >= 0.62)
    let gap = abs(PaperMath.oklch(lifted).h - PaperMath.oklch(navy).h)
    #expect(min(gap, 360 - gap) < 3, "色相不变")
  }

  /// 名字：按色相 12 个词，很灰的叫灰；菜单、旁白里念得出来（不是十六进制）
  @Test func customPapersHaveSpokenNames() {
    let cases: [(Int, String)] = [
      (0xFF0000, "红"), (0xFFC0CB, "粉"), (0xFFA500, "橙"), (0xFFFF00, "黄"), (0x9ACD32, "黄绿"),
      (0x00FF00, "绿"), (0xB4E8D0, "青绿"), (0x00FFFF, "青"), (0x0000FF, "蓝"), (0x6A5ACD, "靛"),
      (0x8000FF, "紫"), (0xFF00FF, "品红"), (0x808080, "灰"), (0x000000, "灰"), (0xFFFFFF, "灰"),
    ]
    for (rgb, word) in cases {
      #expect(NotePaper.customName(rgb: rgb) == "自定义 · \(word)", "\(String(format: "#%06X", rgb))")
    }
    let paper = NotePaper.of(color: Note.custom(rgb: 0xBEDDFA))
    #expect(paper.name == "自定义 · 蓝" && paper.light.paper == 0xBEDDFA)
    #expect(NotePaper.of(color: Note.custom(rgb: 0xBEDDFA)) == paper, "缓存的和现推的一样")
  }

  // MARK: 内存里的写法

  @Test func colorValuesInMemory() {
    let custom = Note.custom(rgb: 0x12ABEF)
    #expect(Note.customRGB(of: custom) == 0x12ABEF)
    #expect(Note.customRGB(of: 3) == nil && Note.customRGB(of: -1) == nil)
    #expect(Note.customRGB(of: 2 << 24) == nil && Note.customRGB(of: .max) == nil)
    #expect(Note.clamped(color: custom) == custom, "自定义的原样")
    #expect(Note.clamped(color: 99) == 7 && Note.clamped(color: -5) == 0)
    // 落盘的那个下标、读回来合起来
    let sky = Note.custom(rgb: 0xC2DFF8)
    #expect(Note.storedPreset(of: sky) == 4, "最接近天蓝")
    #expect(Note.storedPreset(of: 5) == 5 && Note.storedPreset(of: 42) == 7)
    // 文件里：色值合法就是自定义的
    #expect(
      Note.color(preset: 4, tint: 0xC2DFF8) == sky && Note.color(preset: 0, tint: 0xC2DFF8) == sky)
    #expect(Note.color(preset: 4, tint: nil) == 4)
    #expect(Note.color(preset: 4, tint: 0x1000000) == 4 && Note.color(preset: 4, tint: -1) == 4)
    #expect(Note.color(preset: 99, tint: nil) == 7)
    // 库里：tint 记着写入时的预设，和 color 列对得上才算（不重算推导）
    let packed = 4 << 24 | 0xC2DFF8
    #expect(Note.storedTint(of: sky) == packed && Note.storedTint(of: 4) == nil)
    #expect(Note.color(stored: 4, tint: packed) == sky)
    #expect(Note.color(stored: 5, tint: packed) == 5, "对不上：旧版本换过颜色，按它换的")
    #expect(Note.color(stored: 4, tint: nil) == 4 && Note.color(stored: 4, tint: -1) == 4)
    // ⌘. 和新建便签只在预设里轮：自定义的从最接近的那种往下
    #expect(Note.nextPreset(after: sky) == 5)
    #expect(Note.nextPreset(after: 7) == 0)
    #expect(NotesWindowModel.nextColor(after: sky) == 5)
    // 文件里的写法
    #expect(Note.hex(rgb: 0x0A0B0C) == "#0A0B0C")
    #expect(Note.rgb(hex: "#0a0B0c") == 0x0A0B0C)
    for bad in ["0A0B0C", "#0A0B0", "#0A0B0C0", "#GG0000", "#+12345", "#-12345", "", "#"] {
      #expect(Note.rgb(hex: bad) == nil, "\(bad)")
    }
  }

  // MARK: 库

  /// 0.5.0 原样的读写（tag macos-v0.5.0 的 NoteStore：写明列名的 SELECT / upsert，颜色夹进 0–7）
  private static let oldColumns =
    "id, title, body, color, created_at, modified_at, revision, archived, pinned, sort_order, deleted_at"
  private static let oldUpsert = """
    INSERT INTO notes(\(oldColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET title = excluded.title, body = excluded.body,
      color = excluded.color, created_at = excluded.created_at,
      modified_at = excluded.modified_at, revision = excluded.revision,
      archived = excluded.archived, pinned = excluded.pinned, sort_order = excluded.sort_order,
      deleted_at = excluded.deleted_at
    """

  /// 0.5.0 读到的这一条的颜色（夹进 0–7）
  private func oldColor(_ db: Database, _ id: String) throws -> Int? {
    try db.query("SELECT \(Self.oldColumns) FROM notes WHERE id = ?", [id]) {
      min(max(Int(clamping: $0.int(3) ?? 0), 0), 7)
    }.first
  }

  /// 0.5.0 改了这一条（改正文 / 换颜色）写回去：只写原来那几列
  private func oldWrite(_ db: Database, _ id: String, body: String, color: Int) throws {
    try db.execute(
      Self.oldUpsert,
      [id, "", body, color, 0, 1, 2, false, false, 0.0, nil])
  }

  /// 存一条自定义纸色：库里 color 是最接近的预设、tint 是色值，表结构版本还是 1；再开一次读回来一样。
  /// 0.5.0 读同一个库看到最接近的那种；它改了正文写回去，回到新版本颜色还在；它换了别的颜色，回来按它换的
  @Test func databaseKeepsTheTintBesideThePreset() throws {
    let db = try Database(path: ":memory:")
    let store = try NoteStore(db: db)
    let note = store.create(body: "天蓝一点", now: Self.t0)
    let sky = Note.custom(rgb: 0xC2DFF8)
    store.setColor(sky, of: note.id, now: Self.t0)
    #expect(store.note(note.id)?.color == sky)
    let row = try db.query("SELECT color, tint FROM notes WHERE id = ?", [note.id]) {
      ($0.int(0), $0.int(1))
    }.first
    #expect(row?.0 == 4 && row?.1 == Int64(4 << 24 | 0xC2DFF8))
    #expect(try db.query("PRAGMA user_version") { $0.int(0) } == [1], "版本不升")
    #expect(try NoteStore(db: db).note(note.id)?.color == sky)
    // 0.5.0 读：最接近的那种（天蓝），改一个字写回去 → 色值那一列没动
    #expect(try oldColor(db, note.id) == 4)
    try oldWrite(db, note.id, body: "天蓝一点。", color: 4)
    let back = try NoteStore(db: db).note(note.id)
    #expect(back?.body == "天蓝一点。" && back?.color == sky)
    // 0.5.0 里换成了薄荷：回来按薄荷（色值还在列里，但和 color 对不上）；下一次落盘把留着的色值清掉，
    // 之后 0.5.0 再换回天蓝也不会「活」过来
    try oldWrite(db, note.id, body: "天蓝一点。", color: 5)
    let reopened = try NoteStore(db: db)
    #expect(reopened.note(note.id)?.color == 5)
    #expect(reopened.flush())
    let tint = { try db.query("SELECT tint FROM notes WHERE id = ?", [note.id]) { $0.int(0) } }
    #expect(try tint() == [nil])
    try oldWrite(db, note.id, body: "天蓝一点。", color: 4)
    #expect(try NoteStore(db: db).note(note.id)?.color == 4)
    // 自定义的换回预设：tint 清掉
    reopened.setColor(sky, of: note.id, now: Self.t0)
    reopened.setColor(2, of: note.id, now: Self.t0)
    #expect(try tint() == [nil])
  }

  /// 0.5.0 建的库（没有 tint 列）：打开时加上这一列、旧的行都是预设；加列不升版本，0.5.0 照样能读写
  @Test func oldDatabasesGetTheColumn() throws {
    let db = try Database(path: ":memory:")
    try db.execute(
      """
      CREATE TABLE notes(
        id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
        color INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
        sort_order REAL NOT NULL DEFAULT 0, deleted_at INTEGER)
      """)
    try db.execute("PRAGMA user_version = 1")
    let id = UUID().uuidString
    try oldWrite(db, id, body: "旧的", color: 3)
    let store = try NoteStore(db: db)
    #expect(store.note(id)?.color == 3)
    let names = try db.query("PRAGMA table_info(notes)") { $0.text(1) }
    #expect(names.contains("tint"))
    #expect(try db.query("PRAGMA user_version") { $0.int(0) } == [1])
    // 再开一次不重复加列
    #expect(try NoteStore(db: db).note(id)?.color == 3)
    store.setColor(Note.custom(rgb: 0xFFE0F0), of: id, now: Self.t0)
    #expect(try oldColor(db, id) == NotePaper.nearestPreset(rgb: 0xFFE0F0))
  }

  /// 新建便签接着上一条往下轮：上一条是自定义的，从最接近的那种的下一种接着
  @Test func newNotesRotateThroughPresets() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let first = store.create(body: "一", now: Self.t0)
    store.setColor(Note.custom(rgb: 0xC2DFF8), of: first.id, now: Self.t0)
    let second = store.create(body: "二", now: Self.t0.addingTimeInterval(1))
    #expect(second.color == 5)
  }

  // MARK: 导出文件

  /// 导出文件：color 写最接近的预设（0.5.0 读到的），tint 另写；预设的没有 tint 这个字段。读回来合起来；
  /// 旧文件（没有 tint）、写坏的色值、和 color 对不上的色值都按预设；导入（adopt）落到内存里是自定义的
  @Test func exportFilesCarryTheTint() throws {
    let sky = Note.custom(rgb: 0xC2DFF8)
    var note = Note(id: UUID().uuidString, body: "天蓝", createdAt: Self.t0, modifiedAt: Self.t0)
    note.color = sky
    let entry = try #require(SettingsArchive.NoteEntry(note))
    #expect(entry.color == 4 && entry.tint == "#C2DFF8" && entry.noteColor == sky)
    let data = try JSONEncoder().encode([entry])
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"tint\":\"#C2DFF8\"") && json.contains("\"color\":4"))
    let decoded = try JSONDecoder().decode([SettingsArchive.NoteEntry].self, from: data)
    #expect(decoded == [entry])
    // 预设的：没有 tint 字段
    note.color = 2
    let plain = try JSONEncoder().encode([try #require(SettingsArchive.NoteEntry(note))])
    #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("tint"))
    // 旧文件 / 写坏的 / 对不上的
    var old = entry
    old.tint = nil
    #expect(old.noteColor == 4)
    old.tint = "#ZZZZZZ"
    #expect(old.noteColor == 4)
    old.tint = "#C2DFF8"
    old.color = 0
    #expect(old.noteColor == sky, "文件里的色值只有新版本写：认它")
    // tint 类型不对：这一条照样要（颜色按预设）
    let odd = String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "\"#C2DFF8\"", with: "12")
    let oddEntry = try JSONDecoder().decode(
      [SettingsArchive.NoteEntry].self, from: Data(odd.utf8))
    #expect(oddEntry.first?.id == entry.id && oddEntry.first?.tint == nil)
    // 导入：落到仓库里是自定义的；文件里那条更新、本机那一版被换下来进「最近删除」时也带着自己的纸色
    let store = try NoteStore(db: Database(path: ":memory:"))
    store.adopt([entry], now: Self.t0)
    #expect(store.note(entry.id)?.color == sky)
    var newer = entry
    newer.body = "天蓝，改过"
    newer.modifiedAt += 1000
    newer.tint = nil
    newer.color = 1
    store.adopt([newer], now: Self.t0.addingTimeInterval(10))
    #expect(store.note(entry.id)?.color == 1)
    #expect(store.trashed.first?.body == "天蓝" && store.trashed.first?.color == sky)
  }

  // MARK: Markdown 文件头

  /// 文件头：color 写最接近的预设、tint 带引号另写一行（YAML 里 # 起注释）；读回来合起来。没有 tint 的旧文件是预设
  @Test func markdownHeaderCarriesTheTint() throws {
    var note = Note(id: UUID().uuidString, body: "正文", createdAt: Self.t0, modifiedAt: Self.t0)
    note.color = Note.custom(rgb: 0xFFE0F0)
    let header = NoteMarkdownFiles.header(for: note)
    let preset = NotePaper.nearestPreset(rgb: 0xFFE0F0)
    #expect(header.contains("\ncolor: \(preset)\n") && header.contains("\ntint: \"#FFE0F0\"\n"))
    let parsed = try #require(NoteMarkdownFiles.parseHeader(header + "\n\n正文"))
    #expect(parsed.color == preset && parsed.tint == 0xFFE0F0)
    #expect(Note.color(preset: parsed.color, tint: parsed.tint) == note.color)
    // 预设的没有 tint 那一行；旧文件读成预设；写坏的当没有
    note.color = 6
    #expect(!NoteMarkdownFiles.header(for: note).contains("tint"))
    let broken = header.replacingOccurrences(of: "\"#FFE0F0\"", with: "#FFE0F0")
    #expect(NoteMarkdownFiles.parseHeader(broken)?.tint == nil)
  }

  /// 导出成 Markdown 再导回来（走真的读文件那条路、再换成导入用的条目并进仓库）：纸色原样
  @Test func markdownExportImportKeepsTheTint() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-notes-tint-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var note = Note(id: UUID().uuidString, body: "粉", createdAt: Self.t0, modifiedAt: Self.t0)
    note.color = Note.custom(rgb: 0xFFE0F0)
    try (NoteMarkdownFiles.header(for: note) + "\n\n粉").write(
      to: folder.appending(path: "粉.md"), atomically: true, encoding: .utf8)
    let sources = NoteMarkdownFiles.markdownFiles(in: folder).map {
      NoteMarkdownFiles.Source(url: $0, root: folder)
    }
    let result = await NoteMarkdownFiles.importNotes(sources: sources, imageDirectory: nil)
    #expect(result.notes.map(\.color) == [note.color])
    let entries = result.notes.compactMap(SettingsArchive.NoteEntry.init)
    let store = try NoteStore(db: Database(path: ":memory:"))
    store.adopt(entries, now: Self.t0.addingTimeInterval(5))
    #expect(store.note(note.id)?.color == note.color)
  }

  // MARK: 界面（第 3 批）

  /// 临时偏好域（用完删掉）
  private func scratchDefaults() throws -> (UserDefaults, String) {
    let suite = "kitty-notes-recent-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  /// 最近用过：挑一次挪到最前、去重、最多 8 个，写坏的跳过；是这台电脑自己的状态（不注册默认值、不跟导出走）
  @Test func recentColorsKeepTheLatestEight() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(NoteColorPicker.recentColors(in: defaults).isEmpty)
    for rgb in 0..<10 { NoteColorPicker.remember(0x100000 + rgb, in: defaults) }
    #expect(NoteColorPicker.recentColors(in: defaults) == (2..<10).reversed().map { 0x100000 + $0 })
    NoteColorPicker.remember(0x100004, in: defaults)
    let list = NoteColorPicker.recentColors(in: defaults)
    #expect(list.first == 0x100004 && list.count == 8 && Set(list).count == 8)
    defaults.set(["#zz", "#ABCDEF", 3], forKey: Prefs.notesRecentColors)
    #expect(NoteColorPicker.recentColors(in: defaults).isEmpty, "不是一组字的整个不认")
    defaults.set(["#zz", "#ABCDEF"], forKey: Prefs.notesRecentColors)
    #expect(NoteColorPicker.recentColors(in: defaults) == [0xABCDEF])
    let key = Prefs.notesRecentColors
    #expect(Prefs.defaults[key] == nil && SettingsArchive.kinds[key] == nil)
  }

  /// 取色面板给的颜色 → sRGB 的色值（P3、灰度的也换得过来）；挑的正好是哪种预设的浅纸就是那种预设
  @Test func pickedColorsBecomePaperValues() throws {
    #expect(NoteColorPicker.rgb(of: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == 0xFF8000)
    #expect(NoteColorPicker.rgb(of: NSColor(white: 1, alpha: 1)) == 0xFFFFFF)
    let p3 = try #require(
      NoteColorPicker.rgb(of: NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)))
    #expect(p3 >> 16 == 0xFF, "P3 的纯红夹到 sRGB 的红")
    for (index, preset) in NotePaper.all.enumerated() {
      #expect(Note.picked(rgb: preset.light.paper) == index, "\(preset.name)")
    }
    #expect(Note.picked(rgb: 0xC2DFF8) == Note.custom(rgb: 0xC2DFF8))
  }

  /// 颜色菜单（五处共用一份）：8 种预设｜自定义的（这条现在用的排第一个，再是最近用过的，去重、最多 8 个）｜
  /// 其他颜色…；现在的那种打勾，点了换成它
  @Test func colorMenuHasCustomColorsAndOtherColors() {
    let sky = Note.custom(rgb: 0xC2DFF8)
    var chosen: [Int] = []
    var others = 0
    let recent = [0xFFE0F0, 0xC2DFF8] + (0..<10).map { 0x200000 + $0 }
    let items = NotePaper.colorItems(
      current: sky, recent: recent, choose: { chosen.append($0) }, other: { others += 1 })
    #expect(items.count == Note.colorCount + NoteColorPicker.recentLimit + 1)
    let custom = items.filter { $0.section == 1 }
    #expect(custom.count == NoteColorPicker.recentLimit)
    #expect(custom.first?.title == "自定义 · 蓝" && custom.first?.isChecked == true)
    #expect(custom[1].title == "自定义 · 粉" && custom.dropFirst().allSatisfy { $0.isChecked == false })
    #expect(items.prefix(Note.colorCount).allSatisfy { $0.isChecked == false })
    #expect(Set(items.map(\.id)).count == items.count && custom.allSatisfy { $0.image != nil })
    custom[1].run()
    #expect(chosen == [Note.custom(rgb: 0xFFE0F0)])
    #expect(items.last?.title == NotePaper.otherColorTitle && items.last?.section == 2)
    items.last?.run()
    #expect(others == 1)
    // 预设的、没有最近用过的：中间那一节是空的
    let plain = NotePaper.colorItems(current: 3, recent: [], choose: { _ in }, other: {})
    #expect(plain.map(\.section) == Array(repeating: 0, count: Note.colorCount) + [2])
  }

  /// 取色面板边拖边变：慢落盘（同打字），不是每拖一下落一次；落一次之后库里是新的
  @Test func liveColorChangesWaitForTheQuietSave() throws {
    let db = try Database(path: ":memory:")
    let store = try NoteStore(db: db) { _ in try await Task.sleep(for: .seconds(3600)) }
    let note = store.create(body: "拖着色轮", now: Self.t0)
    store.setColor(Note.custom(rgb: 0x123456), of: note.id, now: Self.t0, live: true)
    #expect(store.note(note.id)?.color == Note.custom(rgb: 0x123456))
    #expect(try NoteStore(db: db).note(note.id)?.color == 0, "还没落盘")
    store.flush()
    #expect(try NoteStore(db: db).note(note.id)?.color == Note.custom(rgb: 0x123456))
  }

  /// 那叠的操作菜单：颜色那一级带着最近用过（按 NoteEdge 给的读）、自定义的那条停在它自己那一行；
  /// 「其他颜色…」交给取色面板（这里换成记账的闭包）、菜单先关掉
  @Test func deckMenuPicksOtherColors() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let note = store.create(body: "一条", now: Self.t0)
    store.setColor(Note.custom(rgb: 0xFFE0F0), of: note.id, now: Self.t0)
    let model = NoteDeckModel(store: store)
    model.panelSize = CGSize(width: 538, height: 875)
    model.pillCenter = 437
    model.recentColors = { [0xC2DFF8] }
    var picked: [String] = []
    model.pickColor = { picked.append($0) }
    model.send(.pillEntered(optionDown: false, allowed: true))
    model.tapTab(note.id)
    model.toggleMenu(fromDot: true)
    let items = model.menuItems
    #expect(items.map(\.title).suffix(3) == ["自定义 · 粉", "自定义 · 蓝", NotePaper.otherColorTitle])
    #expect(model.menu?.selection == Note.colorCount, "停在自己那一行（自定义的第一个）")
    model.run(items[items.count - 1])
    #expect(picked == [note.id] && model.menu == nil)
    // 标签的右键菜单里也是这一份
    let tab = try #require(model.tabItems(note.id)[1].submenu)
    tab.last?.run()
    #expect(picked == [note.id, note.id])
  }

  /// 全部便签窗口：「其他颜色…」交给取色面板（窗口给的闭包）；最近用过按窗口的偏好域读，没有偏好域的是空的
  @Test func windowMenuPicksOtherColors() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    NoteColorPicker.remember(0xC2DFF8, in: defaults)
    let store = try NoteStore(db: Database(path: ":memory:"))
    let note = store.create(body: "一条", now: Self.t0)
    let model = NotesWindowModel(store: store, defaults: defaults)
    var picked: [String] = []
    model.pickColor = { picked.append($0) }
    let items = model.colorItems(note)
    #expect(items.map(\.title).suffix(2) == ["自定义 · 蓝", NotePaper.otherColorTitle])
    items.last?.run()
    #expect(picked == [note.id])
    #expect(NotesWindowModel(store: store).colorItems(note).filter { $0.section == 1 }.isEmpty)
  }

  /// 取色面板的状态那一半（不碰系统的取色面板）：边拖边变慢落盘；不是自己打开的那一处、打开的正是它在改的那条都不收；
  /// 收的时候落盘、只把自定义的记进最近用过；改的那条被删了就收；重开另一条先收掉上一条
  @Test func colorPickerStateFollowsItsOwner() throws {
    let (defaults, suite) = try scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let db = try Database(path: ":memory:")
    let store = try NoteStore(db: db) { _ in try await Task.sleep(for: .seconds(3600)) }
    let first = store.create(body: "甲", now: Self.t0)
    let second = store.create(body: "乙", now: Self.t0)
    let picker = NoteColorPicker()
    picker.defaults = defaults
    let owner = NSObject()
    let stranger = NSObject()
    #expect(picker.begin(first.id, in: store, owner: owner, from: nil))
    #expect(picker.isOpen(owner: owner) && !picker.isOpen(owner: stranger))
    picker.apply(NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
    let blue = Note.custom(rgb: 0x0080FF)
    #expect(store.note(first.id)?.color == blue)
    #expect(try NoteStore(db: db).note(first.id)?.color == 0, "边拖边变：还没落盘")
    picker.close(owner: stranger)
    picker.close(owner: owner, keeping: first.id)
    #expect(picker.noteID == first.id, "别人收不掉、打开的正是这条也不收")
    picker.close(owner: owner, keeping: second.id)
    #expect(picker.noteID == nil)
    #expect(try NoteStore(db: db).note(first.id)?.color == blue, "收的时候落盘")
    #expect(NoteColorPicker.recentColors(in: defaults) == [0x0080FF])
    // 挑的是预设的浅纸：存成预设、不进最近用过
    picker.begin(second.id, in: store, owner: owner, from: nil)
    picker.apply(srgb(NotePaper.all[3].light.paper))
    #expect(store.note(second.id)?.color == 3)
    // 重开另一条：上一条先收掉
    picker.begin(first.id, in: store, owner: stranger, from: nil)
    #expect(picker.isOpen(owner: stranger) && !picker.isOpen(owner: owner))
    #expect(NoteColorPicker.recentColors(in: defaults) == [0x0080FF])
    // 改的那条进了最近删除：再挑就收
    store.delete(first.id)
    picker.apply(NSColor.red)
    #expect(picker.noteID == nil && store.note(first.id)?.color == blue)
  }

  /// 那叠 / 浮动便签换了一条：从那里打开的取色面板收掉；打开的正是它在改的那条不收
  @Test func sheetChangeClosesThePicker() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let first = store.create(body: "甲", now: Self.t0)
    let second = store.create(body: "乙", now: Self.t0)
    let model = NoteDeckModel(store: store)
    let picker = NoteColorPicker.shared
    defer { picker.close(owner: model) }
    picker.begin(first.id, in: store, owner: model, from: nil)
    model.sheetChanged(to: first.id)
    #expect(picker.isOpen(owner: model))
    model.sheetChanged(to: second.id)
    #expect(!picker.isOpen(owner: model))
  }

  /// 正文框不接取色面板的 changeColor:（父类会把整篇纯文本染成挑的颜色）
  @Test func bodyIgnoresColorPanelChanges() throws {
    let editor = NoteTextView.make()
    editor.setPaper(NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard)
    editor.setText("正文")
    let before =
      editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
      as? NSColor
    editor.changeColor(nil)
    let after =
      editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
      as? NSColor
    #expect(before != nil && after === before)
  }
}
