// 设置 › 启动器 › 应用别名：按名字或别名找已安装的 App，逐行编辑多个别名。
// 列表沿用启动器的后台扫描；截图自检传固定 apps，不扫描本机，也不写真实偏好。

import SwiftUI

struct AppAliasesPage: View {
  static let route = "page:app-aliases"
  var apps: [LauncherItem]? = nil
  @AppStorage(Prefs.launcherAppAliases) private var aliasesText = ""
  @Environment(\.dismiss) private var dismiss
  @State private var loadedApps: [LauncherItem]?
  @State private var filter = ""
  @State private var scanRevision = 0
  @State private var saveError: String?
  @FocusState private var editing: String?

  var body: some View {
    let aliases = AppAliases(text: aliasesText)
    let catalog = apps ?? loadedApps
    let installed = (catalog ?? []).filter { $0.kind == .app }.sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
    let query = LauncherMatch.fold(filter.trimmingCharacters(in: .whitespacesAndNewlines))
    let shown = installed.filter {
      query.isEmpty || editing == $0.id || LauncherMatch.score(query, item: $0) > 0
        || LauncherMatch.fold(aliases.text(for: $0)).contains(query)
    }
    VStack(spacing: 0) {
      DetailHeader(title: "应用别名", status: "给应用起个顺手的名字，在启动器里输入就能找到") {
        KindTile(symbol: "app.badge", color: Style.Family.command, size: 40)
      }
      Form {
        Section {
          TextField("搜索应用", text: $filter, prompt: Text("按应用名或别名找"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityLabel("搜索应用")
          if let saveError {
            Text(saveError).font(.subheadline).foregroundStyle(.orange)
          }
        } footer: {
          SectionFootnote("多个别名用逗号隔开，例如 wx, 聊天。原来的应用名仍可搜索，清空即可移除别名。")
        }
        Section {
          if catalog == nil {
            HStack {
              ProgressView().controlSize(.small)
              Text("正在读取应用…").foregroundStyle(.secondary)
            }
          } else if shown.isEmpty {
            Text(installed.isEmpty ? "没有找到已安装的应用" : "没有匹配的应用，试试其它名字或别名")
              .foregroundStyle(.secondary)
          } else {
            HStack {
              Text("应用")
              Spacer()
              Text("别名").frame(width: 220, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            ForEach(shown) { item in
              HStack(spacing: 8) {
                if let icon = LauncherIcons.icon(for: item.target) {
                  Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.title).lineLimit(1)
                  Text((item.target as NSString).abbreviatingWithTildeInPath)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                }
                .help(item.target)
                Spacer(minLength: 8)
                TextField("别名", text: binding(for: item, aliases: aliases), prompt: Text("添加别名"))
                  .textFieldStyle(.roundedBorder)
                  .labelsHidden()
                  .frame(width: 220)
                  .focused($editing, equals: item.id)
                  .accessibilityLabel("「\(item.title)」的别名")
              }
            }
          }
        } footer: {
          SectionFootnote(
            "完整输入别名时优先显示对应应用；多个应用用了同一别名时按使用习惯排序。带参数的命令仍按命令处理。每个应用最多 256 字。")
        }
      }
      .formStyle(.grouped)
    }
    .navigationTitle("应用别名")
    .toolbar { SettingsBackButton { dismiss() } }
    .task(id: scanRevision) {
      guard apps == nil else { return }
      let scanned = await AppCatalog.scanInBackground()
      guard !Task.isCancelled else { return }
      loadedApps = scanned
    }
    .onSettingsBecameKey { scanRevision += 1 }
  }

  private func binding(for item: LauncherItem, aliases: AppAliases) -> Binding<String> {
    Binding {
      aliases.text(for: item)
    } set: { value in
      // 每次写入从最新偏好改一项：编辑时同步带来的其它 App 配置也保留。
      guard let saved = AppAliases(text: aliasesText).setting(value, for: item) else {
        saveError =
          value.count > AppAliases.entryLimit
          ? "「\(item.title)」的别名超过 256 字，请缩短后再输入。"
          : "应用别名已达到可保存的长度，请先删去一些不用的别名。"
        return
      }
      aliasesText = saved
      saveError = nil
      // 改过一个别名，「新」就算看过了（光点进这一页不算；WhatsNew）
      WhatsNew.touch(section: "应用别名", of: .launcher)
    }
  }
}
