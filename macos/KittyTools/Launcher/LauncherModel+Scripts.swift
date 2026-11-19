// 启动器的脚本命令（第五轮体检 H1 从 LauncherModel.swift 拆出）：跑脚本、输出页（粘贴 / 拷贝 / 再跑）、从网上下载的脚本先看一眼（review）。

import AppKit
import SwiftUI

extension LauncherModel {
  // MARK: 脚本命令

  /// 搜索框里打着密码参数（第三轮 C3）：不留到下次呼出；⌥↩ / ⌃↩ 不拿它去访达、网页里搜（第 3 批评审：按住 ⌃ 时的说明还会
  /// 把整句连密码显示出来）
  var holdsSecret: Bool {
    ScriptCommand.invocation(for: query, in: activeScripts, alias: scriptAlias).map {
      $0.script.hasSecret && !$0.arguments.isEmpty
    } ?? false
  }

  /// 记一次使用。有密码参数的（第三轮 C3）：查询里有密码，按关键词记，不把打的字存进使用记录；搜索框先清空（全文输出时
  /// 启动器留着，不清就一直看得见）
  func record(_ script: ScriptCommand, _ item: LauncherItem) {
    guard script.hasSecret else { return usage.record(item, query: query) }
    usage.record(item, query: scriptAlias(script) ?? script.title)
    query = ""
  }

  /// 跑一条脚本（B1 B4）：先收起再跑，粘贴的目标在收起前定（焦点原本在自家便签里时直接粘进去）；
  /// 超过 1 秒还没完，岛上出「正在运行」带「停止」。同一个还在跑：不重复起，岛上说一声
  func start(_ script: ScriptCommand, arguments: [String]) {
    guard runningScripts[script.path] == nil else {
      close()
      // 岛上那条「正在运行」会被这一条换掉、挂满 60 秒也会收：这里再给一个「停止」（第三轮评审）
      let path = script.path
      island?.show(
        "「\(script.title)」还在运行", detail: "等它跑完，或者点「停止」", tone: .info,
        actions: [Island.Action("停止") { [weak self] in self?.runningScripts[path]?.cancel() }])
      return
    }
    if script.mode == .full { return startFull(script, arguments: arguments) }
    let target = script.mode == .paste ? pasteTargetView() : nil
    close()
    let path = script.path
    let progress = Self.progress(script)
    runningScripts[path] = Task { [weak self] in
      guard let self else { return }
      let outcome = await Island.whenSlow(after: .seconds(1)) { [weak self] in
        self?.island?.show(
          progress, tone: .progress, symbol: "terminal.fill",
          actions: [Island.Action("停止") { [weak self] in self?.runningScripts[path]?.cancel() }])
      } work: {
        await self.runScript(script, arguments, nil)
      }
      runningScripts[path] = nil
      deliver(outcome, of: script, arguments: arguments, into: target, progress: progress)
    }
  }

  /// 全文输出（B1 full）：启动器留着，列表换成输出那一页；边跑边把写到现在的放上去（第三轮 A1，错误输出并在里面、
  /// 同终端），跑完换成最终的那一份。⌘R 重跑也走这里（第三轮 A3：别的模式的脚本从「看输出」那一页重跑，同样在这一页上看结果）
  private func startFull(_ script: ScriptCommand, arguments: [String]) {
    let path = script.path
    showsActions = false
    output = ScriptOutput(script: script, arguments: arguments)
    let started = output?.startedAt
    runningScripts[path] = Task { [weak self] in
      guard let self else { return }
      let outcome = await runScript(script, arguments) { [weak self] raw in
        guard let self, output?.startedAt == started, output?.isRunning == true else { return }
        output?.showLive(raw)
      }
      runningScripts[path] = nil
      // 跑着时启动器收起了：岛上说结果、带「看输出」；Esc 停掉的、换成别的页的不说。⌘R 重跑的别的模式的脚本也按全文交
      // （第 1 批评审：按它自己的模式交，粘贴脚本会把结果粘进收起后在前面的 App）
      if detachedOutputs.remove(path) != nil {
        var shown = script
        shown.mode = .full
        return deliver(
          outcome, of: shown, arguments: arguments, into: nil, progress: Self.progress(script))
      }
      guard output?.startedAt == started else { return }
      var page = Self.outputPage(outcome, of: script, arguments: arguments)
      page.startedAt = started ?? page.startedAt
      output = page
      Island.announce(page.failure.map { "\($0)" } ?? "「\(script.title)」运行完了")
    }
  }

