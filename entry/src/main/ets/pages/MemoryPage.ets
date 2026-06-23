/**
 * MemoryPage.ets
 * ---------------
 * 记忆可视化页面
 */

import { MemoryService, SemanticRecord, EpisodicRecord, ProceduralRecord, RelationRecord } from "../services/MemoryService";
import { PredictionService, PredictionAccuracyResult } from "../services/PredictionService";
import router from "@ohos.router";

interface PredictionStats {
  total: number;
  accuracy: number;
  avgError: number;
}

@Entry
@Component
struct MemoryPage {
  @State activeTab: number = 0;
  @State profileList: SemanticRecord[] = [];
  @State episodeList: EpisodicRecord[] = [];
  @State relationList: RelationRecord[] = [];
  @State patternList: ProceduralRecord[] = [];
  @State predictionStats: PredictionAccuracyResult = { total: 0, verified: 0, accuracy: 0, avgError: 0 };
  @State stats: Record<string, number> = {};

  private memory: MemoryService = new MemoryService();
  private predictionService: PredictionService = new PredictionService(this.memory);

  aboutToAppear(): void {
    this.memory.init(getContext(this)).then(() => {
      this.loadAll();
    });
  }

  private async loadAll(): Promise<void> {
    this.profileList = await this.memory.getSemanticByCategory("profile");
    const preferences = await this.memory.getSemanticByCategory("preference");
    const values = await this.memory.getSemanticByCategory("value");
    const facts = await this.memory.getSemanticByCategory("fact");
    const allProfile: SemanticRecord[] = [];
    for (let i = 0; i < this.profileList.length; i++) allProfile.push(this.profileList[i]);
    for (let i = 0; i < preferences.length; i++) allProfile.push(preferences[i]);
    for (let i = 0; i < values.length; i++) allProfile.push(values[i]);
    for (let i = 0; i < facts.length; i++) allProfile.push(facts[i]);
    this.profileList = allProfile;

    this.episodeList = await this.memory.getTopEpisodic(50);
    this.relationList = await this.memory.getAllRelations();
    this.patternList = await this.memory.getAllProcedural();
    this.predictionStats = await this.predictionService.getAccuracy();
    this.stats = await this.memory.getStats();
  }

