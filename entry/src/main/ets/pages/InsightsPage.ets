/**
 * InsightsPage.ets
 * ----------------
 * 行为模式可视化页面
 */

import { MemoryService, BehaviorLog, RelationRecord, ProceduralRecord } from "../services/MemoryService";

interface SleepDataItem {
  day: string;
  wakeHour: number;
}

interface EmotionHeatmapItem {
  weekday: number;
  hour: number;
  emotion: string;
  count: number;
}

interface LocationDataItem {
  location: string;
  count: number;
  slots: Record<string, number>;
}

interface TypingDataItem {
  date: string;
  speed: number;
  deleteRatio: number;
}

interface TypingDayData {
  speeds: number[];
  deleteRatios: number[];
}

@Entry
@Component
struct InsightsPage {
  @State activeTab: number = 0;
  @State sleepData: SleepDataItem[] = [];
  @State emotionHeatmap: EmotionHeatmapItem[] = [];
  @State relations: RelationRecord[] = [];
  @State locationData: LocationDataItem[] = [];
  @State typingData: TypingDataItem[] = [];
  @State patterns: ProceduralRecord[] = [];

  private memory: MemoryService = new MemoryService();
  private tabs: string[] = ["作息曲线", "情绪热力图", "关系图谱", "位置轨迹", "打字模式"];

  aboutToAppear(): void {
    this.memory.init(getContext(this)).then(() => {
      this.loadAll();
    });
  }

  private async loadAll(): Promise<void> {
    await this.loadSleepData();
    await this.loadEmotionHeatmap();
    await this.loadRelations();
    await this.loadLocationData();
    await this.loadTypingData();
    await this.loadPatterns();
  }

  private async loadSleepData(): Promise<void> {
    const now = Date.now();
    const since = now - 14 * 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now);

    const byDay: Map<string, number> = new Map();
    for (let i = 0; i < logs.length; i++) {
      const log = logs[i];
      const day = new Date(log.timestamp).toISOString().slice(0, 10);
      const existing = byDay.get(day);
      if (existing === undefined || log.timestamp < existing) {
        byDay.set(day, log.timestamp);
      }
    }

