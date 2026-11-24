// 设置 › 剪贴板里片段展开的两节（2026-11-22 拍板页 https://claude.ai/artifact/PNApPJNxAgNG36JcSC1q1B；11-24 用户「没必要做成插件，
// 直接在剪贴板历史里加」：原来的插件页拆成这两节，PLAN §10「片段展开」）。行为在 SnippetExpand/。
// - SnippetExpandSection（外面，「粘贴」下面）：开关「打关键词展开片段」（默认开：没有片段设关键词时根本不听键盘；ⓘ 说清只在
//   内存里留最近十几个字）；开着时设了关键词的片段一行一条（关键词等宽字 + 片段的叫法，只读，关键词在剪贴板面板里设）；没有
//   辅助功能授权时一行「去授权」；页脚橙字说这会儿为什么不展开（授权有却听不到键盘、有关键词重复、有 App 开着安全输入）
// - SnippetExcludedSection（「高级…」里）：「在这些 App 里不展开片段」——同「不记录」那张名单的样子（AppListRow、「＋ −」、⌫ 删除），
//   默认是那几个密码管理器；改的时候从偏好现读（同 E19）

import SwiftUI

struct SnippetExpandSection: View {
  let store: ClipboardStore
  /// 截图自检传 nil（不建拦截）
  var expander: SnippetExpander?
  /// 截图自检传固定的；正常是 nil = 现读
  private let fixedTrusted: Bool?
  private let fixedSecure: HotKeyCenter.SecureInputBlock??

  @AppStorage(Prefs.clipboardSnippetExpand) private var expands = true
  /// 「新」（WhatsNew）：截图自检里没有设置窗的导航，就不挂
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  @State private var trusted = Permissions.isAccessibilityTrusted
  /// 开着的安全输入（没开 nil）：出现时、设置窗当 key 时现读
  @State private var secure: HotKeyCenter.SecureInputBlock?

  init(
    store: ClipboardStore, expander: SnippetExpander? = nil, trusted: Bool? = nil,
    secure: HotKeyCenter.SecureInputBlock?? = nil
  ) {
    self.store = store
    self.expander = expander
    fixedTrusted = trusted
    fixedSecure = secure
  }

  /// 「新」挂在哪一行、拨过算看过（WhatsNew.Entry 的 section 就是这一行的标题）
  static let title: LocalizedStringResource = "打关键词展开片段"

  var body: some View {
    let items = keyworded
    let duplicates = SnippetKeyword.duplicates(items.compactMap(\.keyword))
    let isTrusted = fixedTrusted ?? trusted
    Section {
      SettingRow(
        title: Self.title, subtitle: "在任何 App 里打出片段的关键词，换成片段的内容",
        info:
          "关键词在剪贴板面板里设：新建片段时填上，已有的片段在 ⌘K 里选「关键词…」。打完关键词的最后一个字就展开，前面紧挨着字母或数字时不展开；密码框里、输入法正在打拼音时不展开。只在内存里留最近打的十几个字用来比对，不存盘、不上传、不写进日志；没有片段设关键词时完全不听键盘。",
        isNew: navigation.map { WhatsNew.marks(section: Self.title, of: .clipboard, in: $0.fresh) }
          ?? false
      ) {
        Toggle(Self.title, isOn: $expands)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.clipboardSnippetExpand)
      .onChange(of: expands) { WhatsNew.touch(section: Self.title, of: .clipboard) }
      if expands {
        if !isTrusted {
          LabeledContent {
            Button("去授权") { Permissions.requestAccessibility() }
          } label: {
            Text("没有辅助功能授权")
            Text("给了才能认出打的关键词、换成片段")
          }
        }
        if items.isEmpty {
          Text("还没有片段设关键词").foregroundStyle(.secondary)
        }
        ForEach(items) { item in
          LabeledContent {
            HStack(spacing: 6) {
              if duplicates.contains(item.keyword ?? "") {
                // 「重复」在提醒里是 Repeat：显式 key
                Text(String(localized: "snippetExpand.duplicate", defaultValue: "重复"))
                  .foregroundStyle(Color(nsColor: .systemOrange))
              }
              Text(verbatim: SnippetKeyword.title(note: item.note, text: item.text))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            }
          } label: {
            Text(verbatim: item.keyword ?? "")
              .font(.body.monospaced())
          }
        }
      }
    } header: {
      Text("片段")
    } footer: {
      if expands,
        let warning = Self.warning(
          secure: secure, duplicated: !duplicates.isEmpty,
          failed: isTrusted && expander?.status == .failed)
      {
        Text(verbatim: warning)
          .font(.caption)
          .foregroundStyle(Color(nsColor: .systemOrange))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
      }
    }
    .onAppear { refresh() }
    // 从系统设置授权回来、设置窗再当 key：刷新授权和安全输入；授权刚给了的话拦截这会儿接上
    .onSettingsBecameKey {
      refresh()
      expander?.refresh()
    }
  }

