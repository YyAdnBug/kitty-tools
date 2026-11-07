// 启动器脚本命令的单测（2026-11-07，PLAN §10「脚本命令」）：开头注释的两种写法、图标 / 参数 / 确认、输出的收拾、环境和 PATH、
// 「关键词 空格 文字」怎么切、列表输出怎么读；
// 真跑临时文件夹里的假脚本（输出、退出码、超时、停止、工作目录、只给几样环境变量）；读文件夹（.template. 不列、没有 #! 的记原因、
// 下载标记）；启动器里的行（搜得到、别名排第一、↩ 跑、上膛、下载来的先看一眼、参数、全文、列表）。不读写用户的偏好：
// PATH 由测试传进去；不碰剪贴板（粘贴 / 复制的路子不在这里按）。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct ScriptCommandTests {
  private func parse(_ text: String, name: String = "test.sh") throws -> ScriptCommand {
    let result = try #require(ScriptCommand.parse(text, path: "/tmp/scripts/\(name)"))
    return try result.get()
  }

  @Test func parsesOwnFields() throws {
    let script = try parse(
      """
      #!/bin/zsh
      # @kitty.title 生成 UUID
      # @kitty.keyword UUID
      # @kitty.icon 🆔
      # @kitty.mode paste
      # @kitty.description 生成一个小写的 UUID
      # @kitty.timeout 5
      # @kitty.argument1 前缀
      # @kitty.argument2 {"placeholder": "个数", "optional": true}
      uuidgen | tr A-Z a-z
      """)
    #expect(script.title == "生成 UUID")
    #expect(script.keyword == "uuid")
    #expect(script.icon == .emoji("🆔"))
    #expect(script.mode == .paste)
    #expect(script.summary == "生成一个小写的 UUID")
    #expect(script.timeout == 5 && script.limit == 5)
    #expect(script.interpreter == ["/bin/zsh"])
    #expect(
      script.arguments == [
        .init(placeholder: "前缀"), .init(placeholder: "个数", isOptional: true),
      ])
    #expect(script.confirmation == nil)
  }

  @Test func readsCommunityFields() throws {
    let script = try parse(
      """
      #!/usr/bin/env python3
      // @raycast.schemaVersion 1
      // @raycast.title Toggle Dark Mode
      // @raycast.mode silent
      // @raycast.packageName System
      // @raycast.icon images/dark.png
      // @raycast.needsConfirmation true
      // @raycast.argument1 { "type": "text", "placeholder": "Query", "optional": true }
      """, name: "dark.py")
    #expect(script.title == "Toggle Dark Mode")
    #expect(script.mode == .island)
    #expect(script.package == "System")
    #expect(script.icon == .image("/tmp/scripts/images/dark.png"))
    #expect(script.confirmation == "再按 ↩ 运行「Toggle Dark Mode」")
    #expect(script.arguments == [.init(placeholder: "Query", isOptional: true)])
    #expect(script.interpreter == ["/usr/bin/env", "python3"])
    #expect(script.keyword == nil)
    // fullOutput 是全文；自家的字段比社区的优先
    let full = try parse(
      "#!/bin/sh\n# @raycast.mode fullOutput\n# @raycast.title A\n# @kitty.title B\n")
    #expect(full.mode == .full && full.title == "B")
    // AppleScript 的注释
    let apple = try parse("#!/usr/bin/osascript\n-- @kitty.title 静音\n", name: "m.applescript")
    #expect(apple.title == "静音")
  }

  @Test func defaultsAndSkips() throws {
    // 没写 title 用文件名，mode 默认岛上一行，超时 60 秒
    let plain = try parse("#!/bin/bash\necho hi\n", name: "say hi.sh")
    #expect(plain.title == "say hi" && plain.mode == .island && plain.limit == 60)
    // .template. 和隐藏文件不列；不是脚本的文件不理；扩展名像脚本却没有 #! 的记原因
    #expect(ScriptCommand.parse("#!/bin/sh\n", path: "/x/a.template.sh") == nil)
    #expect(ScriptCommand.parse("#!/bin/sh\n", path: "/x/.hidden.sh") == nil)
    #expect(ScriptCommand.parse("PNG...", path: "/x/icon.png") == nil)
    #expect(ScriptCommand.parse("echo hi\n", path: "/x/a.sh") == .failure(.noShebang))
    #expect(ScriptCommand.parse("#!\n", path: "/x/a.sh") == .failure(.noShebang))
    // 不认识的 mode 回到默认、超时夹进范围、confirm 自己写的那句
    let odd = try parse(
      "#!/bin/sh\n# @kitty.mode bogus\n# @kitty.timeout 99999\n# @kitty.confirm 真的要清空？\n")
    #expect(odd.mode == .island && odd.timeout == 3600 && odd.confirmation == "真的要清空？")
    #expect(try parse("#!/bin/sh\n# @kitty.confirm false\n").confirmation == nil)
  }

  @Test func icons() {
    #expect(ScriptCommand.icon("⏱ 计时", folder: "/s") == .emoji("⏱\u{FE0F}"))
    #expect(ScriptCommand.icon("🆔", folder: "/s") == .emoji("🆔"))
    #expect(ScriptCommand.icon("clock.fill", folder: "/s") == .symbol("clock.fill"))
    #expect(ScriptCommand.icon("icon.png", folder: "/s") == .image("/s/icon.png"))
    #expect(ScriptCommand.icon("/abs/a.png", folder: "/s") == .image("/abs/a.png"))
    #expect(
      ScriptCommand.icon("https://x.com/a.png", folder: "/s") == .remote("https://x.com/a.png"))
    #expect(ScriptCommand.icon("http://x.com/a.png", folder: "/s") == nil)
    #expect(ScriptCommand.icon("  ", folder: "/s") == nil)
  }

  @Test func cleansOutput() {
    let colored = "\u{1B}[1;32mok\u{1B}[0m\r\nsecond\u{1B}]0;title\u{07}\n\n"
    #expect(ScriptCommand.clean(colored) == "ok\nsecond\n\n")
    #expect(ScriptCommand.lastLine(colored) == "second")
    #expect(ScriptCommand.lastLine("  \n\n") == nil)
    #expect(ScriptCommand.payload("a\n  b\n\n") == "a\n  b")
  }

  @Test func environmentAndPath() throws {
    #expect(
      ScriptCommand.searchPath(login: "/Users/me/.nvm/bin:/usr/bin")
        == "/Users/me/.nvm/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    #expect(ScriptCommand.searchPath(login: nil) == ScriptCommand.fallbackPath)
    #expect(
      ScriptCommand.shellPath(fromOutput: "hello from zshrc\n\n__KITTY_PATH__/a:/b\n") == "/a:/b")
    #expect(ScriptCommand.shellPath(fromOutput: "__KITTY_PATH__/a /b\n") == "/a:/b")  // fish
    #expect(ScriptCommand.shellPath(fromOutput: "no marker") == nil)
    let script = try parse("#!/bin/sh\n")
    let environment = ScriptCommand.environment(
      inherited: [
        "HOME": "/Users/me", "USER": "me", "DYLD_INSERT_LIBRARIES": "x", "SECRET_TOKEN": "t",
      ], path: "/usr/bin", script: script, dataDirectory: "/data", version: "0.8.0",
      language: "zh_CN.UTF-8")
    #expect(
      environment == [
        "HOME": "/Users/me", "USER": "me", "PATH": "/usr/bin", "LANG": "zh_CN.UTF-8",
        "KITTY_SCRIPT_DIR": "/tmp/scripts", "KITTY_DATA_DIR": "/data", "KITTY_VERSION": "0.8.0",
      ])
    #expect(ScriptCommand.language(Locale(identifier: "zh_CN")) == "zh_CN.UTF-8")
    // 系统里没有的组合（en_CN）退回 en_US.UTF-8：要紧的是 UTF-8
    #expect(
      ScriptCommand.language(Locale(identifier: "en_CN"), exists: { _ in false }) == "en_US.UTF-8")
  }

  @Test func invocations() {
    func script(
      _ title: String, _ keyword: String?, args: Int = 1, optional: Bool = false, list: Bool = false
    )
      -> ScriptCommand
    {
      var script = ScriptCommand(path: "/s/\(title).sh", title: title, interpreter: ["/bin/sh"])
      script.keyword = keyword
      script.arguments = (0..<args).map { .init(placeholder: "参数\($0 + 1)", isOptional: optional) }
      if list { script.mode = .list }
      return script
    }
    let weather = script("天气", "tq")
    let pair = script("Unix 时间戳", "t", args: 2)
    let plain = script("说你好", "hi", args: 0)
    let base = script("Base64", "b64", args: 0, list: true)
    let scripts = [weather, pair, plain, base]
    let alias: (ScriptCommand) -> String? = { $0.keyword }
    let tq = ScriptCommand.invocation(for: "TQ  北京 海淀", in: scripts, alias: alias)
    #expect(tq?.script == weather && tq?.keyword == "TQ" && tq?.arguments == ["北京 海淀"])
    // 标题也认（取长的）、两个参数按空白切、最后一段拿剩下的
    let unix = ScriptCommand.invocation(for: "unix 时间戳 1700000000 毫秒 本地", in: scripts, alias: alias)
    #expect(unix?.script == pair && unix?.arguments == ["1700000000", "毫秒 本地"])
    // 只打了关键词（没有空格）、关键词后面紧跟字、不要参数的脚本：都不算
    #expect(ScriptCommand.invocation(for: "tq", in: scripts, alias: alias) == nil)
    #expect(ScriptCommand.invocation(for: "tqx 北京", in: scripts, alias: alias) == nil)
    #expect(ScriptCommand.invocation(for: "hi there", in: scripts, alias: alias) == nil)
    // 列表脚本没声明参数也收；空着的不算一个参数、算「没填够」
    #expect(
      ScriptCommand.invocation(for: "b64 aGk=", in: scripts, alias: alias)?.arguments == ["aGk="])
    let empty = ScriptCommand.invocation(for: "tq ", in: scripts, alias: alias)
    #expect(empty?.arguments == [] && empty?.isMissing == true)
    #expect(ScriptCommand.invocation(for: "b64 ", in: scripts, alias: alias)?.isMissing == false)
    // 改过的别名：原来的词不再认
    #expect(ScriptCommand.invocation(for: "tq 北京", in: scripts, alias: { _ in "w" }) == nil)
    #expect(ScriptCommand.split("a  b c", into: 2) == ["a", "b c"])
    #expect(ScriptCommand.split("  ", into: 3) == [])
  }

  @Test func listLines() {
    #expect(
      ScriptCommand.lines("YUdrPQ==\t编码\n\nhi\t解码\n  只有标题  \n")
        == [
          .init(title: "YUdrPQ==", subtitle: "编码"), .init(title: "hi", subtitle: "解码"),
          .init(title: "只有标题"),
        ])
    let json = """
      {"items": [
        {"title": "第一条", "subtitle": "说明", "arg": "要粘贴的", "uid": "x"},
        {"title": "不能选", "valid": false},
        {"title": "数组", "arg": ["a", "b"]},
        {"subtitle": "没有标题的不要"}
      ]}
      """
    #expect(
      ScriptCommand.lines(json) == [
        .init(title: "第一条", subtitle: "说明", arg: "要粘贴的"),
        .init(title: "不能选", isValid: false), .init(title: "数组", arg: "a\nb"),
      ])
    #expect(ScriptCommand.lines(json)[0].value == "要粘贴的")
    #expect(ScriptCommand.lines(String(repeating: "x\n", count: 500)).count == 200)
  }
}

