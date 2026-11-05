// 查词卡片（D4）：系统词典的释义，放在翻译结果最上面。和服务卡片同一套外观（Whisker §6 翻译：卡片圆角 10、
// 内边距上 7 / 下 8 / 左右 12、标题行 18、18 pt 色块 + 12 semibold 名字、右上角的按钮是同一个 CardActions）；
// 标题到词头 4，下面每块之间 8、一组里 4：词头 20 semibold + 音标（查的是变形时写「ran 的原形」），
// 按词性分组的义项（词性是小胶囊、变形表次要色，例句次要色斜体）。默认最多三组、每组两条、每条一个例句，
// 「展开全部」看完；双语词典的义项后面跟一句淡色小字的注（informal · personal items），读音分英 / 美（D1–D3）。
// 可以朗读词头、在「词典」App 里打开。字号跟着浮窗的 ⌘+ / ⌘-。

import SwiftUI

struct DictionaryCardView: View {
  let entry: DictionaryEntry
  let language: Lang?
  let speaker: Speaker
  var fontScale = 1.0
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let collapsedGroups = 3
  private static let collapsedSenses = 2

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      header
      VStack(alignment: .leading, spacing: 8) {
        headword
        ForEach(Array(shownGroups.enumerated()), id: \.offset) { _, group in
          groupView(group)
        }
        if hiddenCount > 0 || hidesExamples || expanded {
          Button(expandTitle) { expanded.toggle() }
            .buttonStyle(.plain).foregroundStyle(Style.brandInk).pointerStyle(.link)
            .font(.system(size: 12))
        }
      }
    }
    .textSelection(.enabled)
    // 和服务卡同一套内边距（ProviderCardView：上 7、下 8、左右 12、标题行 18）
    .padding(.horizontal, ProviderCardView.sideInset)
    .padding(.top, 7)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: expanded)
  }

  private var header: some View {
    HStack(spacing: 8) {
      KindTile(symbol: "book.closed.fill", color: Color(nsColor: .systemBrown), size: 18)
      Text("系统词典").font(.system(size: 12, weight: .semibold)).opacity(0.85)
      Spacer(minLength: 6)
      CardActions {
        Button(
          "朗读",
          systemImage: speaker.speaking == entry.headword ? "speaker.wave.2.fill" : "speaker.wave.2"
        ) { speaker.toggle(entry.headword, language: language) }
        .symbolEffect(
          .variableColor.iterative.reversing,
          isActive: speaker.speaking == entry.headword && !reduceMotion)
        Button("在「词典」中打开", systemImage: "book") { openInDictionary() }
          .help("在「词典」App 里看完整释义")
      }
    }
    .frame(height: 18)
  }

  private var headword: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(entry.headword).font(.system(size: 20 * fontScale, weight: .semibold))
      ForEach(Array(entry.phonetics.enumerated()), id: \.offset) { _, phonetic in
        Text(Self.label(phonetic)).font(.system(size: 13 * fontScale)).foregroundStyle(.secondary)
      }
      if let query = entry.query {
        Text("\(query) 的原形").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
    }
  }

  private func groupView(_ group: DictionaryEntry.Group) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if group.partOfSpeech != nil || group.forms != nil {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let partOfSpeech = group.partOfSpeech {
            Text(partOfSpeech)
              .font(.system(size: 11, weight: .semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Style.controlFill, in: .capsule)
          }
          if let forms = group.forms {
            Text(forms).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
          }
        }
      }
      let senses = expanded ? group.senses : Array(group.senses.prefix(Self.collapsedSenses))
      ForEach(Array(senses.enumerated()), id: \.offset) { index, sense in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if group.senses.count > 1 {
            Text("\(index + 1)")
              .font(.system(size: 11, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(.tertiary)
              .frame(minWidth: 12, alignment: .trailing)
          }
          VStack(alignment: .leading, spacing: 2) {
            definition(sense).lineSpacing(2)
            let examples = expanded ? sense.examples : Array(sense.examples.prefix(1))
            ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
              Text(example).font(.system(size: 12 * fontScale)).italic().foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  /// 释义 14 × 字号；双语词典的注跟在同一段后面，11.5 × 字号 tertiary（折行时跟着释义一起排）
  private func definition(_ sense: DictionaryEntry.Sense) -> Text {
    let main = Text(sense.definition).font(.system(size: 14 * fontScale))
    guard let note = sense.note else { return main }
    let tail = Text("  " + note).font(.system(size: 11.5 * fontScale)).foregroundStyle(.tertiary)
    return Text("\(main)\(tail)")
  }

  /// 读音：分口音的写「英 /stʌf/」「美 /stəf/」，不分的照旧「/rən/」
  static func label(_ phonetic: DictionaryEntry.Phonetic) -> String {
    switch phonetic.accent {
    case .uk: "英 /\(phonetic.text)/"
    case .us: "美 /\(phonetic.text)/"
    case nil: "/\(phonetic.text)/"
    }
  }

  private var expandTitle: String {
    if expanded { return "收起" }
    return hiddenCount > 0 ? "展开全部 \(entry.senseCount) 条释义" : "展开全部例句"
  }

  /// 收起时有例句没露出来（露出来的义项里有第二个例句）
  private var hidesExamples: Bool {
    entry.groups.prefix(Self.collapsedGroups).contains { group in
      group.senses.prefix(Self.collapsedSenses).contains { $0.examples.count > 1 }
    }
  }

  private var shownGroups: [DictionaryEntry.Group] {
    expanded ? entry.groups : Array(entry.groups.prefix(Self.collapsedGroups))
  }

  /// 收起时没露出来的义项数
  private var hiddenCount: Int {
    entry.senseCount
      - entry.groups.prefix(Self.collapsedGroups).reduce(0) {
        $0 + min($1.senses.count, Self.collapsedSenses)
      }
  }

  private func openInDictionary() {
    let word =
      entry.headword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
      ?? entry.headword
    if let url = URL(string: "dict://\(word)") { NSWorkspace.shared.open(url) }
  }
}
