// 设置 › 剪贴板：历史上限、面板行为、格式与图片文字、隐私（敏感文本 / 排除 App）、清空时机。
// 上限类设置改了立即生效（执行一次清理）。

import SwiftUI

struct ClipboardTab: View {
  let store: ClipboardStore
  @AppStorage(Prefs.clipboardHistoryMax) private var historyMax = 100
  @AppStorage(Prefs.clipboardRetentionDays) private var retentionDays = 7
  @AppStorage(Prefs.clipboardImageBudgetMB) private var imageBudgetMB = 1024
  @AppStorage(Prefs.clipboardShowPreview) private var showPreview = true
  @AppStorage(Prefs.clipboardHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.clipboardKeepRichText) private var keepRichText = true
  @AppStorage(Prefs.clipboardImageOCR) private var imageOCR = true
  @AppStorage(Prefs.clipboardBlockSensitive) private var blockSensitive = true
  @AppStorage(Prefs.clipboardClearOnQuit) private var clearOnQuit = false
  @AppStorage(Prefs.clipboardClearOnLock) private var clearOnLock = false
  @State private var excluded =
    UserDefaults.standard.stringArray(forKey: Prefs.clipboardExcludedApps) ?? []
  @State private var newExcluded = ""
  @State private var confirmClear = false

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
        LabeledContent("图片当前占用", value: imageUsage)
        Text("收藏、片段和已归组的条目不受以上限制").font(.caption).foregroundStyle(.secondary)
      }
      Section("面板") {
        Toggle("显示预览栏", isOn: $showPreview)
        Toggle("点击面板外部时关闭", isOn: $hideOnUnfocus)
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
    // 固定高度、表单内滚动：内容全展开比小屏笔记本还高
    .frame(width: 520, height: 560)
    .onChange(of: historyMax) { store.enforceLimits() }
    .onChange(of: retentionDays) { store.enforceLimits() }
    .onChange(of: imageBudgetMB) { store.enforceLimits() }
    .onChange(of: imageOCR) { store.recognizePendingImages() }
    .onChange(of: excluded) {
      UserDefaults.standard.set(excluded, forKey: Prefs.clipboardExcludedApps)
    }
    .confirmationDialog("清空所有普通历史？", isPresented: $confirmClear) {
      Button("清空", role: .destructive) { store.clearOrdinary() }
    } message: {
      Text("收藏、片段和已归组的条目会保留")
    }
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