/// 真跑脚本、读文件夹：每个测试一个临时文件夹
struct ScriptRunTests {
  let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(path: "kitty-scripts-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func write(_ name: String, _ text: String) throws -> URL {
    let url = folder.appending(path: name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func script(_ name: String, _ text: String) throws -> ScriptCommand {
    let url = try write(name, text)
    return try #require(ScriptCommand.parse(text, path: url.path)).get()
  }

  @Test func runsWithFolderEnvironmentAndArguments() async throws {
    // 没给可执行权限也能跑（按 #! 调解释器）；工作目录是脚本所在的文件夹；只给几样环境变量
    let script = try script(
      "env.sh",
      "#!/bin/zsh\nprint -r -- \"$1|$2|$(pwd -P)|$KITTY_SCRIPT_DIR|${DYLD_INSERT_LIBRARIES:-none}\"\n"
    )
    let outcome = await ScriptRunner.run(script, arguments: ["一 二", "x"], path: "/usr/bin:/bin")
    #expect(outcome.succeeded)
    // 临时目录在 /var 下，pwd -P 给的是 /private/var（URL 的 resolvingSymlinksInPath 反而会去掉 /private）
    let real = folder.path.hasPrefix("/var/") ? "/private" + folder.path : folder.path
    #expect(outcome.output == "一 二|x|\(real)|\(folder.path)|none\n")
  }

  @Test func reportsFailuresTimeoutsAndStops() async throws {
    let failing = try script(
      "fail.sh", "#!/bin/sh\necho partial\necho 'no such thing' >&2\nexit 3\n")
    let failed = await ScriptRunner.run(failing, arguments: [], path: "/usr/bin:/bin")
    #expect(failed.end == .finished(3))
    #expect(ScriptCommand.lastLine(failed.error) == "no such thing")
    // 等输入的脚本读到文件结尾，不会挂着
    let reading = try script("read.sh", "#!/bin/sh\nread line\necho \"got:$line\"\n")
    #expect(
      await ScriptRunner.run(reading, arguments: [], path: "/usr/bin:/bin").output == "got:\n")
    // 超时
    var slow = try script("slow.sh", "#!/bin/sh\nexec sleep 30\n")
    slow.timeout = 1
    let timedOut = await ScriptRunner.run(slow, arguments: [], path: "/usr/bin:/bin")
    #expect(timedOut.end == .timedOut)
    // 停止（任务取消）
    slow.timeout = 0
    let task = Task { await ScriptRunner.run(slow, arguments: [], path: "/usr/bin:/bin") }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    #expect(await task.value.end == .stopped)
    // 解释器不在
    let missing = try script("missing.sh", "#!/no/such/interpreter\n")
    guard
      case .failedToStart(let reason) = await ScriptRunner.run(
        missing, arguments: [], path: "/usr/bin"
      ).end
    else {
      Issue.record("应该起不来")
      return
    }
    #expect(reason.contains("/no/such/interpreter"))
  }

  @Test func scansFoldersAndDownloadMarks() async throws {
    _ = try write("b.sh", "#!/bin/sh\n# @kitty.title 第二个\n")
    _ = try write("a.sh", "#!/bin/sh\n# @kitty.title 第一个\n")
    _ = try write("fill.template.sh", "#!/bin/sh\n")
    _ = try write("broken.py", "print('no shebang')\n")
    _ = try write("icon.png", "not really")
    let downloaded = try write("got.sh", "#!/bin/sh\n# @kitty.title 下载的\n")
    let mark = try await Subprocess.run(
      "/usr/bin/xattr",
      ["-w", "com.apple.quarantine", "0083;00000000;Safari;", downloaded.path])
    #expect(mark.status == 0)
    try FileManager.default.createDirectory(
      at: folder.appending(path: "sub"), withIntermediateDirectories: true)
    _ = try write("sub/deep.sh", "#!/bin/sh\n")
    let scan = await ScriptLibrary.scan([folder, folder])  // 同一个文件夹加了两次只算一遍
    #expect(scan.scripts.map(\.title) == ["第一个", "第二个", "下载的"])
    #expect(scan.scripts.map(\.isDownloaded) == [false, false, true])
    #expect(scan.problems.map(\.problem) == [.noShebang])
    // 确认过：去掉下载标记
    #expect(await ScriptRunner.clearDownloaded(downloaded.path))
    #expect(!ScriptRunner.isDownloaded(downloaded))
  }
}

/// 启动器里的脚本行
@MainActor struct LauncherScriptTests {
  private func model(_ scripts: [ScriptCommand]) throws -> LauncherModel {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.scripts = { scripts }
    return model
  }

