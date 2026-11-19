// 第五轮体检第 6 批（全局：键盘、快捷键、更新）的纯函数单测：面板里的 ⌘ + 字母 / 标点按打出来的字认（E2，德语 Z/Y、法语 A/Q Z/W、
// 俄文退回键位、数字和小键盘照旧按键位、按着 ⌘ 时认布局 ⌘ 那一层的字）；新装时会吞掉要用的字母的默认 ⌥ 键先不注册（E9，只记在这台
// Mac 上）；截图时的键「全部恢复默认」能撤销（U5）；
// 应用内更新装没成的原因怎么分（E10：网络给重试、磁盘满单独说、别的给发布页）和换不了 App 的判断。

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import KittyTools

struct KeyboardChecksTests {
  /// 按打出来的字认：美式照旧；德语 Z、Y 互换、法语 A/Q Z/W 互换、M 在美式的 ; 上；⇧ 打出大写也认；
  /// 不是 ASCII 字母 / 标点（俄文、德语 ß、死键给的空）退回物理键位；数字那一排（法语不按 ⇧ 是 &é"'(）、小键盘、控制键照旧按键位
  @Test func panelKeysFollowTypedCharacters() {
    let typed = { (code: Int, characters: String?) in HotKey.keyCode(code, typing: characters) }
    // 美式
    #expect(typed(kVK_ANSI_Z, "z") == kVK_ANSI_Z)
    #expect(typed(kVK_ANSI_Comma, ",") == kVK_ANSI_Comma)
    // 德语（QWERTZ）：印着 Z 的键在美式的 Y 上
    #expect(typed(kVK_ANSI_Y, "z") == kVK_ANSI_Z)
    #expect(typed(kVK_ANSI_Z, "y") == kVK_ANSI_Y)
    #expect(typed(kVK_ANSI_Slash, "-") == kVK_ANSI_Minus)
    // 法语（AZERTY）
    #expect(typed(kVK_ANSI_Q, "a") == kVK_ANSI_A)
    #expect(typed(kVK_ANSI_A, "q") == kVK_ANSI_Q)
    #expect(typed(kVK_ANSI_W, "z") == kVK_ANSI_Z)
    #expect(typed(kVK_ANSI_Z, "w") == kVK_ANSI_W)
    #expect(typed(kVK_ANSI_Semicolon, "m") == kVK_ANSI_M)
    #expect(typed(kVK_ANSI_M, ",") == kVK_ANSI_Comma)
    #expect(typed(kVK_ANSI_Slash, "=") == kVK_ANSI_Equal)
    // ⇧：字母不分大小写
    #expect(typed(kVK_ANSI_Y, "Z") == kVK_ANSI_Z)
    // 「+」当成 ⌘= 那个键：美式 ⌘⇧=、瑞典（+ 在美式 - 上）、德语（+ 在美式 ] 上）都是放大
    #expect(typed(kVK_ANSI_Equal, "+") == kVK_ANSI_Equal)
    #expect(typed(kVK_ANSI_Minus, "+") == kVK_ANSI_Equal)
    #expect(typed(kVK_ANSI_RightBracket, "+") == kVK_ANSI_Equal)
    // 别的要按 ⇧ 才打得出的标点照旧按键位（ponytail）：法语的「.」在美式 , 上要按 ⇧
    #expect(typed(kVK_ANSI_Comma, ";") == kVK_ANSI_Semicolon)
    // 俄文、希腊文：退回键位（美式的位置）
    #expect(typed(kVK_ANSI_Z, "я") == kVK_ANSI_Z)
    #expect(typed(kVK_ANSI_C, "с") == kVK_ANSI_C)
    #expect(typed(kVK_ANSI_W, "ς") == kVK_ANSI_W)
    #expect(typed(kVK_ANSI_Minus, "ß") == kVK_ANSI_Minus)
    #expect(typed(kVK_ANSI_6, "") == kVK_ANSI_6)
    #expect(typed(kVK_ANSI_A, nil) == kVK_ANSI_A)
    // 数字那一排、小键盘照旧按键位（法语的 ' 在 4 上，不能当成 ⌘'）
    #expect(typed(kVK_ANSI_1, "&") == kVK_ANSI_1)
    #expect(typed(kVK_ANSI_4, "'") == kVK_ANSI_4)
    #expect(typed(kVK_ANSI_KeypadDecimal, ".") == kVK_ANSI_KeypadDecimal)
    #expect(typed(kVK_ANSI_KeypadMinus, "-") == kVK_ANSI_KeypadMinus)
    // 控制键打出的是控制字符、私用区字符，不在表里
    #expect(typed(kVK_Escape, "\u{1b}") == kVK_Escape)
    #expect(typed(kVK_Return, "\r") == kVK_Return)
    #expect(typed(kVK_Tab, "\t") == kVK_Tab)
    #expect(typed(kVK_Delete, "\u{7f}") == kVK_Delete)
    #expect(typed(kVK_UpArrow, "\u{f700}") == kVK_UpArrow)
    #expect(typed(kVK_Space, " ") == kVK_Space)
    // 共用这一份判断的两处：卡片上的 ⌘C（德语、俄文）、App 快捷键里交给输入框的编辑键（法语 ⌘Z 在美式的 W 上）
    #expect(HoverKeyPanel.command(key: "c", keyCode: kVK_ANSI_C, flags: .command) == .copy)
    #expect(HoverKeyPanel.command(key: "с", keyCode: kVK_ANSI_C, flags: .command) == .copy)
    #expect(AppShortcuts.editsText(keyCode: UInt16(kVK_ANSI_W), flags: .command, key: "z"))
    #expect(!AppShortcuts.editsText(keyCode: UInt16(kVK_ANSI_Z), flags: .command, key: "s"))
  }

