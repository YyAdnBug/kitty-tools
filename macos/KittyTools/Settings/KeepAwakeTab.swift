// 设置 › 保持唤醒（第一个插件，2026-11-12 拍板 B2，PLAN §10「保持唤醒」）。页头由 SettingsRoot 画（家族色靛紫）。四组：
// 「现在」——在不在保持唤醒、还剩多久（每分钟走一下），没开时选一档「开始」，开着时「停止」；
// 「屏幕」——屏幕也不熄（默认开；关掉只防系统睡眠）；
// 「定时」——按时段自动保持唤醒（默认关）：哪几天、从几点到几点（或全天），跟着这台 Mac 不同步；
// 最后一行「移除这个插件」（同「功能」页卡片上的「移除」：关掉开关，设置留着；移除后这一页就不在侧栏了，SettingsRoot 带回「功能」页）。

import SwiftUI

struct KeepAwakeTab: View {
  let keepAwake: KeepAwake
  @AppStorage(Prefs.keepAwakeDisplay) private var display = true
  @AppStorage(Prefs.keepAwakeSchedule) private var scheduleText = ""
  /// 「开始」用哪一档（KeepAwakePlan.presets 的下标；默认 1 小时）
  @State private var preset = 1

  var body: some View {
    Form {
      Section {
        TimelineView(.everyMinute) { context in
          LabeledContent {
            if keepAwake.sessionEnd != nil {
              Button("停止") { keepAwake.end() }
            } else {
              HStack(spacing: 8) {
                Picker("时长", selection: $preset) {
                  ForEach(KeepAwakePlan.presets.indices, id: \.self) {
                    Text(KeepAwakePlan.presets[$0].title).tag($0)
                  }
                }
                .labelsHidden()
                .fixedSize()
                Button("开始") { start() }
              }
            }
          } label: {
            Text(keepAwake.isActive ? "保持唤醒中" : "没在保持唤醒")
            Text(keepAwake.isActive ? keepAwake.status(now: context.date) : "电脑照常睡、屏幕照常熄")
          }
        }
      } header: {
        Text("现在")
      } footer: {
        SectionFootnote("也能在菜单栏、主界面里开，或者在启动器里输入「awake 2小时」「保持唤醒 到18点」。重启电脑、退出 Kitty Tools 后不再保持。")
      }
      Section {
        Toggle(isOn: $display) {
          Text("屏幕也不熄")
          Text("关掉就只防系统睡眠，屏幕照常熄灭（后台下载、跑任务时省电）")
        }
      } header: {
        Text("屏幕")
      }
      Section {
        Toggle(isOn: scheduleBinding(\.isOn)) {
          Text("按时段自动保持唤醒")
          Text("在时段里自动开始、出了时段自动停；手动开的那一段优先")
        }
        Group {
          WeekdayRow(
            days: Binding {
              schedule.weekdays.sorted()
            } set: { days in
              update { $0.weekdays = Set(days) }
            })
          Toggle("全天", isOn: scheduleBinding(\.allDay))
          if !schedule.allDay {
            DatePicker("从", selection: clock(\.start), displayedComponents: .hourAndMinute)
            DatePicker("到", selection: clock(\.end), displayedComponents: .hourAndMinute)
          }
        }
        .disabled(!schedule.isOn)
        .opacity(schedule.isOn ? 1 : Style.disabledOpacity)
      } header: {
        Text("定时")
      } footer: {
        SectionFootnote(
          "结束早于开始就是跨过半夜（22:00 到 2:00 管到第二天凌晨）。定时跟着这台 Mac，不同步。合上盖子时系统照样会睡（接着电源和外接显示器时除外）。"
        )
      }
      PluginRemoveSection(plugin: .keepAwake)
    }
    .formStyle(.grouped)
  }

  private var schedule: KeepAwakePlan.Schedule { .decode(scheduleText) }

  private func update(_ change: (inout KeepAwakePlan.Schedule) -> Void) {
    var next = schedule
    change(&next)
    scheduleText = next.encoded
  }

  private func scheduleBinding(_ key: WritableKeyPath<KeepAwakePlan.Schedule, Bool>) -> Binding<
    Bool
  > {
    Binding {
      schedule[keyPath: key]
    } set: { value in
      update { $0[keyPath: key] = value }
    }
  }

  /// 一天里的第几分钟 ↔ 今天那个时刻（给时间选择器用）
  private func clock(_ key: WritableKeyPath<KeepAwakePlan.Schedule, Int>) -> Binding<Date> {
    Binding {
      let minutes = schedule[keyPath: key]
      return Calendar.current.date(
        bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    } set: { date in
      let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
      update { $0[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
    }
  }

  private func start() {
    let choice = KeepAwakePlan.presets[preset]
    keepAwake.begin(
      until: choice.minutes.map { Date.now.addingTimeInterval(Double($0 * 60)) },
      label: choice.title)
  }
}
