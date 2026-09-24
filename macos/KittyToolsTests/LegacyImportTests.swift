// LegacyImport.plan 单测：旧配置字段 → 新偏好 / 钥匙串 / 服务列表（不碰真实偏好和钥匙串）。

import Foundation
import Testing

@testable import KittyTools

struct LegacyImportTests {
  private let config: [String: Any] = [
    "sourceLang": "auto", "targetLang": "zh-TW",
    "bidirectionalLangA": "zh-CN", "bidirectionalLangB": "ja",
    "autoCopy": true, "translateHistoryMax": 1000, "clipboardHistoryMax": 500,
    "clipboardExcludedApps": ["1Password"], "clipboardShortcut": "CommandOrControl+Shift+V",
    "translateServiceEnabled": ["builtin": false, "baidu": true],
    "translateServiceOrder": ["baidu", "ai:b", "builtin", "ai:a"],
    "zhipu": ["apiKey": "", "textModel": "glm-4.6v-flash"],
    "baidu": ["appId": "id1", "secret": "s1"],
    "youdao": ["appKey": "", "appSecret": ""],
    "aiServices": [
      [
        "id": "ai:a", "name": "", "protocol": "weird", "apiBaseUrl": "http://x", "apiKey": "k",
        "model": "m", "enabled": true,
      ],
      [
        "id": "ai:b", "name": "B", "protocol": "anthropic", "apiBaseUrl": "", "apiKey": "",
        "model": "c", "enabled": false,
      ],
      ["id": "bad", "name": "X"],
    ],
  ]

  @Test func preferencesAndLanguages() {
    let plan = LegacyImport.plan(from: config)
    #expect(plan.preferences[Prefs.translateSource] is NSNull)  // auto → 回到默认
    #expect(plan.preferences[Prefs.translateTarget] as? String == Lang.zhHant.rawValue)
    #expect(plan.preferences[Prefs.translateNative] as? String == Lang.zhHans.rawValue)
    #expect(plan.preferences[Prefs.translateForeign] as? String == Lang.ja.rawValue)
    #expect(plan.preferences[Prefs.translateAutoCopy] as? Bool == true)
    #expect(plan.preferences[Prefs.translateHistoryLimit] as? Int == 1000)
    #expect(
      // 不导热键
      plan.preferences.keys.contains { $0.localizedCaseInsensitiveContains("shortcut") } == false)
  }

  @Test func secretsSkipEmptyValues() {
    let plan = LegacyImport.plan(from: config)
    #expect(plan.secrets == ["baidu.appId": "id1", "baidu.secret": "s1", "ai:a.apiKey": "k"])
  }

  @Test func servicesFollowOldOrderAndNormalize() throws {
    let services = try #require(LegacyImport.plan(from: config).services)
    // 旧顺序在前（旧版的 builtin 就是智谱），没排过序的内置服务按名字补在后面；非法 id 丢弃
    #expect(Array(services.map(\.id).prefix(4)) == ["baidu", "ai:b", "zhipu", "ai:a"])
    #expect(services.count == 10)
    #expect(services[0].isEnabled && !services[2].isEnabled)
    #expect(services[1].aiProtocol == .anthropic && !services[1].isEnabled)
    #expect(services[2].model == "glm-4.6v-flash")
    #expect(services[3].name == "AI 服务" && services[3].aiProtocol == .openai)  // 空名、未知协议兜底
  }

  @Test func unknownConfigHasNoServices() {
    #expect(LegacyImport.plan(from: ["autoCopy": false]).services == nil)
  }
}
