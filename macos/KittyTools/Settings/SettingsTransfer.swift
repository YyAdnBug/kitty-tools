// 设置 › 通用「导出与导入」（2026-10-07；文件格式、校验和合并规则在 Storage/SettingsArchive.swift）：一行两个按钮。
// 导出… = 一张表单：勾选类别；要带翻译服务的密钥就再勾一项、设一个密码（至少 8 位，输两遍）→ 存储面板。
// 导入… = 打开面板选文件 → 读出来查过 → 一张表单：文件里有哪几类就列哪几类、勾选要导入的；翻译服务下面列出它们会连到的
// 自己填的地址（别人给的文件里，名字叫 OpenAI 的服务连的不一定是 OpenAI）；文件带密钥时给一个密码框（不填就不导入密钥）；
// 会让历史保留得更少、隐私保护变弱时橙字先说 → 写偏好、合并两张列表、存密钥，再让运行中的东西跟上（applied）。
// 结果用刘海岛说；读不出来的文件也用刘海岛说，不开表单。两个系统面板开着时，对应的按钮 / 表单先停用（不然面板还没关，
// 表单上已经改了勾选，写出去的却是改之前的那份）。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 导出 / 导入要用到的运行中的东西（AppDelegate 给；截图自检给一份不写偏好的）
struct SettingsTransfer {
  let services: TranslateServiceStore
  /// 导入写完偏好之后让运行中的东西跟上（AppDelegate.settingsImported）；返回按新上限清掉了几条剪贴板历史
  var applied: () -> Int = { 0 }
}

/// 通用页最后一组：说明 +「导出…」「导入…」
struct TransferSection: View {
  let transfer: SettingsTransfer
  @Environment(Island.self) private var island: Island?
  /// 点「导出…」那一刻读的；有值就开导出表单
  @State private var outgoing: Draft?
  /// 选好、读出来查过的文件；有值就开导入表单
  @State private var incoming: Draft?
  /// 打开面板开着：两个按钮先停用（不出第二个面板）
  @State private var isChoosing = false

  /// 一张表单要的东西。用 sheet(item:)：收起的动画期间内容还在（isPresented + 可选值的写法，一收起内容就先空了）
  private struct Draft: Identifiable {
    let id = UUID()
    let archive: SettingsArchive
    /// 导出：这些服务在钥匙串里的密钥（账户名 → 值）
    var secrets: [String: String] = [:]
  }

  var body: some View {
    Section {
      LabeledContent {
        HStack(spacing: 8) {
          Button("导出…") {
            let services = transfer.services.services
            outgoing = Draft(
              archive: .capture(services: services),
              secrets: SettingsArchive.secrets(of: services))
          }
          .sheet(item: $outgoing) {
            ExportSheet(archive: $0.archive, secrets: $0.secrets, island: island).appAccent()
          }
          Button("导入…", action: chooseFile)
            .sheet(item: $incoming) {
              ImportSheet(archive: $0.archive, transfer: transfer, island: island).appAccent()
            }
        }
        .disabled(isChoosing)
      } label: {
        Text("全部设置")
        Text("各页的设置、全局快捷键、翻译服务、网页搜索与快捷链接存成一个文件，换电脑或重装后导回来")
      }
    } header: {
      Text("导出与导入")
    } footer: {
      Text("历史记录、片段和收藏不在文件里；截图的存储文件夹、登录时打开和系统权限要在新电脑上重新设。")
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// 选文件、读出来查过再开表单；读不出来的用刘海岛说
  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "选一个 Kitty Tools 导出的设置文件"
    panel.prompt = "选取"
    isChoosing = true
    panel.begin { response in
      isChoosing = false
      guard response == .OK, let url = panel.url else { return }
      do {
        let archive = try SettingsArchive.read(contentsOf: url)
        guard !archive.sections.isEmpty else {
          island?.show("没有导入", detail: "文件里没有可导入的内容", tone: .warning)
          return
        }
        incoming = Draft(archive: archive)
      } catch {
        island?.show(
          "没有导入",
          detail: (error as? SettingsArchive.Failure)?.message ?? error.localizedDescription,
          tone: .error)
      }
    }
  }
}

/// 导出表单：勾选类别、要不要带密钥（带就设密码），「导出…」开存储面板；存好了才收起
struct ExportSheet: View {
  let archive: SettingsArchive
  /// 这些服务在钥匙串里的密钥（账户名 → 值）
  let secrets: [String: String]
  let island: Island?
  @State private var sections = Set(SettingsArchive.Section.allCases)
  @State private var includesSecrets: Bool
  @State private var password = ""
  @State private var confirmation = ""
  /// 存储面板开着：表单先停用（要写的内容开面板前就定了，这时再改勾选、点取消都不该有反应）
  @State private var isSaving = false
  @Environment(\.dismiss) private var dismiss