  build() {
    Column() {
      Row() {
        Text("数字孪生记忆").fontSize(20).fontWeight(FontWeight.Bold).fontColor("#FFFFFF")
        Blank()
        Text("📊").fontSize(20)
          .onClick(() => {
            router.pushUrl({ url: "pages/InsightsPage" });
          })
      }
      .width("100%").height(48)
      .backgroundColor("#1677FF")
      .padding({ left: 16, right: 16 })

      Row() {
        this.statCard("画像", this.stats["semantic_memory"] ?? 0)
        this.statCard("事件", this.stats["episodic_memory"] ?? 0)
        this.statCard("关系", this.stats["relation_network"] ?? 0)
        this.statCard("规律", this.stats["procedural_memory"] ?? 0)
        this.statCard("预测", this.stats["prediction_memory"] ?? 0)
      }
      .width("100%")
      .padding({ left: 8, right: 8, top: 8, bottom: 8 })
      .backgroundColor("#F5F5F5")

      Row() {
        ForEach(["画像", "事件", "关系", "规律", "预测"], (tab: string, idx: number) => {
          Text(tab)
            .fontSize(14)
            .fontColor(this.activeTab === idx ? "#FFFFFF" : "#666666")
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.activeTab === idx ? "#1677FF" : "#EEEEEE")
            .borderRadius(16)
            .margin({ left: 4, right: 4 })
            .onClick(() => { this.activeTab = idx; })
        })
      }
      .width("100%")
      .padding({ top: 8, bottom: 8 })
      .justifyContent(FlexAlign.Center)

      Divider().height(0.5).color("#E0E0E0")

      Scroll() {
        Column() {
          if (this.activeTab === 0) { this.profileTab() }
          else if (this.activeTab === 1) { this.episodeTab() }
          else if (this.activeTab === 2) { this.relationTab() }
          else if (this.activeTab === 3) { this.patternTab() }
          else if (this.activeTab === 4) { this.predictionTab() }
        }.width("100%").padding({ bottom: 20 })
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width("100%").height("100%")
    .backgroundColor("#FAFAFA")
  }

  @Builder
  statCard(label: string, count: number) {
    Column() {
      Text(count.toString()).fontSize(18).fontWeight(FontWeight.Bold).fontColor("#1677FF")
      Text(label).fontSize(11).fontColor("#999999").margin({ top: 2 })
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .backgroundColor("#FFFFFF")
    .borderRadius(8)
    .margin({ left: 2, right: 2 })
  }

  @Builder
  profileTab() {
    if (this.profileList.length === 0) {
      this.emptyState("还没有画像信息，多和知心聊聊吧")
    } else {
      ForEach(this.profileList, (p: SemanticRecord) => {
        Row() {
          Column() {
            Text(p.key).fontSize(13).fontColor("#999999")
            Text(p.value).fontSize(15).fontColor("#333333").margin({ top: 4 })
            Row() {
              Text(`置信度 ${(p.confidence * 100).toFixed(0)}%`)
                .fontSize(11).fontColor(this.confidenceColor(p.confidence))
              Text(`· 证据 ${p.evidence_count} 次`).fontSize(11).fontColor("#AAAAAA").margin({ left: 8 })
              Text(`· ${p.source || "chat"}`).fontSize(11).fontColor("#AAAAAA").margin({ left: 8 })
            }.margin({ top: 4 })
          }
          .layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text(p.category).fontSize(11).fontColor("#1677FF")
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor("#E3F2FD").borderRadius(8)
        }
        .width("100%")
        .padding(12)
        .backgroundColor("#FFFFFF")
        .borderRadius(8)
        .margin({ left: 12, right: 12, top: 6 })
      }, (p: SemanticRecord) => p.id.toString())
    }
  }

  @Builder
  episodeTab() {
    if (this.episodeList.length === 0) {
      this.emptyState("还没有值得记住的事件")
    } else {
      ForEach(this.episodeList, (e: EpisodicRecord) => {
        Column() {
          Row() {
            Text(e.title).fontSize(15).fontWeight(FontWeight.Bold).fontColor("#333333").layoutWeight(1)
            Text(`★ ${(e.importance * 100).toFixed(0)}%`)
              .fontSize(11).fontColor(this.confidenceColor(e.importance))
          }.width("100%")

          if (e.description) {
            Text(e.description).fontSize(13).fontColor("#666666").margin({ top: 4 })
          }

          Row() {
            Text(`📅 ${new Date(e.event_time).toLocaleString()}`)
              .fontSize(11).fontColor("#999999")
            if (e.emotion) {
              Text(`· ${e.emotion}`).fontSize(11).fontColor("#999999").margin({ left: 8 })
            }
            if (e.location) {
              Text(`· 📍 ${e.location}`).fontSize(11).fontColor("#999999").margin({ left: 8 })
            }
          }.margin({ top: 4 })

          if (e.outcome) {
            Text(`结果：${e.outcome}`).fontSize(12).fontColor("#4CAF50").margin({ top: 4 })
          }
        }
        .width("100%")
        .padding(12)
        .backgroundColor("#FFFFFF")
        .borderRadius(8)
        .margin({ left: 12, right: 12, top: 6 })
        .alignItems(HorizontalAlign.Start)
      }, (e: EpisodicRecord) => e.id.toString())
    }
  }

  @Builder
  relationTab() {
    if (this.relationList.length === 0) {
      this.emptyState("还没有记录到社交关系")
    } else {
      ForEach(this.relationList, (r: RelationRecord) => {
        Row() {
          Text(r.person_name.charAt(0))
            .fontSize(18).fontColor("#FFFFFF")
            .width(40).height(40)
            .backgroundColor(this.relationColor(r.relation_type))
            .borderRadius(20)
            .textAlign(TextAlign.Center)

          Column() {
            Text(r.person_name).fontSize(15).fontColor("#333333")
            Row() {
              Text(r.relation_type || "关系不明")
                .fontSize(11).fontColor("#1677FF")
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor("#E3F2FD").borderRadius(4)
              Text(`· 提及 ${r.mention_count} 次`).fontSize(11).fontColor("#999999").margin({ left: 8 })
            }.margin({ top: 4 })
          }
          .layoutWeight(1).alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })

          if (r.sentiment !== 0) {
            Text(r.sentiment > 0 ? "❤️" : "💔").fontSize(16)
          }
        }
        .width("100%")
        .padding(12)
        .backgroundColor("#FFFFFF")
        .borderRadius(8)
        .margin({ left: 12, right: 12, top: 6 })
      }, (r: RelationRecord) => r.id.toString())
    }
  }

