// 翻译服务列表接进全局同步（PLAN §10「全局同步」B8；SyncSource，规则在 Storage/SyncRecords.swift）：一个服务一个记录（编号 =
// TranslateService.id：内置的每台都是同一个——第一次合时跟着文件夹里已有的，同设置；自建的 AI 服务是 "ai:<8 位>"），内容是
// 它的配置（名字、启用、模型、地址、协议、区域……）；顺序单独一条（SyncRecords.orderID）。**密钥不同步**（只在钥匙串里）：
// 别的 Mac 上来的服务显示「未填密钥」，自己填一次（启用着的翻译时那张卡说缺密钥，替用户定的：照常提示，不悄悄跳过）。
// 第一次合时同协议、同地址、同模型的自建 AI 服务只留文件夹里那个，**本机那个的密钥搬给它**（它在本机还没有密钥时）。
// 别处删了的服务这台只拿出列表、**不删钥匙串里的密钥**（自建的 AI 服务被别处删了又加回来，密钥还在；ponytail: 永远不再
// 加回来的会在钥匙串里留一条，要清再加）。账本在偏好里（SyncLedger），先换列表再存账本；偏好里的列表读不出来时这一类先不合。

import Foundation

@MainActor final class TranslateServiceSync: SyncSource {
  private let store: TranslateServiceStore
  private let defaults: UserDefaults

  init(store: TranslateServiceStore, defaults: UserDefaults = .standard) {
    self.store = store
    self.defaults = defaults
  }

  var syncKind: SyncRecords.Kind { .services }

  var syncJoin: SyncRecords.Join {
    .union { value in
      (try? JSONDecoder().decode(TranslateService.self, from: Data(value.utf8))).flatMap(
        Self.joinKey)
    }
  }

  /// 第一次合时认「同一个自建 AI 服务」：协议、地址、模型一样
  private nonisolated static func joinKey(_ service: TranslateService) -> String? {
    guard service.kind == .ai else { return nil }
    return [service.aiProtocol?.rawValue ?? "", service.baseURL ?? "", service.model ?? ""]
      .joined(separator: "\u{0}")
  }

  /// 偏好里有列表、却解不出来（TranslateServiceStore 这时用的是默认列表）
  var syncBusy: Bool {
    guard let data = defaults.data(forKey: TranslateServiceStore.key) else { return false }
    return (try? JSONDecoder().decode([TranslateService].self, from: data)) == nil
  }

  func syncValues() -> [String: String] {
    var values: [String: String] = [
      SyncRecords.orderID: SyncRecords.orderValue(store.services.map(\.id))
    ]
    for service in store.services {
      if let data = try? SyncRecords.encoder.encode(service) {
        values[service.id] = String(decoding: data, as: UTF8.self)
      }
    }
    return values
  }

  func syncLedger(library: String) throws -> SyncRecords.Ledger? {
    try SyncLedger.load(.services, library: library, in: defaults)
  }

  /// 落合并结果：改了的换掉、新来的加上、别处删了的拿出列表（密钥留着），按顺序那条排；有一条解不出来（或者是更新版本写的）
  /// 整个不落
  func applySync(_ changes: [String: String?], ledger: SyncRecords.Ledger, library: String)
    -> SyncApplied
  {
    let before = Dictionary(store.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var services = before
    var order = store.services.map(\.id)
    for (id, value) in changes {
      if id == SyncRecords.orderID {
        guard let value else { continue }
        guard let ids = SyncRecords.decodeExact([String].self, from: value) else { return .newer }
        order = ids
        continue
      }
      guard let value else {
        services[id] = nil
        continue
      }
      guard let service = SyncRecords.decodeExact(TranslateService.self, from: value),
        service.id == id
      else { return .newer }
      services[id] = service
    }
    // 第一次合时被去重掉的本机 AI 服务：密钥搬给留下的那个（它在本机还没有密钥时）
    for (id, old) in before where services[id] == nil {
      guard let key = Self.joinKey(old),
        let kept = services.values.first(where: { $0.id != id && Self.joinKey($0) == key })
      else { continue }
      for field in old.secretFields where kept.secret(field.name) == nil {
        if let secret = old.secret(field.name) { kept.setSecret(secret, field.name) }
      }
    }
    store.services = SyncRecords.arranged(services.keys, by: order).compactMap { services[$0] }
    do {
      try SyncLedger.save(ledger, kind: .services, library: library, in: defaults)
    } catch {
      return .failed
    }
    return .saved
  }
}
