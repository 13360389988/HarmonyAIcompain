/**
 * InsightsPage.ets
 * ----------------
 * 行为模式可视化页面 — 多维度展示数字孪生对你的洞察。
 *
 * 子页面（Tab 切换）：
 *   1. 作息曲线  — 每日起床/入睡时间趋势
 *   2. 情绪热力图 — 按星期×时段的情绪分布
 *   3. 关系图谱  — 社交关系网可视化
 *   4. 位置轨迹  — 高频位置 + 时段分布
 *   5. 打字模式  — 速度/删除率趋势
 *
 * 注：UI 先用基础组件搭骨架，后续可接入图表库或用 Figma 设计稿替换。
 */

import { MemoryService, BehaviorLog, RelationRecord, ProceduralRecord } from "../services/MemoryService";

@Entry
@Component
struct InsightsPage {
  @State activeTab: number = 0;
  @State sleepData: Array<{ day: string; wakeHour: number }> = [];
  @State emotionHeatmap: Array<{ weekday: number; hour: number; emotion: string; count: number }> = [];
  @State relations: RelationRecord[] = [];
  @State locationData: Array<{ location: string; count: number; slots: Record<string, number> }> = [];
  @State typingData: Array<{ date: string; speed: number; deleteRatio: number }> = [];
  @State patterns: ProceduralRecord[] = [];

  private memory: MemoryService = new MemoryService();
  private tabs = ["作息曲线", "情绪热力图", "关系图谱", "位置轨迹", "打字模式"];

  aboutToAppear(): void {
    this.memory.init(getContext(this)).then(() => {
      this.loadAll();
    });
  }

  private async loadAll(): Promise<void> {
    await Promise.all([
      this.loadSleepData(),
      this.loadEmotionHeatmap(),
      this.loadRelations(),
      this.loadLocationData(),
      this.loadTypingData(),
      this.loadPatterns(),
    ]);
  }

  // ============================================================
  // 数据加载
  // ============================================================
  private async loadSleepData(): Promise<void> {
    const now = Date.now();
    const since = now - 14 * 24 * 60 * 60 * 1000;  // 最近 14 天
    const logs = await this.memory.getBehaviorByRange(since, now);

    // 按天分组，找首条活跃时间
    const byDay: Map<string, number> = new Map();
    for (const log of logs) {
      const day = new Date(log.timestamp).toISOString().slice(0, 10);
      if (!byDay.has(day) || log.timestamp < byDay.get(day)!) {
        byDay.set(day, log.timestamp);
      }
    }

    const data: Array<{ day: string; wakeHour: number }> = [];
    for (const [day, ts] of byDay) {
      const h = new Date(ts).getHours() + new Date(ts).getMinutes() / 60;
      data.push({ day: day.slice(5), wakeHour: h });
    }
    data.sort((a, b) => a.day.localeCompare(b.day));
    this.sleepData = data;
  }

  private async loadEmotionHeatmap(): Promise<void> {
    const now = Date.now();
    const since = now - 30 * 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now, "chat");

