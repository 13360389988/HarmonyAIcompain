/**
 * DecisionPage.ets
 * ----------------
 * 决策辅助页面 — 让数字孪生帮你做重大决策。
 *
 * 流程：
 *   1. 输入决策问题
 *   2. 添加可选方案（可选）
 *   3. 系统打包你的画像 + 相关历史 + 类似决策
 *   4. 调用后端 /decision 接口
 *   5. 展示：分析 + 推荐 + 风险 + 备选方案
 */

import { assistDecision, DecisionResult } from "../services/ApiService";
import { MemoryService, EpisodicRecord } from "../services/MemoryService";
import { NetworkMonitor } from "../services/NetworkMonitor";

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
      // 顶部标题
      Row() {
        Text("🤔 帮我决策").fontSize(20).fontWeight(FontWeight.Bold).fontColor("#FFFFFF")
      }
      .width("100%").height(48)
      .backgroundColor("#6A1B9A")
      .justifyContent(FlexAlign.Center)

      if (!this.isOnline) {
        Row() {
          Text("⚠ 离线状态，决策功能需要联网").fontSize(12).fontColor("#FFFFFF")
        }
        .width("100%").height(24)
        .backgroundColor("#E65100")
        .justifyContent(FlexAlign.Center)
      }

      Scroll() {
        Column() {
          // 输入区
          this.inputSection()

          // 结果区
          if (this.result) {
            this.resultSection()
          }

          if (this.errorMsg) {
            Text(this.errorMsg).fontSize(13).fontColor("#F44336")
              .padding(12).backgroundColor("#FFEBEE").borderRadius(8)
              .margin({ left: 12, right: 12, top: 12 })
          }
        }.width("100%").padding({ bottom: 20 })
      }
      .layoutWeight(1).scrollBar(BarState.Off)
    }
    .width("100%").height("100%")
    .backgroundColor("#FAFAFA")
  }

  // ============================================================
  // 输入区
  // ============================================================
  @Builder
  inputSection() {
    Column() {
      Text("决策问题").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#333333")
      TextArea({ placeholder: "例如：要不要跳槽去新公司？", text: this.question })
        .fontSize(14)
        .height(80)
        .backgroundColor("#FFFFFF")
        .borderRadius(8)
        .padding(8)
        .margin({ top: 6 })
        .onChange((v: string) => { this.question = v; })

      // 可选方案
      Text("可选方案（可选）").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#333333").margin({ top: 16 })
      ForEach(this.options, (opt: string, idx: number) => {
        Row() {
          Text(`${idx + 1}. ${opt}`).fontSize(13).fontColor("#333333").layoutWeight(1)
          Text("✕").fontSize(14).fontColor("#F44336")
            .onClick(() => {
              this.options = this.options.filter((_, i) => i !== idx);
            })
        }
        .width("100%")
        .padding(8)
        .backgroundColor("#FFFFFF")
        .borderRadius(6)
        .margin({ top: 4 })
      }, (opt: string, idx: number) => `${idx}_${opt}`)

      Row() {
        TextInput({ placeholder: "添加一个方案", text: this.optionInput })
          .layoutWeight(1).height(36)
          .backgroundColor("#FFFFFF").borderRadius(6)
          .onChange((v: string) => { this.optionInput = v; })
          .onSubmit(() => { this.addOption(); })
        Button("+ 添加").fontSize(13).height(36)
          .backgroundColor("#6A1B9A").fontColor(Color.White)
          .margin({ left: 8 })
          .enabled(this.optionInput.trim().length > 0)
          .onClick(() => { this.addOption(); })
      }
      .width("100%").margin({ top: 6 })

      // 分析按钮
      Button(this.loading ? "分析中..." : "🔮 让知心帮我分析")
        .width("100%").height(48)
        .backgroundColor("#6A1B9A").fontColor(Color.White)
        .borderRadius(8)
        .margin({ top: 20 })
        .enabled(this.question.trim().length > 0 && !this.loading && this.isOnline)
        .onClick(() => { this.analyze(); })
    }
    .width("100%")
    .padding(12)
    .backgroundColor("#FFFFFF")
    .borderRadius(12)
    .margin({ left: 12, right: 12, top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  // 结果区
  // ============================================================
  @Builder
  resultSection() {
    if (this.result) {
      Column() {
        // 综合分析
        this.resultCard("📊 综合分析", this.result.analysis, "#E3F2FD", "#1565C0")

        // 推荐
        Column() {
          Text("✅ 知心推荐").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#2E7D32")
          Text(this.result.recommendation.option)
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor("#1B5E20")
            .margin({ top: 6 })
          Text(this.result.recommendation.reason)
            .fontSize(13).fontColor("#333333").margin({ top: 6 })
          Row() {
            Text("置信度").fontSize(11).fontColor("#999999")
            Text(`${(this.result.recommendation.confidence * 100).toFixed(0)}%`)
              .fontSize(11).fontColor(this.confidenceColor(this.result.recommendation.confidence))
              .margin({ left: 4 })
          }.margin({ top: 4 })
        }
        .width("100%")
        .padding(12)
        .backgroundColor("#E8F5E9")
        .borderRadius(8)
        .margin({ top: 8 })
        .alignItems(HorizontalAlign.Start)

        // 风险
        if (this.result.risks && this.result.risks.length > 0) {
          Column() {
            Text("⚠️ 潜在风险").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#C62828")
            ForEach(this.result.risks, (risk: string) => {
              Text(`• ${risk}`).fontSize(13).fontColor("#333333").margin({ top: 4 })
            }, (risk: string, idx: number) => `${idx}_${risk}`)
          }
          .width("100%")
          .padding(12)
          .backgroundColor("#FFEBEE")
          .borderRadius(8)
          .margin({ top: 8 })
          .alignItems(HorizontalAlign.Start)
        }

        // 备选方案
        if (this.result.alternatives && this.result.alternatives.length > 0) {
          Column() {
            Text("💡 备选方案").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#F57F17")
            ForEach(this.result.alternatives, (alt: string) => {
              Text(`• ${alt}`).fontSize(13).fontColor("#333333").margin({ top: 4 })
            }, (alt: string, idx: number) => `${idx}_${alt}`)
          }
          .width("100%")
          .padding(12)
          .backgroundColor("#FFF8E1")
          .borderRadius(8)
          .margin({ top: 8 })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width("100%")
      .padding(12)
      .backgroundColor("#FFFFFF")
      .borderRadius(12)
      .margin({ left: 12, right: 12, top: 12 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  resultCard(title: string, content: string, bgColor: string, titleColor: string) {
    Column() {
      Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(titleColor)
      Text(content).fontSize(13).fontColor("#333333").margin({ top: 6 })
    }
    .width("100%")
    .padding(12)
    .backgroundColor(bgColor)
    .borderRadius(8)
    .margin({ top: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  // 业务逻辑
  // ============================================================
  private addOption(): void {
    const opt = this.optionInput.trim();
    if (!opt) return;
    this.options = [...this.options, opt];
    this.optionInput = "";
  }

  private async analyze(): Promise<void> {
    this.loading = true;
    this.errorMsg = "";
    this.result = null;

    try {
      // 1. 打包上下文
      const userProfile = await this.memory.getFullProfile();
      const episodes = await this.memory.getTopEpisodic(10);
      const relevantEpisodes = episodes.map(e => ({
        title: e.title,
        description: e.description ?? "",
        outcome: e.outcome,
      }));

      // 2. 查找类似决策（从情景记忆中搜索"决策"相关）
      const similar = await this.memory.searchEpisodic("决策");
      const similarDecisions = similar.slice(0, 5).map(e => ({
        question: e.title,
        choice: e.description ?? "",
        outcome: e.outcome ?? "未知",
      }));

      // 3. 调用后端
      const result = await assistDecision({
        decision_question: this.question,
        options: this.options,
        user_profile: userProfile,
        relevant_episodes: relevantEpisodes,
        similar_decisions: similarDecisions,
      });

      this.result = result;

      // 4. 把这次决策存入情景记忆
      await this.memory.addEpisodic({
        event_time: Date.now(),
        title: `决策：${this.question.slice(0, 20)}`,
        description: `问题：${this.question}\n推荐：${result.recommendation.option}`,
        importance: 0.8,
        outcome: result.recommendation.option,
      });

      await this.memory.logBehavior("decision", {
        question: this.question,
        options: this.options,
        recommendation: result.recommendation,
      });

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