  /// includesSecrets：截图自检直接摆出勾了「包含密钥」的样子
  init(
    archive: SettingsArchive, secrets: [String: String], island: Island?,
    includesSecrets: Bool = false
  ) {
    self.archive = archive
    self.secrets = secrets
    self.island = island
    _includesSecrets = State(initialValue: includesSecrets)
  }

  var body: some View {
    TransferForm(
      symbol: "square.and.arrow.up", title: "导出设置", detail: "勾选要写进文件的内容。",
      action: "导出…", canAct: canExport, act: export
    ) {
      ForEach(SettingsArchive.Section.allCases) { section in
        Toggle(isOn: isSelected(section, in: $sections)) {
          TransferLabel(title: section.title, detail: detail(of: section))
        }
      }
      Divider()
      Toggle(isOn: $includesSecrets) {
        TransferLabel(title: "包含翻译服务的密钥", detail: secretsDetail)
      }
      .disabled(!canIncludeSecrets)
      if sealsSecrets {
        VStack(alignment: .leading, spacing: 6) {
          SecureField(
            "密码", text: $password,
            prompt: Text("密码（至少 \(SettingsArchive.minPasswordLength) 位）"))
          SecureField("再输一次", text: $confirmation, prompt: Text("再输一次"))
          Text(passwordProblem ?? "密码不会存在任何地方；忘了的话，重新导出一份就行。")
            .font(.caption)
            .foregroundStyle(
              passwordProblem == nil
                ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: .systemOrange))
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .padding(.leading, TransferLabel.indent)
      }
    }
    .disabled(isSaving)
  }

  /// 这次要不要把密钥封进文件
  private var sealsSecrets: Bool { includesSecrets && canIncludeSecrets }

  private var canIncludeSecrets: Bool { sections.contains(.services) && !secrets.isEmpty }

  private var canExport: Bool {
    !sections.isEmpty
      && (!sealsSecrets
        || (password.count >= SettingsArchive.minPasswordLength && password == confirmation))
  }

  private var passwordProblem: String? {
    if !password.isEmpty, password.count < SettingsArchive.minPasswordLength {
      return "密码至少 \(SettingsArchive.minPasswordLength) 位"
    }
    if !confirmation.isEmpty, confirmation != password { return "两次输入的密码不一样" }
    return nil
  }

  private func detail(of section: SettingsArchive.Section) -> String {
    switch section {
    case .preferences:
      let count = archive.preferences?.count ?? 0
      return count == 0 ? "各页的选项都还是默认值" : "各页里改过的 \(count) 项，其余是默认值"
    case .hotkeys:
      let count = archive.hotkeys?.count ?? 0
      return count == 0 ? "都还是默认的组合" : "改过的 \(count) 个，其余是默认的组合"
    case .services: return "\(archive.translateServices?.count ?? 0) 个服务的名称、地址、模型和开关"
    case .engines: return "\(archive.searchEngines?.count ?? 0) 条"
    }
  }

