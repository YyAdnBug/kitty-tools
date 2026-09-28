// 朗读（AVSpeechSynthesizer）：再点同一段文字就停止，浮窗收起时 stop()（体检 B23）。
// 声线：这门语言里品质最高的一个（用户在系统设置里下载过的「高音质 / 优化音质」声线优先），没有就用系统默认；
// 中文用 zh-CN（普通话），语言未知时交给系统。

import AVFoundation
import Observation

@Observable final class Speaker {
  /// 正在朗读的文字（按钮据此高亮）
  private(set) var speaking: String?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  /// 正在念的那一句：委托回调是异步到的，只认它（stop 之后旧句子的「已取消」晚到，不能清掉新的一句）
  @ObservationIgnored private var current: ObjectIdentifier?
  @ObservationIgnored private lazy var delegate = FinishDelegate { [weak self] utterance in
    guard let self, current == utterance else { return }
    current = nil
    speaking = nil
  }

  init() {
    synthesizer.delegate = delegate
  }

  func toggle(_ text: String, language: Lang?) {
    let wasSpeaking = speaking == text
    stop()
    guard !wasSpeaking, !text.isEmpty else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = language.flatMap { Self.voice(for: $0.speechCode) }
    speaking = text
    current = ObjectIdentifier(utterance)
    synthesizer.speak(utterance)
  }

  /// 停下（浮窗收起、换一段朗读）
  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    current = nil
    speaking = nil
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

  /// 委托单独成一个无状态对象（Speaker 本身有可变状态，不能兼当 NSObject 委托）；念完、被系统打断都回调
  private final class FinishDelegate: NSObject, AVSpeechSynthesizerDelegate {
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
  }
}