  private func script(
    _ title: String, keyword: String? = nil, path: String? = nil, confirm: String? = nil,
    downloaded: Bool = false
  ) -> ScriptCommand {
    var script = ScriptCommand(
      path: path ?? "/tmp/s/\(title).sh", title: title, interpreter: ["/bin/sh"])
    script.keyword = keyword
    script.confirmation = confirm
    script.isDownloaded = downloaded
    return script
  }

  @Test func listedAndAliasFirst() throws {
    let model = try model([
      script("时间戳", keyword: "time"), script("Timer Reset"), script("生成 UUID", keyword: "uuid"),
    ])
    model.query = "shijian"
    #expect(model.results.first?.title == "时间戳")
    #expect(model.results.first?.kind == .script)
    // 别名一字不差排第一，压过同样以 time 开头的
    model.query = "time"
    #expect(model.results.first?.title == "时间戳")
    #expect(
      LauncherModel.aliased(
        [.script(script("A", keyword: "a"), alias: "a")], scripts: [script("A", keyword: "a")],
        query: " A "
      ).count == 1)
    // 副标题没写说明时是文件夹名
    #expect(model.results.first?.subtitle == "s")
  }

  @Test func runsConfirmsAndReviews() async throws {
    let plain = script("说你好", keyword: "hi")
    let guarded = script("清空下载", keyword: "clean", confirm: "再按 ↩ 清空下载文件夹")
    let downloaded = script("网上的", keyword: "net", downloaded: true)
    let model = try model([plain, guarded, downloaded])
    var ran: [String] = []
    model.runScript = { script, _ in
      ran.append(script.title)
      return .init(end: .finished(0), output: "hello\n")
    }
    model.readScript = { _ in ("#!/bin/sh\nrm -rf ~/Downloads/*\n", false) }

    model.query = "hi"
    model.execute(try #require(model.results.first))
    await model.scriptRun(plain.path)
    #expect(ran == ["说你好"])

    // 写了 confirm 的：第一下只上膛
    model.query = "clean"
    let item = try #require(model.results.first)
    model.execute(item)
    #expect(model.isArmed(item) && ran == ["说你好"])
    #expect(model.alternateSubtitle(for: item) == "再按 ↩ 清空下载文件夹")
    model.execute(item)
    await model.scriptRun(guarded.path)
    #expect(ran == ["说你好", "清空下载"])

    // 下载来的：先看全文，Esc 回去不跑；↩ 运行之后这次运行里不再问
    model.query = "net"
    model.execute(try #require(model.results.first))
    #expect(model.review?.script == downloaded)
    for _ in 0..<20 where model.review?.text == nil { await Task.yield() }
    #expect(model.review?.text?.contains("rm -rf") == true)
    model.cancelReview()
    #expect(model.review == nil && ran.count == 2)
    model.execute(try #require(model.results.first))
    for _ in 0..<20 where model.review?.text == nil { await Task.yield() }
    model.approveReview()
    await model.scriptRun(downloaded.path)
    #expect(ran.last == "网上的" && model.review == nil)
    model.execute(try #require(model.results.first))
    #expect(model.review == nil)
    await model.scriptRun(downloaded.path)
    #expect(ran.filter { $0 == "网上的" }.count == 2)
  }
}

@MainActor struct LauncherScriptInputTests {
  private func model(_ scripts: [ScriptCommand]) throws -> LauncherModel {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.scripts = { scripts }
    return model
  }

  private func script(
    _ title: String, _ keyword: String, mode: ScriptCommand.Mode = .island,
    arguments: [ScriptCommand.Argument] = []
  ) -> ScriptCommand {
    var script = ScriptCommand(path: "/tmp/s/\(keyword).sh", title: title, interpreter: ["/bin/sh"])
    script.keyword = keyword
    script.mode = mode
    script.arguments = arguments
    return script
  }

  @Test func argumentsCompleteThenRun() async throws {
    let weather = script("天气", "tq", arguments: [.init(placeholder: "城市")])
    let model = try model([weather])
    var given: [[String]] = []
    model.runScript = { _, arguments in
      given.append(arguments)
      return .init(end: .finished(0), output: "晴\n")
    }
    // 只打了关键词：普通那一行，↩ 先补「tq 空格」
    model.query = "tq"
    let row = try #require(model.results.first)
    #expect(model.primaryAction(for: row).title == "补全关键词")
    model.execute(row)
    #expect(model.query == "tq " && given.isEmpty)
    // 没填参数：副标题写要填什么，↩ 不跑
    #expect(model.results.first?.subtitle == "输入「tq 空格 城市」")
    #expect(model.primaryAction(for: try #require(model.results.first)).title == "先填参数")
    model.execute(try #require(model.results.first))
    #expect(given.isEmpty)
    model.query = "tq 北京"
    #expect(model.results.first?.subtitle == "「北京」")
    model.execute(try #require(model.results.first))
    await model.scriptRun(weather.path)
    #expect(given == [["北京"]])
  }

  @Test func listRerunsAndShowsRows() async throws {
    let base = script("Base64", "b64", mode: .list)
    let model = try model([base])
    var runs = 0
    model.runScript = { _, arguments in
      runs += 1
      if arguments == ["bad"] { return .init(end: .finished(1), error: "不是 Base64\n") }
      return .init(end: .finished(0), output: "YUdrPQ==\t编码\nhi\t解码\n")
    }
    model.query = "b64 a"
    model.query = "b64 aGk="  // 撤掉上一次：只跑最后一次
    #expect(model.results.first?.title == "正在运行「Base64」…")
    await model.listRun()
    #expect(runs == 1)
    #expect(model.results.prefix(2).map(\.title) == ["YUdrPQ==", "hi"])
    #expect(model.results.prefix(2).map(\.payload) == ["YUdrPQ==", "hi"])
    #expect(model.primaryAction(for: model.results[0]).title == "粘贴")
    #expect(model.copyTitle(for: model.results[0]) == "复制结果")
    // 再打一个字：跑完之前留着这条脚本上一次的结果
    model.query = "b64 bad"
    #expect(model.results.prefix(2).map(\.title) == ["YUdrPQ==", "hi"])
    await model.listRun()
    // 下面只有网页搜索的兜底：留着错误那行
    #expect(model.results.first?.title == "「Base64」出错了")
    #expect(model.results.first?.subtitle == "不是 Base64" && model.results.first?.payload == nil)
  }

  @Test func fullOutputPage() async throws {
    let json = script(
      "JSON 格式化", "json", mode: .full, arguments: [.init(placeholder: "JSON", isOptional: true)])
    let model = try model([json])
    model.runScript = { _, arguments in
      arguments.isEmpty
        ? .init(end: .finished(0), output: "{\n  \"a\": 1\n}\n")
        : .init(end: .finished(2), output: "", error: "SyntaxError: JSON Parse error\n")
    }
    model.query = "json "
    model.execute(try #require(model.results.first))
    #expect(model.output?.isRunning == true)
    await model.scriptRun(json.path)
    #expect(model.output == .init(script: json, text: "{\n  \"a\": 1\n}", isRunning: false))
    model.closeOutput()
    #expect(model.output == nil)
    model.query = "json {oops"
    model.execute(try #require(model.results.first))
    await model.scriptRun(json.path)
    #expect(model.output?.text == "SyntaxError: JSON Parse error")
    #expect(model.output?.failure == "「JSON 格式化」出错了：SyntaxError: JSON Parse error")
    // 打字回到结果
    model.query = "json"
    #expect(model.output == nil)
  }
}

/// 启动器的「命令」表：别名换回原关键词、原关键词改掉 / 关掉的挡掉、撞词、脚本的别名和开关
@MainActor struct LauncherCommandsTests {
  @Test func settingsRoundTrip() {
    var settings = LauncherCommands.Settings()
    settings.setAlias(" K ", for: "builtin:kill", default: "kill")
    settings.setAlias("kill", for: "builtin:quit", default: "quit")
    settings.setAlias("quit", for: "builtin:quit", default: "quit")  // 改回原来的：不存
    settings.setAlias("", for: "system:lock", default: "lock")  // 清空：不要别名
    settings.set(false, for: "builtin:ip")
    #expect(settings.aliases == ["builtin:kill": " K ", "system:lock": ""])  // 存原样，比的时候折叠
    #expect(settings.alias("builtin:kill", default: "kill") == "k")
    #expect(settings.alias("system:lock", default: "lock") == nil)
    #expect(settings.alias("builtin:port", default: "port") == "port")
    #expect(!settings.isOn("builtin:ip") && settings.isOn("builtin:kill"))
    let restored = LauncherCommands.Settings(
      aliasesText: settings.aliasesText, offText: settings.offText)
    #expect(restored == settings)
    #expect(LauncherCommands.Settings(aliasesText: "不是 JSON", offText: "") == .init())
    #expect(LauncherCommands.Settings().aliasesText == "")
  }

  @Test func canonicalAndPrompts() throws {
    let settings = LauncherCommands.Settings(
      aliases: ["builtin:kill": "k", "builtin:fy": ""], off: ["builtin:ip"])
    #expect(LauncherCommands.canonical("K chrome", settings: settings).query == "kill chrome")
    let old = LauncherCommands.canonical("kill chrome", settings: settings)
    #expect(old.query == "kill chrome" && old.blocked.contains("builtin:kill"))
    #expect(LauncherCommands.canonical("ip", settings: settings).blocked.contains("builtin:ip"))
    #expect(
      LauncherCommands.canonical("fy hello", settings: settings).blocked.contains("builtin:fy"))
    #expect(LauncherCommands.canonical("open a", settings: .init()) == ("open a", []))
    // 提示行：改了别名的换词，清空的、关掉的不出
    let kill = try #require(SystemCommands.promptItems(for: "kill").exact.first)
    let relabeled = try #require(LauncherCommands.relabel(kill, settings: settings))
    #expect(relabeled.subtitle == "输入「k 空格 进程名或 :端口」，↩ 或 Tab 补全关键词")
    #expect(relabeled.completion == "k ")
    let fy = try #require(LauncherModel.translatePrompts(for: "fy").exact.first)
    #expect(LauncherCommands.relabel(fy, settings: settings) == nil)
    let port = try #require(SystemCommands.promptItems(for: "port").exact.first)
    #expect(LauncherCommands.relabel(port, settings: settings) == port)
  }

  @Test func conflicts() {
    let found = LauncherCommands.conflicts(
      [("a", "k"), ("b", "k"), ("c", "gh"), ("d", nil), ("e", "x")], engineKeywords: ["GH"])
    #expect(found == ["a", "b", "c"])
    let rows = LauncherCommandsSection.rows(scripts: [])
    #expect(rows.count == LauncherCommands.builtIns.count + SystemCommand.allCases.count)
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(
      LauncherCommandsSection.filter(rows, by: "KILL", settings: .init()).map(\.id)
        == ["builtin:kill"])
  }

  @Test func launcherFollowsTheTable() throws {
    var weather = ScriptCommand(path: "/tmp/s/tq.sh", title: "天气", interpreter: ["/bin/sh"])
    weather.keyword = "tq"
    weather.arguments = [.init(placeholder: "城市")]
    var hidden = ScriptCommand(path: "/tmp/s/x.sh", title: "隐藏的脚本", interpreter: ["/bin/sh"])
    hidden.keyword = "xx"
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.scripts = { [weather, hidden] }
    var settings = LauncherCommands.Settings(
      aliases: [
        "builtin:kill": "k", LauncherCommands.scriptID(weather): "w", "system:lock": "suo",
      ],
      off: ["builtin:port", LauncherCommands.scriptID(hidden), "system:sleep"])
    model.commandSettings = { settings }
    model.query = "k chrome"
    #expect(model.commandRequest?.verb == .kill)
    model.query = "kill chrome"
    #expect(model.commandRequest == nil)
    model.query = "port 3000"
    #expect(model.commandRequest == nil)
    // 系统命令：改了别名的按别名搜得到、副标题写别名；关掉的搜不到
    model.query = "suo"
    #expect(model.results.first?.target == "lock" && model.results.first?.subtitle == "suo")
    model.query = "sleep"
    #expect(!model.results.contains { $0.kind == .system && $0.target == "sleep" })
    // 脚本：改了别名的用新别名传参数，旧的不认；关掉的不出现
    model.query = "w 北京"
    #expect(model.results.first?.arguments == ["北京"])
    model.query = "tq 北京"
    #expect(model.results.first?.arguments == nil)
    model.query = "隐藏"
    #expect(!model.results.contains { $0.kind == .script })
    settings = .init()
    model.query = "隐藏"
    #expect(model.results.first?.title == "隐藏的脚本")
  }

  /// 汇率换算（真机反馈：表里要有它）：别名出用法提示、补全的示例不动；关掉后不换算货币、没有候选
  @Test func currencyFollowsTheTable() throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    var settings = LauncherCommands.Settings(aliases: ["builtin:currency": "hl"])
    model.commandSettings = { settings }
    model.query = "hl"
    let prompt = try #require(model.results.first)
    #expect(prompt.target == ExchangeRates.promptTarget && prompt.completion == "100 美元 转 日元")
    model.query = "汇率"
    #expect(!model.results.contains { $0.target == ExchangeRates.promptTarget })
    model.query = "100 usd to cny"
    #expect(model.results.first?.kind == .calculation)  // 还没有汇率表：占位行
    settings = .init(off: ["builtin:currency"])
    model.query = "100 usd to cny"
    #expect(!model.results.contains { $0.kind == .calculation })
    model.query = "100 美元 转 英"
    #expect(!model.results.contains { $0.target.hasPrefix(ExchangeRates.suggestionPrefix) })
    model.query = "12*3"
    #expect(model.results.first?.kind == .calculation)  // 算式照算
    #expect(
      LauncherCommands.builtIns.contains { $0.id == "builtin:currency" && $0.keyword == "汇率" })
  }
}

/// 自带的 9 个脚本（Resources/scripts，拍板 D1）：都读得出来、都标着自带；会改系统设置的两个（深色模式、防止睡眠）只读不跑，
/// 别的真跑一遍（只用 zsh 和 osascript，PATH 给最小的）。正则测试给第二个参数，不读剪贴板
struct BundledScriptTests {
  private func bundled() async throws -> [String: ScriptCommand] {
    let scan = await ScriptLibrary.scan([], bundled: ScriptLibrary.bundledFiles)
    return Dictionary(uniqueKeysWithValues: scan.scripts.map { ($0.keyword ?? "", $0) })
  }

  private func run(_ script: ScriptCommand?, _ arguments: [String]) async throws
    -> ScriptRunner.Outcome
  {
    await ScriptRunner.run(try #require(script), arguments: arguments, path: "/usr/bin:/bin")
  }

  @Test func allNineParse() async throws {
    let scripts = try await bundled()
    #expect(
      Set(scripts.keys) == ["time", "json", "uuid", "bcvt", "url", "b64", "regt", "dark", "awake"])
    #expect(scripts.values.allSatisfy { $0.isBundled && !$0.isDownloaded })
    #expect(scripts["time"]?.mode == .list && scripts["json"]?.mode == .full)
    #expect(scripts["uuid"]?.mode == .paste && scripts["dark"]?.mode == .island)
    #expect(
      LauncherItem.script(try #require(scripts["uuid"]), alias: "uuid").subtitle.contains("UUID"))
  }

  @Test func listScripts() async throws {
    let scripts = try await bundled()
    let seconds = try await run(scripts["time"], ["1700000000"])
    #expect(ScriptCommand.lines(seconds.output).contains { $0.title == "2023-11-14T22:13:20Z" })
    let now = ScriptCommand.lines(try await run(scripts["time"], []).output)
    #expect(now.count == 4 && now[0].subtitle == "秒" && now[1].title.count == 13)
    #expect(try await run(scripts["time"], ["不是时间"]).end == .finished(1))
    let bases = ScriptCommand.lines(try await run(scripts["bcvt"], ["0xff"]).output)
    #expect(bases.map(\.title) == ["255", "0xFF", "0b11111111", "0o377"])
    #expect(try await run(scripts["bcvt"], ["zz"]).end == .finished(1))
    let url = ScriptCommand.lines(try await run(scripts["url"], ["a b&c=中"]).output)
    #expect(url.map(\.value) == ["a%20b%26c%3D%E4%B8%AD", "a b&c=中"])
    let b64 = ScriptCommand.lines(try await run(scripts["b64"], ["aGk="]).output)
    #expect(b64.map(\.value) == ["YUdrPQ==", "hi"])
    #expect(try await run(scripts["bcvt"], ["99999999999999999999"]).end == .finished(1))
    #expect(try await run(scripts["bcvt"], ["0x8000000000000000"]).end == .finished(1))
    let maxValue = ScriptCommand.lines(
      try await run(scripts["bcvt"], ["0x7fffffffffffffff"]).output)
    #expect(maxValue.first?.title == "9223372036854775807")
    #expect(try await run(scripts["time"], ["12345678901234567890"]).end == .finished(1))
    let utc = ScriptCommand.lines(try await run(scripts["time"], ["2026-11-07T06:01:43Z"]).output)
    let offset = ScriptCommand.lines(
      try await run(scripts["time"], ["2026-11-07T14:01:43+08:00"]).output)
    #expect(utc.first?.title == "1794031303" && offset.first?.title == "1794031303")
    let notB64 = ScriptCommand.lines(try await run(scripts["b64"], ["你好"]).output)
    #expect(notB64.count == 2 && !notB64[1].isValid)
    let regex = ScriptCommand.lines(
      try await run(scripts["regt"], ["(\\d)(\\d+)", "订单 123 和 456"]).output)
    #expect(regex.map(\.value) == ["123", "456"])
    #expect(regex[0].subtitle == "第 1 处 · 位置 3 · 分组：1，23")
    let broken = ScriptCommand.lines(try await run(scripts["regt"], ["(", "x"]).output)
    #expect(broken.first?.title == "正则写错了" && broken.first?.isValid == false)
  }

  @Test func pasteAndFullScripts() async throws {
    let scripts = try await bundled()
    let uuid = ScriptCommand.payload(try await run(scripts["uuid"], []).output)
    #expect(
      uuid.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil)
    let json = try await run(scripts["json"], [#"{"a":[1,2],"b":"中"}"#])
    #expect(
      ScriptCommand.payload(json.output) == "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": \"中\"\n}")
    let bad = try await run(scripts["json"], ["{oops"])
    #expect(bad.end == .finished(1))
    #expect(ScriptCommand.lastLine(bad.error)?.hasPrefix("不是有效的 JSON：") == true)
    // 有系统的 jq 时大整数不丢精度（macOS 15 上有没有没核实，没有就退回 JavaScript）
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/jq") {
      let big = try await run(scripts["json"], [#"{"n":1234567890123456789}"#])
      #expect(ScriptCommand.payload(big.output).contains("1234567890123456789"))
    }
  }
}

/// 端到端：启动器里打字 → 真跑包里的自带脚本 → 列表行 / 全文页 / 补关键词（PATH 固定、不读写偏好、不碰剪贴板）
@MainActor struct LauncherScriptEndToEndTests {
  @Test func bundledScriptsThroughTheLauncher() async throws {
    let scan = await ScriptLibrary.scan([], bundled: ScriptLibrary.bundledFiles)
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.scripts = { scan.scripts }
    model.runScript = { await ScriptRunner.run($0, arguments: $1, path: "/usr/bin:/bin") }
    // 脚本给的那几行（下面还接着普通结果和网页搜索兜底）
    var rows: [LauncherItem] { model.results.filter { $0.kind == .scriptResult } }

    model.query = "b64 aGk="
    await model.listRun()
    #expect(rows.map(\.payload) == ["YUdrPQ==", "hi"])
    model.query = "bcvt 0b1010"
    await model.listRun()
    #expect(rows.map(\.title) == ["10", "0xA", "0b1010", "0o12"])
    model.query = #"regt \d+ 订单 7 和 42"#
    await model.listRun()
    #expect(rows.map(\.title) == ["7", "42"])
    model.query = "url 中 文"
    await model.listRun()
    #expect(rows.map(\.payload) == ["%E4%B8%AD%20%E6%96%87", "中 文"])

    // 只打了关键词：↩ 先补「time 」，补上就跑、列出 4 行
    model.query = "time"
    let row = try #require(model.results.first { $0.kind == .script })
    #expect(model.primaryAction(for: row).title == "补全关键词")
    model.execute(row)
    #expect(model.query == "time ")
    await model.listRun()
    #expect(rows.count == 4 && rows[0].subtitle == "秒" && model.results.first == rows.first)

    // 全文：JSON 排好放在输出页；坏的 JSON 红字写原因
    model.query = #"json {"a":[1,"中"]}"#
    let json = try #require(scan.scripts.first { $0.keyword == "json" })
    model.execute(try #require(model.results.first))
    await model.scriptRun(json.path)
    #expect(model.output?.text == "{\n  \"a\": [\n    1,\n    \"中\"\n  ]\n}")
    #expect(model.output?.failure == nil)
    model.closeOutput()
    model.query = "json {oops"
    model.execute(try #require(model.results.first))
    await model.scriptRun(json.path)
    #expect(model.output?.failure?.hasPrefix("「JSON 格式化」出错了：不是有效的 JSON") == true)
  }
}

/// 评审（2026-11-07）发现的问题：每条一个回归
@MainActor struct ScriptReviewFixTests {
  @Test func listRowsDoNotSwallowNormalResults() async throws {
    var time = ScriptCommand(path: "/tmp/s/time.sh", title: "Unix 时间戳", interpreter: ["/bin/sh"])
    time.keyword = "time"
    time.mode = .list
    time.arguments = [.init(placeholder: "时间戳", isOptional: true)]
    let machine = LauncherItem(
      kind: .app, target: "/Applications/Time Machine.app", title: "Time Machine", subtitle: "",
      names: ["time machine"].map(LauncherMatch.fold))
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [machine])
    model.scripts = { [time] }
    model.runScript = { _, arguments in
      arguments == ["machine"]
        ? .init(end: .finished(1), error: "认不出「machine」\n")
        : .init(end: .finished(0), output: "1\t秒\n")
    }
    // 结果到之前：「正在运行…」一行在最上面，时间机器照样在下面
    model.query = "time machine"
    #expect(model.results.first?.title == "正在运行「Unix 时间戳」…")
    #expect(model.results.contains { $0.title == "Time Machine" })
    // 跑失败了、下面有别的结果：不留错误那行
    await model.listRun()
    #expect(model.results.first?.title == "Time Machine")
    #expect(!model.results.contains { $0.kind == .scriptResult })
    // 跑成了：结果在最上面
    model.query = "time 1"
    await model.listRun()
    #expect(model.results.first?.title == "1")
  }

  @Test func reviewCannotBeSkipped() async throws {
    var script = ScriptCommand(path: "/tmp/s/big.sh", title: "大脚本", interpreter: ["/bin/sh"])
    script.keyword = "big"
    script.isDownloaded = true
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.scripts = { [script] }
    var ran = 0
    model.runScript = { _, _ in
      ran += 1
      return .init(end: .finished(0))
    }
    model.readScript = { _ in ("#!/bin/sh\n# 前面全是注释", true) }
    model.query = "big"
    model.execute(try #require(model.results.first))
    // 全文还没读到：↩ 不放行
    model.approveReview()
    #expect(ran == 0)
    model.execute(try #require(model.results.first))
    for _ in 0..<20 where model.review?.text == nil { await Task.yield() }
    // 没显示全：不放行
    #expect(model.review?.isTruncated == true)
    model.approveReview()
    #expect(ran == 0 && model.review != nil)
    model.readScript = { _ in ("#!/bin/sh\n# 前面全是注释", false) }
    model.cancelReview()
    model.execute(try #require(model.results.first))
    for _ in 0..<20 where model.review?.text == nil { await Task.yield() }
    model.approveReview()
    await model.scriptRun(script.path)
    #expect(ran == 1)
  }

  @Test func aliasEqualToAnotherKeywordKeepsTheOriginal() {
    let settings = LauncherCommands.Settings(aliases: ["builtin:find": "open"])
    #expect(LauncherCommands.canonical("open 报告", settings: settings).query == "open 报告")
    #expect(LauncherCommands.canonical("find 报告", settings: settings).blocked == ["builtin:find"])
  }

  @Test func longAliasListsSurviveExport() {
    #expect(SettingsArchive.kinds[Prefs.launcherCommandAliases] == .text)
    #expect(SettingsArchive.kinds[Prefs.launcherCommandsOff] == .text)
    let long = String(
      repeating: "script:~/Library/Application Support/x/scripts/a.sh\n", count: 300)
    #expect(SettingsArchive.Kind.text.plist(.string(long)) as? String == long)
    #expect(SettingsArchive.Kind.string.plist(.string(long)) == nil)
  }
}

/// 子进程：不理 SIGTERM 的到点也停得掉，输出写太多的停掉
struct SubprocessStopTests {
  @Test func stopsStubbornAndChattyProcesses() async throws {
    // 不量用了多久：看门狗和补 SIGKILL 的任务在主线程上（Subprocess 的超时只当兜底用），全量单测时主线程被别的测试
    // 占着会晚到一两分钟（单独跑约 1.3 秒）。所以脚本自己要撑得比那久（sleep 600），写得也要慢（不然晚到的这段时间里
    // 把临时目录写满）
    let stubborn = try await Subprocess.run(
      "/bin/sh", ["-c", "trap '' TERM; sleep 600"], captures: true, timeout: .milliseconds(300))
    #expect(stubborn.signaled && stubborn.status == SIGKILL)
    let chatty = try await Subprocess.run(
      "/bin/sh", ["-c", "while :; do printf '%0999d\\n' 0; sleep 0.01; done"], captures: true,
      timeout: .seconds(600), outputLimit: 1024)
    #expect(chatty.overflowed && chatty.output.utf8.count == 1024)
  }

  @Test func scansSymlinkedScripts() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "kitty-link-\(UUID())")
    let other = FileManager.default.temporaryDirectory.appending(path: "kitty-real-\(UUID())")
    for url in [folder, other] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try "#!/bin/sh\n# @kitty.title 链接来的\n".write(
      to: other.appending(path: "real.sh"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: folder.appending(path: "link.sh"), withDestinationURL: other.appending(path: "real.sh"))
    let scan = await ScriptLibrary.scan([folder])
    #expect(scan.scripts.map(\.title) == ["链接来的"])
  }
}

/// 第二轮（2026-11-07）：给 AI 的写法说明、从剪贴板新建、启动器里的两条内置动作
@MainActor struct ScriptRoundTwoTests {
  @Test func guideMatchesTheParser() throws {
    let guide = ScriptAIGuide.text
    // 写法说明里要有代码认的每个字段、每种结果方式（改了写法要同步改说明）
    for field in [
      "title", "keyword", "mode", "argument1", "description", "icon", "confirm", "timeout",
    ] {
      #expect(guide.contains("@kitty.\(field)"), "说明里缺 @kitty.\(field)")
    }
    for mode in ScriptCommand.Mode.allCases {
      #expect(guide.contains("`\(mode.rawValue)`"), "说明里缺 mode \(mode.rawValue)")
    }
    // 说明里的例子本身能用
    let start = try #require(guide.range(of: "```zsh\n"))
    let end = try #require(guide.range(of: "\n```", range: start.upperBound..<guide.endIndex))
    let example = String(guide[start.upperBound..<end.lowerBound])
    let script = try #require(ScriptCommand.parse(example, path: "/s/tq.sh")).get()
    #expect(script.title == "查天气" && script.keyword == "tq" && script.arguments.count == 1)
    #expect(script.icon == .emoji("⛅"))
  }

  @Test func scriptFromClipboard() {
    let fenced = "这是脚本：\n```zsh\n#!/bin/zsh\n# @kitty.keyword short-url\necho hi\n```\n"
    #expect(ScriptLibrary.scriptText(fromClipboard: fenced) == nil)  // 前面还有别的话：不认
    let block = "```zsh\n#!/bin/zsh\n# @kitty.keyword short-url\necho hi\n```"
    let text = ScriptLibrary.scriptText(fromClipboard: block)
    #expect(text == "#!/bin/zsh\n# @kitty.keyword short-url\necho hi\n")
    #expect(
      ScriptLibrary.scriptText(fromClipboard: "  #!/bin/sh\necho 1  ") == "#!/bin/sh\necho 1\n")
    #expect(ScriptLibrary.scriptText(fromClipboard: "echo 1") == nil)
    #expect(ScriptLibrary.suggestedName(for: text ?? "") == "short-url.sh")
    #expect(ScriptLibrary.suggestedName(for: "#!/bin/sh\n# @kitty.keyword ../../x\n") == "x.sh")
    #expect(ScriptLibrary.suggestedName(for: "#!/bin/sh\n") == "新脚本.sh")
  }

  @Test func launcherHasNewScriptActions() throws {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.query = "新建脚本"
    #expect(model.results.first?.target == LauncherItem.newScriptID)
    model.query = "写法说明"
    #expect(model.results.first?.target == LauncherItem.scriptGuideID)
    model.scriptsOn = { false }
    model.query = "新建脚本"
    #expect(!model.results.contains { $0.target == LauncherItem.newScriptID })
  }
}

/// 第二轮第 2 批：网址图标、深色图标、命令表的排法和筛选
@MainActor struct ScriptIconTests {
  @Test func parsesDarkAndRemoteIcons() throws {
    let script = try #require(
      ScriptCommand.parse(
        """
        #!/bin/zsh
        # @kitty.title 图标
        # @kitty.icon https://example.com/a.png
        # @kitty.iconDark dark.png
        """, path: "/tmp/s/a.sh")
    ).get()
    #expect(script.icon == .remote("https://example.com/a.png"))
    #expect(script.iconDark == .image("/tmp/s/dark.png"))
    let community = try #require(
      ScriptCommand.parse(
        "#!/bin/sh\n# @raycast.title A\n# @raycast.iconDark 🌙\n", path: "/tmp/s/b.sh")
    ).get()
    #expect(community.iconDark == .emoji("🌙"))
  }

  @Test func cacheNamesAndImageCheck() throws {
    let name = ScriptIcons.cacheName("https://example.com/a.png")
    #expect(name.count == 64 && name.allSatisfy(\.isHexDigit))
    #expect(name != ScriptIcons.cacheName("https://example.com/b.png"))
    #expect(!ScriptIcons.isImage(Data("not an image".utf8)))
    let png = try #require(
      NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in true }
        .tiffRepresentation)
    #expect(ScriptIcons.isImage(png))
  }

  @Test func localAndRemoteFailures() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "script-icons-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let missing = folder.appending(path: "nope.png").path(percentEncoded: false)
    #expect(await ScriptIcons.readLocal(missing) == .failure(.missing("nope.png")))
    let text = folder.appending(path: "a.png")
    try Data("hello".utf8).write(to: text)
    #expect(await ScriptIcons.readLocal(text.path(percentEncoded: false)) == .failure(.notImage))
    // http 不下载；缓存里有就直接用（不联网）
    #expect(
      await ScriptIcons.fetch("http://example.com/a.png", cache: folder) == .failure(.download))
    let png = try #require(
      NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in true }
        .tiffRepresentation)
    let address = "https://example.invalid/a.png"
    try png.write(to: folder.appending(path: ScriptIcons.cacheName(address)))
    #expect(await ScriptIcons.fetch(address, cache: folder) == .success(png))
  }

  @Test func tableOrderAndFilters() {
    var mine = ScriptCommand(path: "/tmp/s/z.sh", title: "测试", interpreter: ["/bin/sh"])
    mine.keyword = "zz"
    let other = ScriptCommand(path: "/tmp/s/a.sh", title: "Alpha", interpreter: ["/bin/sh"])
    var bundled = ScriptCommand(path: "/b/script-time.sh", title: "时间戳", interpreter: ["/bin/sh"])
    bundled.isBundled = true
    let rows = LauncherCommandsSection.rows(scripts: [mine, bundled, other])
    // 我的脚本 → 自带脚本 → 关键词命令 → 系统命令；组里按名字
    #expect(rows.prefix(3).map(\.title) == ["Alpha", "测试", "时间戳"])
    let groups = rows.map(\.group)
    #expect(
      groups
        == groups.sorted { a, b in
          let order = LauncherCommandsSection.Row.Group.allCases
          return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        })
    let settings = LauncherCommands.Settings(off: [LauncherCommands.scriptID(mine), "system:lock"])
    #expect(
      LauncherCommandsSection.filter(rows, by: "", scope: .mine, settings: settings).map(\.title)
        == ["Alpha", "测试"])
    #expect(
      LauncherCommandsSection.filter(rows, by: "", scope: .mine, onlyOn: true, settings: settings)
        .map(\.title) == ["Alpha"])
    let builtIn = LauncherCommandsSection.filter(rows, by: "", scope: .builtIn, settings: settings)
    #expect(builtIn.allSatisfy { $0.group == .keyword || $0.group == .system })
    #expect(builtIn.contains { $0.id == "system:lock" })
    #expect(
      !LauncherCommandsSection.filter(
        rows, by: "", scope: .builtIn, onlyOn: true, settings: settings
      )
      .contains { $0.id == "system:lock" })
    #expect(
      LauncherCommandsSection.filter(rows, by: "zz", scope: .bundled, settings: settings).isEmpty)
  }
}
