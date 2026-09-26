// 查词卡片（D4）：系统词典的释义，放在翻译结果最上面。和服务卡片同一套外观（Whisker §6 翻译：卡片圆角 10、
// 18 pt 色块 + 12 semibold 名字、操作平时 0.45 透明度）：词头 20 semibold + 音标（查的是变形时写「ran 的原形」），
// 按词性分组的义项（词性是小胶囊、变形表次要色，例句次要色斜体）。默认最多三组、每组两条，「展开全部」看完；
// 可以朗读词头、在「词典」App 里打开。字号跟着浮窗的 ⌘+ / ⌘-。

import SwiftUI

struct DictionaryCardView: View {
  let entry: DictionaryEntry
  let language: Lang?
  let speaker: Speaker
  var fontScale = 1.0
  @State private var expanded = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let collapsedGroups = 3
  private static let collapsedSenses = 2

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: 8) {
      header
      headword
      ForEach(Array(shownGroups.enumerated()), id: \.offset) { _, group in
        groupView(group)
      }
      if hiddenCount > 0 || expanded {
        Button(expanded ? "收起" : "展开全部 \(entry.senseCount) 条释义") { expanded.toggle() }
          .buttonStyle(.plain).foregroundStyle(Style.brandInk).pointerStyle(.link)
          .font(.system(size: 12))
      }
    }
    .textSelection(.enabled)
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(scheme == .dark ? .white.opacity(0.06) : .white.opacity(0.55), in: shape)
    .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: expanded)
  }

  private var header: some View {
    HStack(spacing: 8) {
      KindTile(symbol: "book.closed.fill", color: Color(nsColor: .systemBrown), size: 18)
      Text("系统词典").font(.system(size: 12, weight: .semibold)).opacity(0.85)
      Spacer(minLength: 6)
      Group {
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
      .opacity(0.45)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .font(.system(size: 12, weight: .medium))
    .frame(height: 20)
  }

  private var headword: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(entry.headword).font(.system(size: 20 * fontScale, weight: .semibold))
      if let phonetic = entry.phonetic {
        Text("/\(phonetic)/").font(.system(size: 13 * fontScale)).foregroundStyle(.secondary)
      }
      if let query = entry.query {
        Text("\(query) 的原形").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
    }
  }

  private func groupView(_ group: DictionaryEntry.Group) -> some View {
    VStack(alignment: .leading, spacing: 5) {
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
            Text(sense.definition).font(.system(size: 14 * fontScale)).lineSpacing(2)
            if let example = sense.example {
              Text(example).font(.system(size: 12 * fontScale)).italic().foregroundStyle(.secondary)
            }
          }
        }
      }
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