  /// 认哪一层的字：按着 ⌘ 时用布局 ⌘ 那一层（Dvorak – QWERTY ⌘ 按 ⌘ 时是美式；俄语 PC 的 / 键 ⌘ 层是「/」、不按修饰键是「.」），
  /// 取不到退回不按修饰键的；不按 ⌘ 的单键（钉图 O、长截图 A）用不按修饰键的
  @Test func commandLayerOnlyWithCommand() {
    func code(_ physical: Int, command: Bool, layer: String?, plain: String?) -> Int {
      HotKey.keyCode(
        physical,
        typing: HotKey.typedCharacters(command: command, commandLayer: layer, plain: plain))
    }
    // Dvorak – QWERTY ⌘：美式 C 的位置不按修饰键是 j，按着 ⌘ 是 c
    #expect(code(kVK_ANSI_C, command: true, layer: "c", plain: "j") == kVK_ANSI_C)
    #expect(code(kVK_ANSI_C, command: false, layer: nil, plain: "j") == kVK_ANSI_J)
    #expect(code(kVK_ANSI_Slash, command: true, layer: "/", plain: ".") == kVK_ANSI_Slash)
    #expect(code(kVK_ANSI_Slash, command: false, layer: "/", plain: ".") == kVK_ANSI_Period)
    #expect(code(kVK_ANSI_Z, command: true, layer: nil, plain: "w") == kVK_ANSI_W)
    // 法语、德语、瑞典的 ⌘ 层和不按修饰键一样
    #expect(code(kVK_ANSI_W, command: true, layer: "z", plain: "z") == kVK_ANSI_Z)
  }

