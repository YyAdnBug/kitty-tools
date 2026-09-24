// 钥匙串（generic password，service = bundle id）：翻译服务的密钥只存这里，UserDefaults 和日志里不出现。
// 用文件型登录钥匙串：条目受 ACL 保护（绑定签名），不同步 iCloud；换签名身份后首次读取会弹一次确认。

import Foundation
import Security

nonisolated enum Keychain {
  private static let service = Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native"

  static func get(_ account: String) -> String? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 空值即删除
  static func set(_ value: String?, for account: String) {
    let query = baseQuery(account)
    guard let value, !value.isEmpty else {
      SecItemDelete(query as CFDictionary)
      return
    }
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      SecItemAdd(item as CFDictionary, nil)
    }
  }

  private static func baseQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
