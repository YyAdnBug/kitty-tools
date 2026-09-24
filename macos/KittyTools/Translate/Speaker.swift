// 朗读（AVSpeechSynthesizer）：再点同一段文字就停止。中文用 zh-CN 声线（普通话），语言未知时交给系统。

import AVFoundation
import Observation

@Observable final class Speaker {
  /// 正在朗读的文字（按钮据此高亮）
  private(set) var speaking: String?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private lazy var delegate = FinishDelegate { [weak self] in
    self?.speaking = nil
  }

  init() {
    synthesizer.delegate = delegate
  }

  func toggle(_ text: String, language: Lang?) {
    let wasSpeaking = speaking == text
    synthesizer.stopSpeaking(at: .immediate)
    speaking = nil
    guard !wasSpeaking, !text.isEmpty else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = language.flatMap { AVSpeechSynthesisVoice(language: $0.speechCode) }
    speaking = text
    synthesizer.speak(utterance)
  }

  /// 委托单独成一个无状态对象（Speaker 本身有可变状态，不能兼当 NSObject 委托）
  private final class FinishDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: @MainActor @Sendable () -> Void

    init(onFinish: @escaping @MainActor @Sendable () -> Void) {
      self.onFinish = onFinish
    }

    nonisolated func speechSynthesizer(
      _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
      Task { await onFinish() }
    }
  }
}