  private func refresh() {
    trusted = Permissions.isAccessibilityTrusted
    secure = fixedSecure ?? HotKeyCenter.SecureInputBlock.current()
  }

  /// 设了关键词的片段（关键词排序）
  private var keyworded: [ClipItem] {
    store.items.filter { $0.isSnippet && $0.keyword != nil }
      .sorted { ($0.keyword ?? "") < ($1.keyword ?? "") }
  }

  /// 页脚的橙字：授权有却听不到键盘、有关键词重复（同步来的、导入的可能撞上）、有 App 开着安全输入（纯函数，配单测）
  static func warning(
    secure: HotKeyCenter.SecureInputBlock?, duplicated: Bool = false, failed: Bool = false
  ) -> String? {
    var lines: [String] = []
    if failed {
      lines.append(
        String(
          localized: "授权显示给了，却听不到键盘：到 系统设置 › \(Permissions.privacyPane) › 辅助功能 里把它关掉再打开。"))
    }
    if duplicated {
      lines.append(String(localized: "有片段的关键词重复：打出来时用最近用过的那条。在剪贴板面板里给其中一条换个关键词。"))
    }
    if let secure {
      lines.append(
        secure.holder.map { String(localized: "「\($0)」开着安全输入，这会儿哪里都不展开：\(secure.advice)。") }
          ?? String(localized: "有 App 开着安全输入，这会儿哪里都不展开：\(secure.advice)。"))
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}

/// 「高级…」里的「在这些 App 里不展开片段」
struct SnippetExcludedSection: View {
  @State private var selection: String?
  @State private var excluded = Self.stored

  var body: some View {
    Section {
      List(selection: $selection) {
        if excluded.isEmpty {
          Text("在所有 App 里都展开").foregroundStyle(.secondary)
        }
        ForEach(excluded, id: \.self) { AppListRow(bundleID: $0).tag($0) }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .orderedListFrame(rows: excluded.count)
      .onDeleteCommand(perform: removeSelected)
      ListEditBar(removeTitle: "移除所选的 App", canRemove: selection != nil, remove: removeSelected) {
        Menu {
          Menu("正在运行的 App") {
            ForEach(AppListRow.runningApps, id: \.bundleID) { app in
              Button(app.name) { add(app.bundleID) }
                .disabled(excluded.contains(app.bundleID))
            }
          }
          Button("选择 App…") {
            AppListRow.chooseApps(prompt: "不展开片段", message: "选择的 App 在前台时，打关键词不展开")
              .forEach(add)
          }
        } label: {
          Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("添加 App")
      }
    } header: {
      InfoHeader(
        "在这些 App 里不展开片段",
        info: "列表里的 App 在前台时，打关键词照原样留着。密码框不用放进来：输密码时系统不让任何程序看到按键。默认放着几个密码管理器。"
      )
      .settingsAnchor(.clipboardSnippetExcluded)
    }
    // 同步、导入落下了新的名单：页面跟上（偏好里是字符串数组，@AppStorage 存不了，自己读）
    .task {
      for await _ in NotificationCenter.default.notifications(
        named: UserDefaults.didChangeNotification)
      where Self.stored != excluded {
        excluded = Self.stored
      }
    }
  }

  private static var stored: [String] {
    UserDefaults.standard.stringArray(forKey: Prefs.clipboardSnippetExcluded) ?? []
  }

  /// 改名单都从偏好里现读的那份改（同剪贴板「不记录」，第四轮体检 E19）：页面上的这份可能还没跟上刚同步来的
  private func add(_ bundleID: String) {
    let stored = Self.stored
    guard !stored.contains(bundleID) else {
      excluded = stored
      return
    }
    save(stored + [bundleID])
  }

  private func removeSelected() {
    guard let selection else { return }
    save(Self.stored.filter { $0 != selection })
    self.selection = nil
  }

  private func save(_ list: [String]) {
    excluded = list
    UserDefaults.standard.set(list, forKey: Prefs.clipboardSnippetExcluded)
  }
}
