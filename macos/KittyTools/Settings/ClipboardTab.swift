// 设置 › 剪贴板：保留普通历史（一行按时间，体检 A4）与普通图片占用、面板行为（带实时示意图：单列 + 透镜 + 底栏）、
// 粘贴方式与图片文字、隐私（敏感文本 / 清空时机）、排除的 App（按 bundle ID 精确匹配的 App 列表，体检 A11）。
// 上限类设置改了立即生效（执行一次清理）。控件分工（Whisker §6）：> 5 项弹出菜单、3–5 项单选。

import SwiftUI
import UniformTypeIdentifiers

struct ClipboardTab: View {
  let store: ClipboardStore
  @AppStorage(Prefs.clipboardRetentionDays) private var retentionDays = 7
  @AppStorage(Prefs.clipboardImageBudgetMB) private var imageBudgetMB = 512
  @AppStorage(Prefs.clipboardShowPreview) private var showPreview = true
  @AppStorage(Prefs.clipboardLinkPreview) private var linkPreview = true
  @AppStorage(Prefs.clipboardPasteOnClick) private var pasteOnClick = false
  @AppStorage(Prefs.clipboardPastePlain) private var pastePlain = false
  @AppStorage(Prefs.clipboardImageOCR) private var imageOCR = true
  @AppStorage(Prefs.clipboardBlockSensitive) private var blockSensitive = true
  @AppStorage(Prefs.clipboardClearOnQuit) private var clearOnQuit = false
  @AppStorage(Prefs.clipboardClearOnLock) private var clearOnLock = false
  @State private var excluded =
    UserDefaults.standard.stringArray(forKey: Prefs.clipboardExcludedBundleIDs) ?? []
  @State private var excludedSelection: String?
  @State private var confirmClear = false
  @Environment(Island.self) private var island: Island?

