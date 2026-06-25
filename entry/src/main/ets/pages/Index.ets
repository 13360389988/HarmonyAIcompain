/**
 * ChatPage.ets
 * -------------
 * 「知心」数字孪生 — 主聊天页面
 */

import {
  sendChatWithContext,
  ChatContext,
  ChatResult,
  WsClient,
  WsMessage,
  ConversationPair,
  EpisodeInfo,
  PatternInfo,
  RelationInfo,
  ExtractedData,
  ProfileUpdate,
  EpisodeUpdate,
  PersonUpdate,
} from "../services/ApiService";
import { NetworkMonitor } from "../services/NetworkMonitor";
import { OfflineQueue, OfflineMessage } from "../services/OfflineQueue";
import { MemoryService } from "../services/MemoryService";
import { PatternMiner } from "../services/PatternMiner";
import { PredictionService, PredictionCard } from "../services/PredictionService";
import { HomeDetector } from "../services/HomeDetector";
import { SyncOrchestrator, SyncProgress } from "../services/SyncOrchestrator";
import { SyncService } from "../services/SyncService";
import { BehaviorCollector } from "../services/BehaviorCollector";
import { ChatLogData } from "../services/SyncOrchestrator";
import { AppColors, AppRadius } from "../theme/Theme";
import { TabBar } from "../components/TabBar";
import router from "@ohos.router";

interface ChatItem {
  id: number;
  role: string;
  text: string;
  time: string;
  status: string;
  offlineId: number;
  emotion: string;
}

interface MemoryStats {
  semantic_memory: number;
  episodic_memory: number;
  procedural_memory: number;
}

@Entry
@Component
struct ChatPage {
  @State chatList: ChatItem[] = [];
  @State inputText: string = "";
  @State isOnline: boolean = true;
  @State pendingCount: number = 0;
  @State isSyncing: boolean = false;
  @State memoryStats: string = "";
  @State predictions: PredictionCard[] = [];
  @State predictionAccuracy: string = "";
  @State showPredictions: boolean = false;
  @State atHome: boolean = false;
  @State syncProgress: string = "";
  @State isSyncingAll: boolean = false;
  private nextId: number = 0;
  private scroller: Scroller = new Scroller();
  private wsClient: WsClient = new WsClient();
  private netMonitor: NetworkMonitor = NetworkMonitor.getInstance();
  private offlineQueue: OfflineQueue = new OfflineQueue();
  private memory: MemoryService = new MemoryService();
  private patternMiner: PatternMiner = new PatternMiner(this.memory);
  private predictionService: PredictionService = new PredictionService(this.memory);
  private syncService: SyncService = new SyncService(this.memory);
  private syncOrchestrator: SyncOrchestrator = new SyncOrchestrator(
    this.memory, this.offlineQueue, this.patternMiner, this.predictionService, this.syncService
  );
  private homeDetector: HomeDetector = new HomeDetector();
  private behaviorCollector: BehaviorCollector = new BehaviorCollector(this.memory);
  private unsubNet: (() => void) | null = null;
  private unsubHome: (() => void) | null = null;

  aboutToAppear(): void {
    Promise.all([
      this.memory.init(getContext(this)),
      this.offlineQueue.init(getContext(this)),
      this.syncService.init(),
    ]).then(async () => {
      this.refreshPendingCount();
      this.refreshMemoryStats();

      this.homeDetector.config({
        homeSsid: "Dorm-WiFi",
        serverUrl: "http://192.168.137.1:8000",
        homeLatLng: { lat: 0, lng: 0, radius: 0 },
      });
      this.homeDetector.start();
      this.unsubHome = this.homeDetector.onHomeStateChange((atHome: boolean) => {
        this.atHome = atHome;
        this.behaviorCollector.setOnlineStatus(atHome);
        if (atHome) {
          this.triggerFullSync();
        }
      });

      this.behaviorCollector.start();

      this.netMonitor.start();
      this.unsubNet = this.netMonitor.onStatusChange((online: boolean) => {
        this.isOnline = online;
      });

      this.syncOrchestrator.setProgressCallback((p: SyncProgress) => {
        this.syncProgress = `${p.step} (${p.current}/${p.total}) ${p.detail}`;
      });

      this.wsClient.connect((msg: WsMessage) => {
        if (msg.type === "heartbeat") return;
        this.addMessage("system", msg.content || `[${msg.type}]`);
      });

      if (this.homeDetector.isAtHome()) {
        this.triggerFullSync();
      } else {
        await this.predictionService.verifyPending();
        await this.refreshPredictions();
        this.refreshAccuracy();
      }
    });
  }

