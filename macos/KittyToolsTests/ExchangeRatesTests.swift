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
    #expect(item("1 usd to usd")?.title == "1 USD")
    // 1 个是在看汇率：按汇率的精度，不按币种的两位小数
    #expect(item("人民币兑美元")?.title == "0.142857 USD")
    #expect(item("1 usd to eur")?.title == "0.9 EUR")
    #expect(item("100 usd to gbp") == nil)  // 表里没有
    #expect(Calculator.item(for: "5 usd", rates: table, home: "USD")?.title == "4.50 EUR")
    // 没有表：不算，交给模型出占位行
    #expect(Calculator.item(for: "100 usd", rates: nil, home: "CNY") == nil)
  }

  @Test func usagePrompt() throws {
    for query in ["汇率", "huilv", "Currency", " 汇率换算 "] {
      let prompts = ExchangeRates.promptItems(for: query)
      #expect(prompts.exact.first?.completion == "100 美元 转 日元", "\(query)")
      // 同 open / kill 的提示：标题写做什么，副标题写怎么用
      #expect(prompts.exact.first?.title == "汇率换算…")
      #expect(prompts.exact.first?.subtitle.contains("100 美元 转 日元") == true)
      #expect(prompts.partial.isEmpty)
    }
    // 只打了开头：排在后面（用户 2026-11-04：「curr」时就该提示，不用打全）
    for query in ["curr", "CURRENC", "汇", "hui", "exchange"] {
      let prompts = ExchangeRates.promptItems(for: query)
      #expect(prompts.exact.isEmpty && prompts.partial.count == 1, "\(query)")
    }
    for query in ["c", "100 美元", "currencyx", "率"] {
      let prompts = ExchangeRates.promptItems(for: query)
      #expect(prompts.exact.isEmpty && prompts.partial.isEmpty, "\(query)")
    }
    // 普通算式的卡片右侧照旧是「计算」（副标题空着）
    #expect(Calculator.item(for: "1+2")?.subtitle == "")
  }

  // MARK: 2026-11-05「多考虑一些写法」

  private func req(_ amount: Double, _ from: String, _ to: String? = nil) -> ExchangeRates.Request {
    .init(amount: amount, from: from, to: to)
  }

  @Test func amountsWithMultipliersAndMath() {
    #expect(request("100万日元") == req(1_000_000, "JPY"))
    #expect(request("1.5k usd") == req(1500, "USD"))
    #expect(request("2w 人民币 转 美元") == req(20000, "CNY", "USD"))
    #expect(request("5m usd to cny") == req(5_000_000, "USD", "CNY"))
    #expect(request("1亿日元") == req(100_000_000, "JPY"))
    #expect(request("(100+50) 美元") == req(150, "USD"))
    #expect(request("100*3 usd to jpy") == req(300, "USD", "JPY"))
    #expect(request("100/4 usd to cny") == req(25, "USD", "CNY"))  // 「/」拆不开，接着试「to」
    #expect(request("1 mop") == req(1, "MOP"))  // m 先当货币名的一部分：澳门元，不是一百万
    #expect(request("1 kes") == req(1, "KES"))
  }

  @Test func currencyFirstAndRateQuestions() {
    #expect(request("usd 100") == req(100, "USD"))
    #expect(request("US$100 to cny") == req(100, "USD", "CNY"))
    #expect(request("HK$ 1,000") == req(1000, "HKD"))
    #expect(request("JP¥500") == req(500, "JPY"))
    #expect(request("₫100000") == req(100_000, "VND"))
    #expect(request("美元 100 转 日元") == req(100, "USD", "JPY"))
    // 只问汇率：按 1 算
    #expect(request("美元兑人民币") == req(1, "USD", "CNY"))
    #expect(request("usd to cny") == req(1, "USD", "CNY"))
    #expect(request("USD/CNY") == req(1, "USD", "CNY"))
    #expect(request("usd cny") == req(1, "USD", "CNY"))
    #expect(request("美元汇率") == req(1, "USD"))
    #expect(request("美元对人民币汇率") == req(1, "USD", "CNY"))
    #expect(request("汇率 日元") == req(1, "JPY"))
    #expect(request("eur rate") == req(1, "EUR"))
    #expect(request("ALL to TRY") == req(1, "ALL", "TRY"))  // 大写的代码也认
  }

  @Test func spokenAndTraditional() {
    #expect(request("100美元是多少人民币") == req(100, "USD", "CNY"))
    #expect(request("100美元等于多少日元？") == req(100, "USD", "JPY"))
    #expect(request("100美元能换多少人民币") == req(100, "USD", "CNY"))
    #expect(request("请问100美元可以换多少港币呢") == req(100, "USD", "HKD"))
    #expect(request("100美元多少钱") == req(100, "USD"))
    #expect(request("100 usd into jpy") == req(100, "USD", "JPY"))
    #expect(request("100 美金 轉 日圓") == req(100, "USD", "JPY"))
    #expect(request("100 美元 兌 新台幣") == req(100, "USD", "TWD"))
    #expect(request("100美刀") == req(100, "USD"))
    #expect(request("100 bucks") == req(100, "USD"))
    #expect(request("50 quid") == req(50, "GBP"))
  }

  @Test func leavesOtherInputAlone() {
    // 没写金额时不确定是货币的不算（英文里的 all / try / pen / cup 也是货币代码）；单写一种货币、算式、单位换算、普通搜索都不算
    for query in [
      "all to try", "pen cup", "usd", "美元", "汇率", "100", "100/3", "2^10", "10 mod 3", "10 km to mi",
      "2024-01-01", "iphone 15", "1password", "4k video", "我的文档", "1e3",
    ] {
      #expect(request(query) == nil, "\(query)")
    }
    // 刁钻的输入不崩、不乱出
    for query in [
      "", " ", "转", "to", "/", "$", "¥", "100万", "万日元", "1,", "()usd", "usd()", "100 美元 转 转",
      "汇率汇率", "?", "多少钱", "=", "->", "1.2.3 usd", "..usd", "k usd", "100 to", "美元 to", "转 美元",
      "100万万日元", "(100 usd", "1/0 usd",
    ] {
      _ = request(query)
      _ = ExchangeRates.suggestions(for: query)
      _ = Calculator.item(for: query, rates: table, home: "CNY")
    }
    #expect(request("1/0 usd") == nil)  // 算不出有限数
    #expect(Calculator.item(for: "100/4", rates: table, home: "CNY")?.payload == "25")
    #expect(Calculator.item(for: "10 km to mi", rates: table, home: "CNY")?.title == "6.2137 mi")
    #expect(Calculator.item(for: "2^10", rates: table, home: "CNY")?.payload == "1024")
  }

  @Test func remembersUsedCurrencies() {
    var recents = ExchangeRates.remembering("100 usd to jpy", in: [], home: "CNY")
    #expect(recents == ["JPY", "USD"])
    recents = ExchangeRates.remembering("50 欧元", in: recents, home: "CNY")
    #expect(recents == ["CNY", "EUR", "JPY", "USD"])
    #expect(ExchangeRates.remembering("1+2", in: recents, home: "CNY") == recents)  // 不是汇率换算
    let many = ["AUD", "CAD", "SGD", "CHF", "MOP", "THB", "MYR", "RUB"]
    #expect(
      ExchangeRates.remembering("1 usd", in: many, home: "CNY").count == ExchangeRates.recentLimit)
    // 候选：用过的排在同一档的最前面；「转」后面还没打时先列用过的
    let codes = { (query: String, recents: [String]) in
      ExchangeRates.suggestions(for: query, recents: recents).map {
        String($0.target.dropFirst(ExchangeRates.suggestionPrefix.count))
      }
    }
    #expect(codes("100 美元 转", ["JPY", "KRW"]) == ["JPY", "KRW", "CNY", "EUR", "GBP", "HKD"])
    #expect(codes("100 usd to dol", ["CAD"]).first == "CAD")
  }

  @Test func suggestionsForNewForms() {
    let first = { ExchangeRates.suggestions(for: $0).first?.completion }
    #expect(first("100万日") == "100万日元")
    #expect(first("美元兑英") == "美元兑英镑")
    #expect(first("5m u") == "5m USD")
    #expect(first("1 mo") == "1 MOP")
    #expect(first("100/3 u") == "100/3 USD")
    #expect(first("100美元换多少英") == "100美元换多少英镑")
    #expect(ExchangeRates.suggestions(for: "all to t").isEmpty)  // 左边不确定是货币
  }

  @Test func currencySuggestions() {
    let hints = { ExchangeRates.suggestions(for: $0) }
    let codes = {
      hints($0).map { String($0.target.dropFirst(ExchangeRates.suggestionPrefix.count)) }
    }
    // 右边打到一半：中文名、代码、英文名、全拼都能搜到；打中文换成中文名，打字母换成代码
    let gbp = hints("100 美元 转 英").first
    #expect(gbp?.title == "英镑" && gbp?.subtitle == "GBP · British Pound")
    #expect(gbp?.completion == "100 美元 转 英镑")
    #expect(hints("100美元转英").first?.completion == "100美元转英镑")
    #expect(hints("100 usd to gb").first?.completion == "100 usd to GBP")
    #expect(codes("100 usd to pound").first == "GBP")  // 英文名里的词
    #expect(codes("100 usd to yingb").first == "GBP")  // 全拼
    #expect(codes("100 usd to 林吉").first == "MYR")  // 简称
    #expect(codes("100 usd to dol").prefix(3) == ["USD", "HKD", "TWD"])  // 常用的排前面
    // 「转」后面还没打：列常用的几种（不含左边那种）
    #expect(codes("100 美元 转") == ["CNY", "EUR", "JPY", "GBP", "HKD", "TWD"])
    #expect(hints("100 美元 转").first?.completion == "100 美元 转 人民币")
    // 左边打到一半
    #expect(hints("100 美").first?.completion == "100 美元")
    #expect(codes("100 dol").first == "USD")
    // 左边打 1 个字母就出（用户 2026-11-05：「100 u」）：美元排前面
    #expect(codes("100 u").first == "USD")
    #expect(hints("100 u").first?.completion == "100 USD")
    #expect(codes("100 e").first == "EUR")
    // 不出：已经是一种货币、左边打的是单位名（在换算单位）、不是这种写法
    for query in [
      "100 美元 转 英镑", "100 usd to gbp", "10 km", "10 k", "100 g", "5 m", "1 h", "2 kb", "100 usd",
      "hello", "100", "3 个月",
    ] {
      #expect(hints(query).isEmpty, "\(query)")
    }
  }

  @Test func modelListsSuggestionsOnlyWithoutResult() throws {
    let (model, _) = try model(table)
    model.query = "100 美元 转 英"
    let first = try #require(model.results.first)
    #expect(first.target == ExchangeRates.suggestionPrefix + "GBP")
    #expect(model.primaryAction(for: first).title == "补全货币")
    model.execute(first)
    #expect(model.query == "100 美元 转 英镑")
    // 单位换算有结果：不列货币候选
    model.query = "10 km to m"
    #expect(!model.results.contains { $0.target.hasPrefix(ExchangeRates.suggestionPrefix) })
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
    #expect(model.query == "100 美元 转 日元")
    await model.ratesFetch()
    #expect(model.results.first?.kind == .calculation)
  }

  @Test func modelListsPromptForPrefix() throws {
    let (model, _) = try model(table)
    model.query = "curr"
    #expect(model.results.first?.target == ExchangeRates.promptTarget)
  }

  @Test func modelSkipsPassersBy() async throws {
    let (model, counter) = try model(table)
    model.query = "100 usd"
    model.query = "100 usdx"  // 0.3 s 之内打走了
    await model.ratesFetch()
    #expect(counter.calls == 0)
  }
}
