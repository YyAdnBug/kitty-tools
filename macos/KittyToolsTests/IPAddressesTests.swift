// 启动器「ip」的单测（2026-10-28）：关键词、本机那几行的排序和叫法、两家外网结果拼成的行、查询服务回的文字，
// 以及模型里外网地址异步换行、打字路过 ip 时不联网。本机地址、外网查询都是注入的，不读网卡、不联网、不写剪贴板。

import Foundation
import Testing

@testable import KittyTools

struct IPAddressesTests {
  @Test func keywords() {
    for query in ["ip", "IP", " ip ", "IP 地址", "ip地址", "内网 IP", "外网ip"] {
      #expect(IPAddresses.matches(query), "\(query)")
    }
    for query in ["i", "ipa", "iphone", "ip 1", "ipconfig", ""] {
      #expect(!IPAddresses.matches(query), "\(query)")
    }
  }

  @Test func localRows() {
    let rows = IPAddresses.localItems(
      [
        .init(interface: "bridge100", address: "192.168.64.1"),
        .init(interface: "en0", address: "192.168.1.23"),
        .init(interface: "utun4", address: "10.8.0.6"),
      ], primary: "en0", names: ["en0": "Wi-Fi"])
    #expect(rows.map(\.title) == ["192.168.1.23", "192.168.64.1", "10.8.0.6"])
    #expect(rows.map(\.subtitle) == ["局域网 · Wi-Fi（en0）", "局域网 · bridge100", "内网 · VPN（utun4）"])
    #expect(rows.map(\.payload) == ["192.168.1.23", "192.168.64.1", "10.8.0.6"])
    #expect(Set(rows.map(\.id)).count == 3)

    let offline = IPAddresses.localItems([], primary: nil, names: [:])
    #expect(offline.map(\.subtitle) == ["没有连上网络"] && offline[0].payload == nil)
  }

  @Test func publicRows() {
    let rows = { (lookups: [IPAddresses.Service: IPAddresses.Lookup]) in
      IPAddresses.publicItems(lookups).map { "\($0.title) | \($0.subtitle) | \($0.payload ?? "-")" }
    }
    #expect(rows([:]) == ["外网 IP | 没查到：没有联网，或查询超时 | -"])
    #expect(rows([.domestic: .pending, .overseas: .pending]) == ["外网 IP | 正在查询… | -"])
    #expect(rows([.domestic: .failed, .overseas: .failed]) == ["外网 IP | 没查到：没有联网，或查询超时 | -"])
    // 只查到一家（另一家还在查 / 没查到）、两家一样：一行
    #expect(
      rows([.domestic: .found("203.0.113.7"), .overseas: .pending]) == [
        "203.0.113.7 | 外网 | 203.0.113.7"
      ])
    #expect(
      rows([.domestic: .failed, .overseas: .found("198.51.100.24")]) == [
        "198.51.100.24 | 外网 | 198.51.100.24"
      ])
    #expect(
      rows([.domestic: .found("203.0.113.7"), .overseas: .found("203.0.113.7")]) == [
        "203.0.113.7 | 外网 | 203.0.113.7"
      ])
    // 不一样（开着代理）：国内的在前，各写访问哪边时
    #expect(
      rows([.domestic: .found("203.0.113.7"), .overseas: .found("198.51.100.24")]) == [
        "203.0.113.7 | 外网 · 访问国内网站时 | 203.0.113.7",
        "198.51.100.24 | 外网 · 访问国外网站时 | 198.51.100.24",
      ])
    // 第一行的 id 一直是同一个：查到了原地换，选中不跳
    #expect(
      IPAddresses.publicItems([.domestic: .pending])[0].id
        == IPAddresses.publicItems([
          .domestic: .found("203.0.113.7"), .overseas: .found("198.51.100.24"),
        ])[0].id)
  }

  @Test func serviceReply() {
    #expect(IPAddresses.address(in: "203.0.113.7\n") == "203.0.113.7")
    #expect(IPAddresses.address(in: " 39.144.172.172 ") == "39.144.172.172")
    #expect(IPAddresses.address(in: "256.1.1.1") == nil)
    #expect(IPAddresses.address(in: "<html><body>请先登录</body></html>") == nil)
    #expect(IPAddresses.address(in: "当前 IP：1.2.3.4") == nil)
    #expect(IPAddresses.address(in: "") == nil)
  }

  private func model() throws -> (LauncherModel, Counter) {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    let counter = Counter()
    model.localAddresses = {
      IPAddresses.localItems(
        [.init(interface: "en0", address: "192.168.1.23")], primary: "en0", names: ["en0": "Wi-Fi"])
    }
    model.publicAddress = { service in
      counter.calls += 1
      return service == .domestic ? "203.0.113.7" : "198.51.100.24"
    }
    return (model, counter)
  }

  @MainActor final class Counter {
    var calls = 0
  }

  @Test func modelFillsPublicRowsInPlace() async throws {
    let (model, counter) = try model()
    model.query = "ip"
    #expect(model.results.prefix(2).map(\.subtitle) == ["局域网 · Wi-Fi（en0）", "正在查询…"])
    await model.ipLookup()
    #expect(
      model.results.prefix(3).map(\.title) == ["192.168.1.23", "203.0.113.7", "198.51.100.24"])
    #expect(model.selection == 0)
    #expect(model.primaryAction(for: model.results[0]).title == "粘贴")
    #expect(model.commandReturnAction(for: model.results[0])?.title == "只复制，不粘贴")
    #expect(model.copyTitle(for: model.results[0]) == "复制地址")
    // ⌘K 里复制只列一次（⌘↩），不另列 ⌘C
    #expect(model.actions(for: model.results[0]).filter { $0.title.contains("复制") }.count == 1)
    // 这次呼出里查到的不再问
    model.query = "ipa"
    model.query = "ip"
    await model.ipLookup()
    #expect(counter.calls == 2)
    #expect(
      model.results.prefix(3).map(\.title) == ["192.168.1.23", "203.0.113.7", "198.51.100.24"])
    // 收起再呼出：重查
    model.didHide()
    model.query = "ip"
    await model.ipLookup()
    #expect(counter.calls == 4)
  }

  @Test func pendingRowCannotBePasted() throws {
    let (model, _) = try model()
    model.query = "ip"
    let pending = try #require(model.results.first { $0.subtitle == "正在查询…" })
    #expect(model.commandReturnAction(for: pending) == nil)
    #expect(model.copyTitle(for: pending) == nil)
  }

  @Test func typingPastIPDoesNotLookUp() async throws {
    let (model, counter) = try model()
    model.query = "ip"
    model.query = "iph"
    await model.ipLookup()
    // 撤掉的那两个还在等 0.3 s：多等一会儿，确认它们醒来后不再问
    try await Task.sleep(for: IPAddresses.lookupDelay * 2)
    #expect(counter.calls == 0)
    #expect(!model.results.contains { $0.kind == .ip })
  }
}
