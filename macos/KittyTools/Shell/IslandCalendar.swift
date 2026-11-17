// 那一张上的月历（2026-11-14，以 Alcove 为准那一轮剩下的一项，用户「把没做的也做了」）：快捷动作下面一块——左边今天是
// 星期几、几号，下面列今天的日程；右边这个月的日期网格，今天圈出来。设置 › 刘海岛「日程」里打开（默认关）。
// 日期网格是纯算的，不要任何授权；今天的日程只在已经给了「日历」授权时列（NextEvent.agenda，EventKit 只在那个文件里用），
// 这里从不问授权。点这一块打开「日历」App。
// 星期、月份跟着界面语言（多语言，2026-11-15：calendar 的地区就是 Locale.current）——中文「周六」「11月」「日 一 二…」，
// 英文「Sat」「Nov」「S M T…」，用系统自己的写法、不手拼；一周从星期几开始跟系统的日历设置（Calendar.firstWeekday）。
// 画在岛的黑底上，颜色用岛的强调色。

import SwiftUI

extension Island {
  /// 今天的一条日程（那一张的月历旁边列）：标题和开始时刻（全天的写「全天」）
  struct AgendaItem: Equatable, Identifiable {
    var id: String
    var title: String
    var time: String
    /// 它所在日历的颜色（设置里打开「用日历的颜色」时有：行首一个小圆点）
    var color: CGColor? = nil
  }

  /// 今天的日程：最多列几条，另有几条没列；busy：这个月里有日程的那几天（几号，「月历上标出有日程的日子」打开时有）
  struct Agenda: Equatable {
    var items: [AgendaItem]
    var more = 0
    var busy: Set<Int> = []
  }
}

/// 一个月的日期网格（纯函数，单测锁住）
nonisolated enum MonthGrid {
  struct Day: Equatable {
    var number: Int
    /// 是这个月的（不是为了补满一周借来的上下月的日子——那些格子空着不画）
    var inMonth: Bool
    var isToday: Bool
    /// 周末（按地区：calendar.isDateInWeekend；画得暗一档）
    var isWeekend: Bool
  }

  /// date 所在的那个月：一周一行，从 calendar.firstWeekday 起，头尾用上下月的日子补满整周（4–6 行）
  static func weeks(of date: Date, calendar: Calendar) -> [[Day]] {
    guard let month = calendar.dateInterval(of: .month, for: date),
      let count = calendar.range(of: .day, in: .month, for: date)?.count
    else { return [] }
    let lead = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
    let cells = ((lead + count + 6) / 7) * 7
    let days: [Day] = (0..<cells).compactMap { index in
      guard let day = calendar.date(byAdding: .day, value: index - lead, to: month.start) else {
        return nil
      }
      return Day(
        number: calendar.component(.day, from: day),
        inMonth: calendar.isDate(day, equalTo: date, toGranularity: .month),
        isToday: calendar.isDate(day, inSameDayAs: date),
        isWeekend: calendar.isDateInWeekend(day))
    }
    return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
  }

  /// 星期、月份的写法按界面语言取（Locale.current），一周从哪天起仍按传进来的 calendar
  private static func symbols(_ calendar: Calendar) -> Calendar {
    var copy = calendar
    copy.locale = .current
    return copy
  }

  /// 表头那一行：从 calendar.firstWeekday 起的七个字（中文「日 一 二…」、英文一个字母「S M T…」）
  static func header(calendar: Calendar) -> [String] {
    let names = symbols(calendar).veryShortStandaloneWeekdaySymbols
    return (0..<7).map { names[(calendar.firstWeekday - 1 + $0) % 7] }
  }

  /// 「周六」/「Sat」
  static func weekday(of date: Date, calendar: Calendar) -> String {
    symbols(calendar).shortStandaloneWeekdaySymbols[
      (calendar.component(.weekday, from: date) - 1) % 7]
  }

  /// 「11月」/「Nov」
  static func month(of date: Date, calendar: Calendar) -> String {
    symbols(calendar).shortStandaloneMonthSymbols[(calendar.component(.month, from: date) - 1) % 12]
  }
}