  var body: some View {
    Form {
      Section("历史") {
        Picker("保留普通历史", selection: $retentionDays) {
          ForEach(Prefs.clipboardRetentionChoices, id: \.self) {
            Text(Self.retentionTitle($0)).tag($0)
          }
        }
        Picker("图片最多占用", selection: $imageBudgetMB) {
          ForEach([(512, "512 MB"), (1024, "1 GB"), (2048, "2 GB"), (5120, "5 GB")], id: \.0) {
            Text($0.1).tag($0.0)
          }
          Text("不限").tag(0)
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        LabeledContent("图片当前占用", value: imageUsage)
        Text("收藏和片段一直留着，图片占用也只算普通历史里的").font(.caption).foregroundStyle(.secondary)
      }
      Section("面板") {
        ClipboardPanelSketch(showsLens: showPreview, showsLinkPreview: linkPreview)
          .frame(maxWidth: .infinity)
        Toggle(isOn: $showPreview) {
          Text("显示透镜")
          Text("选中的条目在原地展开预览；关掉就是纯列表，一屏多露出几行")
        }
        Toggle(isOn: $linkPreview) {
          Text("链接显示网页标题和图片")
          Text("选中链接时联网读取；本机、内网和带登录令牌的网址不读")
        }
        Toggle(isOn: $pasteOnClick) {
          Text("单击条目直接粘贴")
          Text("关着时单击选中、双击粘贴；打开后点一下就粘贴，想先看内容用 ↑↓，⌘ 单击、⇧ 单击照常多选")
        }
      }
      Section("内容") {
        Toggle(isOn: $pastePlain) {
          Text("默认粘贴为纯文本")
          Text("打开后 ↩ 粘贴纯文本，⌥↩ 保留格式；文字的格式总是记下来")
        }
        Toggle("识别图片中的文字，用于搜索", isOn: $imageOCR)
      }
      Section("隐私") {
        Toggle("不记录疑似密钥和银行卡号", isOn: $blockSensitive)
        Toggle("退出 App 时清空普通历史", isOn: $clearOnQuit)
        Toggle("锁屏时清空普通历史", isOn: $clearOnLock)
        DangerButton("立即清空普通历史…") { confirmClear = true }
      }
      Section {
        excludedList
        ListEditBar(
          removeTitle: "移除所选的 App", canRemove: excludedSelection != nil, remove: removeSelected
        ) {
          Menu {
            Menu("正在运行的 App") {
              ForEach(runningApps, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }.disabled(excluded.contains(app.bundleID))
              }
            }
            Button("选择 App…", action: chooseApps)
          } label: {
            Image(systemName: "plus")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .help("添加 App")
        }
      } header: {
        Text("不记录这些 App 里的复制")
      } footer: {
        OrderedList.footnote("密码管理器通常会自己标记「不要记录」，这里只是兜底。")
      }
    }
    .formStyle(.grouped)
    .onChange(of: retentionDays) { pruned(store.enforceLimits()) }
    .onChange(of: imageBudgetMB) { pruned(store.enforceLimits()) }
    .onChange(of: imageOCR) { store.recognizePendingImages() }
    .onChange(of: excluded) {
      UserDefaults.standard.set(excluded, forKey: Prefs.clipboardExcludedBundleIDs)
    }
    .confirmationDialog("清空所有普通历史？", isPresented: $confirmClear) {
      Button("清空", role: .destructive) {
        let count = store.clearOrdinary()
        island?.show(
          count > 0 ? "已清空普通历史" : "没有可清空的普通历史",
          detail: count > 0 ? "删了 \(count) 条，收藏和片段留着" : nil,
          tone: count > 0 ? .success : .info, symbol: "trash")
      }
    } message: {
      Text("收藏和片段会保留")
    }
  }

  /// 「保留普通历史」的档位名：1 天 / 1 周 / 1 个月 / 3 个月 / 1 年 / 永久
  static func retentionTitle(_ days: Int) -> String {
    switch days {
    case 0: "永久"
    case 7: "1 周"
    case 30: "1 个月"
    case 90: "3 个月"
    case 365: "1 年"
    default: "\(days) 天"
    }
  }

  /// 上限改小、当场删掉的条目在设置页上看不出来：用刘海说一声
  private func pruned(_ count: Int) {
    guard count > 0 else { return }
    island?.show(
      "已按新上限清理 \(count) 条", detail: "收藏和片段不受影响", tone: .info, symbol: "trash")
  }

  /// 「普通 X · 留下的 Y」：只有普通的算进「图片最多占用」（体检 B2）
  private var imageUsage: String {
    let usage = store.imageUsage
    return "普通 \(usage.ordinary.formatted(.byteCount(style: .file))) · 留下的 "
      + usage.retained.formatted(.byteCount(style: .file))
  }

  // MARK: 排除的 App

  /// App 列表（图标 + 名字），不排序；选中后「−」或 ⌫ 移除
  private var excludedList: some View {
    List(selection: $excludedSelection) {
      if excluded.isEmpty {
        Text("没有排除的 App").foregroundStyle(.secondary)
      }
      ForEach(excluded, id: \.self) { ExcludedAppRow(bundleID: $0).tag($0) }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: excluded.count)
    .onDeleteCommand(perform: removeSelected)
  }

  private func add(_ bundleID: String) {
    guard !excluded.contains(bundleID) else { return }
    excluded.append(bundleID)
  }

  private func removeSelected() {
    guard let id = excludedSelection else { return }
    excluded.removeAll { $0 == id }
    excludedSelection = nil
  }

  /// 从「应用程序」里选（可多选），按 App 包的 bundle ID 加进来
  private func chooseApps() {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(filePath: "/Applications")
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = true
    panel.prompt = "不记录"
    panel.message = "选择的 App 里复制的内容不进剪贴板历史"
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
    }
  }

  /// 正在运行的普通 App（有 Dock 图标的），按名称排序
  private var runningApps: [(bundleID: String, name: String)] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0 != .current }
      .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

/// 排除列表的一行：16 pt App 图标 + 名字；本机找不到这个 App 时显示 bundle ID（secondary）
private struct ExcludedAppRow: View {
  let bundleID: String

