// 设置 › 片段展开（插件，2026-11-22，拍板页 https://claude.ai/artifact/PNApPJNxAgNG36JcSC1q1B「全部按推荐」；PLAN §10「片段展开」）。
// 页头由 SettingsRoot 画（剪贴板的家族色）。缺辅助功能时「权限」在最上面，然后：
// 「关键词」——设了关键词的片段一行一条（关键词等宽字 + 片段的叫法），只读；关键词在剪贴板面板里设（新建片段时填，已有的
//   ⌘K「关键词…」）。剪贴板关着、有 App 开着安全输入时，页脚橙字说为什么这会儿不展开；
// 「在这些 App 里不展开」——同平滑滚动那张名单的样子（AppListRow、「＋ −」、⌫ 删除），默认是剪贴板「不记录」的那几个密码管理器；
// 「权限」——辅助功能（PluginPermissionSection，按 Shell/Plugin.swift 的声明）；
// 最后「关于这个插件」（后台、同步、移除）。行为在 SnippetExpand/。

import SwiftUI

struct SnippetExpandTab: View {
  let store: ClipboardStore
  /// 截图自检传 nil（不建拦截）
  var expander: SnippetExpander?
  /// 截图自检传固定的；正常是 nil = 现读
  private let authorized: Bool?
  private let fixedExcluded: [String]?
  private let fixedSecure: HotKeyCenter.SecureInputBlock??

  /// 设置窗重新当 key 时 +1：「权限」组重查（从系统设置授权回来）
  @State private var accessChecks = 0
  @State private var selection: String?
  @State private var excluded: [String]
  /// 开着的安全输入（没开 nil）：出现时、设置窗当 key 时现读
  @State private var secure: HotKeyCenter.SecureInputBlock?

  init(
    store: ClipboardStore, expander: SnippetExpander? = nil, authorized: Bool? = nil,
    excluded: [String]? = nil, secure: HotKeyCenter.SecureInputBlock?? = nil
  ) {
    self.store = store
    self.expander = expander
    self.authorized = authorized
    fixedExcluded = excluded
    fixedSecure = secure
    _excluded = State(initialValue: excluded ?? Self.stored)
  }

  var body: some View {
    Form {
      permissions(at: .top)
      keywordsSection.gated(by: .snippetExpand)
      excludedSection.gated(by: .snippetExpand)
      permissions(at: .bottom)
      PluginAboutSection(plugin: .snippetExpand)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
    .onAppear { readSecureInput() }
    // 从系统设置授权回来、设置窗再当 key：刷新授权和安全输入；授权刚给了的话拦截这会儿接上
    .onSettingsBecameKey {
      accessChecks += 1
      readSecureInput()
      expander?.refresh()
    }
  }

  private func readSecureInput() {
    secure = fixedSecure ?? HotKeyCenter.SecureInputBlock.current()
  }

  /// 「权限」组（辅助功能）；缺授权时画在最上面。授权有却听不到键盘时页脚橙字说
  private func permissions(at placement: PluginPermissionPlacement) -> some View {
    PluginPermissionSection(
      plugin: .snippetExpand, at: placement, checks: accessChecks,
      granted: authorized.map { value in { (_: Permissions.Kind) -> Bool? in value } }
    ) {
      if expander?.status == .failed {
        Text(
          "授权显示给了，却听不到键盘：到 系统设置 › \(Permissions.privacyPane) › 辅助功能 里把它关掉再打开。"
        )
        .font(.caption)
        .foregroundStyle(Color(nsColor: .systemOrange))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
      }
    }
  }

  // MARK: 关键词

  /// 设了关键词的片段（关键词排序）
  private var keyworded: [ClipItem] {
    store.items.filter { $0.isSnippet && $0.keyword != nil }
      .sorted { ($0.keyword ?? "") < ($1.keyword ?? "") }
  }

  private var keywordsSection: some View {
    let items = keyworded
    let duplicates = SnippetKeyword.duplicates(items.compactMap(\.keyword))
    return Section {
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
    } header: {
      InfoHeader(
        "关键词",
        info:
          "在剪贴板面板里新建片段时填上关键词，已有的片段在 ⌘K 里选「关键词…」。在任何 App 里打完关键词的最后一个字，它就换成片段的内容；关键词前面紧挨着字母或数字时不展开。"
      )
    } footer: {
      if let warning = Self.warning(
        clipboardOn: Feature.clipboard.isOn, secure: secure, duplicated: !duplicates.isEmpty)
      {
        Text(verbatim: warning)
          .font(.caption)
          .foregroundStyle(Color(nsColor: .systemOrange))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
      }
    }
  }

  /// 「关键词」页脚的橙字：剪贴板关着、有 App 开着安全输入、有关键词重复（同步来的、导入的可能撞上；纯函数，配单测）
  static func warning(
    clipboardOn: Bool, secure: HotKeyCenter.SecureInputBlock?, duplicated: Bool = false
  ) -> String? {
    var lines: [String] = []
    if duplicated {
      lines.append(String(localized: "有片段的关键词重复：打出来时用最近用过的那条。在剪贴板面板里给其中一条换个关键词。"))
    }
    if !clipboardOn {
      lines.append(String(localized: "剪贴板关着：片段在剪贴板里，打开剪贴板才会展开。"))
    }
    if let secure {
      lines.append(
        secure.holder.map { String(localized: "「\($0)」开着安全输入，这会儿哪里都不展开：\(secure.advice)。") }
          ?? String(localized: "有 App 开着安全输入，这会儿哪里都不展开：\(secure.advice)。"))
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  // MARK: 不展开的 App

  private var excludedSection: some View {
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
        "在这些 App 里不展开",
        info: "列表里的 App 在前台时，打关键词照原样留着。密码框不用放进来：输密码时系统不让任何程序看到按键。默认放着几个密码管理器。"
      )
      .settingsAnchor(.snippetExpandExcluded)
    }
    // 同步、导入落下了新的名单：页面跟上（偏好里是字符串数组，@AppStorage 存不了，自己读）
    .task {
      guard fixedExcluded == nil else { return }
      for await _ in NotificationCenter.default.notifications(
        named: UserDefaults.didChangeNotification)
      where Self.stored != excluded {
        excluded = Self.stored
      }
    }
  }

  private static var stored: [String] {
    UserDefaults.standard.stringArray(forKey: Prefs.snippetExpandExcluded) ?? []
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
    UserDefaults.standard.set(list, forKey: Prefs.snippetExpandExcluded)
  }
}
