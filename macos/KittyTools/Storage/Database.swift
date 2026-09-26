// SQLite 单连接封装（系统 libsqlite3，WAL 模式）。全部在主线程执行：每次只写一行，远小于 1ms（PLAN §4）。
// 和 sqlite3 C API 打交道的代码只在这里，调用方只见 Swift 值。

import Foundation
import SQLite3

final class Database {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// 查询结果的一行；列号从 0 开始
  struct Row {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64? {
      sqlite3_column_type(statement, column) == SQLITE_NULL
        ? nil : sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double? {
      sqlite3_column_type(statement, column) == SQLITE_NULL
        ? nil : sqlite3_column_double(statement, column)
    }

    func text(_ column: Int32) -> String? {
      guard let pointer = sqlite3_column_text(statement, column) else { return nil }
      return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data? {
      guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
      return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
  }

  private var handle: OpaquePointer?

  /// path 传 ":memory:" 得到内存库（单测用）
  init(path: String) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
      throw Failure(description: "打开数据库失败：\(path)")
    }
    sqlite3_busy_timeout(handle, 2000)
    try execute("PRAGMA journal_mode = WAL")
  }

  /// 执行一条不关心结果行的语句
  func execute(_ sql: String, _ arguments: [Any?] = []) throws {
    _ = try query(sql, arguments) { _ in () }
  }

  func query<T>(_ sql: String, _ arguments: [Any?] = [], row map: (Row) -> T) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure(sql)
    }
    defer { sqlite3_finalize(statement) }
    try bind(arguments, to: statement, sql: sql)
    var rows: [T] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: rows.append(map(Row(statement: statement)))
      case SQLITE_DONE: return rows
      default: throw failure(sql)
      }
    }
  }

  /// body 抛错则整体回滚
  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func bind(_ arguments: [Any?], to statement: OpaquePointer, sql: String) throws {
    // SQLITE_TRANSIENT：让 sqlite 自己拷一份，Swift 临时缓冲随后释放也没事
    let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    for (offset, argument) in arguments.enumerated() {
      let index = Int32(offset + 1)
      let status: Int32
      switch argument {
      case nil: status = sqlite3_bind_null(statement, index)
      case let value as Bool: status = sqlite3_bind_int64(statement, index, value ? 1 : 0)
      case let value as Int: status = sqlite3_bind_int64(statement, index, Int64(value))
      case let value as Int64: status = sqlite3_bind_int64(statement, index, value)
      case let value as Double: status = sqlite3_bind_double(statement, index, value)
      case let value as String: status = sqlite3_bind_text(statement, index, value, -1, transient)
      case let value as Data:
        status = value.withUnsafeBytes {
          sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
        }
      default: throw Failure(description: "不支持的参数类型 \(type(of: argument!))：\(sql)")
      }
      guard status == SQLITE_OK else { throw failure(sql) }
    }
  }

  private func failure(_ sql: String) -> Failure {
    Failure(description: "\(String(cString: sqlite3_errmsg(handle)))：\(sql)")
  }
}