  /// 输出那一页的 ⌘R：用同样的参数再跑一次（第三轮 A3）。按的是脚本现在的样子（改完脚本再跑一次看结果）；还在跑的、
  /// 写了 confirm 的（重跑不该绕过「按两次」）、已经不在了的不跑
  func rerunOutput() {
    guard let output, !output.isRunning, runningScripts[output.script.path] == nil else {
      return NSSound.beep()
    }
    guard let script = activeScripts.first(where: { $0.path == output.script.path }),
      !script.isDownloaded || approvedScripts.contains(script.path)
    else {
      island?.show("「\(output.script.title)」不在了", detail: "脚本被删掉、关掉或者换过了", tone: .info)
      return NSSound.beep()
    }
    guard script.confirmation == nil else { return NSSound.beep() }
    startFull(script, arguments: output.arguments)
  }

  /// 这一页能不能 ⌘R：底栏的「重跑」跟着它
  var canRerunOutput: Bool {
    guard let output else { return false }
    return !output.isRunning && output.script.confirmation == nil
  }

  /// 全文脚本跑着时启动器收起了：接着跑，岛上挂「正在运行」带「停止」，跑完由 startFull 交给 deliver
  func detach(_ script: ScriptCommand) {
    let path = script.path
    detachedOutputs.insert(path)
    island?.show(
      Self.progress(script), tone: .progress, symbol: "terminal.fill",
      actions: [Island.Action("停止") { [weak self] in self?.runningScripts[path]?.cancel() }])
  }

  /// 全文那一页上的东西：输出，没跑成时接上错误输出；没跑成的那一句（红字）。全文输出和岛上「看输出」同一份
  static func outputPage(
    _ outcome: ScriptRunner.Outcome, of script: ScriptCommand, arguments: [String]
  ) -> ScriptOutput {
    var raw = outcome.output
    if !outcome.succeeded, !ScriptCommand.payload(outcome.error).isEmpty {
      while raw.last?.isNewline == true { raw.removeLast() }
      raw += (raw.isEmpty ? "" : "\n\n") + outcome.error
    }
    let failure = Self.failure(outcome, of: script).map {
      $0.detail.isEmpty ? $0.title : String(localized: "\($0.title)：\($0.detail)")
    }
    var page = ScriptOutput(
      script: script, arguments: arguments, isRunning: false, failure: failure)
    page.show(raw)
    return page
  }

  /// 岛上「看输出」：叫出启动器，原地显示那一次的全部输出（同全文输出那一页：↩ 粘贴、⌘C 复制、Esc 回到结果）。
  /// 只留着最近一次的：后来又有脚本要看输出，早先那座岛上的按钮就说没留着
  func showOutput(_ id: UUID) {
    guard let lastOutput, lastOutput.id == id else {
      island?.show("那次的输出没留着", detail: "只留最近一次的输出", tone: .info)
      return
    }
    // 先叫出来再换上：收起着时呼出会按「过了 60 秒」清掉查询，那会顺手关掉输出页；正在跑的全文脚本停掉（同 Esc）。
    // 启动器功能关着叫不出来：不留一张过期的输出页（第三轮评审）
    if output != nil { closeOutput() }
    guard showPanel() else { return }
    review = nil
    showsActions = false
    output = lastOutput.page
  }

  /// 输出那一页：回到结果（还在跑就停掉）
  func closeOutput() {
    guard let output else { return }
    if output.isRunning { runningScripts[output.script.path]?.cancel() }
    self.output = nil
  }

  /// 输出那一页的 ↩：把全部输出粘贴到前台 App（同计算结果的粘贴）
  func pasteOutput() {
    guard let output, !output.isRunning, !output.text.isEmpty else { return NSSound.beep() }
    let text = output.text
    self.output = nil
    paste { Paster.write(string: text, record: true) }
  }

  /// 输出那一页的 ⌘C：全部复制，收起，岛上说一声
  func copyOutput() {
    guard let output, !output.isRunning, !output.text.isEmpty else { return NSSound.beep() }
    let text = output.text
    self.output = nil
    Paster.write(string: text, record: true)
    close()
    island?.show("已复制「\(output.script.title)」的输出", detail: "\(Island.excerpt(text))")
  }

  /// 等脚本跑完（单测）
  func scriptRun(_ path: String) async { await runningScripts[path]?.value }

  /// 岛上「正在运行」那一条：show、dismiss(ifShowing:) 给同一个（按 key + 插进去的名字认）
  static func progress(_ script: ScriptCommand) -> LocalizedStringResource {
    "正在运行「\(script.title)」"
  }

