/**
 * DecisionPage.ets
 * ----------------
 * 决策辅助页面
 */

import { assistDecision, DecisionResult } from "../services/ApiService";
import { MemoryService } from "../services/MemoryService";
import { NetworkMonitor } from "../services/NetworkMonitor";
import { AppColors, AppRadius } from "../theme/Theme";
import { TabBar } from "../components/TabBar";

interface RelevantEpisode {
  title: string;
  description: string;
  time: string;
  outcome: string;
}

interface DecisionLogData {
  question: string;
  options: number;
  recommendation: string;
}

interface SimilarDecision {
  question: string;
  choice: string;
  outcome: string;
}

@Entry
@Component
struct DecisionPage {
  @State question: string = "";
  @State options: string[] = [];
  @State optionInput: string = "";
  @State loading: boolean = false;
  @State result: DecisionResult | null = null;
  @State errorMsg: string = "";
  @State isOnline: boolean = true;

  private memory: MemoryService = new MemoryService();
  private netMonitor: NetworkMonitor = NetworkMonitor.getInstance();

  aboutToAppear(): void {
    this.memory.init(getContext(this));
    this.netMonitor.start();
    this.isOnline = this.netMonitor.isOnline();
  }

  aboutToDisappear(): void {
    this.netMonitor.stop();
  }

  build() {
    Column() {
      Row() {
        Text("帮我决策").fontSize(18).fontWeight(FontWeight.Bold).fontColor("#FFFFFF")
      }
      .width("100%").height(48)
      .backgroundColor(AppColors.HEADER_BG)
      .justifyContent(FlexAlign.Center)

      if (!this.isOnline) {
        Row() {
          Text("⚠ 离线状态，决策功能需要联网").fontSize(12).fontColor(AppColors.BG_CARD)
        }
        .width("100%").height(24)
        .backgroundColor(AppColors.HEADER_BG_OUT)
        .justifyContent(FlexAlign.Center)
      }

      Scroll() {
        Column() {
          this.inputSection()

          if (this.result) {
            this.resultSection()
          }

          if (this.errorMsg) {
            Text(this.errorMsg).fontSize(13).fontColor("#F44336")
              .padding(12).backgroundColor("#FFEBEE").borderRadius(AppRadius.SM)
              .margin({ left: 12, right: 12, top: 12 })
          }
        }.width("100%").padding({ bottom: 20 })
      }
      .layoutWeight(1).scrollBar(BarState.Off)

      TabBar({ activeIndex: 2 })
    }
    .width("100%").height("100%")
    .backgroundColor(AppColors.BG_PAGE)
  }