  /// 系统自带布局的 uchr 按 id 取来算（不切换系统布局）：波兰语 Pro 的 ⌥A = ą；土耳其语 Q 的 ç 有自己的键（不按 ⌥ 也打得出）
  @Test func layoutCharactersFromInstalledLayouts() throws {
    func layout(_ id: String) -> Data? {
      let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
      guard
        let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
          as? [TISInputSource],
        let source = list.first,
        let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
      else { return nil }
      return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }
    let polish = try #require(layout("com.apple.keylayout.PolishPro"))
    let polishA = HotKey.character(
      for: UInt16(kVK_ANSI_A), modifiers: UInt32(optionKey), in: polish)
    #expect(polishA == "ą")
    #expect(HotKey.character(for: UInt16(kVK_ANSI_A), in: polish) == "a")
    #expect(
      HotKey.swallowedLetter(
        typed: polishA, plain: HotKey.plainCharacters(in: polish), languages: ["pl"])
        == "ą")
    let turkish = try #require(layout("com.apple.keylayout.Turkish-QWERTY-PC"))
    let turkishC = HotKey.character(
      for: UInt16(kVK_ANSI_C), modifiers: UInt32(optionKey), in: turkish)
    #expect(turkishC == "ç")
    #expect(HotKey.plainCharacters(in: turkish).contains("ç"))
    #expect(
      HotKey.swallowedLetter(
        typed: turkishC, plain: HotKey.plainCharacters(in: turkish), languages: ["tr"])
        == nil)
  }

  /// 会吞掉的字母（E9）：⌥ + 键打出的是非 ASCII 的字母、语言里又要用到才算；中文、英文系统的 ⌥C = ç 不算，
  /// 法语算；北欧的 å ø、德语 ß、波兰语 ą；不是字母（∂、不换行空格、死键给的 ˜）、ASCII 字母、同一个布局不按 ⌥ 也打得出的都不算
  @Test func swallowedLettersFollowSystemLanguages() {
    let swallowed = { (typed: String?, languages: [String]) in
      HotKey.swallowedLetter(typed: typed, plain: ["a", "c", "o", "1"], languages: languages)
    }
    #expect(
      HotKey.swallowedLetter(typed: "Ç", plain: ["c", "ç"], languages: ["tr", "fr"]) == nil)
    // 拿哪些语言判断：布局的语言只在系统里没有同一种语言时才补。英文系统 + 波兰语 Pro 补上 pl（⌥A = ą 算吞）；
    // 瑞士德语布局写的是 de，系统是 de-CH（不用 ß）：不补，⌥S = ß 不算吞；系统语言读不到时用 preferred
    let polish = HotKey.languages(system: ["en-US", "zh-Hans-CN"], preferred: ["fr"], layout: "pl")
    #expect(polish == ["en-US", "zh-Hans-CN", "pl"])
    #expect(HotKey.swallowedLetter(typed: "ą", plain: ["a"], languages: polish) == "ą")
    let swiss = HotKey.languages(system: ["de-CH", "en-CH"], preferred: [], layout: "de")
    #expect(swiss == ["de-CH", "en-CH"])
    #expect(HotKey.swallowedLetter(typed: "ß", plain: ["s"], languages: swiss) == nil)
    #expect(HotKey.languages(system: [], preferred: ["fr-FR"], layout: nil) == ["fr-FR"])
    #expect(swallowed("ç", ["zh-Hans-CN", "en-CN"]) == nil)
    #expect(swallowed("ç", ["en-US", "fr-FR"]) == "ç")
    #expect(swallowed("å", ["da-DK"]) == "å")
    #expect(swallowed("ø", ["nb-NO"]) == "ø")
    #expect(swallowed("ß", ["de-DE"]) == "ß")
    #expect(swallowed("ą", ["pl-PL"]) == "ą")
    #expect(swallowed("Ç", ["fr"]) == "Ç")
    #expect(swallowed("∂", ["fr", "de"]) == nil)
    #expect(swallowed("\u{a0}", ["fr"]) == nil)
    #expect(swallowed("˜", ["es"]) == nil)
    #expect(swallowed("c", ["en"]) == nil)
    #expect(swallowed(nil, ["fr"]) == nil)
    #expect(swallowed("çç", ["fr"]) == nil)
    // 带 ⌘ / ⌃、⌥Space、F 键不查布局，直接不算
    #expect(HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | optionKey).swallowedLetter == nil)
    #expect(HotKey(keyCode: kVK_Space, modifiers: optionKey).swallowedLetter == nil)
    #expect(HotKey(keyCode: kVK_F5, modifiers: optionKey).swallowedLetter == nil)
  }

  /// 新装（没看过任何一版、引导也没开过）时吞字母的默认键记进这台 Mac 自己的列表（不写 hotkey.<动作>）：没存过的当没设、
  /// 不注册；存了的（自己设的、同步 / 导入来的）照用；回到默认（偏好里那一项删掉）后照旧空着；这个列表不进导出、不进同步；
  /// 已经存过的不记；升级上来的整个不碰
  @Test func seedWithholdsSwallowingDefaults() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let mine = HotKeyAction.stored(HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey))
    defaults.set(mine, forKey: HotKeyAction.screenshot.prefsKey)
    let swallows = { (key: HotKey) in
      [kVK_ANSI_C, kVK_ANSI_A, kVK_ANSI_O].contains(Int(key.keyCode))
    }
    HotKeyAction.seedNewInstall(defaults, domainName: suite, swallows: swallows)
    let stored = defaults.persistentDomain(forName: suite) ?? [:]
    #expect(Set(stored.keys) == [HotKeyAction.screenshot.prefsKey, Prefs.hotkeysWithheld])
    let withheld = HotKeyAction.withheld(in: defaults)
    #expect(withheld == [.clipboard, .recognizeText])
    func resolve(_ action: HotKeyAction) -> HotKey? {
      action.resolve(withheld: withheld) { defaults.data(forKey: $0.prefsKey) }
    }
    #expect(resolve(.clipboard) == nil)
    #expect(resolve(.launcher) == HotKeyAction.launcher.defaultHotKey)
    // 自己设的 / 同步来的盖过它；删掉那一项（导入的文件里没有、同步里改回默认）后照旧空着
    let optionV = HotKey(keyCode: kVK_ANSI_V, modifiers: optionKey)
    defaults.set(HotKeyAction.stored(optionV), forKey: HotKeyAction.clipboard.prefsKey)
    #expect(resolve(.clipboard) == optionV)
    defaults.removeObject(forKey: HotKeyAction.clipboard.prefsKey)
    #expect(resolve(.clipboard) == nil)
    // 跟着这台 Mac：不注册默认值，导出、同步都不带
    #expect(Prefs.defaults[Prefs.hotkeysWithheld] == nil)
    #expect(SettingsArchive.kinds[Prefs.hotkeysWithheld] == nil)
    // 再来一次不变（列表已经有了）
    HotKeyAction.seedNewInstall(defaults, domainName: suite, swallows: { _ in true })
    #expect(HotKeyAction.withheld(in: defaults) == [.clipboard, .recognizeText])

    let upgraded = "kitty-test-\(UUID().uuidString)"
    let old = try #require(UserDefaults(suiteName: upgraded))
    defer { old.removePersistentDomain(forName: upgraded) }
    old.set("0.10.0", forKey: Prefs.lastSeenVersion)
    HotKeyAction.seedNewInstall(old, domainName: upgraded, swallows: { _ in true })
    #expect(old.persistentDomain(forName: upgraded)?.keys.sorted() == [Prefs.lastSeenVersion])
  }

  /// 截图时不让录的固定键（A6）：录制时按这台的布局把物理键换成打出来的字再比（法语键盘上 ⌘= 在美式 / 的位置）；导入、同步的
  /// 校验（isUsable）只按物理键位，收不收不看收的那台是什么布局
  @Test func shotReservedKeysByTypedCharacter() {
    let slash = HotKey(keyCode: kVK_ANSI_Slash, modifiers: cmdKey)
    #expect(ShotKey.isReserved(slash, typing: "="))
    #expect(!ShotKey.isReserved(slash, typing: "/"))
    #expect(!ShotKey.isReserved(slash))
    #expect(ShotKey.isUsable(slash))
    let commandD = HotKey(keyCode: kVK_ANSI_D, modifiers: cmdKey)
    #expect(ShotKey.isReserved(commandD) && !ShotKey.isUsable(commandD))
    // 德语：印着 D 的键还是美式 D 的位置；俄文打出 в 时按物理键位
    #expect(ShotKey.isReserved(commandD, typing: "d"))
    #expect(ShotKey.isReserved(commandD, typing: "в"))
    #expect(ShotKey.isReserved(HotKey(keyCode: kVK_Escape, modifiers: 0), typing: "\u{1b}"))
  }

  /// 「全部恢复默认」的撤销（U5）：拷下改过的那几个，恢复默认后放回；只放回现在还是「没存过」的——恢复默认之后又录的、
  /// 同步落下的不盖；拷的时候就是默认的不动
  @Test func shotKeysRestoreAfterReset() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ShotKey.snapshot(in: defaults).isEmpty)
    let pin = HotKey(keyCode: kVK_ANSI_P, modifiers: 0)
    ShotKey.pin.set(pin, in: defaults)
    ShotKey.crop.set(nil, in: defaults)
    let before = ShotKey.snapshot(in: defaults)
    #expect(Set(before.keys) == [.pin, .crop])
    for key in ShotKey.allCases { key.set(key.defaultKey, in: defaults) }
    #expect(ShotKey.pin.key(in: defaults) == ShotKey.pin.defaultKey)
    // 恢复默认之后：拷贝改了一个新键（拷的时候是默认），裁剪又录了一个（拷的时候是清除了）
    let copyKey = HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey)
    let cropKey = HotKey(keyCode: kVK_ANSI_J, modifiers: 0)
    ShotKey.copy.set(copyKey, in: defaults)
    ShotKey.crop.set(cropKey, in: defaults)
    ShotKey.restore(before, in: defaults)
    #expect(ShotKey.pin.key(in: defaults) == pin)
    #expect(ShotKey.crop.key(in: defaults) == cropKey)
    #expect(ShotKey.copy.key(in: defaults) == copyKey)
    // 没被后来改过的：清除了的放回成清除了
    for key in ShotKey.allCases { key.set(key.defaultKey, in: defaults) }
    ShotKey.restore(before, in: defaults)
    #expect(ShotKey.crop.key(in: defaults) == nil)
    #expect(Set(ShotKey.snapshot(in: defaults).keys) == [.pin, .crop])
  }

  /// 装没成的原因（E10）：断网、服务器不是 200、校验值对不上 = 网络（给重试）；没空间（错误链上哪一层说的都算）、写不了临时文件 /
  /// 解不开包时磁盘快满了 = 磁盘满；签名没过、包不对、解不开（空间够）= 别的（给发布页）
  @Test func updateFailuresAreClassified() {
    let kind = { (error: Error, low: Bool) in Updater.failureKind(error, lowOnSpace: low) }
    #expect(kind(URLError(.notConnectedToInternet), false) == .network)
    #expect(kind(URLError(.timedOut), true) == .network)
    #expect(kind(URLError(.cannotWriteToFile), true) == .diskFull)
    #expect(kind(URLError(.cannotWriteToFile), false) == .network)
    #expect(kind(UpdateError("下载失败（\(503)）", kind: .network), true) == .network)
    #expect(kind(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), false) == .diskFull)
    #expect(kind(CocoaError(.fileWriteOutOfSpace), false) == .diskFull)
    let wrapped = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
    #expect(kind(wrapped, false) == .diskFull)
    #expect(kind(UpdateError("更新包解不开", kind: .unpack), true) == .diskFull)
    #expect(kind(UpdateError("更新包解不开", kind: .unpack), false) == .other)
    #expect(kind(UpdateError("更新包的签名校验没通过"), true) == .other)
    #expect(kind(CocoaError(.fileWriteNoPermission), false) == .other)
  }

  /// 换不了 App 的判断（E10）：被系统挪到临时位置的、只读卷上的、文件夹写不进去的；能写的文件夹里的能换
  @Test func replaceObstacles() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-test-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: folder)
    }
    let app = folder.appending(path: "Kitty Tools.app")
    #expect(Updater.obstacle(app) == nil)
    let translocated = URL(
      filePath: "/private/var/folders/x/AppTranslocation/0000/d/Kitty Tools.app")
    #expect(Updater.obstacle(translocated) == .notInstalled)
    // 系统卷上的（只读、写不进去）也换不了
    #expect(Updater.obstacle(URL(filePath: "/System/Applications/Calculator.app")) != nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    #expect(Updater.obstacle(app) == .noPermission)
    #expect(throws: UpdateError.self) { try Updater.checkReplaceable(app) }
  }
}
