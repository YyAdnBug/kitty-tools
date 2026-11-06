// 朗读：再点同一段就停止，浮窗收起时 stop()（体检 B23）。
// - 句子（toggle）：系统声音（AVSpeechSynthesizer），挑这门语言里品质最高的声线（用户在系统设置里下载过的
//   「高音质 / 优化音质」优先），中文用 zh-CN（普通话），语言未知时交给系统。
// - 英文单词（toggleWord，2026-11-05 拍板 R2 R3）：开着「英文单词用真人发音」（默认开）时放有道词典的真人录音
//   （美 / 英两种，一个普通的 GET，不带任何冒充别的客户端的东西）；关着、取不到（没网、3 秒超时、不是音频）时用
//   系统的美式 / 英式声音念。录音按「词 + 口音」记最近 32 个。
// - 拍板的 R4（句子用微软在线神经网络语音）没做：那个接口要冒充 Edge 浏览器的扩展才肯回，违反「只如实标明自己」。
// 卡片该读哪段字（R1：单词卡只读释义、不读音标和例句）和单词卡第一行的读音行（R2）是这里的两个纯函数。

import AVFoundation
import Foundation
import Observation

@Observable final class Speaker {
  typealias Accent = DictionaryEntry.Phonetic.Accent

  /// 正在朗读的那一段的标识（按钮据此高亮）：句子是文字本身，单词是 key(word:accent:)
  private(set) var speaking: String?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var download: Task<Void, Never>?
  /// 正在念的那一句 / 那段录音：委托回调是异步到的，只认它（stop 之后旧的「已取消」晚到，不能清掉新的一段）
  @ObservationIgnored private var current: ObjectIdentifier?
  /// ponytail: 录音记最近 32 个（几 KB 一个），满了整个清掉；要更多再换成按使用时间淘汰
  @ObservationIgnored private var recordings: [String: Data] = [:]
  @ObservationIgnored private lazy var delegate = FinishDelegate { [weak self] id in
    guard let self, current == id else { return }
    current = nil
    player = nil
    speaking = nil
  }

  init() {
    synthesizer.delegate = delegate
  }

  /// 读一段文字（句子、释义）：系统声音
  func toggle(_ text: String, language: Lang?) {
    let wasSpeaking = speaking == text
    stop()
    guard !wasSpeaking, !text.isEmpty else { return }
    speak(text, voice: language.flatMap { Self.voice(for: $0.speechCode) }, as: text)
  }

  /// 读一个英文单词：真人录音，取不到用系统的美式 / 英式声音。accent 为 nil 用设置里的「发音」
  func toggleWord(_ word: String, accent: Accent? = nil) {
    let accent = accent ?? Self.preferredAccent
    let key = Self.key(word: word, accent: accent)
    let wasSpeaking = speaking == key
    stop()
    guard !wasSpeaking, !word.isEmpty else { return }
    let fallback: () -> Void = { [weak self] in
      self?.speak(word, voice: Self.voice(for: accent == .uk ? "en-GB" : "en-US"), as: key)
    }
    guard UserDefaults.standard.bool(forKey: Prefs.translateWordRecording),
      let url = Self.recordingURL(word: word, accent: accent)
    else { return fallback() }
    speaking = key
    download = Task { [weak self] in
      var data = self?.recordings[key]
      if data == nil { data = await Self.fetch(url) }
      guard let self, !Task.isCancelled, speaking == key else { return }
      guard let data, let player = try? AVAudioPlayer(data: data) else { return fallback() }
      if recordings.count >= 32 { recordings.removeAll() }
      recordings[key] = data
      player.delegate = delegate
      self.player = player
      current = ObjectIdentifier(player)
      if !player.play() { fallback() }
    }
  }

  /// 停下（浮窗收起、换一段朗读）
  func stop() {
    download?.cancel()
    download = nil
    synthesizer.stopSpeaking(at: .immediate)
    player?.stop()
    player = nil
    current = nil
    speaking = nil
  }

  private func speak(_ text: String, voice: AVSpeechSynthesisVoice?, as key: String) {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    speaking = key
    current = ObjectIdentifier(utterance)
    synthesizer.speak(utterance)
  }

  /// 一个单词在 speaking 里的标识：同一个词的美音、英音分开亮
  nonisolated static func key(word: String, accent: Accent) -> String {
    "\(word)\u{1F}\(accent == .uk ? "uk" : "us")"
  }

  /// 设置 › 翻译「英文单词发音」：美音（默认）/ 英音
  static var preferredAccent: Accent {
    UserDefaults.standard.string(forKey: Prefs.translateWordAccent) == "uk" ? .uk : .us
  }

  /// 有道词典的真人录音地址：只给像英文词的（字母、连字符、撇号，最多 3 个词、40 个字），别的 nil（用系统声音）
  nonisolated static func recordingURL(word: String, accent: Accent) -> URL? {
    let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = word.split(separator: " ")
    guard !word.isEmpty, word.count <= 40, (1...3).contains(words.count),
      word.allSatisfy({ ($0.isASCII && $0.isLetter) || " -'’".contains($0) })
    else { return nil }
    var components = URLComponents(string: "https://dict.youdao.com/dictvoice")!
    components.queryItems = [
      URLQueryItem(name: "audio", value: word),
      URLQueryItem(name: "type", value: accent == .uk ? "1" : "2"),
    ]
    return components.url
  }

