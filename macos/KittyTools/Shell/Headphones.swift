// 耳机的电量和图标（2026-11-14，刘海岛「耳机连上」的提示带电量；用户：「做，带电量」）。
// 电量从系统自带的 `system_profiler SPBluetoothDataType -json` 读：连着的蓝牙设备那一段里有 device_batteryLevelLeft /
// Right / Case / Main（写成「85%」）。公开的命令行工具、进程外（Subprocess），**不要蓝牙授权、不用非公开接口**——
// 2026-11-14 在本机从我们自己的进程（强化运行时、没有蓝牙用途说明）起它：拿得到设备表、约 60 ms、不弹授权框
// （探针 macos/build/research/island-polish-2026-11-13/headphones/，不进仓库）。原来拍板 D1 说「要蓝牙授权和私有键」
// 是按 IOBluetooth 的私有键想的，用不着。
// 设备的名字、地址不进日志。输出按不可信输入对待：只认这几个键、百分比夹在 0…100。
// ponytail: 刚连上的那一下系统还没拿到电量（键不在）：调用方过一会儿再读一次；再没有就不显示电量

import Foundation

nonisolated enum Headphones {
  /// 一副耳机的电量（0…1）：左右耳各一个（AirPods 这类），或者整机一个；充电盒不算
  struct Battery: Equatable, Sendable {
    var left: Double?
    var right: Double?
    var main: Double?

    /// 显示的那一个数：两只耳朵取低的那只（先没电的那只说了算），只有一只就是它，否则整机的
    var level: Double? {
      switch (left, right) {
      case (let left?, let right?): min(left, right)
      case (let one?, nil), (nil, let one?): one
      default: main
      }
    }
  }

  /// 从 system_profiler 的 JSON 里找这副耳机的电量（纯函数）：先按蓝牙地址找，找不到按名字；没连着、没有电量是 nil
  static func battery(in json: Data, address: String?, name: String?) -> Battery? {
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
    else { return nil }
    let connected = controllers.flatMap { $0["device_connected"] as? [[String: Any]] ?? [] }
    var byName: [String: Any]?
    for entry in connected {
      for (title, value) in entry {
        guard let info = value as? [String: Any] else { continue }
        if let address, let theirs = info["device_address"] as? String,
          normalized(theirs) == normalized(address)
        {
          return battery(of: info)
        }
        if let name, title == name, byName == nil { byName = info }
      }
    }
    return byName.flatMap(battery(of:))
  }

  private static func battery(of info: [String: Any]) -> Battery? {
    let battery = Battery(
      left: percent(info["device_batteryLevelLeft"]),
      right: percent(info["device_batteryLevelRight"]),
      main: percent(info["device_batteryLevelMain"]))
    return battery.level == nil ? nil : battery
  }

  /// 「85%」→ 0.85；不是这个样子、超出 0…100 的不要
  static func percent(_ value: Any?) -> Double? {
    guard let text = value as? String, text.hasSuffix("%"), let number = Int(text.dropLast()),
      (0...100).contains(number)
    else { return nil }
    return Double(number) / 100
  }

  /// 蓝牙地址只留十六进制的字、转大写（两边的分隔符不一样：系统报告里是冒号，音频设备的编号里是短横）
  private static func normalized(_ address: String) -> String {
    address.uppercased().filter(\.isHexDigit)
  }

  /// 音频设备的编号（「AA-BB-CC-DD-EE-FF:output」这种）里的蓝牙地址；不是这个样子是 nil
  static func address(fromUID uid: String) -> String? {
    let head = uid.split(separator: ":").first.map(String.init) ?? uid
    let parts = head.split(separator: "-")
    guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) })
    else { return nil }
    return parts.joined(separator: ":").uppercased()
  }

  /// 照名字挑图标（系统符号，用 macOS 15 就有的那几个名字）
  static func symbol(named name: String?) -> String {
    let name = (name ?? "").lowercased()
    if name.contains("airpods max") { return "airpodsmax" }
    if name.contains("airpods pro") { return "airpodspro" }
    if name.contains("airpods") { return "airpods" }
    if name.contains("beats") { return "beats.headphones" }
    return "headphones"
  }

  /// 读这副耳机现在的电量（进程外，约 60 ms；读不到是 nil）
  @MainActor static func battery(address: String?, name: String?) async -> Battery? {
    guard
      let result = try? await Subprocess.run(
        "/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], captures: true,
        timeout: .seconds(5), quality: .utility, outputLimit: 1 << 20),
      result.status == 0
    else { return nil }
    return battery(in: Data(result.output.utf8), address: address, name: name)
  }
}