  private var secretsDetail: String {
    if !sections.contains(.services) { return "要先勾选「翻译服务」" }
    if secrets.isEmpty { return "这些服务还没有存密钥" }
    return "勾上后设一个密码，密钥加密后写进文件，导入时输同一个密码；不勾就只导出服务，不带密钥"
  }

  /// 开存储面板；存好了收起表单、刘海岛说一声，取消就留在表单上
  private func export() {
    var archive = archive.keeping(sections)
    let data: Data
    do {
      if sealsSecrets { try archive.seal(secrets, password: password) }
      data = try archive.encoded()
    } catch {
      island?.show("导出失败", detail: error.localizedDescription, tone: .error)
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = SettingsArchive.fileName()
    isSaving = true
    panel.begin { response in
      isSaving = false
      guard response == .OK, let url = panel.url else { return }
      do {
        try data.write(to: url, options: .atomic)
        dismiss()
        island?.show("已导出设置", detail: url.lastPathComponent, symbol: "square.and.arrow.up")
      } catch {
        island?.show("导出失败", detail: error.localizedDescription, tone: .error)
      }
    }
  }
}

/// 导入表单：文件里有哪几类、勾选要导入的；带密钥的文件给一个密码框
struct ImportSheet: View {
  let archive: SettingsArchive
  let transfer: SettingsTransfer
  let island: Island?
  @State private var sections: Set<SettingsArchive.Section>
  @State private var password = ""
  /// 密码不对这类：写在密码框下面，表单不收
  @State private var problem: String?
  @Environment(\.dismiss) private var dismiss

  init(archive: SettingsArchive, transfer: SettingsTransfer, island: Island?) {
    self.archive = archive
    self.transfer = transfer
    self.island = island
    _sections = State(initialValue: Set(archive.sections))
  }