  var body: some View {
    let name = AppIcons.name(for: bundleID)
    HStack(spacing: 8) {
      if let icon = AppIcons.icon(for: bundleID) {
        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
      } else {
        Image(systemName: "app.dashed").foregroundStyle(.tertiary).frame(width: 16)
      }
      Text(name ?? bundleID)
        .foregroundStyle(name == nil ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .help(bundleID)
    .accessibilityElement(children: .combine)
  }
}

/// 剪贴板面板的示意图（实时预览，Sleeve 式）：单列 + 一块透镜 + 底栏，跟着「显示透镜」「链接显示网页标题和图片」变——
/// 关掉透镜时选中行只是一条中性高亮（纯列表，多露出几行）；透镜里的链接有没有头图。只是线框，不画真内容
private struct ClipboardPanelSketch: View {
  let showsLens: Bool
  let showsLinkPreview: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let panel = RoundedRectangle(cornerRadius: 12, style: .continuous)
    VStack(spacing: 0) {
      // 搜索线：放大镜 + 一枚粉色筛选标签 + 占位
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
        Capsule().fill(Style.brand.opacity(0.22)).frame(width: 22, height: 8)
        Capsule().fill(.primary.opacity(0.12)).frame(width: 70, height: 5)
        Spacer()
      }
      .padding(.horizontal, 10)
      .frame(height: 22)
      Hairline()
      VStack(spacing: 0) {
        row(tile: .primary.opacity(0.14))
        lens
        row(tile: .primary.opacity(0.14))
        row(tile: Style.Family.clipboard.opacity(0.5))
        if !showsLens { row(tile: .primary.opacity(0.14)) }
        Spacer(minLength: 0)
      }
      .padding(4)
      Hairline()
      // 底栏：条数 ｜ 粘贴 [↩] · 操作 ⌘K
      HStack(spacing: 4) {
        Capsule().fill(.primary.opacity(0.12)).frame(width: 22, height: 4)
        Spacer()
        Capsule().fill(.primary.opacity(0.16)).frame(width: 14, height: 4)
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Style.brand)
          .frame(width: 9, height: 8)
        Capsule().fill(.primary.opacity(0.16)).frame(width: 18, height: 4)
      }
      .padding(.horizontal, 8)
      .frame(height: 14)
    }
    .frame(width: 240, height: 136)
    .background(.background, in: panel)
    .overlay(panel.hairlineBorder())
    .clipShape(panel)
    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    // 减弱动态效果：直接变（不展开、不缩放）
    .animation(reduceMotion ? nil : Style.Motion.settle.animation(), value: showsLens)
    .animation(reduceMotion ? nil : Style.Motion.settle.animation(), value: showsLinkPreview)
    .padding(.vertical, 6)
    .accessibilityHidden(true)
  }

  private func row(tile: some ShapeStyle) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(tile).frame(width: 9, height: 9)
      Capsule().fill(.primary.opacity(0.12)).frame(width: 110, height: 4)
      Spacer()
      Capsule().fill(.primary.opacity(0.08)).frame(width: 26, height: 3)
    }
    .padding(.horizontal, 5)
    .frame(height: 14)
  }

  /// 选中行：一块中性高亮；开着透镜时在原地展开成链接预览（头图 + 标题）+ 元信息
  private var lens: some View {
    VStack(alignment: .leading, spacing: 4) {
      row(tile: Style.Family.url.opacity(0.7))
      if showsLens {
        HStack(alignment: .top, spacing: 5) {
          if showsLinkPreview {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [Style.Family.url.opacity(0.5), Style.Family.search.opacity(0.35)],
                  startPoint: .topLeading, endPoint: .bottomTrailing)
              )
              .frame(width: 40, height: 23)
              .transition(.opacity)
          }
          VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(.primary.opacity(0.22)).frame(width: 80, height: 5)
            Capsule().fill(.primary.opacity(0.12)).frame(width: 60, height: 4)
          }
        }
        .padding(.leading, 19)
        .transition(.opacity)
        Capsule().fill(.primary.opacity(0.08)).frame(width: 70, height: 3)
          .padding(.leading, 19)
          .padding(.bottom, 4)
          .transition(.opacity)
      }
    }
    .background(Style.selectedFill, in: .rect(cornerRadius: 4, style: .continuous))
  }
}
