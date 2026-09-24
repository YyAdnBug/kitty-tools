// 翻译浮窗根视图（原生重新设计，不沿用旧版样式）：
// 顶栏：源语言 ⇄ 目标语言（在这里切换、全局记住）+ 复制即译 / 历史 / 设置 / 固定；
// 原文区（Enter 翻译，Shift+Enter 换行）+ 实际方向与原文操作；
// 下方是各服务结果卡片，历史覆盖在结果区上。状态和操作都在 TranslateCoordinator。

import SwiftUI

struct TranslatePanelView: View {
  @Bindable var coordinator: TranslateCoordinator
  let speaker: Speaker
  var openSettings: () -> Void = {}

  @AppStorage(Prefs.floatingPinned) private var pinned = false
  @AppStorage(Prefs.translateCopyToTranslate) private var copyToTranslate = false
  /// nil = 自动检测
  @AppStorage(Prefs.translateSource) private var source: String?
  /// nil = 自动（第一 ⇄ 第二语言）
  @AppStorage(Prefs.translateTarget) private var target: String?
  @AppStorage(Prefs.translateFirst) private var first: String?
  @AppStorage(Prefs.translateSecond) private var second: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      sourceArea
      Divider()
      // 历史打开时整块替换结果区（材质半透明，叠在上面会透出下面的内容）
      if coordinator.showsHistory {
        HistoryView(history: coordinator.history) { entry in
          coordinator.translate(entry.source)
        } onClose: {
          coordinator.showsHistory = false
        }
      } else {
        results.frame(maxHeight: .infinity)
      }
    }
    // 一次操作只重译一次（交换、撞同语言时两个值在同一次更新里一起改）
    .onChange(of: [source, target]) { retranslate() }
  }

  // MARK: 顶栏

  private var header: some View {
    HStack(spacing: 6) {
      Picker("源语言", selection: choose(\.source, other: \.target)) {
        Text("自动检测").tag(String?.none)
        Divider()
        ForEach(Lang.allCases, id: \.self) { Text($0.title).tag(String?.some($0.rawValue)) }
      }
      // 原样互换，「自动」也照换（Bob 的做法）；两边都自动时本来就是双向的，不用换
      Button("交换语言", systemImage: "arrow.left.arrow.right") { (source, target) = (target, source) }
        .disabled(source == nil && target == nil)
      Picker("目标语言", selection: choose(\.target, other: \.source)) {
        let pair = Lang.pair(first: first, second: second)
        Text("自动（\(pair.first.title) ⇄ \(pair.second.title)）").tag(String?.none)
        Divider()
        ForEach(Lang.allCases, id: \.self) { Text($0.title).tag(String?.some($0.rawValue)) }
      }
      Spacer(minLength: 4)
      Toggle(isOn: $copyToTranslate) { Image(systemName: "doc.on.clipboard") }
        .toggleStyle(.button)
        .help(copyToTranslate ? "复制即译：已开启（复制文字后自动翻译）" : "复制即译：复制文字后自动翻译")
      Toggle(isOn: $coordinator.showsHistory) { Image(systemName: "clock.arrow.circlepath") }
        .toggleStyle(.button)
        .help("翻译历史")
      Button("设置", systemImage: "gearshape", action: openSettings).help("翻译设置")
      Toggle(isOn: $pinned) { Image(systemName: pinned ? "pin.fill" : "pin") }
        .toggleStyle(.button)
        .help(pinned ? "已固定：失焦不收起、Esc 不关闭" : "固定浮窗")
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .controlSize(.small)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  /// 选成和另一边相同的固定语言时，另一边换成这边原来的值（像交换一样），不会出现「英 → 英」
  private func choose(
    _ side: ReferenceWritableKeyPath<Self, String?>, other: ReferenceWritableKeyPath<Self, String?>
  ) -> Binding<String?> {
    Binding {
      self[keyPath: side]
    } set: { new in
      if new != nil, new == self[keyPath: other] { self[keyPath: other] = self[keyPath: side] }
      self[keyPath: side] = new
    }
  }

  private func retranslate() {
    if !coordinator.sourceText.isEmpty { coordinator.start() }
  }

  // MARK: 原文区

  private var sourceArea: some View {
    VStack(alignment: .leading, spacing: 6) {
      SourceTextView(text: $coordinator.sourceText) { coordinator.start() }
        .frame(height: 84)
        .overlay(alignment: .topLeading) {
          if coordinator.sourceText.isEmpty {
            Text("输入或粘贴文字，↩ 翻译，⇧↩ 换行")
              .foregroundStyle(.tertiary)
              .padding(.leading, 6)
              .padding(.top, 6)
              .allowsHitTesting(false)
          }
        }
      HStack(spacing: 8) {
        if let direction { Text(direction).font(.caption).foregroundStyle(.secondary) }
        Spacer()
        Group {
          Button(
            "朗读原文",
            systemImage: speaker.speaking == coordinator.sourceText ? "stop.fill" : "speaker.wave.2"
          ) {
            speaker.toggle(
              coordinator.sourceText,
              language: coordinator.fixedSource ?? coordinator.detected)
          }
          Button("复制原文", systemImage: "doc.on.doc") { Paster.write(string: coordinator.sourceText) }
          Button("清空", systemImage: "xmark.circle") { coordinator.beginInput() }
        }
        .labelStyle(.iconOnly)
        .disabled(coordinator.sourceText.isEmpty)
        Button("翻译") { coordinator.start() }
          .buttonStyle(.borderedProminent)
          .disabled(coordinator.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// 这次会话的实际方向「英语 → 简体中文」（源自动时显示检测结果），出乎所选的地方写明原因：
  /// 固定目标正好是原文语言而改译了另一端；固定源和检测结果对不上（照所选发出，只提示）
  private var direction: String? {
    guard let to = coordinator.target else { return nil }
    let fixedSource = coordinator.fixedSource
    var text = "\((fixedSource ?? coordinator.detected)?.title ?? "自动识别") → \(to.title)"
    if let abandoned = coordinator.abandonedTarget {
      text += "（原文已是\(abandoned.title)）"
    } else if let fixedSource, let detected = coordinator.detected,
      !detected.isSameLanguage(as: fixedSource)
    {
      text += " · 检测到\(detected.title)"
    }
    return text
  }

  // MARK: 结果

  @ViewBuilder private var results: some View {
    if let notice = coordinator.notice {
      ContentUnavailableView {
        Label(notice, systemImage: "exclamationmark.bubble")
      } actions: {
        // 只有授权类提示才给按钮（以前任何提示都挂「打开辅助功能设置」）
        if let permission = coordinator.noticePermission {
          Button(permission.settingsTitle, action: permission.openSettings)
        }
      }
    } else if coordinator.services.enabled.isEmpty {
      ContentUnavailableView {
        Label("没有启用的翻译服务", systemImage: "character.bubble")
      } actions: {
        Button("打开翻译设置", action: openSettings)
      }
    } else if coordinator.cards.isEmpty {
      ContentUnavailableView(
        "划词、截图或输入后开始翻译", systemImage: "character.bubble",
        description: Text("划词翻译、截图翻译、输入翻译的快捷键可在设置里修改"))
    } else {
      ScrollView {
        VStack(spacing: 8) {
          ForEach(coordinator.cards) { card in
            ProviderCardView(card: card, language: coordinator.target, speaker: speaker) {
              coordinator.retry(card.id)
            }
          }
        }
        .padding(10)
      }
    }
  }
}