  @Builder
  inputSection() {
    Column() {
      Text("决策问题").fontSize(14).fontWeight(FontWeight.Bold).fontColor(AppColors.TEXT_PRIMARY)
      TextArea({ placeholder: "例如：要不要跳槽去新公司？", text: this.question })
        .fontSize(14)
        .height(80)
        .backgroundColor(AppColors.BG_CARD)
        .borderRadius(AppRadius.SM)
        .padding(8)
        .margin({ top: 6 })
        .onChange((v: string) => { this.question = v; })

      Text("可选方案（可选）").fontSize(14).fontWeight(FontWeight.Bold).fontColor(AppColors.TEXT_PRIMARY).margin({ top: 16 })
      ForEach(this.options, (opt: string, idx: number) => {
        Row() {
          Text(`${idx + 1}. ${opt}`).fontSize(13).fontColor(AppColors.TEXT_PRIMARY).layoutWeight(1)
          Text("✕").fontSize(14).fontColor("#F44336")
            .onClick(() => {
              const newOptions: string[] = [];
              for (let i = 0; i < this.options.length; i++) {
                if (i !== idx) {
                  newOptions.push(this.options[i]);
                }
              }
              this.options = newOptions;
            })
        }
        .width("100%")
        .padding(8)
        .backgroundColor(AppColors.BG_CARD)
        .borderRadius(6)
        .margin({ top: 4 })
      }, (opt: string, idx: number) => `${idx}_${opt}`)

      Row() {
        TextInput({ placeholder: "添加一个方案", text: this.optionInput })
          .layoutWeight(1).height(36)
          .backgroundColor(AppColors.BG_CARD).borderRadius(6)
          .onChange((v: string) => { this.optionInput = v; })
          .onSubmit(() => { this.addOption(); })
        Button("+ 添加").fontSize(13).height(36)
          .backgroundColor(AppColors.PRIMARY).fontColor(Color.White)
          .margin({ left: 8 })
          .enabled(this.optionInput.trim().length > 0)
          .onClick(() => { this.addOption(); })
      }
      .width("100%").margin({ top: 6 })

      Button(this.loading ? "分析中..." : "🔮 让知心帮我分析")
        .width("100%").height(48)
        .backgroundColor(AppColors.PRIMARY).fontColor(Color.White)
        .borderRadius(AppRadius.SM)
        .margin({ top: 20 })
        .enabled(this.question.trim().length > 0 && !this.loading && this.isOnline)
        .onClick(() => { this.analyze(); })
    }
    .width("100%")
    .padding(12)
    .backgroundColor(AppColors.BG_CARD)
    .borderRadius(AppRadius.MD)
    .margin({ left: 12, right: 12, top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  resultSection() {
    if (this.result) {
      Column() {
        this.resultCard("📊 综合分析", this.result.analysis, "#E3F2FD", "#1565C0")

        Column() {
          Text("✅ 知心推荐").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#2E7D32")
          Text(this.result.recommendation.option)
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor("#1B5E20")
            .margin({ top: 6 })
          Text(this.result.recommendation.reason)
            .fontSize(13).fontColor(AppColors.TEXT_PRIMARY).margin({ top: 6 })
          Row() {
            Text("置信度").fontSize(11).fontColor(AppColors.TEXT_TERTIARY)
            Text(`${(this.result.recommendation.confidence * 100).toFixed(0)}%`)
              .fontSize(11).fontColor(this.confidenceColor(this.result.recommendation.confidence))
              .margin({ left: 4 })
          }.margin({ top: 4 })
        }
        .width("100%")
        .padding(12)
        .backgroundColor("#E8F5E9")
        .borderRadius(AppRadius.SM)
        .margin({ top: 8 })
        .alignItems(HorizontalAlign.Start)

        if (this.result.risks && this.result.risks.length > 0) {
          Column() {
            Text("⚠️ 潜在风险").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#C62828")
            ForEach(this.result.risks, (risk: string) => {
              Text(`• ${risk}`).fontSize(13).fontColor(AppColors.TEXT_PRIMARY).margin({ top: 4 })
            }, (risk: string, idx: number) => `${idx}_${risk}`)
          }
          .width("100%")
          .padding(12)
          .backgroundColor("#FFEBEE")
          .borderRadius(AppRadius.SM)
          .margin({ top: 8 })
          .alignItems(HorizontalAlign.Start)
        }

        if (this.result.alternatives && this.result.alternatives.length > 0) {
          Column() {
            Text("💡 备选方案").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#F57F17")
            ForEach(this.result.alternatives, (alt: string) => {
              Text(`• ${alt}`).fontSize(13).fontColor(AppColors.TEXT_PRIMARY).margin({ top: 4 })
            }, (alt: string, idx: number) => `${idx}_${alt}`)
          }
          .width("100%")
          .padding(12)
          .backgroundColor("#FFF8E1")
          .borderRadius(AppRadius.SM)
          .margin({ top: 8 })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width("100%")
      .padding(12)
      .backgroundColor(AppColors.BG_CARD)
      .borderRadius(AppRadius.MD)
      .margin({ left: 12, right: 12, top: 12 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  resultCard(title: string, content: string, bgColor: string, titleColor: string) {
    Column() {
      Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(titleColor)
      Text(content).fontSize(13).fontColor(AppColors.TEXT_PRIMARY).margin({ top: 6 })
    }
    .width("100%")
    .padding(12)
    .backgroundColor(bgColor)
    .borderRadius(AppRadius.SM)
    .margin({ top: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  private addOption(): void {
    const opt = this.optionInput.trim();
    if (!opt) return;
    const newOptions: string[] = [];
    for (let i = 0; i < this.options.length; i++) {
      newOptions.push(this.options[i]);
    }
    newOptions.push(opt);
    this.options = newOptions;
    this.optionInput = "";
  }

  private async analyze(): Promise<void> {
    this.loading = true;
    this.errorMsg = "";
    this.result = null;

    try {
      const userProfile = await this.memory.getFullProfile();
      const episodes = await this.memory.getTopEpisodic(10);
      const relevantEpisodes: RelevantEpisode[] = [];
      for (let i = 0; i < episodes.length; i++) {
        relevantEpisodes.push({
          title: episodes[i].title,
          description: episodes[i].description || "",
          time: new Date(episodes[i].event_time).toLocaleString(),
          outcome: episodes[i].outcome || "",
        });
      }

      const similar = await this.memory.searchEpisodic("决策");
      const similarDecisions: SimilarDecision[] = [];
      for (let i = 0; i < similar.length && i < 5; i++) {
        const choice = similar[i].description ? similar[i].description : "";
        const outcome = similar[i].outcome ? similar[i].outcome : "未知";
        similarDecisions.push({
          question: similar[i].title,
          choice: choice,
          outcome: outcome,
        });
      }

      const result = await assistDecision({
        decision_question: this.question,
        options: this.options,
        user_profile: userProfile,
        relevant_episodes: relevantEpisodes,
        similar_decisions: similarDecisions,
      });

      this.result = result;

      await this.memory.addEpisodic({
        event_time: Date.now(),
        title: `决策：${this.question.slice(0, 20)}`,
        description: `问题：${this.question}\n推荐：${result.recommendation.option}`,
        importance: 0.8,
        outcome: result.recommendation.option,
      });

      const decisionData: DecisionLogData = {
        question: this.question,
        options: this.options.length,
        recommendation: result.recommendation.option,
      };
      await this.memory.logBehavior("decision", decisionData);

    } catch (err) {
      this.errorMsg = `分析失败：${(err as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  private confidenceColor(conf: number): ResourceColor {
    if (conf >= 0.7) return "#4CAF50";
    if (conf >= 0.4) return "#FF9800";
    return "#F44336";
  }
}
