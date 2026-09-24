// 设置 › 关于：版本号、打开发布页、随包分发的更新日志（changelog.json，最新版在前）。
// 更新后第一次启动会自动打开这一页（AppDelegate 比较 lastSeenVersion）。不做在线更新（PLAN D8）。

import SwiftUI

struct AboutTab: View {
  /// changelog.json 的一个版本
  struct Release: Decodable, Identifiable {
    struct Change: Decodable, Hashable {
      let type: String
      let scope: String
      let text: String
    }

    let version: String
    let date: String
    let summary: String
    let changes: [Change]
    var id: String { version }
  }

  // 只发 GitHub 预发布版（tag macos-v*），和旧版的正式版在同一个仓库里，按 tag 过滤
  private static let releasesURL = URL(
    string: "https://github.com/yyandbug-coder/kitty-tools/releases?q=macos-v&expanded=true")!

  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

  static let releases: [Release] = {
    guard let url = Bundle.main.url(forResource: "changelog", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return [] }
    return (try? JSONDecoder().decode([Release].self, from: data)) ?? []
  }()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
        VStack(alignment: .leading, spacing: 4) {
          Text("Kitty Tools Native").font(.title2.weight(.semibold))
          Text("版本 \(Self.version)" + (Self.build.map { "（\($0)）" } ?? ""))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        Spacer()
        Button("打开发布页") { NSWorkspace.shared.open(Self.releasesURL) }
      }
      .padding(20)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          ForEach(Self.releases) { release in
            ReleaseView(release: release, isCurrent: release.version == Self.version)
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 520, height: 460)
  }
}

private struct ReleaseView: View {
  let release: AboutTab.Release
  let isCurrent: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(release.version).font(.headline)
        if isCurrent {
          Text("当前版本")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
        }
        Spacer()
        Text(release.date).font(.caption).foregroundStyle(.secondary)
      }
      Text(release.summary).foregroundStyle(.secondary)
      ForEach(release.changes, id: \.self) { change in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(Self.label(change.type))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, alignment: .leading)
          Text("\(Text(change.scope).fontWeight(.medium))　\(change.text)")
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .textSelection(.enabled)
  }

  private static func label(_ type: String) -> String {
    switch type {
    case "feat": "新增"
    case "fix": "修复"
    case "perf": "性能"
    case "ui": "界面"
    default: type
    }
  }
}
