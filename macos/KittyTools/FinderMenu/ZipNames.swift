// zip 文件名的编码判断（访达右键「解压到这里」，2026-11-08 右键扩充拍板 D2；从 Kitty Box 的 Archive/ZipNames.swift 搬来，同一个作者、
// 同为 MIT，Kitty Box 已不再开发）：自己读中央目录，看每个条目的 UTF-8 标志和名字字节，告诉 tar 按哪种编码解
// （`--options hdrcharset=`）。Windows 打的 zip 名字多半是 GBK、又不标 UTF-8；访达 / ditto 打的写的是 UTF-8 却也不标
// （实测），所以不能一律当 GBK：没标志、字节又不是合法 UTF-8 的，才按 GB18030（GBK 的超集）解。顺带看有没有加密的条目（先问密码）。

import Foundation

nonisolated enum ZipNames {
  enum Charset: String {
    case utf8 = "UTF-8"
    case gb18030 = "GB18030"
  }

  struct Entry {
    var name: Data
    var utf8Flag: Bool
    /// 标志位第 0 位：这一条加了密（ZipCrypto 或 AES）
    var encrypted = false
    /// 解开后多大；ZIP64 的大条目（记成 0xFFFFFFFF）不另读，是 nil
    var size: UInt64?
  }

  /// 条目的名字按什么编码读成字：标了 UTF-8 的按 UTF-8，其余按整包判断出的编码（「看看里面」用）
  static func name(of entry: Entry, charset: Charset) -> String {
    let gb18030 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let encoding: String.Encoding = entry.utf8Flag || charset == .utf8 ? .utf8 : gb18030
    return String(data: entry.name, encoding: encoding)
      ?? String(decoding: entry.name, as: UTF8.self)
  }

  /// 是不是 zip：开头是本地文件头 PK\3\4，空包是结尾记录 PK\5\6
  static func isZip(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = [UInt8](handle.readData(ofLength: 4))
    return head == [0x50, 0x4B, 0x03, 0x04] || head == [0x50, 0x4B, 0x05, 0x06]
  }

  /// 读不出（不是 zip、坏了）时是 nil，调用方按 UTF-8 解
  static func charset(of url: URL) -> Charset? {
    entries(of: url).map(charset(for:))
  }

  /// ponytail: 一个包里既有没标志的 UTF-8 名字、又有 GBK 名字时整包按 GB18030，前者会乱码；日文 Shift-JIS 的包
  /// 也会被当成 GB18030。真遇到了再逐条判断、或加日文检测
  static func charset(for entries: [Entry]) -> Charset {
    var legacy = false
    for entry in entries where !entry.utf8Flag {
      if String(data: entry.name, encoding: .utf8) != nil { continue }
      guard String(data: entry.name, encoding: gb18030) != nil else { return .utf8 }
      legacy = true
    }
    return legacy ? .gb18030 : .utf8
  }

  private static let gb18030 = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

  // MARK: 读中央目录

  /// 结尾记录在文件最后 22 + 注释（最长 65535）字节里；它前面 20 字节可能是 ZIP64 的定位记录
  private static let tailLength = 22 + 65_535 + 20

  static func entries(of url: URL) -> [Entry]? {
    guard let handle = try? FileHandle(forReadingFrom: url),
      let size = try? handle.seekToEnd()
    else { return nil }
    defer { try? handle.close() }
    let tailStart = size > UInt64(tailLength) ? size - UInt64(tailLength) : 0
    guard (try? handle.seek(toOffset: tailStart)) != nil,
      let tail = try? handle.readToEnd().map([UInt8].init),
      let end = lastIndex(of: 0x0605_4B50, in: tail)
    else { return nil }

    var count = UInt64(tail.u16(end + 10))
    var cdSize = UInt64(tail.u32(end + 12))
    var cdOffset = UInt64(tail.u32(end + 16))
    // ZIP64：真值在 ZIP64 结尾记录里，定位记录紧挨着普通结尾记录前面
    if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
      guard end >= 20, tail.u32(end - 20) == 0x0706_4B50,
        (try? handle.seek(toOffset: tail.u64(end - 20 + 8))) != nil,
        let record = try? handle.read(upToCount: 56).map([UInt8].init), record.count == 56,
        record.u32(0) == 0x0606_4B50
      else { return nil }
      count = record.u64(32)
      cdSize = record.u64(40)
      cdOffset = record.u64(48)
    }
    if count == 0 { return [] }
    // 不把两个数加起来比：ZIP64 里是文件自己写的 64 位数，坏包、恶意包加起来会溢出、整个 App 崩掉。
    // 中央目录最多读 64 MB（一条至少 46 字节，够一百多万条）：坏包把它写成整个文件那么大时，不在主线程上把几 GB 读进内存
    guard cdSize <= min(size, 64 << 20), cdOffset <= size - cdSize,
      (try? handle.seek(toOffset: cdOffset)) != nil,
      let directory = try? handle.read(upToCount: Int(cdSize)).map([UInt8].init)
    else { return nil }
    return parse(directory, count: count)
  }

  /// 中央目录里一条一条的文件头（PK\1\2）：+8 标志位（第 0 位加密，第 11 位是 UTF-8），+24 解开后的大小，+28 / +30 / +32 名字、扩展、注释长度，+46 起是名字
  static func parse(_ directory: [UInt8], count: UInt64) -> [Entry]? {
    var entries: [Entry] = []
    var offset = 0
    while entries.count < count {
      guard offset + 46 <= directory.count, directory.u32(offset) == 0x0201_4B50 else { return nil }
      let nameLength = directory.u16(offset + 28)
      let skip = 46 + nameLength + directory.u16(offset + 30) + directory.u16(offset + 32)
      guard offset + skip <= directory.count else { return nil }
      entries.append(
        Entry(
          name: Data(directory[offset + 46..<offset + 46 + nameLength]),
          utf8Flag: directory.u16(offset + 8) & 0x0800 != 0,
          encrypted: directory.u16(offset + 8) & 0x0001 != 0,
          size: directory.u32(offset + 24) == 0xFFFF_FFFF
            ? nil : UInt64(directory.u32(offset + 24))))
      offset += skip
    }
    return entries
  }

  private static func lastIndex(of signature: UInt32, in bytes: [UInt8]) -> Int? {
    guard bytes.count >= 22 else { return nil }
    return stride(from: bytes.count - 22, through: 0, by: -1).first { bytes.u32($0) == signature }
  }
}

extension [UInt8] {
  /// 小端整数
  nonisolated fileprivate func u16(_ at: Int) -> Int { Int(self[at]) | Int(self[at + 1]) << 8 }
  nonisolated fileprivate func u32(_ at: Int) -> UInt32 {
    UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
  }
  nonisolated fileprivate func u64(_ at: Int) -> UInt64 {
    UInt64(u32(at)) | UInt64(u32(at + 4)) << 32
  }
}
