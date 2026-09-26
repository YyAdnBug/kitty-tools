// 设置 › 翻译 › 某个服务（N12 详情页，从服务列表推进来）：页头 40 pt 服务图标 + 名称 + 状态，
// 下面分组表单：启用、各服务自己的选项（自建 AI 实例的名称 / 协议 / 地址 / 模型与「获取模型」）、钥匙串里的密钥、
// 测试连接；自建 AI 实例可以删除（连同密钥）。改动即时生效（服务列表写 UserDefaults，密钥直接写钥匙串）。

import SwiftUI

struct TranslateServiceDetail: View {
  @Bindable var store: TranslateServiceStore
  let id: String
  @Environment(\.dismiss) private var dismiss
  @State private var secrets: [String: String] = [:]
  @State private var models: [String] = []
  /// 测试连接 / 获取模型的结果：ok = 成功（绿）、否则失败（红）
  @State private var result: (ok: Bool, text: String)?
  @State private var isBusy = false
  @State private var confirmsDelete = false

  var body: some View {
    // 删掉之后、退回列表之前的这一帧没有这条服务：什么都不画
    if let current = store.services.first(where: { $0.id == id }) {
      form(current)
        .navigationTitle(current.name)
    }
  }

  private func form(_ current: TranslateService) -> some View {
    let service = binding(current)
    let status = current.settingsStatus
    return Form {
      Section {
        Toggle("启用", isOn: service.isEnabled)
        options(service)
        if current.kind == .ai { modelRow(service) }
      } header: {
        DetailHeader(title: current.name, status: status.text, isProblem: status.isProblem) {
          ServiceTile(service: current, size: 40)
        }
      }
      Section {
        ForEach(current.secretFields, id: \.name) { field in
          SecureField(field.label, text: secretBinding(field.name), prompt: Text(field.prompt))
        }
      } header: {
        Text("密钥")
      } footer: {
        OrderedList.footnote("只存在这台 Mac 的钥匙串里。")
      }
      Section {
        HStack(spacing: 8) {
          Button("测试连接", action: test).disabled(isBusy)
          if isBusy { ProgressView().controlSize(.small) }
          if let result {
            Label {
              Text(result.text).foregroundStyle(.secondary).lineLimit(2)
            } icon: {
              Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(Color(nsColor: result.ok ? .systemGreen : .systemRed))
            }
            .font(.caption)
          }
          Spacer(minLength: 0)
        }
      } footer: {
        OrderedList.footnote("用「Hello, world」做一次英译中。")
      }
      if current.kind == .ai {
        Section {
          Button("删除服务…", role: .destructive) { confirmsDelete = true }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: id) {
      secrets = Dictionary(
        uniqueKeysWithValues: current.secretFields.map { ($0.name, current.secret($0.name) ?? "") })
    }
    .confirmationDialog("删除「\(current.name)」？", isPresented: $confirmsDelete) {
      Button("删除", role: .destructive) {
        dismiss()
        store.remove(id)
      }
    } message: {
      Text("会同时删除它保存在钥匙串里的密钥")
    }
  }

  /// 按 id 找回这条服务的绑定（列表拖动排序后下标会变）
  private func binding(_ fallback: TranslateService) -> Binding<TranslateService> {
    Binding {
      store.services.first { $0.id == id } ?? fallback
    } set: { value in
      if let index = store.services.firstIndex(where: { $0.id == id }) {
        store.services[index] = value
      }
    }
  }

  @ViewBuilder private func options(_ service: Binding<TranslateService>) -> some View {
    switch service.wrappedValue.kind {
    case .zhipu:
      Picker("模型", selection: Binding(service.model, default: TranslateService.zhipuModels[0])) {
        ForEach(TranslateService.zhipuModels, id: \.self) { Text($0).tag($0) }
      }
      .pickerStyle(.segmented)
    case .ai:
      TextField("名称", text: service.name)
      Picker("协议", selection: Binding(service.aiProtocol, default: .openai)) {
        ForEach(TranslateService.AIProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      TextField(
        "服务地址", text: Binding(service.baseURL, default: ""),
        prompt: Text(Self.addressHint(service.wrappedValue.aiProtocol ?? .openai)))
    case .deepl:
      Picker("接口", selection: Binding(service.usesDeepLX, default: false)) {
        Text("官方 API").tag(false)
        Text("DeepLX（自建）").tag(true)
      }
      .pickerStyle(.segmented)
      if service.wrappedValue.usesDeepLX == true {
        TextField(
          "DeepLX 地址", text: Binding(service.baseURL, default: ""),
          prompt: Text("如 http://127.0.0.1:1188/translate"))
      }
    case .microsoft:
      TextField(
        "区域", text: Binding(service.region, default: ""), prompt: Text("填了 Key 才需要，如 eastasia"))
    default:
      EmptyView()
    }
  }

  private func modelRow(_ service: Binding<TranslateService>) -> some View {
    HStack {
      TextField("模型", text: Binding(service.model, default: ""), prompt: Text("如 gpt-4o-mini"))
      Menu("获取模型") {
        if models.isEmpty { Text("点「获取」读取服务端的模型列表") }
        ForEach(models, id: \.self) { model in Button(model) { service.wrappedValue.model = model }
        }
        Divider()
        Button("获取") { fetchModels(service.wrappedValue) }
      }
      .fixedSize()
    }
  }

  private func secretBinding(_ field: String) -> Binding<String> {
    Binding(
      get: { secrets[field] ?? "" },
      set: { value in
        secrets[field] = value
        store.services.first { $0.id == id }?
          .setSecret(value.trimmingCharacters(in: .whitespacesAndNewlines), field)
      })
  }

  private static func addressHint(_ aiProtocol: TranslateService.AIProtocol) -> String {
    switch aiProtocol {
    case .openai: "https://api.openai.com/v1 或本机 http://127.0.0.1:11434/v1"
    case .azure: "https://<资源名>.openai.azure.com/openai/v1"
    case .anthropic: "留空即 https://api.anthropic.com"
    }
  }

  /// 用 Hello, world 做一次英译中
  private func test() {
    guard let service = store.services.first(where: { $0.id == id }) else { return }
    isBusy = true
    result = nil
    let request = TranslateRequest(text: "Hello, world", from: .en, to: .zhHans)
    Task {
      defer { isBusy = false }
      do {
        var text = ""
        for try await chunk in service.translate(request) { text = chunk }
        result = (true, text)
      } catch {
        result = (false, error.localizedDescription)
      }
    }
  }

  private func fetchModels(_ service: TranslateService) {
    isBusy = true
    result = nil
    let key = secrets["apiKey"] ?? ""
    let (baseURL, aiProtocol) = (service.baseURL ?? "", service.aiProtocol ?? .openai)
    Task {
      defer { isBusy = false }
      do {
        models = try await AIService.fetchModels(baseURL: baseURL, aiProtocol: aiProtocol, key: key)
        result =
          models.isEmpty ? (false, "服务端没有返回模型") : (true, "找到 \(models.count) 个模型，在「获取模型」里选择")
      } catch {
        result = (false, error.localizedDescription)
      }
    }
  }
}

extension TranslateService {
  /// 服务行和详情页头的状态副标题。isProblem = 开着却缺配置（橙色）；关着的服务缺配置只用 secondary 写出来，
  /// 不然默认关着的那几个内置服务会一片橙色。读钥匙串，只在设置里用
  var settingsStatus: (text: String, isProblem: Bool) {
    let (text, missing): (String, Bool) =
      switch kind {
      case .zhipu: (model ?? TranslateService.zhipuModels[0], false)
      case .ai:
        if aiProtocol != .anthropic, (baseURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
          ("未填服务地址", true)
        } else if (model ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
          ("未填模型", true)
        } else {
          ([aiProtocol?.title, model].compactMap { $0 }.joined(separator: " · "), false)
        }
      case .deepl:
        if usesDeepLX == true {
          (baseURL ?? "").isEmpty ? ("未填 DeepLX 地址", true) : ("DeepLX（自建）", false)
        } else {
          secret("authKey") == nil ? ("未填密钥", true) : ("官方 API", false)
        }
      case .microsoft: (secret("subscriptionKey") == nil ? "免费 Edge 接口" : "Azure 翻译", false)
      default:
        secretFields.allSatisfy { secret($0.name) != nil } ? ("已填密钥", false) : ("未填密钥", true)
      }
    return (text, missing && isEnabled)
  }
}

extension Binding {
  /// 把可选值绑定成非可选（读空时用默认值，写回原样）
  init(_ source: Binding<Value?>, default value: Value) {
    self.init(get: { source.wrappedValue ?? value }, set: { source.wrappedValue = $0 })
  }
}
