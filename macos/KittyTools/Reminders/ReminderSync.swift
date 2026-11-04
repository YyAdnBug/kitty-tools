// 提醒列表接进全局同步（PLAN §10「提醒」E3；SyncSource，规则在 Storage/SyncRecords.swift）：同状态屏的状态
// （StatusPresetSync）——**一条提醒一条记录**（编号 = Reminder.id；三条示例每台都是同一个编号），顺序单独一条
// （SyncRecords.orderID）。第一次合并在一起（标题和时间规则都一样的只留一条）。列表存在偏好里（没存过 = 示例），账本也在偏好里
// （SyncLedger），先写列表再存账本；偏好里的列表读不出来时这一类先不合。落之前收拾一遍（Reminder.sanitized：最多 50 条……），
// 收拾掉的下一轮当本机删了传出去（ponytail: 两台同时加满超过 50 条会删掉多出来的，真碰到再把上限放宽）。
// 只同步列表：每条处理到哪一刻、推到几点、暂停到几点是这台电脑自己的（Prefs.remindersState）。两台都开着时两台都响，
// 「知道了」各管各的；一次性的点了「知道了」会从列表里删掉，删除同步过去，另一台下一轮跟着收（执行层看着偏好变化）。

import Foundation

@MainActor final class ReminderSync: SyncSource {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var syncKind: SyncRecords.Kind { .reminders }

  /// 第一次合：标题和时间规则都一样的算同一条
  var syncJoin: SyncRecords.Join {
    .union { value in
      guard let reminder = try? JSONDecoder().decode(Reminder.self, from: Data(value.utf8)),
        let schedule = try? SyncRecords.encoder.encode(reminder.schedule)
      else { return nil }
      return reminder.title + "\n" + String(decoding: schedule, as: UTF8.self)
    }
  }

  /// 偏好里有列表、却解不出来（不是 JSON 数组）
  var syncBusy: Bool {
    guard let data = defaults.data(forKey: Prefs.reminders) else { return false }
    return (try? JSONSerialization.jsonObject(with: data) as? [Any]) == nil
  }

  /// 偏好里存着的列表；没存过就是空的（不是示例：没碰过提醒的那台不该把三条示例当成自己的交出去，
  /// 别处删掉的示例也不会这样被送回来）
  private var stored: [Reminder] {
    defaults.data(forKey: Prefs.reminders) == nil ? [] : Reminder.load(defaults)
  }

  func syncValues() -> [String: String] {
    let reminders = stored
    var values = [SyncRecords.orderID: SyncRecords.orderValue(reminders.map(\.id))]
    for reminder in reminders {
      if let data = try? SyncRecords.encoder.encode(reminder) {
        values[reminder.id] = String(decoding: data, as: UTF8.self)
      }
    }
    return values
  }

  func syncLedger(library: String) throws -> SyncRecords.Ledger? {
    try SyncLedger.load(.reminders, library: library, in: defaults)
  }

  /// 落合并结果：改了的换掉、新来的加上、别处删了的拿掉，按顺序那条排；有一条解不出来（或者是更新版本写的）整个不落
  func applySync(_ changes: [String: String?], ledger: SyncRecords.Ledger, library: String)
    -> SyncApplied
  {
    let current = stored
    var reminders = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var order = current.map(\.id)
    for (id, value) in changes {
      if id == SyncRecords.orderID {
        guard let value else { continue }
        guard let ids = SyncRecords.decodeExact([String].self, from: value) else { return .newer }
        order = ids
        continue
      }
      guard let value else {
        reminders[id] = nil
        continue
      }
      guard let reminder = SyncRecords.decodeExact(Reminder.self, from: value), reminder.id == id
      else { return .newer }
      reminders[id] = reminder
    }
    let list = SyncRecords.arranged(reminders.keys, by: order).compactMap { reminders[$0] }
    Reminder.save(list, to: defaults)
    do {
      try SyncLedger.save(ledger, kind: .reminders, library: library, in: defaults)
    } catch {
      return .failed
    }
    return .saved
  }
}