  aboutToDisappear(): void {
    this.wsClient.disconnect();
    this.behaviorCollector.stop();
    if (this.unsubNet) this.unsubNet();
    if (this.unsubHome) this.unsubHome();
    this.netMonitor.stop();
    this.homeDetector.stop();
  }

  private async triggerFullSync(): Promise<void> {
    if (this.isSyncingAll) return;
    this.isSyncingAll = true;

    try {
      const result = await this.syncOrchestrator.triggerFullSync();

      await this.refreshPredictions();
      this.refreshAccuracy();
      this.refreshMemoryStats();
      this.refreshPendingCount();

      if (result.messagesSynced > 0 || result.patternsMined > 0 || result.newPredictions > 0) {
        this.addMessage("system",
          `回到宿舍同步完成：消息 ${result.messagesSynced} 条 · ` +
          `新模式 ${result.patternsMined} 个 · ` +
          `新预测 ${result.newPredictions} 条` +
          (result.errors.length > 0 ? ` · 错误 ${result.errors.length} 个` : "")
        );
      }
    } catch (e) {
      this.addMessage("system", `同步失败：${(e as Error).message}`);
    } finally {
      this.isSyncingAll = false;
      this.syncProgress = "";
    }
  }

  private addMessage(
    role: string,
    text: string,
    status: string = "sent",
    offlineId: number = 0,
    emotion: string = ""
  ): void {
    const now = new Date();
    const h = now.getHours().toString().padStart(2, "0");
    const m = now.getMinutes().toString().padStart(2, "0");
    this.chatList.push({
      id: this.nextId++,
      role, text,
      time: `${h}:${m}`,
      status, offlineId, emotion,
    });
    setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom); }, 100);
  }

  private updateMessageStatus(id: number, status: string): void {
    let idx = -1;
    for (let i = 0; i < this.chatList.length; i++) {
      if (this.chatList[i].id === id) {
        idx = i;
        break;
      }
    }
    if (idx >= 0) {
      const item = this.chatList[idx];
      const newItem: ChatItem = {
        id: item.id,
        role: item.role,
        text: item.text,
        time: item.time,
        status: status,
        offlineId: item.offlineId,
        emotion: item.emotion,
      };
      this.chatList[idx] = newItem;
      const newList: ChatItem[] = [];
      for (let i = 0; i < this.chatList.length; i++) {
        newList.push(this.chatList[i]);
      }
      this.chatList = newList;
    }
  }

  private async refreshPendingCount(): Promise<void> {
    this.pendingCount = await this.offlineQueue.size();
  }

  private async refreshMemoryStats(): Promise<void> {
    try {
      const stats = await this.memory.getStats();
      if (stats) {
        this.memoryStats = `画像${stats["semantic_memory"] || 0} · 事件${stats["episodic_memory"] || 0} · 模式${stats["procedural_memory"] || 0}`;
      }
    } catch { /* 忽略 */ }
  }

  private async refreshPredictions(): Promise<void> {
    try {
      this.predictions = await this.predictionService.getActivePredictions();
    } catch { /* 忽略 */ }
  }

  private async refreshAccuracy(): Promise<void> {
    try {
      const acc = await this.predictionService.getAccuracy();
      if (acc.total > 0) {
        this.predictionAccuracy = `准确率 ${(acc.accuracy * 100).toFixed(0)}% (${acc.total}次)`;
      }
    } catch { /* 忽略 */ }
  }

  private async buildContext(userMessage: string): Promise<ChatContext> {
    const userProfile = await this.memory.getFullProfile();

    const recentRecords = await this.memory.getRecentRounds(10);
    const recentConversations: ConversationPair[] = [];
    for (let i = 0; i < recentRecords.length - 1; i += 2) {
      if (recentRecords[i].role === "user" && recentRecords[i + 1].role === "assistant") {
        recentConversations.push({
          user: recentRecords[i].content,
          assistant: recentRecords[i + 1].content,
        });
      }
    }

    const topEpisodes = await this.memory.getTopEpisodic(5);
    const relevantEpisodes: EpisodeInfo[] = [];
    for (let i = 0; i < topEpisodes.length; i++) {
      const e = topEpisodes[i];
      const desc = e.description ? e.description : "";
      relevantEpisodes.push({
        title: e.title,
        description: desc,
        time: new Date(e.event_time).toLocaleString(),
      });
    }

    const patterns = await this.memory.getAllProcedural();
    const behaviorPatterns: PatternInfo[] = [];
    for (let i = 0; i < patterns.length && i < 5; i++) {
      const conf = patterns[i].confidence ? patterns[i].confidence : 0.5;
      behaviorPatterns.push({
        description: patterns[i].description,
        confidence: conf,
      });
    }

    const relations = await this.memory.getAllRelations();
    const relationList: RelationInfo[] = [];
    for (let i = 0; i < relations.length && i < 10; i++) {
      const rel = relations[i].relation_type ? relations[i].relation_type : "acquaintance";
      const men = relations[i].mention_count ? relations[i].mention_count : 1;
      relationList.push({
        name: relations[i].person_name,
        relation: rel,
        mentions: men,
      });
    }

    return {
      message: userMessage,
      current_time: new Date().toLocaleString(),
      current_location: "",
      user_profile: userProfile,
      recent_conversations: recentConversations,
      relevant_episodes: relevantEpisodes,
      behavior_patterns: behaviorPatterns,
      relations: relationList,
      pending_predictions: [],
    };
  }

  private async processExtracted(
    userMessage: string,
    aiReply: string,
    extracted: ExtractedData
  ): Promise<void> {
    await this.memory.addShortTerm({
      role: "user",
      content: userMessage,
      emotion: extracted.emotion,
    });
    await this.memory.addShortTerm({
      role: "assistant",
      content: aiReply,
    });

    const chatData: ChatLogData = {
      user_msg: userMessage,
      ai_reply: aiReply,
      emotion: extracted.emotion !== undefined ? extracted.emotion : "",
      synced: false,
    };
    await this.memory.logBehavior("chat", chatData);

    if (extracted.profile_updates) {
      for (let i = 0; i < extracted.profile_updates.length; i++) {
        const p: ProfileUpdate = extracted.profile_updates[i];
        const conf: number = p.confidence !== undefined ? p.confidence : 0.5;
        await this.memory.setSemantic({
          category: p.category,
          key: p.key,
          value: p.value,
          confidence: conf,
          source: "chat",
        });
      }
    }

    if (extracted.episodes) {
      for (let i = 0; i < extracted.episodes.length; i++) {
        const e: EpisodeUpdate = extracted.episodes[i];
        const imp: number = e.importance !== undefined ? e.importance : 0.5;
        const peopleStr: string = e.people !== undefined ? JSON.stringify(e.people) : "";
        await this.memory.addEpisodic({
          event_time: Date.now(),
          title: e.title,
          description: e.description,
          importance: imp,
          people: peopleStr,
          outcome: e.outcome,
          emotion: extracted.emotion,
        });
      }
    }

    if (extracted.persons) {
      for (let i = 0; i < extracted.persons.length; i++) {
        const p: PersonUpdate = extracted.persons[i];
        const sent: number = p.sentiment !== undefined ? p.sentiment : 0;
        await this.memory.mentionPerson(
          p.name,
          p.relation,
          sent
        );
      }
    }

    if (extracted.should_summarize) {
      this.generateAndStoreSummary(userMessage, aiReply);
    }

    this.refreshMemoryStats();
    this.triggerNewPrediction();
  }

  private async triggerNewPrediction(): Promise<void> {
    if (!this.isOnline) return;
    try {
      await this.predictionService.generate();
      await this.refreshPredictions();
    } catch { /* 预测失败不影响主流程 */ }
  }

  private async generateAndStoreSummary(userMessage: string, aiReply: string): Promise<void> {
    try {
      await this.memory.addEpisodic({
        event_time: Date.now(),
        title: "对话摘要",
        description: `用户：${userMessage.slice(0, 50)}... → AI：${aiReply.slice(0, 50)}...`,
        importance: 0.6,
        emotion: "neutral",
      });
    } catch { /* 忽略 */ }
  }

  private send(): void {
    const text = this.inputText.trim();
    if (!text) return;
    this.inputText = "";

    if (this.atHome) {
      this.sendOnline(text);
    } else {
      this.handleOfflineSend(text);
    }
  }

  private sendOnline(text: string): void {
    this.addMessage("user", text, "sent");

    this.buildContext(text).then(ctx => {
      return sendChatWithContext(ctx);
    }).then(result => {
      this.addMessage("ai", result.reply, "sent");
      this.processExtracted(text, result.reply, result.extracted);
    }).catch((err: Error) => {
      this.handleSendFailure(text);
      console.error("[ChatPage] 发送失败:", JSON.stringify(err));
    });
  }

  private async handleSendFailure(text: string): Promise<void> {
    const offlineId = await this.offlineQueue.enqueue(text);
    let lastUserMsg: ChatItem | null = null;
    for (let i = this.chatList.length - 1; i >= 0; i--) {
      if (this.chatList[i].role === "user" && this.chatList[i].status === "sent") {
        lastUserMsg = this.chatList[i];
        break;
      }
    }
    if (lastUserMsg) {
      let idx = -1;
      for (let i = 0; i < this.chatList.length; i++) {
        if (this.chatList[i].id === lastUserMsg!.id) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        const item = this.chatList[idx];
        this.chatList[idx] = {
          id: item.id,
          role: item.role,
          text: item.text,
          time: item.time,
          status: "pending",
          offlineId: offlineId,
          emotion: item.emotion,
        };
        const newList: ChatItem[] = [];
        for (let i = 0; i < this.chatList.length; i++) {
          newList.push(this.chatList[i]);
        }
        this.chatList = newList;
      }
    }
    this.addMessage("system", "后端未响应，消息已暂存，联网后将自动发送。");
    this.refreshPendingCount();
  }

  private async handleOfflineSend(text: string): Promise<void> {
    const offlineId = await this.offlineQueue.enqueue(text);
    this.addMessage("user", text, "pending", offlineId);
    this.refreshPendingCount();
  }

  private async syncOfflineQueue(): Promise<void> {
    if (this.isSyncing) return;
    this.isSyncing = true;

    try {
      const pending: OfflineMessage[] = await this.offlineQueue.getAll();
      if (pending.length === 0) {
        this.isSyncing = false;
        return;
      }

      this.addMessage("system", `网络已恢复，正在同步 ${pending.length} 条待发送消息...`);

      let success = 0;
      let failed = 0;

      for (let i = 0; i < pending.length; i++) {
        const msg = pending[i];
        try {
          const ctx = await this.buildContext(msg.text);
          const result = await sendChatWithContext(ctx);

          let chatItem: ChatItem | null = null;
          for (let j = 0; j < this.chatList.length; j++) {
            if (this.chatList[j].offlineId === msg.id) {
              chatItem = this.chatList[j];
              break;
            }
          }
          if (chatItem) this.updateMessageStatus(chatItem.id, "sent");

          this.addMessage("ai", result.reply, "sent");
          await this.processExtracted(msg.text, result.reply, result.extracted);
          await this.offlineQueue.remove(msg.id);
          success++;
        } catch {
          failed++;
        }
      }

      if (success > 0) {
        this.addMessage("system", `同步完成：成功 ${success} 条${failed > 0 ? `，失败 ${failed} 条将稍后重试` : ""}。`);
      } else if (failed > 0) {
        this.addMessage("system", `同步失败，${failed} 条消息将稍后自动重试。`);
      }

      this.refreshPendingCount();
    } finally {
      this.isSyncing = false;
    }
  }

  @Builder
  bubble(item: ChatItem) {
    Column() {
      Text(item.text)
        .fontSize(15)
        .lineHeight(22)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius({
          topLeft: AppRadius.LG, topRight: AppRadius.LG,
          bottomLeft: item.role === "user" ? AppRadius.LG : 4,
          bottomRight: item.role === "user" ? 4 : AppRadius.LG
        })
        .constraintSize({ maxWidth: "78%" })
        .backgroundColor(item.role === "user" ? AppColors.BUBBLE_USER :
                         item.role === "system" ? AppColors.BUBBLE_SYSTEM : AppColors.BUBBLE_AI)
        .fontColor(item.role === "user" ? Color.White :
                   item.role === "system" ? "#B85C00" : AppColors.TEXT_PRIMARY)

      Row() {
        Text(item.time).fontSize(10).fontColor(AppColors.TEXT_TERTIARY)
        if (item.role === "user" && item.status === "pending") {
          Text("  ⏳ 待发送").fontSize(10).fontColor(AppColors.WARNING)
        } else if (item.role === "user" && item.status === "failed") {
          Text("  ⚠ 失败").fontSize(10).fontColor(AppColors.DANGER)
        }
        if (item.emotion && item.role === "user") {
          Text(`  · ${item.emotion}`).fontSize(10).fontColor(AppColors.TEXT_TERTIARY)
        }
      }.margin({ top: 4 })
    }
    .alignItems(item.role === "user" ? HorizontalAlign.End :
                item.role === "system" ? HorizontalAlign.Center : HorizontalAlign.Start)
    .width("100%")
  }

  @Builder
  statusBar() {
    Row() {
      if (this.isSyncingAll) {
        LoadingProgress().width(14).height(14).color("#FFFFFF")
        Text(this.syncProgress || "同步中...").fontSize(11).fontColor("#FFFFFF").margin({ left: 6 })
      } else if (this.atHome) {
        Circle({ width: 6, height: 6 }).fill(AppColors.SUCCESS)
        Text("在宿舍").fontSize(11).fontColor("#FFFFFF").margin({ left: 4 })
        if (this.pendingCount > 0) {
          Text(`· ${this.pendingCount} 待同步`).fontSize(11).fontColor("#FFD54F").margin({ left: 4 })
        }
        if (this.memoryStats) {
          Text(`· ${this.memoryStats}`).fontSize(10).fontColor("#90CAF9").margin({ left: 4 })
        }
        if (this.predictionAccuracy) {
          Text(`· ${this.predictionAccuracy}`).fontSize(10).fontColor("#A5D6A7").margin({ left: 4 })
        }
      } else {
        Circle({ width: 6, height: 6 }).fill(AppColors.WARNING)
        Text("外出模式").fontSize(11).fontColor("#FFFFFF").margin({ left: 4 })
        if (this.pendingCount > 0) {
          Text(`· ${this.pendingCount} 待回宿舍同步`).fontSize(11).fontColor("#FFD54F").margin({ left: 4 })
        }
      }
    }
    .width("100%").height(28)
    .backgroundColor(this.atHome ? AppColors.PRIMARY_DARK : AppColors.HEADER_BG_OUT)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  predictionPanel() {
    if (this.predictions.length > 0) {
      Column() {
        Row() {
          Text("🔮 知心预测").fontSize(14).fontWeight(FontWeight.Bold).fontColor(AppColors.TEXT_PRIMARY)
          Blank()
          Text(this.showPredictions ? "收起 ▲" : "展开 ▼")
            .fontSize(12).fontColor(AppColors.PRIMARY)
        }
        .width("100%")
        .padding({ left: 16, right: 16, top: 10, bottom: 8 })
        .onClick(() => { this.showPredictions = !this.showPredictions; })

        if (this.showPredictions) {
          ForEach(this.predictions, (p: PredictionCard) => {
            Row() {
              Column() {
                Row() {
                  Text(this.predictionTypeIcon(p.type))
                    .fontSize(16)
                  Text(p.content)
                    .fontSize(13)
                    .fontColor(AppColors.TEXT_PRIMARY)
                    .layoutWeight(1)
                    .margin({ left: 6 })
                  Text(`${(p.confidence * 100).toFixed(0)}%`)
                    .fontSize(11)
                    .fontColor(this.confidenceColor(p.confidence))
                }
                .width("100%")

                Text(`⏰ ${p.targetTime}`)
                  .fontSize(11)
                  .fontColor(AppColors.TEXT_TERTIARY)
                  .margin({ top: 4 })

                if (p.reasoning) {
                  Text(`💡 ${p.reasoning}`)
                    .fontSize(11)
                    .fontColor(AppColors.TEXT_SECONDARY)
                    .margin({ top: 2 })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width("100%")
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(AppColors.BG_INPUT)
            .borderRadius(AppRadius.SM)
            .margin({ left: 12, right: 12, bottom: 6 })
          }, (p: PredictionCard) => p.id.toString())
        }
      }
      .width("100%")
      .backgroundColor(AppColors.BG_CARD)
      .borderRadius(AppRadius.MD)
      .margin({ left: 8, right: 8, top: 8 })
    }
  }

  private predictionTypeIcon(type: string): string {
    switch (type) {
      case "location": return "📍";
      case "behavior": return "🎯";
      case "emotion": return "😊";
      default: return "🔮";
    }
  }

  private confidenceColor(conf: number): ResourceColor {
    if (conf >= 0.7) return "#4CAF50";
    if (conf >= 0.4) return "#FF9800";
    return "#F44336";
  }

  build() {
    Column() {
      // 头部
      Row() {
        Text("知心").fontSize(18).fontWeight(FontWeight.Bold).fontColor("#FFFFFF")
      }
      .width("100%").height(48)
      .backgroundColor(AppColors.HEADER_BG)
      .justifyContent(FlexAlign.Center)

      this.statusBar()

      // 聊天区域
      Scroll(this.scroller) {
        Column() {
          this.predictionPanel()

          ForEach(this.chatList, (item: ChatItem) => {
            Column() { this.bubble(item) }
              .padding({ left: 16, right: 16, top: 8, bottom: 4 })
              .width("100%")
          }, (item: ChatItem) => item.id.toString())
        }.width("100%")
      }
      .layoutWeight(1).scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)

      Divider().height(0.5).color(AppColors.BORDER)

      // 输入栏
      Row() {
        TextInput({
          placeholder: this.atHome ? "想和知心聊聊..." : "外出模式，消息将暂存",
          text: this.inputText
        })
          .onChange((value: string) => { this.inputText = value; })
          .onSubmit(() => { this.send(); })
          .layoutWeight(1).height(40)
          .backgroundColor(AppColors.BG_INPUT).borderRadius(20)
          .padding({ left: 16, right: 16 })

        Button(this.atHome ? "发送" : "暂存")
          .fontSize(14).height(40)
          .padding({ left: 20, right: 20 }).borderRadius(20)
          .backgroundColor(this.atHome ? AppColors.PRIMARY : AppColors.WARNING)
          .fontColor(Color.White)
          .margin({ left: 8 })
          .enabled(this.inputText.trim().length > 0)
          .onClick(() => { this.send(); })
      }
      .width("100%")
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(AppColors.BG_CARD)

      // 底部导航
      TabBar({ activeIndex: 0 })
    }
    .width("100%").height("100%")
    .backgroundColor(AppColors.BG_PAGE)
  }
}
