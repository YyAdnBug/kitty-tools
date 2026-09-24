// ClipboardFilter 单测：敏感文本（含旧版两处 bug 的回归）、卡号、排除 App。

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

  @Test func excludedApps() {
    let excluded = ["1Password", " keychain ", "", "com.apple.Passwords"]
    #expect(ClipboardFilter.isExcluded(appName: "1Password 8", bundleID: nil, excluded: excluded))
    #expect(
      ClipboardFilter.isExcluded(appName: "Keychain Access", bundleID: nil, excluded: excluded))
    #expect(
      ClipboardFilter.isExcluded(appName: "密码", bundleID: "com.apple.Passwords", excluded: excluded)
    )
    #expect(
      !ClipboardFilter.isExcluded(
        appName: "Safari", bundleID: "com.apple.Safari", excluded: excluded))
    #expect(!ClipboardFilter.isExcluded(appName: nil, bundleID: nil, excluded: excluded))
  }
}
