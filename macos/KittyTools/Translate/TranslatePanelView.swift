// 翻译浮窗根视图（原生重新设计，不沿用旧版样式）：
// 顶栏：源语言 ⇄ 目标语言 + 复制即译 / 历史 / 设置 / 固定；原文区（Enter 翻译，Shift+Enter 换行）+ 语种与原文操作；
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
  /// nil = 智能
  @AppStorage(Prefs.translateTarget) private var target: String?

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
    .onChange(of: source) { retranslate() }
    .onChange(of: target) { retranslate() }
  }

  // MARK: 顶栏

  private var header: some View {
    HStack(spacing: 6) {
      Picker("源语言", selection: $source) {
        Text("自动检测").tag(String?.none)
        Divider()
        ForEach(Lang.allCases, id: \.self) { Text($0.title).tag(String?.some($0.rawValue)) }
      }
      Button("交换语言", systemImage: "arrow.left.arrow.right", action: swap)
        .disabled(source == nil && target == nil && coordinator.target == nil)
      Picker("目标语言", selection: $target) {
        Text("智能（中⇄外）").tag(String?.none)
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

  /// 交换：自动 / 智能的一侧用实际检测或解析出的语言
  private func swap() {
    let newSource = target ?? coordinator.target?.rawValue
    target = source ?? coordinator.detected?.rawValue
    source = newSource
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
            speaker.toggle(coordinator.sourceText, language: coordinator.detected)
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

  /// 「英语 → 简体中文」（源是自动时显示检测结果）
  private var direction: String? {
    guard let to = coordinator.target else { return nil }
    let from = source.flatMap(Lang.init(rawValue:)) ?? coordinator.detected
    return "\(from?.title ?? "自动识别") → \(to.title)"
  }

  // MARK: 结果

  @ViewBuilder private var results: some View {
    if let notice = coordinator.notice {
      ContentUnavailableView {
        Label(notice, systemImage: "exclamationmark.bubble")
      } actions: {
        if !Permissions.isAccessibilityTrusted {
          Button("打开辅助功能设置", action: Permissions.openAccessibilitySettings)
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
        "划词或输入后开始翻译", systemImage: "character.bubble",
        description: Text("划词翻译、输入翻译的快捷键可在设置里修改"))
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
