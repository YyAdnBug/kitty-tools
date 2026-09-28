// 设置 › 剪贴板：历史上限、面板行为（带实时示意图：单列 + 透镜 + 底栏）、格式与图片文字、隐私（敏感文本 / 排除 App）、清空时机。
// 上限类设置改了立即生效（执行一次清理）。控件分工（Whisker §6）：> 5 项弹出菜单、3–5 项单选。

import SwiftUI

struct ClipboardTab: View {
  let store: ClipboardStore
  @AppStorage(Prefs.clipboardHistoryMax) private var historyMax = 0
  @AppStorage(Prefs.clipboardRetentionDays) private var retentionDays = 7
  @AppStorage(Prefs.clipboardImageBudgetMB) private var imageBudgetMB = 512
  @AppStorage(Prefs.clipboardShowPreview) private var showPreview = true
  @AppStorage(Prefs.clipboardLinkPreview) private var linkPreview = true
  @AppStorage(Prefs.clipboardKeepRichText) private var keepRichText = true
  @AppStorage(Prefs.clipboardImageOCR) private var imageOCR = true
  @AppStorage(Prefs.clipboardBlockSensitive) private var blockSensitive = true
  @AppStorage(Prefs.clipboardClearOnQuit) private var clearOnQuit = false
  @AppStorage(Prefs.clipboardClearOnLock) private var clearOnLock = false
  @State private var excluded =
    UserDefaults.standard.stringArray(forKey: Prefs.clipboardExcludedApps) ?? []
  @State private var newExcluded = ""
  @State private var confirmClear = false
  @Environment(Island.self) private var island: Island?

  var body: some View {
    Form {
      Section("历史") {
        Picker("普通历史最多保留", selection: $historyMax) {
          ForEach([50, 100, 200, 500, 1000, 2000], id: \.self) { Text("\($0) 条").tag($0) }
          Text("不限").tag(0)
        }
        Picker("普通历史保留", selection: $retentionDays) {
          ForEach([1, 3, 7, 14, 30, 90], id: \.self) { Text("\($0) 天").tag($0) }
          Text("永久").tag(0)
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
        Text("收藏、片段和已归组的条目不受以上限制").font(.caption).foregroundStyle(.secondary)
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
      }
      Section("内容") {
        Toggle("保留文本格式（RTF / HTML）", isOn: $keepRichText)
        Toggle("识别图片中的文字，用于搜索", isOn: $imageOCR)
      }
      Section("隐私") {
        Toggle("不记录疑似密钥和银行卡号", isOn: $blockSensitive)
        Toggle("退出 App 时清空普通历史", isOn: $clearOnQuit)
        Toggle("锁屏时清空普通历史", isOn: $clearOnLock)
        Button("立即清空普通历史…") { confirmClear = true }
      }
      Section {
        ForEach(excluded, id: \.self) { keyword in
          HStack {
            if let icon = excludedIcon(keyword) {
              Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(keyword)
            Spacer()
            Button("移除", systemImage: "minus.circle.fill") { excluded.removeAll { $0 == keyword } }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
          }
        }
        HStack {
          TextField("名称或 bundle ID 关键词", text: $newExcluded)
            .labelsHidden()
            .onSubmit { add(newExcluded) }
          Button("添加") { add(newExcluded) }.disabled(
            newExcluded.trimmingCharacters(in: .whitespaces).isEmpty)
          Menu("从运行中的 App 选择") {
            ForEach(runningApps, id: \.bundleID) { app in
              Button(app.name) { add(app.bundleID) }
            }
          }
          .fixedSize()
        }
      } header: {
        Text("不记录这些 App 里的复制")
      } footer: {
        Text("按名称或 bundle ID 包含关键词匹配。密码管理器通常会自己标记「不要记录」，这里只是兜底。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onChange(of: historyMax) { pruned(store.enforceLimits()) }
    .onChange(of: retentionDays) { pruned(store.enforceLimits()) }
    .onChange(of: imageBudgetMB) { pruned(store.enforceLimits()) }
    .onChange(of: imageOCR) { store.recognizePendingImages() }
    .onChange(of: excluded) {
      UserDefaults.standard.set(excluded, forKey: Prefs.clipboardExcludedApps)
    }
    .confirmationDialog("清空所有普通历史？", isPresented: $confirmClear) {
      Button("清空", role: .destructive) {
        let count = store.clearOrdinary()
        island?.show(
          count > 0 ? "已清空普通历史" : "没有可清空的普通历史",
          detail: count > 0 ? "删了 \(count) 条，收藏、片段和已归组的留着" : nil,
          tone: count > 0 ? .success : .info, symbol: "trash")
      }
    } message: {
      Text("收藏、片段和已归组的条目会保留")
    }
  }

  /// 上限改小、当场删掉的条目在设置页上看不出来：用刘海说一声
  private func pruned(_ count: Int) {
    guard count > 0 else { return }
    island?.show(
      "已按新上限清理 \(count) 条", detail: "收藏、片段和已归组的不受影响", tone: .info, symbol: "trash")
  }

  private var imageUsage: String {
    store.items.reduce(0) { $0 + ($1.image?.byteCount ?? 0) }.formatted(.byteCount(style: .file))
  }

  private func add(_ raw: String) {
    let keyword = raw.trimmingCharacters(in: .whitespaces)
    guard !keyword.isEmpty, !excluded.contains(keyword) else { return }
    excluded.append(keyword)
    newExcluded = ""
  }

  /// 关键词正好是某个 App 的 bundle ID 时显示它的图标
  private func excludedIcon(_ keyword: String) -> NSImage? {
    AppIcons.icon(for: keyword.contains(".") ? keyword : nil)
  }

  /// 正在运行的普通 App（有 Dock 图标的），按名称排序
  private var runningApps: [(bundleID: String, name: String)] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0 != .current }
      .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
