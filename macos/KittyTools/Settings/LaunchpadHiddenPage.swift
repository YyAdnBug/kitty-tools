// 设置 › 启动台 › 隐藏的 App（issue #44，2026-11-22）：列出启动台的 App（同启动台的目录），关掉的不进网格，搜索里照样搜得到；
// 再打开的排到最后一页末尾（同新装）。列表在后台扫（LaunchpadCatalog.loadInBackground）；截图自检传固定 apps，不扫本机，
// 偏好走 defaultAppStorage 的临时域，不写真实偏好。

import SwiftUI

struct LaunchpadHiddenPage: View {
  static let route = "page:launchpad-hidden"
  var apps: [LaunchpadProjectApp]? = nil
  @AppStorage(Prefs.launchpadHiddenApps) private var hiddenText = ""
  @Environment(\.dismiss) private var dismiss
  @State private var loadedApps: [LaunchpadProjectApp]?
  @State private var filter = ""

  /// 页头那一句（先算好再传：可选参数里写三元式，抽字时第二个分支会漏掉）
  private func status(hidden: Int) -> LocalizedStringResource {
    hidden == 0 ? "启动台里的 App 都显示着" : "\(hidden) 个 App 不在启动台的网格里"
  }

  var body: some View {
    let hidden = Launchpad.hiddenIDs(hiddenText)
    let catalog = apps ?? loadedApps
    let query = LauncherMatch.fold(filter.trimmingCharacters(in: .whitespacesAndNewlines))
    let shown = (catalog ?? []).filter {
      query.isEmpty || LauncherMatch.score(query, item: $0.item) > 0
    }
    VStack(spacing: 0) {
      DetailHeader(
        title: "隐藏的 App",
        status: status(hidden: (catalog ?? []).filter { hidden.contains($0.id) }.count)
      ) {
        KindTile(
          symbol: SettingsPage.launchpad.symbol, color: SettingsPage.launchpad.color, size: 40)
      }
      Form {
        Section {
          TextField("搜索应用", text: $filter, prompt: Text("按应用名找"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityLabel("搜索应用")
        } footer: {
          SectionFootnote("关掉的 App 不在启动台的网格里，在启动台里打字照样搜得到；再打开就排到最后一页末尾。")
        }
        Section {
          if catalog == nil {
            HStack {
              ProgressView().controlSize(.small)
              Text("正在读取应用…").foregroundStyle(.secondary)
            }
          } else if shown.isEmpty {
            Text((catalog ?? []).isEmpty ? "没有找到已安装的应用" : "没有匹配的应用，试试其它名字")
              .foregroundStyle(.secondary)
          } else {
            ForEach(shown) { app in
              Toggle(isOn: binding(for: app.id, hidden: hidden)) {
                HStack(spacing: 8) {
                  if let icon = LauncherIcons.icon(for: app.item.target) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                      .accessibilityHidden(true)
                  }
                  Text(app.name).lineLimit(1).truncationMode(.tail)
                }
              }
              .accessibilityLabel(Text("在启动台里显示「\(app.name)」"))
            }
          }
        } header: {
          Text("在启动台里显示")
        }
      }
      .formStyle(.grouped)
    }
    .navigationTitle(String(localized: "隐藏的 App"))
    .toolbar { SettingsBackButton { dismiss() } }
    .task {
      guard apps == nil else { return }
      let scanned = await LaunchpadCatalog.loadInBackground()
      guard !Task.isCancelled else { return }
      loadedApps = scanned
    }
  }

  /// 开关 = 显示着；写回时从最新的偏好改这一项（同步、别处改的照样留着），排好序一行一个
  private func binding(for id: String, hidden: Set<String>) -> Binding<Bool> {
    Binding {
      !hidden.contains(id)
    } set: { shown in
      var current = Launchpad.hiddenIDs(hiddenText)
      if shown { current.remove(id) } else { current.insert(id) }
      hiddenText = current.sorted().joined(separator: "\n")
    }
  }
}