    const data: SleepDataItem[] = [];
    const entries = Array.from(byDay.entries());
    for (let i = 0; i < entries.length; i++) {
      const day = entries[i][0];
      const ts = entries[i][1];
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

    const map: Map<string, EmotionHeatmapItem> = new Map();
    for (let i = 0; i < logs.length; i++) {
      try {
        const data = JSON.parse(logs[i].data) as Record<string, string>;
        if (!data.emotion) continue;
        const d = new Date(logs[i].timestamp);
        const wd = d.getDay();
        const h = Math.floor(d.getHours() / 4) * 4;
        const key = `${wd}_${h}`;
        if (!map.has(key)) {
          map.set(key, { weekday: wd, hour: h, emotion: data.emotion, count: 0 });
        }
        const item = map.get(key)!;
        item.count++;
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

    const byLoc: Map<string, LocationDataItem> = new Map();
    for (let i = 0; i < logs.length; i++) {
      const log = logs[i];
      if (!log.location) continue;
      if (!byLoc.has(log.location)) {
        byLoc.set(log.location, { location: log.location, count: 0, slots: {} });
      }
      const entry = byLoc.get(log.location)!;
      entry.count++;
      const slot = this.timeToSlot(new Date(log.timestamp).getHours());
      const prev = entry.slots[slot] ?? 0;
      entry.slots[slot] = prev + 1;
    }

    const items = Array.from(byLoc.values());
    items.sort((a, b) => b.count - a.count);
    this.locationData = items;
  }

  private async loadTypingData(): Promise<void> {
    const now = Date.now();
    const since = now - 14 * 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now, "typing_pattern");

    const byDate: Map<string, TypingDayData> = new Map();
    for (let i = 0; i < logs.length; i++) {
      try {
        const data = JSON.parse(logs[i].data) as Record<string, number>;
        const day = new Date(logs[i].timestamp).toISOString().slice(0, 10);
        if (!byDate.has(day)) byDate.set(day, { speeds: [], deleteRatios: [] });
        const entry = byDate.get(day)!;
        if (data.typing_speed !== undefined) entry.speeds.push(data.typing_speed);
        if (data.delete_ratio !== undefined) entry.deleteRatios.push(data.delete_ratio);
      } catch { /* 忽略 */ }
    }

    const items: TypingDataItem[] = [];
    const dateEntries = Array.from(byDate.entries());
    for (let i = 0; i < dateEntries.length; i++) {
      const date = dateEntries[i][0];
      const v = dateEntries[i][1];
      let speedSum = 0;
      for (let j = 0; j < v.speeds.length; j++) {
        speedSum += v.speeds[j];
      }
      let deleteSum = 0;
      for (let j = 0; j < v.deleteRatios.length; j++) {
        deleteSum += v.deleteRatios[j];
      }
      items.push({
        date: date.slice(5),
        speed: speedSum / Math.max(1, v.speeds.length),
        deleteRatio: deleteSum / Math.max(1, v.deleteRatios.length),
      });
    }
    items.sort((a, b) => a.date.localeCompare(b.date));
    this.typingData = items;
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

  build() {
    Column() {
      Row() {
        Text("📊 行为洞察").fontSize(20).fontWeight(FontWeight.Bold).fontColor("#FFFFFF")
      }
      .width("100%").height(48)
      .backgroundColor("#00695C")
      .justifyContent(FlexAlign.Center)

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

  @Builder
  sleepTab() {
    Column() {
      Text("最近 14 天起床时间").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("根据每日首次活跃时间推断").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.sleepData.length === 0) {
        this.emptyState("数据不足，多用几天再来")
      } else {
        Row() {
          ForEach(this.sleepData, (d: SleepDataItem) => {
            Column() {
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

        this.statRow("平均起床", this.avgSleepTime(this.sleepData))
        this.statRow("最早起床", this.earliestSleep(this.sleepData))
        this.statRow("最晚起床", this.latestSleep(this.sleepData))
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  emotionTab() {
    Column() {
      Text("情绪热力图（最近 30 天）").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("星期 × 时段的情绪分布").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.emotionHeatmap.length === 0) {
        this.emptyState("还没有情绪数据")
      } else {
        Row() {
          Text("").width(50)
          ForEach(["深夜", "上午", "下午", "晚上"], (slot: string) => {
            Text(slot).fontSize(11).fontColor("#666666").layoutWeight(1).textAlign(TextAlign.Center)
          })
        }
        .width("100%").padding({ top: 12, bottom: 4 })

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
    Column() {
      if (this.hasHeatmapCell(weekday, hour)) {
        Text(this.getHeatmapEmotion(weekday, hour).slice(0, 2))
          .fontSize(10)
          .fontColor("#FFFFFF")
      } else {
        Text("·").fontSize(10).fontColor("#CCCCCC")
      }
    }
    .layoutWeight(1)
    .height(32)
    .margin(2)
    .backgroundColor(this.hasHeatmapCell(weekday, hour) ? this.emotionColor(this.getHeatmapEmotion(weekday, hour)) : "#F5F5F5")
    .borderRadius(4)
    .justifyContent(FlexAlign.Center)
  }

  private hasHeatmapCell(weekday: number, hour: number): boolean {
    for (let i = 0; i < this.emotionHeatmap.length; i++) {
      if (this.emotionHeatmap[i].weekday === weekday && this.emotionHeatmap[i].hour === hour) {
        return true;
      }
    }
    return false;
  }

  private getHeatmapEmotion(weekday: number, hour: number): string {
    for (let i = 0; i < this.emotionHeatmap.length; i++) {
      if (this.emotionHeatmap[i].weekday === weekday && this.emotionHeatmap[i].hour === hour) {
        return this.emotionHeatmap[i].emotion;
      }
    }
    return "";
  }

  @Builder
  relationTab() {
    Column() {
      Text("社交关系网").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("按提及频率排列").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.relations.length === 0) {
        this.emptyState("还没有记录到社交关系")
      } else {
        Column() {
          Text("你")
            .fontSize(16).fontColor("#FFFFFF")
            .width(60).height(60)
            .backgroundColor("#1677FF")
            .borderRadius(30)
            .textAlign(TextAlign.Center)
        }
        .width("100%")
        .padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center)

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
              Text(r.relation_type || "关系不明").fontSize(11).fontColor("#999999")
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 10 })

            Row() {
              ForEach(this.range(Math.min(5, r.mention_count || 0)), () => {
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
        }, (r: RelationRecord) => r.id.toString())
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  locationTab() {
    Column() {
      Text("高频位置（最近 30 天）").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("按时段统计位置分布").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.locationData.length === 0) {
        this.emptyState("还没有位置数据")
      } else {
        ForEach(this.locationData.slice(0, 10), (loc: LocationDataItem) => {
          Column() {
            Row() {
              Text("📍").fontSize(16)
              Text(loc.location).fontSize(14).fontColor("#333333").layoutWeight(1).margin({ left: 6 })
              Text(`${loc.count} 次`).fontSize(12).fontColor("#999999")
            }.width("100%")

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
        }, (loc: LocationDataItem) => loc.location)
      }
    }
    .width("100%").padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  typingTab() {
    Column() {
      Text("打字节奏（最近 14 天）").fontSize(16).fontWeight(FontWeight.Bold).fontColor("#333333")
      Text("速度与删除率反映心理状态").fontSize(12).fontColor("#999999").margin({ top: 4 })

      if (this.typingData.length === 0) {
        this.emptyState("还没有打字数据")
      } else {
        Text("打字速度（字/秒）").fontSize(13).fontColor("#666666").margin({ top: 12 })
        Row() {
          ForEach(this.typingData, (d: TypingDataItem) => {
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

        Text("删除率").fontSize(13).fontColor("#666666").margin({ top: 16 })
        Row() {
          ForEach(this.typingData, (d: TypingDataItem) => {
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

  private sleepBarHeight(hour: number): number {
    return Math.max(20, 130 - (hour - 5) * 12);
  }

  private sleepBarColor(hour: number): ResourceColor {
    if (hour < 7) return "#4CAF50";
    if (hour < 9) return "#2196F3";
    if (hour < 11) return "#FF9800";
    return "#F44336";
  }

  private avgSleepTime(data: SleepDataItem[]): string {
    let sum = 0;
    for (let i = 0; i < data.length; i++) {
      sum += data[i].wakeHour;
    }
    const avg = sum / data.length;
    return `${Math.floor(avg)}:${Math.round((avg % 1) * 60).toString().padStart(2, "0")}`;
  }

  private earliestSleep(data: SleepDataItem[]): string {
    let min = data[0].wakeHour;
    for (let i = 1; i < data.length; i++) {
      if (data[i].wakeHour < min) min = data[i].wakeHour;
    }
    return `${Math.floor(min)}:${Math.round((min % 1) * 60).toString().padStart(2, "0")}`;
  }

  private latestSleep(data: SleepDataItem[]): string {
    let max = data[0].wakeHour;
    for (let i = 1; i < data.length; i++) {
      if (data[i].wakeHour > max) max = data[i].wakeHour;
    }
    return `${Math.floor(max)}:${Math.round((max % 1) * 60).toString().padStart(2, "0")}`;
  }

  private emotionColor(emotion: string): ResourceColor {
    const positive = ["愉快", "开心", "兴奋", "平静", "满足"];
    const negative = ["焦虑", "疲惫", "低落", "烦躁", "难过"];
    for (let i = 0; i < positive.length; i++) {
      if (emotion.includes(positive[i])) return "#4CAF50";
    }
    for (let i = 0; i < negative.length; i++) {
      if (emotion.includes(negative[i])) return "#F44336";
    }
    return "#FF9800";
  }

  private relationColor(type: string): ResourceColor {
    switch (type) {
      case "family": return "#E91E63";
      case "lover": return "#F44336";
      case "friend": return "#4CAF50";
      case "colleague": return "#2196F3";
      default: return "#9E9E9E";
    }
  }

  private deleteRatioColor(ratio: number): ResourceColor {
    if (ratio < 0.1) return "#4CAF50";
    if (ratio < 0.2) return "#FF9800";
    return "#F44336";
  }

  private typingInsight(): string {
    let speedSum = 0;
    let ratioSum = 0;
    for (let i = 0; i < this.typingData.length; i++) {
      speedSum += this.typingData[i].speed;
      ratioSum += this.typingData[i].deleteRatio;
    }
    const avgSpeed = speedSum / this.typingData.length;
    const avgRatio = ratioSum / this.typingData.length;
    if (avgRatio > 0.2) {
      return `平均删除率 ${(avgRatio * 100).toFixed(0)}%，偏高。可能你在表达时较为犹豫，或近期压力较大。`;
    }
    return `平均打字速度 ${avgSpeed.toFixed(1)} 字/秒，状态稳定。`;
  }

  private range(n: number): number[] {
    const result: number[] = [];
    for (let i = 0; i < n; i++) {
      result.push(i);
    }
    return result;
  }
}
