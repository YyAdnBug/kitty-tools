// 启动器的「ip」（2026-10-28 用户要的；对标 Raycast / Alfred 常见的 My IP）：输入 ip（或「ip 地址」「内网 ip」这类）
// 排在最前面列本机地址和外网地址，↩ 粘贴、⌘↩ 只复制（同计算结果）。
// 本机：每块联网的网卡一个 IPv4 一行（getifaddrs；回环、169.254 自分配的、代理 TUN 的 198.18 假地址不列），默认路由走的那块排第一；
// VPN 的 utun / ipsec / ppp 写「内网」，其余写「局域网」，网卡名用 系统设置 › 网络 里的叫法（Wi-Fi、以太网，SystemConfiguration）。
// 外网：本机不知道，要问查询服务。问两家——国内的 myip.ipip.net、国外的 api.ipify.org：开着代理时国内网站直连、国外网站走代理，
// 两家看到的常常不一样（2026-10-28 本机实测就是两个），一样就一行「外网」，不一样各一行写清是访问哪边时的。
// 输到 ip 等 0.3 s 再问（打「iphone」路过 ip 时不发请求），这次呼出里查到的不再问，没查到的再输一次 ip 时重查（LauncherModel）。
// 这里只有读网卡、联网查和拼行（纯函数配单测）。

import Foundation
import SystemConfiguration

enum IPAddresses {
  /// 一块网卡上的一个 IPv4 地址
  struct Local: Equatable {
    let interface: String
    let address: String
  }

  /// 外网地址问谁：国内的（直连）和国外的（开着代理时是代理的出口）
  nonisolated enum Service: CaseIterable, Sendable {
    case domestic, overseas

    var url: URL {
      switch self {
      case .domestic: URL(string: "https://myip.ipip.net/s")!
      case .overseas: URL(string: "https://api.ipify.org")!
      }
    }
  }

  /// 一家查询服务的结果
  enum Lookup: Equatable {
    case pending
    case found(String)
    case failed
  }

  /// 输到 ip 之后等多久才联网查
  static let lookupDelay = Duration.milliseconds(300)

  /// 「ip」「IP 地址」「内网ip」…（不分大小写和空格）
  static func matches(_ query: String) -> Bool {
    keywords.contains(LauncherMatch.fold(query).filter { !$0.isWhitespace })
  }

  private static let keywords: Set<String> = ["ip", "ip地址", "本机ip", "局域网ip", "内网ip", "外网ip"]

  // MARK: 本机

  /// 本机这一刻的几行（读网卡、问系统的网卡名，几毫秒）
  static func localItems() -> [LauncherItem] {
    localItems(local(), primary: primaryInterface(), names: displayNames())
  }

  /// 默认路由走的网卡排第一，其余按网卡顺序；一个都没有时一行「没有连上网络」（不能粘贴）
  static func localItems(_ addresses: [Local], primary: String?, names: [String: String])
    -> [LauncherItem]
  {
    guard !addresses.isEmpty else {
      return [LauncherItem(kind: .ip, target: "lan", title: "局域网 IP", subtitle: "没有连上网络")]
    }
    let sorted =
      addresses.filter { $0.interface == primary } + addresses.filter { $0.interface != primary }
    return sorted.map { local in
      let vpn = isVPN(local.interface)
      let name =
        names[local.interface].map { "\($0)（\(local.interface)）" }
        ?? (vpn ? "VPN（\(local.interface)）" : local.interface)
      return LauncherItem(
        kind: .ip, target: local.interface + " " + local.address, title: local.address,
        subtitle: (vpn ? "内网" : "局域网") + " · " + name, payload: local.address)
    }
  }

  /// VPN 的网卡（这上面的地址写「内网」）；行的目标以网卡名开头，图标也按它取
  static func isVPN(_ interface: String) -> Bool {
    ["utun", "ipsec", "ppp"].contains { interface.hasPrefix($0) }
  }

  /// 开着的网卡上的 IPv4（不含回环、169.254 自分配的、198.18 假地址），按 getifaddrs 的顺序
  private static func local() -> [Local] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return [] }
    defer { freeifaddrs(head) }
    var found: [Local] = []
    for pointer in sequence(first: head, next: { $0.pointee.ifa_next }) {
      let entry = pointer.pointee
      guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
        entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
      else { continue }
      // s_addr 是网络字节序：内存里的四个字节就是点分的四段
      let bytes = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        withUnsafeBytes(of: $0.pointee.sin_addr.s_addr, Array.init)
      }
      // 169.254 是没拿到地址时自分配的；198.18 / 198.19 是代理软件 TUN 模式的假地址（utun 上，2026-10-28 本机实测），
      // 都不是能给别人用的地址
      guard bytes.prefix(2) != [169, 254], !(bytes[0] == 198 && bytes[1] & 0xFE == 18) else {
        continue
      }
      found.append(
        Local(
          interface: String(cString: entry.ifa_name),
          address: bytes.map(String.init).joined(separator: ".")))
    }
    return found
  }

  /// 默认路由走的网卡（BSD 名，如 en0）
  private static func primaryInterface() -> String? {
    let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString)
    return (global as? [String: Any])?["PrimaryInterface"] as? String
  }

  /// BSD 名 → 系统设置 › 网络 里的名字（Wi-Fi、以太网、Thunderbolt 网桥）；VPN 的 utun 不在里面
  private static func displayNames() -> [String: String] {
    let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
    return interfaces.reduce(into: [:]) { names, interface in
      guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
        let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
      else { return }
      names[bsd] = name
    }
  }

  // MARK: 外网

  /// 两家的结果拼成的行：查到的地址一样（或只查到一家）一行「外网」，不一样各一行；都没查到时一行占位（不能粘贴）
  static func publicItems(_ lookups: [Service: Lookup]) -> [LauncherItem] {
    let found = Service.allCases.compactMap { service -> (Service, String)? in
      guard case .found(let address) = lookups[service] else { return nil }
      return (service, address)
    }
    if Set(found.map(\.1)).count > 1 {
      return found.map { service, address in
        LauncherItem(
          kind: .ip, target: service == .domestic ? "public" : "public-overseas", title: address,
          subtitle: service == .domestic ? "外网 · 访问国内网站时" : "外网 · 访问国外网站时",
          payload: address)
      }
    }
    if let address = found.first?.1 {
      return [
        LauncherItem(kind: .ip, target: "public", title: address, subtitle: "外网", payload: address)
      ]
    }
    let pending = lookups.values.contains(.pending)
    return [
      LauncherItem(
        kind: .ip, target: "public", title: "外网 IP",
        subtitle: pending ? "正在查询…" : "没查到：没有联网，或查询超时")
    ]
  }

  /// 问一家：5 秒没回、不是 200、回的不是一个 IPv4（被劫持到登录页这类）都算没查到
  nonisolated static func lookUp(_ service: Service) async -> String? {
    let request = URLRequest(
      url: service.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return address(in: String(decoding: data, as: UTF8.self))
  }

  /// 查询服务回的一行纯文本里的 IPv4
  nonisolated static func address(in text: String) -> String? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = text.wholeMatch(of: /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/),
      [match.1, match.2, match.3, match.4].allSatisfy({ UInt8($0) != nil })
    else { return nil }
    return text
  }
}