  var body: some View {
    TransferForm(
      symbol: "square.and.arrow.down", title: "导入设置",
      detail: "Kitty Tools \(archive.version) 在 "
        + archive.exportedAt.formatted(date: .long, time: .shortened)
        + " 导出的文件。导入不能撤销。",
      action: "导入", canAct: !sections.isEmpty, act: importSelected
    ) {
      ForEach(archive.sections) { section in
        Toggle(isOn: isSelected(section, in: $sections)) {
          TransferLabel(title: section.title, detail: detail(of: section))
        }
        if section == .services, sections.contains(.services) { hostList }
      }
      if archive.secrets != nil, sections.contains(.services) {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
          Text("文件里带着加密的密钥")
          SecureField("导出时设的密码", text: $password, prompt: Text("导出时设的密码"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onChange(of: password) { problem = nil }
          Text(problem ?? "不填就只导入服务，不导入密钥。")
            .font(.caption)
            .foregroundStyle(
              problem == nil
                ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: .systemOrange))
        }
      }
      if sections.contains(.preferences), archive.keepsLessHistory() {
        Text("导入后历史会保留得比现在少（保留时间、图片上限、翻译历史条数变小，或者退出、锁屏时清空），超出的普通历史会被清理；收藏和片段不动。")
          .font(.caption)
          .foregroundStyle(Color(nsColor: .systemOrange))
          .fixedSize(horizontal: false, vertical: true)
      }
      if sections.contains(.preferences), !privacyLosses.isEmpty {
        Text("导入后隐私保护会比现在弱：" + privacyLosses.joined(separator: "；") + "。")
          .font(.caption)
          .foregroundStyle(Color(nsColor: .systemOrange))
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("只导入自己导出的、或信得过的人给的文件：设置会照文件改；翻译服务和网页搜索的地址也照文件里的，要翻译的文字、密钥和搜索的内容会发到那里；快捷链接能打开任意网址和文件。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var privacyLosses: [String] { archive.privacyLosses() }

  /// 「翻译服务」下面：文件里的服务会连到的自己填的地址，一行一个（太长的掐头留尾：要看的是结尾的域名）；
  /// 多于 8 个放进定高的框里滚，不省略——省略了，藏在后面的那个就没人看得到
  @ViewBuilder private var hostList: some View {
    let hosts = archive.customHosts
    if !hosts.isEmpty {
      let lines = VStack(alignment: .leading, spacing: 1) {
        ForEach(hosts, id: \.self) { Text($0).lineLimit(1).truncationMode(.head) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text("要翻译的文字和密钥会发到这些地址（共 \(hosts.count) 个）：")
        if hosts.count > 8 {
          ScrollView { lines }.frame(height: 126)
        } else {
          lines
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.leading, TransferLabel.indent)
    }
  }

  private func detail(of section: SettingsArchive.Section) -> String {
    switch section {
    case .preferences:
      "换成文件里的样子：改过的 \(archive.preferences?.count ?? 0) 项照文件，其余回到默认值"
    case .hotkeys:
      "换成文件里的样子：改过的 \(archive.hotkeys?.count ?? 0) 个照文件，其余回到默认的组合"
    case .services:
      "\(archive.translateServices?.count ?? 0) 个：已有的按文件更新，没有的加上；现在的服务不会删"
    case .engines:
      "\(archive.searchEngines?.count ?? 0) 条：已有的按文件更新，没有的加上；现在的不会删"
    }
  }

  /// 密码不对就停在表单上（这时什么都还没写）；导入完让运行中的东西跟上，刘海岛说导入了哪几类
  private func importSelected() {
    let secrets: Int
    do {
      secrets = try archive.install(sections, password: password, services: transfer.services)
    } catch {
      problem = (error as? SettingsArchive.Failure)?.message ?? error.localizedDescription
      return
    }
    let pruned = transfer.applied()
    dismiss()
    var detail = archive.sections.filter(sections.contains).map(\.title).joined(separator: "、")
    if secrets > 0 { detail += "，含密钥" }
    // 清理每次都做（和复制时一样）；只有这次改了上限才归到导入头上说
    if pruned > 0, sections.contains(.preferences) {
      detail += "；按新上限清理了 \(pruned) 条剪贴板历史"
    }
    island?.show("已导入设置", detail: detail, symbol: "square.and.arrow.down")
  }
}

/// 两张表单共用的骨架：页头（40 pt 色块 + 标题 + 一句说明）、内容、底栏「取消」+ 主按钮（↩；Esc = 取消）
private struct TransferForm<Content: View>: View {
  let symbol: String
  let title: String
  let detail: String
  let action: String
  let canAct: Bool
  let act: () -> Void
  @ViewBuilder let content: Content
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        KindTile(symbol: symbol, color: Style.Family.general, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.title2.weight(.semibold))
          Text(detail).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .padding(.horizontal, 20)
      .padding(.top, 18)
      .padding(.bottom, 14)
      VStack(alignment: .leading, spacing: 12) { content }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
      HStack(spacing: 10) {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(action, action: act)
          .buttonStyle(BrandButtonStyle())
          .keyboardShortcut(.defaultAction)
          .disabled(!canAct)
      }
      .padding(.horizontal, 20)
      .frame(height: 52)
      .overlay(alignment: .top) { Hairline() }
    }
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// 勾选框 ↔ 选中的类别
private func isSelected(
  _ section: SettingsArchive.Section, in sections: Binding<Set<SettingsArchive.Section>>
) -> Binding<Bool> {
  Binding {
    sections.wrappedValue.contains(section)
  } set: { isOn in
    if isOn {
      sections.wrappedValue.insert(section)
    } else {
      sections.wrappedValue.remove(section)
    }
  }
}

/// 勾选框的两行标签：名字 + 一句说明
private struct TransferLabel: View {
  let title: String
  let detail: String
  /// 勾选框的宽度 + 间距：密码框和标签的文字左对齐
  static let indent: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
      Text(detail).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