/// 那一张上的月历：左边星期 + 几号 + 今天的日程，右边月份 + 日期网格。高 156（6 行的月份 170）
struct IslandCalendar: View {
  let date: Date
  /// nil = 没有「日历」授权（左边只有日期，不写「没有日程」）
  let agenda: Island.Agenda?
  var calendar = Calendar.current

  var body: some View {
    let tint = IslandLeading.tint(.info)
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 0) {
        Text(MonthGrid.weekday(of: date, calendar: calendar))
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(tint)
        Text("\(calendar.component(.day, from: date))")
          .font(.system(size: 34, weight: .regular))
          .foregroundStyle(.white.opacity(0.95))
          .padding(.top, -2)
        Spacer(minLength: 6)
        events
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      VStack(alignment: .trailing, spacing: 4) {
        Text(MonthGrid.month(of: date, calendar: calendar))
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(tint)
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
          GridRow {
            ForEach(Array(MonthGrid.header(calendar: calendar).enumerated()), id: \.offset) {
              _, name in
              Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 24, height: 18)
            }
          }
          ForEach(Array(MonthGrid.weeks(of: date, calendar: calendar).enumerated()), id: \.offset) {
            _, week in
            GridRow {
              ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                // 上下月借来的格子空着；周末暗一档；今天是强调色的圆底，上面的字用 Style.onBrand（黄、橙、绿这些
                // 亮强调色上要换深色，同 IslandLeading）
                Text(day.inMonth ? "\(day.number)" : "")
                  .font(
                    .system(size: 11, weight: day.isToday ? .bold : .semibold).monospacedDigit()
                  )
                  .foregroundStyle(
                    day.isToday
                      ? AnyShapeStyle(Style.onBrand)
                      : AnyShapeStyle(.white.opacity(day.isWeekend ? 0.45 : 0.9))
                  )
                  .frame(width: 24, height: 19)
                  .background {
                    if day.isToday { Circle().fill(tint).frame(width: 19, height: 19) }
                  }
                  // 有日程的日子：数字下面一个小点（今天的圆底上不画）
                  .overlay(alignment: .bottom) {
                    if day.inMonth, !day.isToday, agenda?.busy.contains(day.number) == true {
                      Circle().fill(.white.opacity(0.55)).frame(width: 3, height: 3).offset(y: 1)
                    }
                  }
              }
            }
          }
        }
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 10)
    // 一般 5 行；一周从星期一起、1 号又落在周末的月份是 6 行，跟着长高
    .frame(minHeight: 156)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
  }

  /// 今天的日程：一行一条（时刻 + 标题），没有就一句话；没授权时什么都不写
  @ViewBuilder private var events: some View {
    if let agenda {
      if agenda.items.isEmpty {
        Text("今天没有日程")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white.opacity(0.55))
      } else {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(agenda.items) { item in
            HStack(spacing: 6) {
              if let color = item.color {
                Circle().fill(Color(cgColor: color)).frame(width: 6, height: 6)
              }
              Text(item.time)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize()
              Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          if agenda.more > 0 {
            Text("还有 \(agenda.more) 个")
              .font(.system(size: 11))
              .foregroundStyle(.white.opacity(0.4))
          }
        }
      }
    }
  }

  /// 读屏：「11月15日星期六，今天没有日程」（日期跟着界面语言，系统的写法）
  private var label: String {
    var style = Date.FormatStyle.dateTime.month(.wide).day().weekday(.wide)
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    let day = date.formatted(style)
    guard let agenda else { return day }
    let comma = Island.comma
    if agenda.items.isEmpty { return day + comma + String(localized: "今天没有日程") }
    return day + comma + agenda.items.map { "\($0.time) \($0.title)" }.joined(separator: comma)
      + (agenda.more > 0 ? comma + String(localized: "还有 \(agenda.more) 个") : "")
  }
}
