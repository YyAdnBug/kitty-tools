// 状态屏的状态列表接进全局同步（PLAN §10「全局同步」；SyncSource，规则在 Storage/SyncRecords.swift）：状态是用户自己写的东西，
// **一个状态一条**（编号 = StatusPreset.id；自带的三个每台都是同一个编号），顺序单独一条（SyncRecords.orderID）——整张一条的话
// 第一次合会把这台写的抹掉、两台同时各加一个会丢一个（评审）。第一次合并在一起（标题一样的只留文件夹里那个）。列表存在偏好里
// （没存过 = 自带的三个），账本也在偏好里（SyncLedger），先写列表再存账本；偏好里的列表读不出来时这一类先不合。落之前收拾一遍
// （StatusPreset.sanitized：标题长度、最多 20 个……），收拾掉的下一轮当本机删了传出去（ponytail: 两台同时加满超过 20 个会删掉
// 多出来的，真碰到再把上限放宽）。

import Foundation

@MainActor final class StatusPresetSync: SyncSource {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var syncKind: SyncRecords.Kind { .statuses }

  var syncJoin: SyncRecords.Join {
    .union { value in
      (try? JSONDecoder().decode(StatusPreset.self, from: Data(value.utf8))).map(\.title)
    }
  }

  /// 偏好里有列表、却解不出来
  var syncBusy: Bool {
    guard let data = defaults.data(forKey: Prefs.statusScreenPresets) else { return false }
    return (try? JSONDecoder().decode([StatusPreset].self, from: data)) == nil
  }

  func syncValues() -> [String: String] {
    let presets = StatusPreset.load(defaults)
    var values = [SyncRecords.orderID: SyncRecords.orderValue(presets.map(\.id))]
    for preset in presets {
      if let data = try? SyncRecords.encoder.encode(preset) {
        values[preset.id] = String(decoding: data, as: UTF8.self)
      }
    }
    return values
  }

  func syncLedger(library: String) throws -> SyncRecords.Ledger? {
    try SyncLedger.load(.statuses, library: library, in: defaults)
  }

  /// 落合并结果：改了的换掉、新来的加上、别处删了的拿掉，按顺序那条排；有一条解不出来（或者是更新版本写的）整个不落
  func applySync(_ changes: [String: String?], ledger: SyncRecords.Ledger, library: String)
    -> SyncApplied
  {
    let current = StatusPreset.load(defaults)
    var presets = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var order = current.map(\.id)
    for (id, value) in changes {
      if id == SyncRecords.orderID {
        guard let value else { continue }
        guard let ids = SyncRecords.decodeExact([String].self, from: value) else { return .newer }
        order = ids
        continue
      }
      guard let value else {
        presets[id] = nil
        continue
      }
      guard let preset = SyncRecords.decodeExact(StatusPreset.self, from: value), preset.id == id
      else { return .newer }
      presets[id] = preset
    }
    let list = SyncRecords.arranged(presets.keys, by: order).compactMap { presets[$0] }
    StatusPreset.save(list, to: defaults)
    do {
      try SyncLedger.save(ledger, kind: .statuses, library: library, in: defaults)
    } catch {
      return .failed
    }
    return .saved
  }
}
