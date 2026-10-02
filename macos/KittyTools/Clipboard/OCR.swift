// 图片文字识别（Vision，设备端）：剪贴板图片（让截图里的文字能被搜索到）、截图翻译、识字共用；识字还认二维码 / 条码。
// 剪贴板图片的后台识字放在子进程里（第二轮体检 M2，文件末尾「子进程识字」）：识字模型一加载就常驻 45–52 MB，
// 让它跟着子进程退掉；截图翻译、识字、钉图这些当场要结果的照旧在进程内识（用过一次模型就留着，已知取舍）。
// 分段（体检 A32）：按行框的纵向间距和句末短行切段，段内的行按中日文 / 其它文字的规则接起来；截图翻译总是按段送去翻，
// 识字按设置 › 截图的开关；翻译的「把同一段里的换行接起来」调这里的 joiningLines（纯文本按空行分段），段内接行和识字同一个 joinLine。

import Foundation
import OSLog
import Vision

nonisolated enum OCR {
  /// 剪贴板入库文字上限：超大图可能识别出巨量文字（截图翻译不套，翻译那边另有 32KB 上限）
  static let maxCharacters = 4096

  /// 识别失败返回 nil；图里没有文字返回 ""
  @concurrent static func recognizeText(in url: URL) async -> String? {
    guard let observations = try? await request().perform(on: url) else { return nil }
    return String(join(observations).prefix(maxCharacters))
  }

  /// 截图翻译、识字：带行框的一行行（Vision 顺序，左右分栏时先左栏后右栏）；识别失败 nil、没有文字 []
  @concurrent static func recognizeLines(in image: CGImage) async -> [Line]? {
    guard let observations = try? await request().perform(on: image) else { return nil }
    return observations.compactMap { observation in
      guard
        let text = observation.topCandidates(1).first?.string
          .trimmingCharacters(in: .whitespaces), !text.isEmpty
      else { return nil }
      return Line(text: text, box: observation.boundingBox.cgRect)
    }
  }

  /// 识别出的一行：文字 + 行框（归一化坐标、原点左下，同 Vision）
  struct Line: Equatable, Sendable {
    var text: String
    var box: CGRect
  }

  /// 只开自动识别语种、不给语言提示。实测：写死简中 / 繁中 / 英文会丢日文假名、韩文识别为空、
  /// 俄文变拉丁乱码（PLAN §11 #21）；给第一 / 第二语言作提示，中日韩混排图里日文、韩文整行丢失
  private static func request() -> RecognizeTextRequest {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate  // .fast 不支持中日韩
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = []
    return request
  }

  /// 二维码 / 条码的内容（有几个返回几个，重复的去掉）。识字时有码优先用码
  @concurrent static func barcodes(in image: CGImage) async -> [String] {
    guard let observations = try? await DetectBarcodesRequest().perform(on: image) else {
      return []
    }
    var seen = Set<String>()
    return observations.compactMap(\.payloadString).filter {
      !$0.isEmpty && seen.insert($0).inserted
    }
  }

  /// 按行框切段（纯函数，配单测）：两种情况断段——① 这一行和上一行的纵向间距大于 1.2 倍中位行高（空了一行、段间距）；
  /// ② 上一行以句末标点结尾、且不到中位行宽的 80%（段落最后一行）。另外往回跳（这一行在上一行上面，换栏）、
  /// 和上一行并排（同一高度的另一块）也断开。ponytail: 不看缩进和左边界（容易误判列表、代码）；
  /// macOS 26 的 RecognizeDocumentsRequest 直接给段落，有 26 测试机再换
  static func paragraphs(_ lines: [Line]) -> [[String]] {
    guard !lines.isEmpty else { return [] }
    let heights = lines.map(\.box.height).sorted()
    let widths = lines.map(\.box.width).sorted()
    let lineHeight = heights[heights.count / 2]
    let lineWidth = widths[widths.count / 2]
    var result: [[String]] = []
    var previous: Line?
    for line in lines {
      if let previous {
        let gap = previous.box.minY - line.box.maxY
        let endsSentence = previous.text.last.map { "。！？.!?".contains($0) } ?? false
        let breaks =
          gap > 1.2 * lineHeight || gap < -0.5 * lineHeight
          || (endsSentence && previous.box.width < 0.8 * lineWidth)
        if breaks { result.append([]) }
      } else {
        result.append([])
      }
      result[result.count - 1].append(line.text)
      previous = line
    }
    return result
  }

  /// 识别结果写成文字：joined = 段内的行接起来、段间用 separator（识字「接起来」开着时 \n，截图翻译 \n\n）；
  /// 不接时一行一行原样（\n）
  static func text(_ lines: [Line], joined: Bool, separator: String = "\n") -> String {
    guard joined else { return lines.map(\.text).joined(separator: "\n") }
    return paragraphs(lines).map { joinLine($0) }.joined(separator: separator)
  }

  /// 纯文本的「把同一段里的换行接起来」（翻译前的预处理）：空行分段（段间换成 paragraphSeparator），
  /// 段内的行按 joinLine 接起来。纯函数，配单测
  static func joiningLines(_ text: String, paragraphSeparator: String = "\n") -> String {
    text.split(separator: /\n[ \t\r]*\n\s*/)
      .map { joinLine($0.split(whereSeparator: \.isNewline)) }
      .filter { !$0.isEmpty }
      .joined(separator: paragraphSeparator)
  }

  /// 同一段里的行接成一行：中日文字之间直接连，其它加一个空格。行尾是紧跟字母的连字符时不加空格：下一行小写开头
  /// 是断开的单词（exam-/ple → example），去掉连字符；大写开头是复合词（State-/Of-the-art），连字符留着
  static func joinLine<S: StringProtocol>(_ lines: [S]) -> String {
    lines.reduce(into: "") { joined, line in
      let line = line.trimmingCharacters(in: .whitespaces)
      guard let last = joined.last, let first = line.first else {
        joined += line
        return
      }
      if last == "-", joined.dropLast().last?.isLetter == true {
        if first.isLowercase { joined.removeLast() }
      } else if !(isCJK(last) || isCJK(first)) {
        joined += " "
      }
      joined += line
    }
  }

  /// 汉字、假名、中日文标点和全角符号（韩文词之间本来就有空格，不算）
  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains {
      switch $0.value {
      case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: true
      default: false
      }
    }
  }

  /// 按 Vision 返回的顺序一行一行拼起来（剪贴板图片的识别文字，只拿来搜索）
  private static func join(_ observations: [RecognizedTextObservation]) -> String {
    observations.compactMap {
      $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
    }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
  }

  // MARK: 子进程识字（剪贴板后台识字）

  /// 子进程就是本 App 的可执行文件带这个参数再起一次：`<可执行文件> --ocr <图片路径>`（入口在 KittyToolsApp.swift 的 Main）
  static let helperFlag = "--ocr"
  /// 子进程最多跑这么久，到点杀掉、退回进程内识（整屏截图实测一两秒；长截图慢一些）
  static let helperTimeout = Duration.seconds(60)

  /// 这次启动是不是子进程识字
  enum Launch: Equatable {
    case recognize(URL)
    /// 带了 --ocr 但参数不对：报错退出，别当成正常启动
    case usage
  }

  /// 看命令行（纯函数）：第一个参数不是 --ocr = 正常启动（nil）
  static func launch(_ arguments: [String]) -> Launch? {
    guard arguments.dropFirst().first == helperFlag else { return nil }
    guard arguments.count == 3, !arguments[2].isEmpty else { return .usage }
    return .recognize(URL(filePath: arguments[2]))
  }

  /// 子进程里跑的：识字，结果写标准输出。退出码 0 = 识出来了（图里没有文字时文字为空），1 = 识别失败，
  /// 2 = 图片不在肯识的两处（helperRoots；这时标准输出什么都不写）
  @concurrent static func runHelper(_ image: URL) async -> Int32 {
    guard let path = helperPath(image, roots: helperRoots) else { return 2 }
    guard let data = readWithoutLinks(path),
      let observations = try? await request().perform(on: data)
    else { return 1 }
    let text = String(join(observations).prefix(maxCharacters))
    FileHandle.standardOutput.write(Data(encode(text).utf8))
    return 0
  }

  /// 子进程模式的参数是信任边界：别的进程可以拿本 App 的可执行文件带 --ocr 起一个（让它自己当责任进程），借本 App 的
  /// 「完全磁盘访问权限」、桌面 / 文稿 / 下载的文件夹授权去读它自己读不到的图，从标准输出拿图里的字。所以只肯识两处的文件：
  /// 本 App 数据目录的 images（算法同 AppDelegate）和当前用户的临时目录（单测、探针的合成图在那里；它不受隐私保护）。
  /// 这里给的是真实路径的前缀
  static var helperRoots: [String] {
    let support = URL.applicationSupportDirectory
    let identifier = Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native"
    let temporary = FileManager.default.temporaryDirectory
    return [
      helperRoot(
        anchor: support.deletingLastPathComponent().deletingLastPathComponent(),
        support.pathComponents.suffix(2) + [identifier, "images"]),
      helperRoot(anchor: temporary.deletingLastPathComponent(), [temporary.lastPathComponent]),
    ].compactMap { $0 }
  }

  /// 一处肯识的目录的真实路径前缀：anchor（用户换不掉的那一层：家目录、临时目录的上一层）解析符号链接，后面几层按字面接上。
  /// 后面这几层用户自己就能改：谁被换成了指向别处的符号链接，里面文件的真实路径就对不上这个前缀，不认
  /// （所以不能把整个目录解析完再比——把 images 换成指向「文稿」的软链就绕过去了）
  static func helperRoot(anchor: URL, _ components: [String]) -> String? {
    guard let base = realPath(anchor) else { return nil }
    return ([base == "/" ? "" : base] + components).joined(separator: "/")
  }

  /// 图片的真实路径（符号链接、`..` 都解析掉）落在 roots 某一处里面才给，否则 nil（不存在的文件也是 nil）
  static func helperPath(_ image: URL, roots: [String]) -> String? {
    guard let path = realPath(image), roots.contains(where: { path.hasPrefix($0 + "/") }) else {
      return nil
    }
    return path
  }

  /// 真实路径；文件不存在是 nil。两步都要：canonicalPath 不跟最后一层的符号链接（文件本身是软链时给的是软链自己），
  /// resolvingSymlinksInPath 会跟，但它把 /private/var 写成 /var，再过一遍 canonicalPath 才是统一的写法
  private static func realPath(_ url: URL) -> String? {
    try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
  }

  /// 按真实路径读文件，路径上哪一层是符号链接都打不开（O_NOFOLLOW_ANY）：检查完到打开之间被人换成软链也读不到别处去。
  /// 读进内存再识，不让 Vision 按路径重新打开
  private static func readWithoutLinks(_ path: String) -> Data? {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW_ANY)
    guard descriptor >= 0 else { return nil }
    return try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).readToEnd()
  }

  /// 子进程的输出：一行头「kitty-ocr <文字的 UTF-8 字节数>」，换行后是文字（已按 maxCharacters 截过）
  static func encode(_ text: String) -> String { "kitty-ocr \(text.utf8.count)\n\(text)" }

  /// 解析子进程的输出：找不到头、字节数对不上（被截断）都是 nil。头前面允许有别的行——Vision 自己会往标准输出写诊断
  /// （实测识别失败时写一行「VTEST: error…」），所以从每一行的开头找头，后面剩下的字节数正好对得上才算
  static func decode(_ output: String) -> String? {
    var rest = output[...]
    while true {
      if rest.hasPrefix("kitty-ocr "), let newline = rest.firstIndex(of: "\n"),
        let count = Int(rest[..<newline].dropFirst("kitty-ocr ".count))
      {
        let text = rest[rest.index(after: newline)...]
        if text.utf8.count == count { return String(text) }
      }
      guard let next = rest.firstIndex(of: "\n") else { return nil }
      rest = rest[rest.index(after: next)...]
    }
  }

  /// 给子进程的环境变量：只带这几样。别把本进程的 DYLD_* 之类带过去——单测宿主的环境里有测试注入，
  /// 子进程是同一个可执行文件，带着它会跟着去加载测试
  static func helperEnvironment(_ environment: [String: String]) -> [String: String] {
    let kept: Set = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "__CF_USER_TEXT_ENCODING"]
    return environment.filter { kept.contains($0.key) }
  }

  /// 剪贴板后台识字：起一个子进程识、识完就退，本进程不加载识字模型。返回值同 recognizeText（失败 nil、没有文字 ""）。
  /// 图片文件不在直接算失败，不起子进程；子进程起不来、超时、非零退出、输出对不上时退回进程内识一次（功能不能丢），记一条日志。
  /// executable 只给单测换（默认是本 App 自己）
  static func recognizeTextInHelper(
    in url: URL, executable: String? = Bundle.main.executablePath
  ) async -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let result: Subprocess.Result? =
      if let executable {
        try? await Subprocess.run(
          executable, [helperFlag, url.path], captures: true,
          environment: helperEnvironment(ProcessInfo.processInfo.environment),
          timeout: helperTimeout, quality: .utility)
      } else {
        nil
      }
    if let result, result.status == 0, let text = decode(result.output) { return text }
    // 状态：-1 = 没起来；15 = 超时被杀；1 = 子进程里识别失败；0 = 输出对不上
    Log.clipboard.error("子进程识字没成（状态 \(result?.status ?? -1)），退回进程内识一次")
    return await recognizeText(in: url)
  }
}