  /// 下载录音：3 秒超时、要 200 和音频类型、不超过 1 MB；不成就 nil（调用方退回系统声音，不报错）
  nonisolated private static func fetch(_ url: URL) async -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    guard let (data, response) = try? await HTTP.session(for: url).data(for: request),
      let http = response as? HTTPURLResponse, http.statusCode == 200,
      http.mimeType?.hasPrefix("audio/") == true, !data.isEmpty, data.count <= 1 << 20
    else { return nil }
    return data
  }

  /// 这门语言品质最高的声线（premium > enhanced > default）；同品质时用系统默认的那个（别挑到怪声线）
  static func voice(for language: String) -> AVSpeechSynthesisVoice? {
    let fallback = AVSpeechSynthesisVoice(language: language)
    let best = AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language == language }
      .max { $0.quality.rawValue < $1.quality.rawValue }
    guard let best, best.quality.rawValue > (fallback?.quality.rawValue ?? 0) else {
      return fallback
    }
    return best
  }

  // MARK: 读哪段字（纯函数，配单测）

  /// 卡片右上角的喇叭读的字（R1）：单词卡只读第一行释义（去掉读音行、拼音行、例句和 n. v. 这类词性记号）；
  /// 别的卡读整段，先去掉 Markdown 记号
  nonisolated static func speechText(_ result: String, wordStyle: Bool) -> String {
    let plain = withoutMarkdown(result)
    guard wordStyle else { return plain }
    let meaning = plain.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { line in
        !line.isEmpty && phonetics(line) == nil && !isPinyinLine(line)
          && !["例", "Example", "e.g."].contains(where: { line.hasPrefix($0) })
      }
    guard let meaning else { return plain }
    let stripped = meaning.replacing(
      /^(?:[A-Za-z]{1,6}\.\s*(?:&\s*[A-Za-z]{1,6}\.\s*)?)+/, with: ""
    )
    .trimmingCharacters(in: .whitespaces)
    return stripped.isEmpty ? meaning : stripped
  }

  /// 单词卡的第一行是读音行（美 /rʌn/  英 /rʌn/）时拆出来：读音和剩下的正文（R2）。第一行还没出完（流式中
  /// 没到换行）、或者不全是读音时为 nil
  nonisolated static func phoneticLine(_ text: String) -> (
    phonetics: [DictionaryEntry.Phonetic], rest: String
  )? {
    guard let newline = text.firstIndex(where: \.isNewline),
      let phonetics = phonetics(String(text[..<newline]))
    else { return nil }
    return (phonetics, String(text[text.index(after: newline)...]))
  }

  /// 一行是不是只有「美 /…/」「英 /…/」（之间随便几个空白；粗体记号去掉再看）
  nonisolated private static func phonetics(_ line: String) -> [DictionaryEntry.Phonetic]? {
    let line = line.replacing("**", with: "").trimmingCharacters(in: .whitespaces)
    let pattern = /(美|英)\s*[\/\[]([^\/\[\]]+)[\/\]]/
    let matches = line.matches(of: pattern)
    guard !matches.isEmpty,
      line.replacing(pattern, with: "").trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return matches.map {
      .init(accent: $0.output.1 == "英" ? .uk : .us, text: String($0.output.2))
    }
  }

  /// 拼音行（汉译英单词卡的第一行 píngguǒ）：全是拼音字母、至少一个带声调
  nonisolated private static func isPinyinLine(_ line: String) -> Bool {
    let tones = Set("āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ")
    return line.contains(where: tones.contains)
      && line.lowercased().allSatisfy {
        ($0.isLetter && $0.isASCII) || tones.contains($0) || " -'ü".contains($0)
      }
  }

  /// 去掉 Markdown 记号：粗体 / 斜体 / 代码的记号、链接只留文字、行首的 # > - * + 和围栏行
  nonisolated static func withoutMarkdown(_ text: String) -> String {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
      .map { line in
        String(line)
          .replacing(/^\s*(?:#{1,6}\s+|>\s?|[-*+]\s+)/, with: "")
          .replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
          .replacing("**", with: "").replacing("__", with: "").replacing("`", with: "")
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 委托单独成一个无状态对象（Speaker 本身有可变状态，不能兼当 NSObject 委托）；念完、被系统打断、录音放完都回调。
  /// 回调线程没写明（同录制的委托，mac-native §3），一律 nonisolated、投回主线程
  private final class FinishDelegate: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    let onFinish: @MainActor @Sendable (ObjectIdentifier) -> Void

    init(onFinish: @escaping @MainActor @Sendable (ObjectIdentifier) -> Void) {
      self.onFinish = onFinish
    }

    nonisolated func speechSynthesizer(
      _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
      let id = ObjectIdentifier(utterance)
      Task { await onFinish(id) }
    }

    nonisolated func speechSynthesizer(
      _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
      let id = ObjectIdentifier(utterance)
      Task { await onFinish(id) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
      let id = ObjectIdentifier(player)
      Task { await onFinish(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
      let id = ObjectIdentifier(player)
      Task { await onFinish(id) }
    }
  }
}
