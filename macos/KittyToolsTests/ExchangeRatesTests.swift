// 计算器汇率换算的单测（2026-11-04）：「100 usd」这类输入怎么解析、和单位换算 / 算式不抢、按表换算和小数位、
// 数据源回的 JSON 怎么收拾、什么时候算旧，以及模型里先出占位行、取到汇率后原地换掉。汇率表都是注入的，不联网、不写偏好。

import Foundation
import Testing

@testable import KittyTools

struct ExchangeRatesTests {
  /// 1 美元 = 7 人民币 = 150 日元 = 1400 韩元 = 0.9 欧元
  private let table = ExchangeRates.Table(
    date: "2026-11-03", fetchedAt: .now,
    rates: ["USD": 1, "CNY": 7, "JPY": 150, "KRW": 1400, "EUR": 0.9, "HKD": 7.8])

  private func request(_ query: String) -> ExchangeRates.Request? {
    ExchangeRates.request(for: query)
  }

  @Test func parsesAmountsAndCurrencies() {
    #expect(request("100 usd") == .init(amount: 100, from: "USD", to: nil))
    #expect(request("100USD to cny") == .init(amount: 100, from: "USD", to: "CNY"))
    #expect(request("100美元转人民币") == .init(amount: 100, from: "USD", to: "CNY"))
    #expect(request("100 美元 兑 港币") == .init(amount: 100, from: "USD", to: "HKD"))
    #expect(request("$100 in jpy") == .init(amount: 100, from: "USD", to: "JPY"))
    #expect(request("100$") == .init(amount: 100, from: "USD", to: nil))
    #expect(request("100刀") == .init(amount: 100, from: "USD", to: nil))
    #expect(request("￥100") == .init(amount: 100, from: "CNY", to: nil))  // 全角的也认
    #expect(request("1,299.5 eur = cny") == .init(amount: 1299.5, from: "EUR", to: "CNY"))
    #expect(request("5 TWD -> usd") == .init(amount: 5, from: "TWD", to: "USD"))
    // 不知道代码也行：系统给的简体 / 繁体 / 英文名，159 种都有
    #expect(request("100 沙特里亚尔") == .init(amount: 100, from: "SAR", to: nil))
    #expect(request("100 港幣 转 日圓") == .init(amount: 100, from: "HKD", to: "JPY"))
    #expect(
      request("100 Japanese Yen to swiss franc") == .init(amount: 100, from: "JPY", to: "CHF"))
    #expect(request("100 马来西亚林吉特") == .init(amount: 100, from: "MYR", to: nil))
  }

  @Test func ignoresWhatIsNotCurrency() {
    for query in [
      "100 usd to xyz", "100 abc", "100 usd in", "iphone 15", "1password", "2024-01-01", "12",
      "1+2", "10 mod 3", "1e3", "100 btc",
    ] {
      #expect(request(query) == nil, "\(query)")
    }
    // 和单位换算撞名的（cup 也是古巴比索的代码）：单位换算在前
    #expect(
      Calculator.item(for: "1 cup to ml", rates: table, home: "CNY")?.title.hasSuffix(" mL") == true
    )
    #expect(
      Calculator.item(for: "1 pound to kg", rates: table, home: "CNY")?.title.hasSuffix(" kg")
        == true)
    #expect(Calculator.item(for: "200*15%", rates: table, home: "CNY")?.payload == "30")
  }

  @Test func convertsByTable() throws {
    let item = { Calculator.item(for: $0, rates: self.table, home: "CNY") }
    let usd = try #require(item("100 usd"))
    #expect(usd.title == "700.00 CNY")
    #expect(usd.payload == "700.00 CNY")
    #expect(usd.subtitle == "人民币 · 11-03 汇率")  // 右侧小字写中文名，不认识 CNY 也看得懂
    #expect(usd.target == "100 usd")
    // 写回去还能接着换：人民币只写左边时换成美元
    #expect(item("700.00 CNY")?.title == "100.00 USD")
    #expect(item("10000 cny to jpy")?.title == "214,286 JPY")  // 日元没有小数，大字分组
    #expect(item("10000 cny to jpy")?.payload == "214286 JPY")  // 粘贴的不分组
    #expect(item("100 krw to usd")?.title == "0.07143 USD")  // 不到 1 的按有效数字
    #expect(item("1 usd to usd")?.title == "1.00 USD")
    #expect(item("100 usd to gbp") == nil)  // 表里没有
    #expect(Calculator.item(for: "5 usd", rates: table, home: "USD")?.title == "4.50 EUR")
    // 没有表：不算，交给模型出占位行
    #expect(Calculator.item(for: "100 usd", rates: nil, home: "CNY") == nil)
  }

  @Test func usagePrompt() throws {
    for query in ["汇率", "huilv", "Currency", " 汇率换算 "] {
      #expect(ExchangeRates.promptItems(for: query).first?.completion == "100 美元", "\(query)")
    }
    #expect(ExchangeRates.promptItems(for: "汇").isEmpty)
    #expect(ExchangeRates.promptItems(for: "100 美元").isEmpty)
    // 普通算式的卡片右侧照旧是「计算」（副标题空着）
    #expect(Calculator.item(for: "1+2")?.subtitle == "")
  }

  @Test func extraCopies() throws {
    let result = try #require(Calculator.result(for: "100 usd to jpy", rates: table, home: "CNY"))
    #expect(result.copies.map(\.text) == ["15000", "1 USD = 150 JPY"])
    #expect(result.copies.map(\.title) == ["复制原始数字", "复制汇率"])
  }

  @Test func readsSourceReply() throws {
    let codes = [
      "usd", "cny", "eur", "jpy", "gbp", "hkd", "twd", "krw", "aud", "cad", "sgd", "chf", "rub",
      "inr", "thb", "myr", "vnd", "php", "idr", "nzd", "sek",
    ]
    var rates = Dictionary(uniqueKeysWithValues: codes.map { ($0, 2.0) })
    rates["usd"] = 1
    rates["btc"] = 0.00001  // 加密货币
    rates["ats"] = 12  // 停用的奥地利先令
    rates["eur"] = -1  // 不是正数
    let json = { (date: String, rates: [String: Double]) in
      try JSONSerialization.data(withJSONObject: ["date": date, "usd": rates])
    }
    let table = try #require(
      ExchangeRates.table(from: try json("2026-11-03", rates), fetchedAt: .now))
    #expect(table.date == "2026-11-03")
    #expect(table.rates["USD"] == 1 && table.rates["TWD"] == 2)
    #expect(table.rates["BTC"] == nil && table.rates["ATS"] == nil && table.rates["EUR"] == nil)
    #expect(table.rates.count == codes.count - 1)
    #expect(ExchangeRates.table(from: try json("昨天", rates), fetchedAt: .now) == nil)
    #expect(
      ExchangeRates.table(from: try json("2026-11-03", ["usd": 1, "cny": 7]), fetchedAt: .now)
        == nil)
    #expect(ExchangeRates.table(from: Data("<html>请先登录</html>".utf8), fetchedAt: .now) == nil)
  }

  @Test func staleness() {
    let now = Date.now
    let at = {
      ExchangeRates.Table(date: "2026-11-03", fetchedAt: now.addingTimeInterval($0), rates: [:])
    }
    #expect(!ExchangeRates.isStale(at(-3600), now: now))
    #expect(ExchangeRates.isStale(at(-7 * 3600), now: now))
    #expect(ExchangeRates.isStale(at(3600), now: now))  // 系统时钟往回调过
  }

  // MARK: 模型

  @MainActor final class Counter {
    var calls = 0
  }

  private func model(_ reply: ExchangeRates.Table?) throws -> (LauncherModel, Counter) {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    let counter = Counter()
    model.fetchRates = {
      counter.calls += 1
      return reply
    }
    return (model, counter)
  }

  @Test func modelFillsRowInPlace() async throws {
    let (model, counter) = try model(table)
    model.query = "100 usd to cny"
    #expect(model.results.first?.title == "正在取汇率…")
    #expect(model.copyTitle(for: try #require(model.results.first)) == nil)  // 占位行不能复制
    let id = model.results.first?.id
    await model.ratesFetch()
    #expect(model.results.first?.title == "700.00 CNY")
    #expect(model.results.first?.id == id)
    #expect(model.actions.contains { $0.title == "复制汇率" && $0.detail == "1 USD = 7 CNY" })
    // 表是新的：接着打不再取
    model.query = "200 usd to cny"
    #expect(model.results.first?.title == "1,400.00 CNY")
    await model.ratesFetch()
    #expect(counter.calls == 1)
  }

  @Test func modelSaysWhenFetchFails() async throws {
    let (model, counter) = try model(nil)
    model.query = "100 usd to cny"
    await model.ratesFetch()
    #expect(model.results.first?.title == "没取到汇率，检查一下网络")
    // 再打字重取
    model.query = "100 usd to cn"
    model.query = "100 usd to cny"
    #expect(model.results.first?.title == "正在取汇率…")
    await model.ratesFetch()
    #expect(counter.calls == 2)
  }

  @Test func modelPromptFillsExample() async throws {
    let (model, _) = try model(table)
    model.query = "汇率"
    let prompt = try #require(model.results.first)
    #expect(prompt.target == ExchangeRates.promptTarget)
    #expect(model.primaryAction(for: prompt).title == "填进示例")
    model.execute(prompt)
    #expect(model.query == "100 美元")
    await model.ratesFetch()
    #expect(model.results.first?.kind == .calculation)
  }

  @Test func modelSkipsPassersBy() async throws {
    let (model, counter) = try model(table)
    model.query = "100 usd"
    model.query = "100 usdx"  // 0.3 s 之内打走了
    await model.ratesFetch()
    #expect(counter.calls == 0)
  }
}