  @Builder
  patternTab() {
    if (this.patternList.length === 0) {
      this.emptyState("还没有发现行为规律，多用几天看看")
    } else {
      ForEach(this.patternList, (p: ProceduralRecord) => {
        Column() {
          Row() {
            Text(this.patternTypeIcon(p.pattern_type)).fontSize(16)
            Text(p.description).fontSize(14).fontColor("#333333").layoutWeight(1).margin({ left: 6 })
            Text(`${(p.confidence * 100).toFixed(0)}%`)
              .fontSize(11).fontColor(this.confidenceColor(p.confidence))
          }.width("100%")

          Row() {
            Text(p.pattern_type).fontSize(11).fontColor("#666666")
            if (p.frequency) {
              Text(`· ${p.frequency}`).fontSize(11).fontColor("#666666").margin({ left: 8 })
            }
            Text(`· 触发 ${p.trigger_count} 次`).fontSize(11).fontColor("#666666").margin({ left: 8 })
          }.margin({ top: 4 })

          if (p.last_triggered) {
            Text(`上次触发：${new Date(p.last_triggered).toLocaleString()}`)
              .fontSize(11).fontColor("#AAAAAA").margin({ top: 2 })
          }
        }
        .width("100%")
        .padding(12)
        .backgroundColor("#FFFFFF")
        .borderRadius(8)
        .margin({ left: 12, right: 12, top: 6 })
        .alignItems(HorizontalAlign.Start)
      }, (p: ProceduralRecord) => p.id.toString())
    }
  }

  @Builder
  predictionTab() {
    Column() {
      Column() {
        Text("预测准确率").fontSize(14).fontColor("#666666")
        Text(`${(this.predictionStats.accuracy * 100).toFixed(0)}%`)
          .fontSize(48).fontWeight(FontWeight.Bold)
          .fontColor(this.confidenceColor(this.predictionStats.accuracy))
          .margin({ top: 8 })
        Text(`基于 ${this.predictionStats.total} 次验证`)
          .fontSize(12).fontColor("#999999").margin({ top: 4 })
        Text(`平均误差：${(this.predictionStats.avgError * 100).toFixed(0)}%`)
          .fontSize(12).fontColor("#999999").margin({ top: 2 })
      }
      .width("100%")
      .padding({ top: 24, bottom: 24 })
      .backgroundColor("#FFFFFF")
      .borderRadius(12)
      .margin({ left: 12, right: 12, top: 12 })
      .alignItems(HorizontalAlign.Center)

      Column() {
        Text("预测校准机制").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#333333")
        Text("每次预测后，系统会在目标时间到达时自动对比你的实际行为，计算误差并校准后续预测。预测越多，系统越了解你。")
          .fontSize(12).fontColor("#666666").margin({ top: 8 })
      }
      .width("100%")
      .padding(12)
      .backgroundColor("#FFFFFF")
      .borderRadius(8)
      .margin({ left: 12, right: 12, top: 12 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  emptyState(text: string) {
    Column() {
      Text("📭").fontSize(48)
      Text(text).fontSize(13).fontColor("#999999").margin({ top: 12 })
    }
    .width("100%")
    .padding({ top: 60, bottom: 60 })
    .alignItems(HorizontalAlign.Center)
  }

  private confidenceColor(conf: number): ResourceColor {
    if (conf >= 0.7) return "#4CAF50";
    if (conf >= 0.4) return "#FF9800";
    return "#F44336";
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

  private patternTypeIcon(type: string): string {
    switch (type) {
      case "routine": return "⏰";
      case "habit": return "🔄";
      case "trigger": return "⚡";
      case "rhythm": return "📊";
      default: return "📌";
    }
  }
}
