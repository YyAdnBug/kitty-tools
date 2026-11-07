// 启动器脚本命令的单测（2026-11-07，PLAN §10「脚本命令」）：开头注释的两种写法、图标 / 参数 / 确认、输出的收拾、环境和 PATH、
// 「关键词 空格 文字」怎么切、列表输出怎么读；
// 真跑临时文件夹里的假脚本（输出、退出码、超时、停止、工作目录、只给几样环境变量）；读文件夹（.template. 不列、没有 #! 的记原因、
// 下载标记）；启动器里的行（搜得到、别名排第一、↩ 跑、上膛、下载来的先看一眼、参数、全文、列表）。不读写用户的偏好：
// PATH 由测试传进去；不碰剪贴板（粘贴 / 复制的路子不在这里按）。

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
    #expect(ScriptCommand.icon("https://x.com/a.png", folder: "/s") == nil)
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
    model.readScript = { _ in "#!/bin/sh\nrm -rf ~/Downloads/*\n" }

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
    #expect(model.results.count == 1 && model.results.first?.subtitle == "「北京」")
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
    #expect(model.results.isEmpty && model.emptyText == "正在运行「Base64」…")
    await model.listRun()
    #expect(runs == 1)
    #expect(model.results.map(\.title) == ["YUdrPQ==", "hi"])
    #expect(model.results.map(\.payload) == ["YUdrPQ==", "hi"])
    #expect(model.primaryAction(for: model.results[0]).title == "粘贴")
    #expect(model.copyTitle(for: model.results[0]) == "复制结果")
    // 再打一个字：跑完之前留着这条脚本上一次的结果
    model.query = "b64 bad"
    #expect(model.results.count == 2)
    await model.listRun()
    #expect(model.results.map(\.title) == ["「Base64」出错了"])
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
