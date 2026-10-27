// 网页搜索与快捷链接接进全局同步（PLAN §10「全局同步」B7；SyncSource，规则在 Storage/SyncRecords.swift）：一条一个记录
// （编号 = SearchEngine.id；内置的几个每台都是同一个编号——第一次合时跟着文件夹里已有的，同设置），内容是名字、关键词、
// 网址、兜底；顺序单独一条（SyncRecords.orderID）。列表存在偏好里，账本也在偏好里（SyncLedger），先写列表再存账本。
// 第一次合时同网址、同关键词的只留文件夹里那条。偏好里的列表读不出来时这一类先不合（当成默认列表的话，账本里别的几条
// 全成了删除，删到每一台）。

import Foundation

@MainActor final class WebSearchSync: SyncSource {
  private nonisolated struct Synced: Codable {
    var name: String
    var keyword: String
    var url: String
    var fallback: Bool
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var syncKind: SyncRecords.Kind { .engines }

  var syncJoin: SyncRecords.Join {
    .union { value in
      (try? JSONDecoder().decode(Synced.self, from: Data(value.utf8))).map {
        $0.url + "\u{0}" + $0.keyword
      }
    }
  }

  /// 偏好里有列表、却解不出来
  var syncBusy: Bool {
    guard let data = defaults.data(forKey: Prefs.launcherWebSearchEngines) else { return false }
    return (try? JSONDecoder().decode([SearchEngine].self, from: data)) == nil
  }

  func syncValues() -> [String: String] {
    let engines = WebSearch.engines(in: defaults)
    var values: [String: String] = [SyncRecords.orderID: SyncRecords.orderValue(engines.map(\.id))]
    for engine in engines {
      let synced = Synced(
        name: engine.name, keyword: engine.keyword, url: engine.urlTemplate,
        fallback: engine.enabled)
      if let data = try? SyncRecords.encoder.encode(synced) {
        values[engine.id] = String(decoding: data, as: UTF8.self)
      }
    }
    return values
  }

  func syncLedger(library: String) throws -> SyncRecords.Ledger? {
    try SyncLedger.load(.engines, library: library, in: defaults)
  }

  /// 落合并结果：改了的换掉、新来的加上、别处删了的拿掉，按顺序那条排；有一条解不出来（或者是更新版本写的）整个不落
  func applySync(_ changes: [String: String?], ledger: SyncRecords.Ledger, library: String)
    -> SyncApplied
  {
    var engines = Dictionary(
      WebSearch.engines(in: defaults).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var order = WebSearch.engines(in: defaults).map(\.id)
    for (id, value) in changes {
      if id == SyncRecords.orderID {
        guard let value else { continue }
        guard let ids = SyncRecords.decodeExact([String].self, from: value) else { return .newer }
        order = ids
        continue
      }
      guard let value else {
        engines[id] = nil
        continue
      }
      guard let synced = SyncRecords.decodeExact(Synced.self, from: value) else { return .newer }
      engines[id] = SearchEngine(
        id: id, name: synced.name, keyword: synced.keyword, urlTemplate: synced.url,
        enabled: synced.fallback)
    }
    let list = SyncRecords.arranged(engines.keys, by: order).compactMap { engines[$0] }
    WebSearch.setEngines(list, in: defaults)
    do {
      try SyncLedger.save(ledger, kind: .engines, library: library, in: defaults)
    } catch {
      return .failed
    }
    return .saved
  }
}
