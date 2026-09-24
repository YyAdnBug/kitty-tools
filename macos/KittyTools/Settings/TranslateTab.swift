// 设置 › 翻译：语言（源、目标、智能模式的母语 / 常用外语）、行为（去换行、自动复制、历史），
// 服务（启用、排序、各服务的选项与密钥、自建 AI 实例的增删改、获取模型、测试连接）。密钥直接读写钥匙串。

import SwiftUI

struct TranslateTab: View {
  @Bindable var services: TranslateServiceStore
  @AppStorage(Prefs.translateSource) private var source: String?
  @AppStorage(Prefs.translateTarget) private var target: String?
  @AppStorage(Prefs.translateNative) private var native = Lang.zhHans.rawValue
  @AppStorage(Prefs.translateForeign) private var foreign = Lang.en.rawValue
  @AppStorage(Prefs.translateRemoveNewlines) private var removeNewlines = false
  @AppStorage(Prefs.translateAutoCopy) private var autoCopy = false
  @AppStorage(Prefs.translateHistoryEnabled) private var historyEnabled = true
  @AppStorage(Prefs.translateHistoryLimit) private var historyLimit = 500
  @State private var editing: String?

  var body: some View {
    Form {
      Section("语言") {
        Picker("源语言", selection: $source) {
          Text("自动检测").tag(String?.none)
          ForEach(Lang.allCases, id: \.self) { Text($0.title).tag(String?.some($0.rawValue)) }
        }
        Picker("目标语言", selection: $target) {
          Text("智能").tag(String?.none)
          ForEach(Lang.allCases, id: \.self) { Text($0.title).tag(String?.some($0.rawValue)) }
        }
        Picker("母语", selection: $native) {
          ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }
        Picker("常用外语", selection: $foreign) {
          ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }
        Text("「智能」：原文是母语就译成常用外语，否则译成母语。选了固定目标语言、而原文正好是这种语言时，也会改译成另一端。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("行为") {
        Toggle("翻译前把换行合成一段（适合 PDF 复制的文字）", isOn: $removeNewlines)
        Toggle("自动复制第一个服务的译文", isOn: $autoCopy)
          .help("「复制即译」开着时不会自动复制，免得自己触发自己")
        Toggle("记录翻译历史", isOn: $historyEnabled)
        Picker("历史最多保留", selection: $historyLimit) {
          ForEach([100, 200, 500, 1000, 2000], id: \.self) { Text("\($0) 条").tag($0) }
        }
        .disabled(!historyEnabled)
      }
      Section {
        ForEach($services.services) { $service in
          ServiceRow(
            service: $service, isEditing: editing == service.id,
            canMoveUp: service.id != services.services.first?.id,
            canMoveDown: service.id != services.services.last?.id
          ) { offset in
            move(service.id, by: offset)
          } onEdit: {
            editing = editing == service.id ? nil : service.id
          }
          if editing == service.id {
            ServiceEditor(service: $service) {
              services.remove(service.id)
              editing = nil
            }
          }
        }
        Button("添加 AI 服务", systemImage: "plus") {
          let service = TranslateService.newAI()
          services.services.append(service)
          editing = service.id
        }
      } header: {
        Text("翻译服务")
      } footer: {
        Text("结果按列表顺序显示；第一个服务的结果写入历史、用于自动复制。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 540, height: 600)
  }

  private func move(_ id: String, by offset: Int) {
    guard let index = services.services.firstIndex(where: { $0.id == id }),
      services.services.indices.contains(index + offset)
    else { return }
    services.services.swapAt(index, index + offset)
  }
}

private struct ServiceRow: View {
  @Binding var service: TranslateService
  let isEditing: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onMove: (Int) -> Void
  let onEdit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Toggle("启用", isOn: $service.isEnabled).labelsHidden()
      Image(systemName: service.symbol).foregroundStyle(.tint).frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(service.name).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Group {
        Button("上移", systemImage: "chevron.up") { onMove(-1) }.disabled(!canMoveUp)
        Button("下移", systemImage: "chevron.down") { onMove(1) }.disabled(!canMoveDown)
        Button(
          isEditing ? "完成" : "编辑",
          systemImage: isEditing ? "checkmark.circle" : "slider.horizontal.3", action: onEdit)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
    }
  }

  private var detail: String {
    switch service.kind {
    case .zhipu: service.model ?? ""
    case .ai:
      [service.aiProtocol?.title, service.model].compactMap { $0 }.filter { !$0.isEmpty }
        .joined(separator: " · ")
    case .deepl: service.usesDeepLX == true ? "DeepLX" : "官方 API"
    case .microsoft: service.secret("subscriptionKey") == nil ? "免费 Edge 接口" : "Azure 翻译"
    default: service.secretFields.allSatisfy { service.secret($0.name) != nil } ? "已配置" : "未配置密钥"
    }
  }
}

/// 展开在服务行下面的配置表单：各服务自己的选项 + 钥匙串里的密钥字段 + 测试连接
private struct ServiceEditor: View {
  @Binding var service: TranslateService
  let onDelete: () -> Void
  @State private var secrets: [String: String] = [:]
  @State private var models: [String] = []
  @State private var status: String?
  @State private var isBusy = false
  @State private var confirmDelete = false

  var body: some View {
    Group {
      options
      ForEach(service.secretFields, id: \.name) { field in
        SecureField(field.label, text: secretBinding(field.name), prompt: Text(field.prompt))
      }
      if service.kind == .ai { modelRow }
      HStack {
        Button("测试连接", action: test).disabled(isBusy)
        if isBusy { ProgressView().controlSize(.small) }
        if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        Spacer()
        if service.kind == .ai {
          Button("删除服务", role: .destructive) { confirmDelete = true }
        }
      }
    }
    .task(id: service.id) {
      secrets = Dictionary(
        uniqueKeysWithValues: service.secretFields.map { ($0.name, service.secret($0.name) ?? "") })
    }
    .confirmationDialog("删除「\(service.name)」？", isPresented: $confirmDelete) {
      Button("删除", role: .destructive, action: onDelete)
    } message: {
      Text("会同时删除它保存在钥匙串里的密钥")
    }
  }

  @ViewBuilder private var options: some View {
    switch service.kind {
    case .zhipu:
      Picker("模型", selection: Binding($service.model, default: TranslateService.zhipuModels[0])) {
        ForEach(TranslateService.zhipuModels, id: \.self) { Text($0).tag($0) }
      }
    case .ai:
      TextField("名称", text: $service.name)
      Picker("协议", selection: Binding($service.aiProtocol, default: .openai)) {
        ForEach(TranslateService.AIProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      TextField("服务地址", text: Binding($service.baseURL, default: ""), prompt: Text(addressHint))
    case .deepl:
      Picker("接口", selection: Binding($service.usesDeepLX, default: false)) {
        Text("官方 API").tag(false)
        Text("DeepLX（自建）").tag(true)
      }
      if service.usesDeepLX == true {
        TextField(
          "DeepLX 地址", text: Binding($service.baseURL, default: ""),
          prompt: Text("如 http://127.0.0.1:1188/translate"))
      }
    case .microsoft:
      TextField(
        "区域", text: Binding($service.region, default: ""), prompt: Text("填了 Key 才需要，如 eastasia"))
    default:
      EmptyView()
    }
  }

  private var modelRow: some View {
    HStack {
      TextField("模型", text: Binding($service.model, default: ""), prompt: Text("如 gpt-4o-mini"))
      Menu("获取模型") {
        if models.isEmpty { Text("点「获取」读取服务端的模型列表") }
        ForEach(models, id: \.self) { model in Button(model) { service.model = model } }
        Divider()
        Button("获取", action: fetchModels)
      }
      .fixedSize()
    }
  }

  private func secretBinding(_ field: String) -> Binding<String> {
    Binding(
      get: { secrets[field] ?? "" },
      set: { value in
        secrets[field] = value
        service.setSecret(value.trimmingCharacters(in: .whitespacesAndNewlines), field)
      })
  }

  private var addressHint: String {
    switch service.aiProtocol ?? .openai {
    case .openai: "https://api.openai.com/v1 或本机 http://127.0.0.1:11434/v1"
    case .azure: "https://<资源名>.openai.azure.com/openai/v1"
    case .anthropic: "留空即 https://api.anthropic.com"
    }
  }

  /// 用 Hello, world 做一次英译中
  private func test() {
    isBusy = true
    status = nil
    let request = TranslateRequest(text: "Hello, world", from: .en, to: .zhHans)
    let service = service
    Task {
      defer { isBusy = false }
      do {
        var result = ""
        for try await text in service.translate(request) { result = text }
        status = "✓ \(result)"
      } catch {
        status = "✗ \(error.localizedDescription)"
      }
    }
  }

  private func fetchModels() {
    isBusy = true
    status = nil
    let key = secrets["apiKey"] ?? ""
    let (baseURL, aiProtocol) = (service.baseURL ?? "", service.aiProtocol ?? .openai)
    Task {
      defer { isBusy = false }
      do {
        models = try await AIService.fetchModels(baseURL: baseURL, aiProtocol: aiProtocol, key: key)
        status = models.isEmpty ? "服务端没有返回模型" : "找到 \(models.count) 个模型，在「获取模型」里选择"
      } catch {
        status = "✗ \(error.localizedDescription)"
      }
    }
  }
}

extension Binding {
  /// 把可选值绑定成非可选（读空时用默认值，写回原样）
  init(_ source: Binding<Value?>, default value: Value) {
    self.init(get: { source.wrappedValue ?? value }, set: { source.wrappedValue = $0 })
  }
}
