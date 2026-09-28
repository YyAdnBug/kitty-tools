// ClipboardFilter 单测：敏感文本（含旧版两处 bug 的回归、固定前缀的常见密钥）、卡号、排除 App（bundle ID 精确匹配与旧列表迁移）；
// 采集时的隐私标记与来源判断（ClipboardWatcher）、旧偏好升级（Prefs.migrate）。

import AppKit
import Testing

@testable import KittyTools

struct ClipboardFilterTests {
  @Test func cardNumbers() {
    #expect(ClipboardFilter.looksSensitive("4111 1111 1111 1111"))  // Visa 公开测试号
    #expect(ClipboardFilter.looksSensitive("4111-1111-1111-1111"))
    #expect(!ClipboardFilter.looksSensitive("1234567890123456"))  // 不过 Luhn
    #expect(!ClipboardFilter.looksSensitive("order 4111111111111111"))  // 不是整段数字
    #expect(
      !ClipboardFilter.looksLikeCardNumber(String(repeating: "4111 1111 1111 1111 ", count: 10)))
  }

  @Test func apiKeys() {
    #expect(ClipboardFilter.looksSensitive("SK-ABCDEFGHIJ0123456789xyz"))
    // 旧版漏拦的现行格式
    #expect(ClipboardFilter.looksSensitive("sk-proj-Ab3dEf6hIj9kLmN0pQrStUvWx"))
    #expect(ClipboardFilter.looksSensitive("key: sk-ant-api03-AbC123dEf456GhI789jKl"))
    #expect(!ClipboardFilter.looksSensitive("sk-short1"))
    // 放行 - 之后不能误伤连字符英文（没有数字 / 前面不是词边界）
    #expect(!ClipboardFilter.looksSensitive("desk-organizer-product-description-long"))
    #expect(!ClipboardFilter.looksSensitive("task-2024-roadmap-planning-document-v2"))
  }

  @Test func bearerTokens() {
    #expect(ClipboardFilter.looksSensitive("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6"))
    #expect(!ClipboardFilter.looksSensitive("Bearer abc123"))
    // 旧版 bug：只要 bearer 后面整段够长就判敏感，一篇讲 bearer token 的文章会被整段丢弃
    #expect(
      !ClipboardFilter.looksSensitive(
        "OAuth uses a bearer token in the Authorization header; this paragraph explains why."))
  }

  @Test func ordinaryText() {
    #expect(!ClipboardFilter.looksSensitive("你好，世界"))
    #expect(!ClipboardFilter.looksSensitive(String(repeating: "中文剪贴板内容", count: 500)))
  }

  /// 固定前缀的密钥（体检 B5）：每种一条命中；文章里提到前缀、长度不够、前面不是词边界的不拦
  @Test func knownSecretFormats() {
    let hits = [
      "token: ghp_" + String(repeating: "a1B2", count: 9),
      "github_pat_" + String(repeating: "Ab3_", count: 16),
      "AKIAIOSFODNN7EXAMPLE",
      "xoxb-1234567890-abcdefghij",
      "AIza" + String(repeating: "Sy_-9", count: 7),
      "-----BEGIN RSA PRIVATE KEY-----\nMIIEow...",
      "-----BEGIN PRIVATE KEY-----",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
      "密钥ghp_" + String(repeating: "a1B2", count: 9),  // 中文紧挨着也算词边界
    ]
    for text in hits { #expect(ClipboardFilter.looksSensitive(text), "\(text)") }
    let misses = [
      "ghp_ 开头的 token 是 GitHub 的个人访问令牌",
      "ghp_short123",
      "xghp_" + String(repeating: "a1B2", count: 9),
      "AKIA 开头的是 AWS 的访问密钥",
      "xoxb-short",
      "BEGIN PRIVATE KEY 是私钥文件的开头",
      "eyJ 开头的一般是 JWT",
    ]
    for text in misses { #expect(!ClipboardFilter.looksSensitive(text), "\(text)") }
  }

  /// 大段文本（watcher 在主线程过滤，最多 5 MB）：只在字节上找确切前缀，不对全文跑正则。
  /// 1 MB 满是 gh / night / light 的英文不命中、也不慢；后面藏着一个 token 照样拦住
  @Test func largeTextStaysFast() {
    let prose = String(
      repeating: "The night light was high, though the thought of ghosts ghostly eyJ xox AKIA. ",
      count: 13_000)
    let clock = ContinuousClock()
    var sensitive = true
    let elapsed = clock.measure { sensitive = ClipboardFilter.looksSensitive(prose) }
    #expect(!sensitive)
    #expect(elapsed < .milliseconds(500), "\(elapsed)")
    #expect(ClipboardFilter.looksSensitive(prose + "ghp_" + String(repeating: "a1B2", count: 9)))
  }

  /// 排除 App 按 bundle ID 精确匹配（体检 A11）：填「Code」不会连 Xcode 一起排除
  @Test func excludedApps() {
    let excluded: Set = ["com.apple.Passwords", "Code"]
    #expect(ClipboardFilter.isExcluded(bundleID: "com.apple.Passwords", excluded: excluded))
    #expect(!ClipboardFilter.isExcluded(bundleID: "com.apple.dt.Xcode", excluded: excluded))
    #expect(!ClipboardFilter.isExcluded(bundleID: "com.microsoft.VSCode", excluded: excluded))
    #expect(!ClipboardFilter.isExcluded(bundleID: nil, excluded: excluded))
  }

  /// 旧的关键词列表：含「.」的留下，名称关键词丢掉，并上默认的密码管理器（不重复）
  @Test func migratesExcludedKeywords() {
    let migrated = ClipboardFilter.migratedExcluded([
      "1Password", "com.tinyspeck.slackmacgap", " com.apple.Passwords ", "钥匙串",
    ])
    #expect(migrated.first == "com.tinyspeck.slackmacgap")
    #expect(Set(migrated) == Set(ClipboardFilter.defaultExcluded + ["com.tinyspeck.slackmacgap"]))
    #expect(migrated.count == ClipboardFilter.defaultExcluded.count + 1)
  }

  /// 旧偏好升级：改过排除列表的只迁一次（之后删掉默认项不会被加回来）；保留天数不在新档位里的挪到下一档
  @Test func migratesPreferences() throws {
    let suite = "kitty-prefs-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["1Password", "com.example.secret"], forKey: Prefs.clipboardExcludedAppsLegacy)
    defaults.set(14, forKey: Prefs.clipboardRetentionDays)
    Prefs.migrate(defaults, domainName: suite)
    let migrated = defaults.stringArray(forKey: Prefs.clipboardExcludedBundleIDs) ?? []
    #expect(migrated.contains("com.example.secret") && migrated.contains("com.1password.1password"))
    #expect(defaults.object(forKey: Prefs.clipboardExcludedAppsLegacy) == nil)
    #expect(defaults.integer(forKey: Prefs.clipboardRetentionDays) == 30)
    defaults.set(["com.example.secret"], forKey: Prefs.clipboardExcludedBundleIDs)
    defaults.set(3, forKey: Prefs.clipboardRetentionDays)
    Prefs.migrate(defaults, domainName: suite)
    #expect(
      defaults.stringArray(forKey: Prefs.clipboardExcludedBundleIDs) == ["com.example.secret"])
    #expect(defaults.integer(forKey: Prefs.clipboardRetentionDays) == 7)
  }

  /// 隐私标记（体检 B4）：nspasteboard.org 的三种之外，1Password 7、TypeIt4Me、Keyboard Maestro、KeeWeb 等的也不记
  @Test func privateMarkers() {
    for type in [
      "org.nspasteboard.ConcealedType", "com.agilebits.onepassword", "Pasteboard generator type",
      "com.typeit4me.clipping", "de.petermaurer.TransientPasteboardType", "net.antelle.keeweb",
    ] {
      #expect(ClipboardWatcher.privateMarkers.contains(.init(type)), "\(type)")
    }
  }

  /// 来源（体检 B6）：通用剪贴板过来的是「其他设备」、没有 bundle ID；有来源标记用它（名字按 bundle ID 查，查不到用 ID）；
  /// 都没有才是前台 App
  @Test func clipSource() {
    let front = (name: String?("Xcode"), bundleID: String?("com.apple.dt.Xcode"))
    let names = ["com.apple.Safari": "Safari"]
    let source = { (remote: Bool, marker: String?) in
      ClipboardWatcher.source(remote: remote, marker: marker, frontmost: front) { names[$0] }
    }
    #expect(source(true, "com.apple.Safari") == ("其他设备", nil))
    #expect(source(false, "com.apple.Safari") == ("Safari", "com.apple.Safari"))
    #expect(source(false, "com.example.cli") == ("com.example.cli", "com.example.cli"))
    #expect(source(false, nil) == ("Xcode", "com.apple.dt.Xcode"))
    #expect(source(false, "") == ("Xcode", "com.apple.dt.Xcode"))
  }
}