    const map: Map<string, { weekday: number; hour: number; emotion: string; count: number }> = new Map();
    for (const log of logs) {
      try {
        const data = JSON.parse(log.data);
        if (!data.emotion) continue;
        const d = new Date(log.timestamp);
        const wd = d.getDay();
        const h = Math.floor(d.getHours() / 4) * 4;  // 4 小时一格
        const key = `${wd}_${h}`;
        if (!map.has(key)) {
          map.set(key, { weekday: wd, hour: h, emotion: data.emotion, count: 0 });
        }
        map.get(key)!.count++;
      } catch { /* 忽略 */ }
    }
    this.emotionHeatmap = Array.from(map.values());
  }

  private async loadRelations(): Promise<void> {
    this.relations = await this.memory.getAllRelations();
  }

  private async loadLocationData(): Promise<void> {
    const now = Date.now();
    const since = now - 30 * 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now, "location");

    const byLoc: Map<string, { count: number; slots: Record<string, number> }> = new Map();
    for (const log of logs) {
      if (!log.location) continue;
      if (!byLoc.has(log.location)) {
        byLoc.set(log.location, { count: 0, slots: {} });
      }
      const entry = byLoc.get(log.location)!;
      entry.count++;
      const slot = this.timeToSlot(new Date(log.timestamp).getHours());
      entry.slots[slot] = (entry.slots[slot] ?? 0) + 1;
    }

    this.locationData = Array.from(byLoc.entries())
      .map(([location, v]) => ({ location, ...v }))
      .sort((a, b) => b.count - a.count);
  }

  private async loadTypingData(): Promise<void> {
    const now = Date.now();
    const since = now - 14 * 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now, "typing_pattern");

    const byDate: Map<string, { speeds: number[]; deleteRatios: number[] }> = new Map();
    for (const log of logs) {
      try {
        const data = JSON.parse(log.data);
        const day = new Date(log.timestamp).toISOString().slice(0, 10);
        if (!byDate.has(day)) byDate.set(day, { speeds: [], deleteRatios: [] });
        if (data.typing_speed !== undefined) byDate.get(day)!.speeds.push(data.typing_speed);
        if (data.delete_ratio !== undefined) byDate.get(day)!.deleteRatios.push(data.delete_ratio);
      } catch { /* 忽略 */ }
    }

    this.typingData = Array.from(byDate.entries()).map(([date, v]) => ({
      date: date.slice(5),
      speed: v.speeds.reduce((a, b) => a + b, 0) / Math.max(1, v.speeds.length),
      deleteRatio: v.deleteRatios.reduce((a, b) => a + b, 0) / Math.max(1, v.deleteRatios.length),
    })).sort((a, b) => a.date.localeCompare(b.date));
  }

  private async loadPatterns(): Promise<void> {
    this.patterns = await this.memory.getAllProcedural();
  }

  private timeToSlot(hour: number): string {
    if (hour < 6) return "深夜";
    if (hour < 12) return "上午";
    if (hour < 18) return "下午";
    return "晚上";
  }

  // ============================================================
  // 构建 UI
  // ============================================================
  build() {
    Column() {
      // 顶部标题
      Row() {
        Text("📊 行为洞察").fontSize(20).fontWeight(FontWeight.Bold).fontColor("#FFFFFF")
      }
      .width("100%").height(48)
      .backgroundColor("#00695C")
      .justifyContent(FlexAlign.Center)

      // Tab 切换（横向滚动）
      Scroll() {
        Row() {
          ForEach(this.tabs, (tab: string, idx: number) => {
            Text(tab)
              .fontSize(13)
              .fontColor(this.activeTab === idx ? "#FFFFFF" : "#666666")
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.activeTab === idx ? "#00695C" : "#EEEEEE")
              .borderRadius(14)
              .margin({ left: 4, right: 4 })
              .onClick(() => { this.activeTab = idx; })
          })
        }.padding({ left: 8, right: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .height(40)

      Divider().height(0.5).color("#E0E0E0")

      // 内容区
      Scroll() {
        Column() {
          if (this.activeTab === 0) { this.sleepTab() }
          else if (this.activeTab === 1) { this.emotionTab() }
          else if (this.activeTab === 2) { this.relationTab() }
          else if (this.activeTab === 3) { this.locationTab() }
          else if (this.activeTab === 4) { this.typingTab() }
        }.width("100%").padding({ bottom: 20 })
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width("100%").height("100%")
    .backgroundColor("#FAFAFA")
  }

  // ============================================================
  // Tab 1: 作息曲线
  // ============================================================
  @Builder
  sleepTab() {
    Column() {
      Text("最近 14 天起床时间").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("根据每日首次活跃时间推断").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.sleepData.length === 0) {
        this.emptyState("数据不足，多用几天再来")
      } else {
        // 简易柱状图：用 Row + 高度比例
        Row() {
          ForEach(this.sleepData, (d: { day: string; wakeHour: number }) => {
            Column() {
              // 柱子（高度代表起床时间，越早起越短）
              Column()
                .width(20)
                .height(this.sleepBarHeight(d.wakeHour))
                .backgroundColor(this.sleepBarColor(d.wakeHour))
                .borderRadius({ topLeft: 4, topRight: 4 })
              Text(d.day).fontSize(9).fontColor("#999999").margin({ top: 4 })
              Text(`${Math.floor(d.wakeHour)}:${Math.round((d.wakeHour % 1) * 60).toString().padStart(2, "0")}`)
                .fontSize(9).fontColor("#666666")
            }
            .margin({ left: 4, right: 4 })
            .alignItems(HorizontalAlign.Center)
          })
        }
        .width("100%")
        .height(180)
        .padding({ left: 8, right: 8, top: 20 })
        .alignItems(VerticalAlign.Bottom)

        // 统计
        this.statRow("平均起床", this.avgSleepTime(this.sleepData))
        this.statRow("最早起床", this.earliestSleep(this.sleepData))
        this.statRow("最晚起床", this.latestSleep(this.sleepData))
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  // Tab 2: 情绪热力图
  // ============================================================
  @Builder
  emotionTab() {
    Column() {
      Text("情绪热力图（最近 30 天）").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("星期 × 时段的情绪分布").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.emotionHeatmap.length === 0) {
        this.emptyState("还没有情绪数据")
      } else {
        // 表头：时段
        Row() {
          Text("").width(50)
          ForEach(["深夜", "上午", "下午", "晚上"], (slot: string) => {
            Text(slot).fontSize(11).fontColor("#666666").layoutWeight(1).textAlign(TextAlign.Center)
          })
        }
        .width("100%").padding({ top: 12, bottom: 4 })

        // 7 行（周一到周日）
        ForEach([1, 2, 3, 4, 5, 6, 0], (wd: number) => {
          Row() {
            Text(["日", "一", "二", "三", "四", "五", "六"][wd])
              .fontSize(11).fontColor("#666666").width(50)
            ForEach([0, 4, 8, 12, 16, 20], (h: number) => {
              this.heatmapCell(wd, h)
            })
          }
          .width("100%").height(36)
        })
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  heatmapCell(weekday: number, hour: number) {
    let cell = this.emotionHeatmap.find(e => e.weekday === weekday && e.hour === hour);
    Column() {
      if (cell) {
        Text(cell.emotion.slice(0, 2))
          .fontSize(10)
          .fontColor("#FFFFFF")
      } else {
        Text("·").fontSize(10).fontColor("#CCCCCC")
      }
    }
    .layoutWeight(1)
    .height(32)
    .margin(2)
    .backgroundColor(cell ? this.emotionColor(cell.emotion) : "#F5F5F5")
    .borderRadius(4)
    .justifyContent(FlexAlign.Center)
  }

  // ============================================================
  // Tab 3: 关系图谱
  // ============================================================
  @Builder
  relationTab() {
    Column() {
      Text("社交关系网").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("按提及频率排列").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.relations.length === 0) {
        this.emptyState("还没有记录到社交关系")
      } else {
        // 简易关系图：中心是你，周围是关系人
        Column() {
          // 中心节点
          Text("你")
            .fontSize(16).fontColor("#FFFFFF")
            .width(60).height(60)
            .backgroundColor("#1677FF")
            .borderRadius(30)
            .textAlign(TextAlign.Center)
            .textAlignVertical(TextAlign.Center)
        }
        .width("100%")
        .padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center)

        // 关系列表
        ForEach(this.relations.slice(0, 20), (r: RelationRecord) => {
          Row() {
            Text(r.person_name.charAt(0))
              .fontSize(14).fontColor("#FFFFFF")
              .width(32).height(32)
              .backgroundColor(this.relationColor(r.relation_type))
              .borderRadius(16)
              .textAlign(TextAlign.Center)

            Column() {
              Text(r.person_name).fontSize(14).fontColor("#333333")
              Text(r.relation_type ?? "关系不明").fontSize(11).fontColor("#999999")
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 10 })

            // 提及次数条形
            Row() {
              ForEach(this.range(Math.min(5, r.mention_count ?? 0)), () => {
                Text("█").fontSize(10).fontColor("#1677FF")
              })
            }
            Text(`${r.mention_count}`).fontSize(11).fontColor("#999999").margin({ left: 4 })
          }
          .width("100%")
          .padding(10)
          .backgroundColor("#FFFFFF")
          .borderRadius(8)
          .margin({ top: 4 })
        }, (r: RelationRecord) => r.id?.toString() ?? r.person_name)
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  // Tab 4: 位置轨迹
  // ============================================================
  @Builder
  locationTab() {
    Column() {
      Text("高频位置（最近 30 天）").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("按时段统计位置分布").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.locationData.length === 0) {
        this.emptyState("还没有位置数据")
      } else {
        ForEach(this.locationData.slice(0, 10), (loc: { location: string; count: number; slots: Record<string, number> }) => {
          Column() {
            Row() {
              Text("📍").fontSize(16)
              Text(loc.location).fontSize(14).fontColor("#333333").layoutWeight(1).margin({ left: 6 })
              Text(`${loc.count} 次`).fontSize(12).fontColor("#999999")
            }.width("100%")

            // 时段分布条
            Row() {
              ForEach(["深夜", "上午", "下午", "晚上"], (slot: string) => {
                Column() {
                  Text(slot).fontSize(10).fontColor("#999999")
                  Text(`${loc.slots[slot] ?? 0}`).fontSize(11).fontColor("#1677FF")
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Center)
              })
            }
            .width("100%")
            .padding({ top: 8, bottom: 8 })
            .backgroundColor("#F5F5F5")
            .borderRadius(6)
            .margin({ top: 6 })
          }
          .width("100%")
          .padding(12)
          .backgroundColor("#FFFFFF")
          .borderRadius(8)
          .margin({ top: 6 })
          .alignItems(HorizontalAlign.Start)
        }, (loc: { location: string }) => loc.location)
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  // Tab 5: 打字模式
  // ============================================================
  @Builder
  typingTab() {
    Column() {
      Text("打字节奏（最近 14 天）").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("速度与删除率反映心理状态").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.typingData.length === 0) {
        this.emptyState("还没有打字数据")
      } else {
        // 速度趋势
        Text("打字速度（字/秒）").fontSize(13).fontColor("#666666").margin({ top: 12 })
        Row() {
          ForEach(this.typingData, (d: { date: string; speed: number; deleteRatio: number }) => {
            Column() {
              Column()
                .width(16)
                .height(Math.min(80, d.speed * 20))
                .backgroundColor("#4CAF50")
                .borderRadius({ topLeft: 4, topRight: 4 })
              Text(d.date).fontSize(8).fontColor("#999999").margin({ top: 2 })
            }
            .margin({ left: 3, right: 3 })
            .alignItems(HorizontalAlign.Center)
          })
        }
        .width("100%").height(110)
        .padding({ top: 12 })
        .alignItems(VerticalAlign.Bottom)

        // 删除率趋势
        Text("删除率").fontSize(13).fontColor("#666666").margin({ top: 16 })
        Row() {
          ForEach(this.typingData, (d: { date: string; speed: number; deleteRatio: number }) => {
            Column() {
              Column()
                .width(16)
                .height(Math.min(80, d.deleteRatio * 200))
                .backgroundColor(this.deleteRatioColor(d.deleteRatio))
                .borderRadius({ topLeft: 4, topRight: 4 })
              Text(d.date).fontSize(8).fontColor("#999999").margin({ top: 2 })
            }
            .margin({ left: 3, right: 3 })
            .alignItems(HorizontalAlign.Center)
          })
        }
        .width("100%").height(110)
        .padding({ top: 12 })
        .alignItems(VerticalAlign.Bottom)

        // 洞察
        if (this.typingData.length >= 3) {
          Column() {
            Text("💡 洞察").fontSize(13).fontWeight(FontWeight.Bold).fontColor("#333333")
            Text(this.typingInsight()).fontSize(12).fontColor("#666666").margin({ top: 4 })
          }
          .width("100%")
          .padding(12)
          .backgroundColor("#E3F2FD")
          .borderRadius(8)
          .margin({ top: 16 })
          .alignItems(HorizontalAlign.Start)
        }
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  // 辅助
  // ============================================================
  @Builder
  emptyState(text: string) {
    Column() {
      Text("📭").fontSize(48)
      Text(text).fontSize(13).fontColor("#999999").margin({ top: 12 })
    }
    .width("100%").padding({ top: 60, bottom: 60 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  statRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor("#666666")
      Blank()
      Text(value).fontSize(14).fontColor("#333333").fontWeight(FontWeight.Bold)
    }
    .width("100%")
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor("#FFFFFF")
    .borderRadius(6)
    .margin({ top: 6 })
  }

  // 作息辅助
  private sleepBarHeight(hour: number): number {
    // 5 点起 = 100，12 点起 = 30
    return Math.max(20, 130 - (hour - 5) * 12);
  }

  private sleepBarColor(hour: number): ResourceColor {
    if (hour < 7) return "#4CAF50";   // 早起绿
    if (hour < 9) return "#2196F3";   // 正常蓝
    if (hour < 11) return "#FF9800";  // 偏晚橙
    return "#F44336";                  // 太晚红
  }

  private avgSleepTime(data: Array<{ day: string; wakeHour: number }>): string {
    const avg = data.reduce((s, d) => s + d.wakeHour, 0) / data.length;
    return `${Math.floor(avg)}:${Math.round((avg % 1) * 60).toString().padStart(2, "0")}`;
  }

  private earliestSleep(data: Array<{ day: string; wakeHour: number }>): string {
    const min = Math.min(...data.map(d => d.wakeHour));
    return `${Math.floor(min)}:${Math.round((min % 1) * 60).toString().padStart(2, "0")}`;
  }

  private latestSleep(data: Array<{ day: string; wakeHour: number }>): string {
    const max = Math.max(...data.map(d => d.wakeHour));
    return `${Math.floor(max)}:${Math.round((max % 1) * 60).toString().padStart(2, "0")}`;
  }

  // 情绪颜色
  private emotionColor(emotion: string): ResourceColor {
    const positive = ["愉快", "开心", "兴奋", "平静", "满足"];
    const negative = ["焦虑", "疲惫", "低落", "烦躁", "难过"];
    if (positive.some(p => emotion.includes(p))) return "#4CAF50";
    if (negative.some(n => emotion.includes(n))) return "#F44336";
    return "#FF9800";
  }

  // 关系颜色
  private relationColor(type?: string): ResourceColor {
    switch (type) {
      case "family": return "#E91E63";
      case "lover": return "#F44336";
      case "friend": return "#4CAF50";
      case "colleague": return "#2196F3";
      default: return "#9E9E9E";
    }
  }

  // 打字辅助
  private deleteRatioColor(ratio: number): ResourceColor {
    if (ratio < 0.1) return "#4CAF50";
    if (ratio < 0.2) return "#FF9800";
    return "#F44336";
  }

  private typingInsight(): string {
    const avgSpeed = this.typingData.reduce((s, d) => s + d.speed, 0) / this.typingData.length;
    const avgRatio = this.typingData.reduce((s, d) => s + d.deleteRatio, 0) / this.typingData.length;
    if (avgRatio > 0.2) {
      return `平均删除率 ${(avgRatio * 100).toFixed(0)}%，偏高。可能你在表达时较为犹豫，或近期压力较大。`;
    }
    return `平均打字速度 ${avgSpeed.toFixed(1)} 字/秒，状态稳定。`;
  }

  private range(n: number): number[] {
    return Array.from({ length: n }, (_, i) => i);
  }
}
