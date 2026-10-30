// SQLite 单连接封装（系统 libsqlite3，WAL 模式）。主连接全部在主线程执行：每次只写一行，远小于 1ms（PLAN §4）。
// 和 sqlite3 C API 打交道的代码只在这里，调用方只见 Swift 值。
// nonisolated：deinit 要关连接（默认 MainActor 的类，deinit 碰不到 OpaquePointer）；不是 Sendable，一个连接只在建它的地方用——
// 主连接在主线程，在主线程外的只有每日备份自己另开的只读连接（Backup.run、便签库的 NotesBackup.run，用完就关）。

import Foundation
import SQLite3

nonisolated final class Database {
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

  /// path 传 ":memory:" 得到内存库（单测用）。readOnly：只读打开（启动器读克隆出来的 Chromium 系浏览器的网站图标库；
  /// 每日备份另开的连接和检查备份文件，Backup；便签库的备份同样，NotesBackup），不建文件、不改日志模式。wal 传 false：可写但不改成 WAL
  /// （整理备份文件用：备份是单个文件，旁边不能留 -wal、-shm）。uri：path 按 SQLite 的 URI 认（启动台导入系统旧库的拷贝：
  /// `file:…?immutable=1` 只读打开，不改动拷贝、也不建 -wal / -shm）
  init(path: String, readOnly: Bool = false, wal: Bool = true, uri: Bool = false) throws {
    let flags =
      (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
      | (uri ? SQLITE_OPEN_URI : 0)
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
      // 打开失败也可能给了连接：关掉并置空，throw 之后 deinit 照样会跑，不能再关一次
      sqlite3_close(handle)
      handle = nil
      throw Failure(description: "打开数据库失败：\(path)")
    }
    sqlite3_busy_timeout(handle, 2000)
    guard !readOnly else { return }
    // 删掉的内容清零（第四轮体检 E5：删掉、清空、到期清理的正文和备注不留在库文件里）。用 ON 不用 FAST：FAST 只清
    // 页里的行，超过一页的长正文删掉后溢出页整页进空闲列表、原样留着（评审实测搜得到）；ON 连空闲页一起清，代价是删长行时
    // 多写一些盘。-wal 里写进来时的那几帧另外截掉（ClipboardStore.clearOrdinary）。macOS 27 的系统 sqlite 默认是 FAST
    try execute("PRAGMA secure_delete = ON")
    if wal { try execute("PRAGMA journal_mode = WAL") }
  }

  deinit { sqlite3_close(handle) }

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

  /// 库的页结构是不是好的（PRAGMA quick_check；坏库有的返回一串问题、有的直接报错，都算不好）。
  /// 实测 1.7 MB 的库不到 1 ms、49 MB 的约 10 ms
  func isIntact() -> Bool {
    (try? query("PRAGMA quick_check") { $0.text(0) }) == ["ok"]
  }

  /// 整库拷一份到 path（VACUUM INTO）：在一个读事务里重建出一个新文件，WAL 里还没合并的写入也在里面，是一致的快照
  /// （直接拷文件拿到的可能是写到一半的）；出来的文件不带 -wal / -shm。path 已经有文件时报错，不覆盖。
  /// 实测 1.7 MB 的库约 6 ms、49 MB 的约 83 ms（Backup.run 另开只读连接在主线程外做）
  func copy(to path: String) throws {
    try execute("VACUUM INTO ?", [path])
  }

  /// body 抛错则整体回滚。已经在事务里（外层开的）时用保存点嵌进去：抛错只退回这一段、错误照样往外抛，
  /// 外层接住就接着做（ClipboardStore.update 自己包一层事务，导入 adopt 又在它外面开了一层）
  func transaction(_ body: () throws -> Void) throws {
    let nested = sqlite3_get_autocommit(handle) == 0
    try execute(nested ? "SAVEPOINT nested" : "BEGIN IMMEDIATE")
    do {
      try body()
      if nested {
        try execute("RELEASE nested")
      } else {
        // body 里有语句出错被吞掉、SQLite 已经自动回滚了整个事务（之后的语句是一条条自动提交的）：别当成功
        guard sqlite3_get_autocommit(handle) == 0 else {
          throw Failure(description: "事务已被回滚")
        }
        try execute("COMMIT")
      }
    } catch {
      if nested {
        try? execute("ROLLBACK TO nested")
        try? execute("RELEASE nested")
      } else {
        try? execute("ROLLBACK")
      }
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