  /// 把结果交出去（B1）：出错的一律岛上红字（最后一行；没有就写退出码），成功的按 mode
  private func deliver(
    _ outcome: ScriptRunner.Outcome, of script: ScriptCommand, arguments: [String],
    into target: NSTextView?, progress: LocalizedStringResource
  ) {
    if let failure = Self.failure(outcome, of: script) {
      let stopped = outcome.end == .stopped
      // 出错了带「看输出」（D3）：前面几行才说得清为什么；自己停的、什么都没输出的不带
      let page = Self.outputPage(outcome, of: script, arguments: arguments)
      let keeps = !stopped && !page.text.isEmpty
      let id = UUID()
      if keeps { lastOutput = (id, page) }
      island?.show(
        "\(failure.title)", detail: failure.detail.isEmpty ? nil : "\(failure.detail)",
        tone: stopped ? .info : .error,
        actions: keeps
          ? [Island.Action("看输出", opens: true) { [weak self] in self?.showOutput(id) }] : [])
      return
    }
    let text = ScriptCommand.payload(outcome.output)
    switch script.mode {
    case .paste, .copy:
      guard !text.isEmpty else {
        island?.show("「\(script.title)」没有输出", tone: .warning)
        return
      }
      if script.mode == .copy {
        Paster.write(string: text, record: true)
        island?.show("已复制「\(script.title)」的输出", detail: "\(Island.excerpt(text))")
      } else {
        island?.dismiss(ifShowing: progress)
        pasteOutput(text, into: target)
      }
    case .none:
      island?.dismiss(ifShowing: progress)
    // 全文：跑着时启动器收起了的才走这里（detach）。岛上说一声，带「看输出」
    case .full:
      let page = Self.outputPage(outcome, of: script, arguments: arguments)
      let id = UUID()
      if !page.text.isEmpty { lastOutput = (id, page) }
      island?.show(
        "「\(script.title)」运行完了", detail: ScriptCommand.lastLine(outcome.output).map { "\($0)" },
        actions: page.text.isEmpty
          ? [] : [Island.Action("看输出", opens: true) { [weak self] in self?.showOutput(id) }])
    // list 平时不走这里（列表行）；万一走到了按岛上一行
    case .island, .list:
      if let line = ScriptCommand.lastLine(outcome.output) {
        island?.show("\(line)", detail: "\(script.title)")
      } else {
        island?.show("已运行「\(script.title)」")
      }
    }
  }

  /// 粘贴脚本的输出（同计算结果的粘贴：自家便签直接粘进去；没有辅助功能授权时只复制、岛上说去授权）。脚本的输出是本 App
  /// 给出的新文字，同时记进剪贴板历史（mac-native §5）
  private func pasteOutput(_ text: String, into target: NSTextView?) {
    if let target {
      Paster.paste(into: target) { Paster.write(string: text, record: true) }
      return
    }
    Paster.write(string: text, record: true)
    guard Permissions.isAccessibilityTrusted else {
      island?.show(
        "已复制到剪贴板", detail: "授权辅助功能后才能直接粘贴", tone: .warning,
        actions: [.settings(for: .accessibility)])
      return
    }
    _ = Paster.pasteToFrontmost()
  }

  /// 从网上下载的脚本：面板里换成它的全文（读到之前写「正在读取…」）
  func showReview(_ script: ScriptCommand, arguments: [String]? = nil) {
    armed = nil
    showsActions = false
    review = ScriptReview(script: script, arguments: arguments)
    Task {
      let read = await readScript(script)
      guard review?.script.path == script.path else { return }
      review?.reading = read
      review?.shownAt = .now
      try? await Task.sleep(for: reviewDwell)
      guard review?.script.path == script.path else { return }
      review?.isSettled = true
    }
    Island.announce("这个脚本是从网上下载的，先看一眼再运行。按回车运行，按 Esc 返回")
  }

  /// 看过了（↩ / 「运行」）：记下、去掉隔离标记，然后照常跑（写了 confirm 的不再上膛：看全文就是确认）
  func approveReview() {
    // 全文还没读到、没显示全、藏着打乱显示顺序的字符：不跑（看不全的脚本别运行；去编辑器里看）。刚显示出来那 1 秒的 ↩
    // 也不算：呼出时照习惯连按两下 ↩ 的第二下不能直接放行（第三轮评审）
    guard let review, review.isRunnable, let shown = review.shownAt,
      ContinuousClock.now - shown >= reviewDwell
    else { return NSSound.beep() }
    let script = review.script
    self.review = nil
    approvedScripts.insert(script.path)
    Task { await approveScript(script) }
    // 要参数、却是从普通那一行来的：补「关键词 空格」；列表脚本重搜一次（这下可以跑了）
    guard let arguments = review.arguments ?? (script.takesInput ? nil : []) else {
      query = (scriptAlias(script) ?? script.title) + " "
      return
    }
    guard arguments.count >= script.requiredCount, script.invalidChoice(arguments) == nil else {
      return NSSound.beep()
    }
    if script.mode == .list { return search() }
    record(script, LauncherItem.script(script, alias: scriptAlias(script)))
    start(script, arguments: arguments)
  }

  /// 不跑了（Esc / 「返回」）：回到结果
  func cancelReview() { review = nil }
}
