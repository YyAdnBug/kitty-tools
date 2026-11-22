// 读写单个键盘服务的系统映射。用法编号在进入 AppKit 之前由 macOS 转换。

import Foundation
import IOKit.hidsystem

nonisolated struct RemapKeyboard: Codable, Equatable, Identifiable {
  let id: String
  let name: String
}

nonisolated struct RemapRule: Codable, Equatable, Identifiable {
  let source: UInt64
  let target: UInt64

  var id: UInt64 { source }
}

enum HIDKeyMapping {
  static let property = "UserKeyMapping" as CFString
  private static let sourceKey = "HIDKeyboardModifierMappingSrc"
  private static let targetKey = "HIDKeyboardModifierMappingDst"

  struct Service {
    let id: UInt64
    let keyboard: RemapKeyboard
    let handle: IOHIDServiceClient

    init?(_ handle: IOHIDServiceClient) {
      func get(_ key: String) -> CFTypeRef? {
        IOHIDServiceClientCopyProperty(handle, key as CFString)
      }
      guard IOHIDServiceClientConformsTo(handle, 1, 6) != 0,
        let vendor = get("VendorID") as? Int, let product = get("ProductID") as? Int,
        let registryID = IOHIDServiceClientGetRegistryID(handle) as? UInt64
      else { return nil }
      let transport = get("Transport") as? String ?? ""
      let serial = get("SerialNumber") as? String ?? ""
      let productName = get("Product") as? String ?? String(localized: "键盘")
      let name = transport.isEmpty ? productName : "\(productName) · \(transport)"
      id = registryID
      keyboard = RemapKeyboard(id: "\(vendor):\(product):\(transport):\(serial)", name: name)
      self.handle = handle
    }

    func read() throws -> [UInt64: UInt64] {
      guard let property = IOHIDServiceClientCopyProperty(handle, HIDKeyMapping.property) else {
        return [:]
      }
      guard let rows = property as? [[String: UInt64]] else { throw Failure.read }
      var rules: [UInt64: UInt64] = [:]
      for row in rows {
        guard let source = row[sourceKey], let target = row[targetKey],
          rules.updateValue(target, forKey: source) == nil
        else { throw Failure.read }
      }
      return rules
    }

    func write(_ rules: [UInt64: UInt64]) throws {
      let rows = rules.keys.sorted().map { source in
        [sourceKey: source, targetKey: rules[source]!]
      }
      guard IOHIDServiceClientSetProperty(handle, HIDKeyMapping.property, rows as CFArray),
        try read() == rules
      else { throw Failure.write }
    }
  }

  enum Failure: Error {
    case read
    case write
    case conflict(UInt64)
  }

  /// 只撤回本插件写入且目前仍相同的映射。其它来源写入的规则原样保留。
  /// 系统里已有、和规则一模一样的条目也算自己的（闪退、被强退后重开，上一次写的就是这样留下来的；不认的话移除插件撤不掉）。
  /// ponytail: 别的工具恰好写了同一条时，移除插件会连它一起撤掉；要分得清就得把写过的按服务记到磁盘上
  static func plan(
    current: [UInt64: UInt64], owned: [UInt64: UInt64], desired: [RemapRule]
  ) throws -> (mapping: [UInt64: UInt64], owned: [UInt64: UInt64]) {
    var mapping = current.filter { owned[$0.key] != $0.value }
    var claimed: [UInt64: UInt64] = [:]
    for rule in desired {
      if let existing = mapping[rule.source] {
        guard existing == rule.target else { throw Failure.conflict(rule.source) }
        claimed[rule.source] = rule.target
      } else {
        mapping[rule.source] = rule.target
        claimed[rule.source] = rule.target
      }
    }
    return (mapping, claimed)
  }
}
