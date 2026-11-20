// 设置里推进去的子页（设置改版 S1，2026-11-18，规格 SPEC §1.3）：一页里同一主题 4 项以上、或者本身是一组状态的，外面留一行
// 推进行（行尾写现在的状态），点进去是这一页。路由一律 "sub:<页>.<名>"（navigation.path 里的一项），翻译服务、网页搜索的
// id 不会以它开头。子页 = 页头（40 pt 页的色块 + 子页名 + 一句现在的状态）+ 分组表单，工具栏「‹ 返回」，最后一组页脚右边
// 「恢复默认」（只管这一页里登记的偏好键，SettingsReset）。

import SwiftUI

enum SettingsSubpage: String, CaseIterable, Identifiable {
  case generalPermissions = "general.permissions"
  case generalSync = "general.sync"
  case generalBackup = "general.backup"
  case screenshotHistory = "screenshot.history"
  case translateLookup = "translate.lookup"
  case translateHistory = "translate.history"
  case launcherScripts = "launcher.scripts"
  case notesDeck = "notes.deck"
  case islandActions = "island.actions"
  case islandMedia = "island.media"
  case islandCalendar = "island.calendar"
  case islandLevels = "island.levels"
  case islandFocus = "island.focus"
  case islandNotices = "island.notices"

  var id: String { rawValue }

  var page: SettingsPage {
    switch self {
    case .generalPermissions, .generalSync, .generalBackup: .general
    case .screenshotHistory: .screenshot
    case .translateLookup, .translateHistory: .translate
    case .launcherScripts: .launcher
    case .notesDeck: .notes
    case .islandActions, .islandMedia, .islandCalendar, .islandLevels, .islandFocus, .islandNotices:
      .island
    }
  }

  var title: LocalizedStringResource {
    switch self {
    case .generalPermissions: "权限"
    case .generalSync: "同步"
    case .generalBackup: "备份与导出导入"
    case .screenshotHistory: "截图历史"
    case .translateLookup: "查词与朗读"
    case .translateHistory: "翻译历史"
    case .launcherScripts: "脚本命令"
    case .notesDeck: "屏幕边缘"
    case .islandActions: "快捷动作"
    case .islandMedia: "正在播放"
    case .islandCalendar: "日程与月历"
    case .islandLevels: "音量与亮度"
    case .islandFocus: "专注模式"
    case .islandNotices: "系统提示"
    }
  }

  /// navigation.path 里的那一项
  var route: String { "sub:" + rawValue }

  init?(route: String) {
    guard route.hasPrefix("sub:") else { return nil }
    self.init(rawValue: String(route.dropFirst("sub:".count)))
  }

  /// 岛上、搜索结果里说的位置：「通用 › 权限」
  var location: String { "\(page.title) › \(String(localized: title))" }

  /// 这一页「恢复默认」管的键
  var resetKeys: [String] {
    SettingsReset.keys(of: SettingsItem.allCases.filter { $0.place == .subpage(self) })
  }
}

/// 一个子页的骨架：页头、分组表单（滚到搜到的那一行）、工具栏的「‹ 返回」、最后一组页脚右边的「恢复默认」
struct SubpageForm<Content: View>: View {
  let subpage: SettingsSubpage
  /// 页头下面那一句：现在的状态
  let status: LocalizedStringResource
  var statusIsProblem = false
  /// 钉在页头下面的悬停预览（刘海岛的几个子页）：页里挂 .previews 的行停着时演它
  var preview: PreviewScene?
  @ViewBuilder let content: Content
  @Environment(\.dismiss) private var dismiss
  @State private var previewFocus = PreviewFocus()

  var body: some View {
    VStack(spacing: 0) {
      DetailHeader(title: subpage.title, status: status, isProblem: statusIsProblem) {
        KindTile(symbol: subpage.page.symbol, color: subpage.page.color, size: 40)
      }
      if let preview { PreviewStage(still: preview).pinned() }
      Form {
        content
        let keys = subpage.resetKeys
        if !keys.isEmpty {
          Section {
          } footer: {
            HStack {
              Spacer()
              ResetDefaultsButton(keys: keys, place: subpage.location)
            }
          }
        }
      }
      .formStyle(.grouped)
      .settingsScrollTarget()
    }
    .environment(previewFocus)
    .navigationTitle(String(localized: subpage.title))
    .toolbar { SettingsBackButton { dismiss() } }
  }
}
