/**
 * ChatPage.ets
 * -------------
 * 「知心」数字孪生 — 主聊天页面
 *
 * 核心流程：
 *   1. 用户输入 → 从本地六层记忆打包上下文
 *   2. 发送给后端无状态推理服务
 *   3. 收到回复 + extracted 结构化信息
 *   4. 自动写入对应记忆层：
 *      - emotion → short_term_memory
 *      - profile_updates → semantic_memory
 *      - episodes → episodic_memory
 *      - persons → relation_network
 *   5. 离线时入队，联网后自动同步
 */

import {
  sendChatWithContext,
  ChatContext,
  ChatResult,
  WsClient,
  WsMessage
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
import router from "@ohos.router";

// ---- 数据模型 ----
interface ChatItem {
  id: number;
  role: "user" | "ai" | "system";
  text: string;
  time: string;
  status: "sent" | "pending" | "failed";
  offlineId?: number;
  emotion?: string;  // 用户消息的情绪（由 LLM 提取）
}

@Entry
@Component
struct ChatPage {
  @State chatList: ChatItem[] = [];
  @State inputText: string = "";
  @State isOnline: boolean = true;
  @State pendingCount: number = 0;
  @State isSyncing: boolean = false;
  @State memoryStats: string = "";  // 记忆统计展示
  @State predictions: PredictionCard[] = [];  // 当前预测
  @State predictionAccuracy: string = "";  // 准确率展示
  @State showPredictions: boolean = false;  // 是否展开预测面板
  @State atHome: boolean = false;  // 是否在宿舍（后端可达）
  @State syncProgress: string = "";  // 同步进度展示
  @State isSyncingAll: boolean = false;  // 是否正在批量同步
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
    // 1. 初始化记忆系统 + 离线队列
    Promise.all([
      this.memory.init(getContext(this)),
      this.offlineQueue.init(getContext(this)),
      this.syncService.init(),
    ]).then(async () => {
      this.refreshPendingCount();
      this.refreshMemoryStats();

      // 2. 配置宿舍检测器
      //    TODO: 把 "你的宿舍WiFi名" 改成实际 WiFi SSID
      //    后端地址与 ApiService.ets 中的一致
      this.homeDetector.config({
        homeSsid: "Dorm-WiFi",  // ← 改成你宿舍的 WiFi 名
        serverUrl: "http://192.168.137.1:8000",  // ← 改成你电脑的 IP
      });
      this.homeDetector.start();
      this.unsubHome = this.homeDetector.onHomeStateChange((atHome: boolean) => {
        this.atHome = atHome;
        this.behaviorCollector.setOnlineStatus(atHome);
        if (atHome) {
          // 回到宿舍 → 自动触发完整同步
          this.triggerFullSync();
        }
      });

      // 3. 启动行为采集（离线也采集）
      this.behaviorCollector.start();

      // 4. 启动网络监听
      this.netMonitor.start();
      this.unsubNet = this.netMonitor.onStatusChange((online: boolean) => {
        this.isOnline = online;
      });

      // 5. 设置同步进度回调
      this.syncOrchestrator.setProgressCallback((p: SyncProgress) => {
        this.syncProgress = `${p.step} (${p.current}/${p.total}) ${p.detail}`;
      });

      // 6. WebSocket（保留用于未来主动推送）
      this.wsClient.connect((msg: WsMessage) => {
        if (msg.type === "heartbeat") return;
        this.addMessage("system", msg.content ?? `[${msg.type}]`);
      });

      // 7. 启动时如果已在宿舍，立即同步
      if (this.homeDetector.isAtHome()) {
        this.triggerFullSync();
      } else {
        // 不在宿舍也尝试验证历史预测 + 加载已有预测
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

  /** 触发完整同步（回到宿舍时自动调用） */
  private async triggerFullSync(): Promise<void> {
    if (this.isSyncingAll) return;
    this.isSyncingAll = true;

    try {
      const result = await this.syncOrchestrator.triggerFullSync();

      // 同步完成后刷新 UI
      await this.refreshPredictions();
      this.refreshAccuracy();
      this.refreshMemoryStats();
      this.refreshPendingCount();

      // 显示同步结果
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

  // ============================================================
  // 消息管理
  // ============================================================
  private addMessage(
    role: "user" | "ai" | "system",
    text: string,
    status: "sent" | "pending" | "failed" = "sent",
    offlineId?: number,
    emotion?: string
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
    setTimeout(() => this.scroller.scrollEdge(Edge.Bottom), 100);
  }

  private updateMessageStatus(id: number, status: "sent" | "pending" | "failed"): void {
    const idx = this.chatList.findIndex(c => c.id === id);
    if (idx >= 0) {
      this.chatList[idx] = { ...this.chatList[idx], status };
      this.chatList = [...this.chatList];
    }
  }

  private async refreshPendingCount(): Promise<void> {
    this.pendingCount = await this.offlineQueue.size();
  }

  private async refreshMemoryStats(): Promise<void> {
    // 简单展示各记忆层的记录数（可在设置页详细展示）
    try {
      const stats = await this.memory.getStats?.();
      if (stats) {
        this.memoryStats = `画像${stats.semantic_memory ?? 0} · 事件${stats.episodic_memory ?? 0} · 模式${stats.procedural_memory ?? 0}`;
      }
    } catch { /* 忽略 */ }
  }

  /** 刷新当前预测列表 */
  private async refreshPredictions(): Promise<void> {
    try {
      this.predictions = await this.predictionService.getActivePredictions();
    } catch { /* 忽略 */ }
  }

  /** 刷新预测准确率展示 */
  private async refreshAccuracy(): Promise<void> {
    try {
      const acc = await this.predictionService.getAccuracy();
      if (acc.total > 0) {
        this.predictionAccuracy = `准确率 ${(acc.accuracy * 100).toFixed(0)}% (${acc.total}次)`;
      }
    } catch { /* 忽略 */ }
  }

  // ============================================================
  // 打包上下文（核心 — 从六层记忆组装）
  // ============================================================
  private async buildContext(userMessage: string): Promise<ChatContext> {
    // 1. 用户画像（语义记忆）
    const userProfile = await this.memory.getFullProfile();

    // 2. 最近对话（短期记忆）— 取最近 10 轮
    const recentRecords = await this.memory.getRecentRounds(10);
    const recentConversations: Array<{ user: string; assistant: string }> = [];
    for (let i = 0; i < recentRecords.length - 1; i += 2) {
      if (recentRecords[i].role === "user" && recentRecords[i + 1]?.role === "assistant") {
        recentConversations.push({
          user: recentRecords[i].content,
          assistant: recentRecords[i + 1].content,
        });
      }
    }

    // 3. 相关情景记忆 — 取最重要的 5 条
    const topEpisodes = await this.memory.getTopEpisodic(5);
    const relevantEpisodes = topEpisodes.map(e => ({
      title: e.title,
      description: e.description ?? "",
      time: new Date(e.event_time).toLocaleString(),
    }));

    // 4. 行为模式（程序记忆）— 取置信度最高的 5 条
    const patterns = await this.memory.getAllProcedural();
    const behaviorPatterns = patterns.slice(0, 5).map(p => ({
      description: p.description,
      confidence: p.confidence ?? 0.5,
    }));

    // 5. 关系网络 — 取提及最多的 10 个
    const relations = await this.memory.getAllRelations();
    const relationList = relations.slice(0, 10).map(r => ({
      name: r.person_name,
      relation: r.relation_type ?? "acquaintance",
      mentions: r.mention_count ?? 1,
    }));

    return {
      message: userMessage,
      current_time: new Date().toLocaleString(),
      current_location: "",  // TODO: 接入定位后填充
      user_profile: userProfile,
      recent_conversations: recentConversations,
      relevant_episodes: relevantEpisodes,
      behavior_patterns: behaviorPatterns,
      relations: relationList,
    };
  }

  // ============================================================
  // 处理 LLM 返回的 extracted — 写入对应记忆层
  // ============================================================
  private async processExtracted(
    userMessage: string,
    aiReply: string,
    extracted: ChatResult["extracted"]
  ): Promise<void> {
    // 1. 写入短期记忆
    await this.memory.addShortTerm({
      role: "user",
      content: userMessage,
      emotion: extracted.emotion,
    });
    await this.memory.addShortTerm({
      role: "assistant",
      content: aiReply,
    });

    // 2. 记录行为日志
    await this.memory.logBehavior("chat", {
      user_msg: userMessage,
      ai_reply: aiReply,
      emotion: extracted.emotion,
    });

    // 3. 更新语义记忆（画像）
    if (extracted.profile_updates) {
      for (const p of extracted.profile_updates) {
        await this.memory.setSemantic({
          category: p.category,
          key: p.key,
          value: p.value,
          confidence: p.confidence,
          source: "chat",
        });
      }
    }

    // 4. 写入情景记忆
    if (extracted.episodes) {
      for (const e of extracted.episodes) {
        await this.memory.addEpisodic({
          event_time: Date.now(),
          title: e.title,
          description: e.description,
          importance: e.importance ?? 0.5,
          people: e.people ? JSON.stringify(e.people) : undefined,
          outcome: e.outcome,
          emotion: extracted.emotion,
        });
      }
    }

    // 5. 更新关系网络
    if (extracted.persons) {
      for (const p of extracted.persons) {
        await this.memory.mentionPerson(
          p.name,
          p.relation,
          p.sentiment ?? 0
        );
      }
    }

    // 6. 如果建议摘要，触发摘要生成
    if (extracted.should_summarize) {
      // 异步生成摘要，不阻塞 UI
      this.generateAndStoreSummary(userMessage, aiReply);
    }

    this.refreshMemoryStats();

    // 7. 触发新一轮预测（异步，不阻塞 UI）
    this.triggerNewPrediction();
  }

  /** 触发新一轮预测 */
  private async triggerNewPrediction(): Promise<void> {
    if (!this.isOnline) return;
    try {
      await this.predictionService.generate();
      await this.refreshPredictions();
    } catch { /* 预测失败不影响主流程 */ }
  }

  private async generateAndStoreSummary(userMessage: string, aiReply: string): Promise<void> {
    try {
      // 这里简化处理：直接把本轮对话存为情景记忆的摘要
      // 实际可以调用后端 /summarize 接口
      await this.memory.addEpisodic({
        event_time: Date.now(),
        title: "对话摘要",
        description: `用户：${userMessage.slice(0, 50)}... → AI：${aiReply.slice(0, 50)}...`,
        importance: 0.6,
        emotion: "neutral",
      });
    } catch { /* 忽略 */ }
  }

  // ============================================================
  // 发送消息
  // ============================================================
  private send(): void {
    const text = this.inputText.trim();
    if (!text) return;
    this.inputText = "";

    if (this.atHome) {
      // 在宿舍（后端可达）→ 直接发送
      this.sendOnline(text);
    } else {
      // 不在宿舍 → 入离线队列，等回宿舍自动同步
      this.handleOfflineSend(text);
    }
  }

  private sendOnline(text: string): void {
    this.addMessage("user", text, "sent");

    // 1. 打包上下文
    this.buildContext(text).then(ctx => {
      // 2. 调用后端
      return sendChatWithContext(ctx);
    }).then(result => {
      // 3. 显示 AI 回复
      this.addMessage("ai", result.reply, "sent");
      // 4. 异步处理 extracted，写入记忆
      this.processExtracted(text, result.reply, result.extracted);
    }).catch((err: Error) => {
      // 在线但失败 → 转入离线队列
      this.handleSendFailure(text);
      console.error("[ChatPage] 发送失败:", JSON.stringify(err));
    });
  }

  private async handleSendFailure(text: string): Promise<void> {
    const offlineId = await this.offlineQueue.enqueue(text);
    const lastUserMsg = [...this.chatList].reverse().find(c => c.role === "user" && c.status === "sent");
    if (lastUserMsg) {
      const idx = this.chatList.findIndex(c => c.id === lastUserMsg.id);
      this.chatList[idx] = { ...this.chatList[idx], status: "pending", offlineId };
      this.chatList = [...this.chatList];
    }
    this.addMessage("system", "后端未响应，消息已暂存，联网后将自动发送。");
    this.refreshPendingCount();
  }

  private async handleOfflineSend(text: string): Promise<void> {
    const offlineId = await this.offlineQueue.enqueue(text);
    this.addMessage("user", text, "pending", offlineId);
    this.refreshPendingCount();
  }

  // ============================================================
  // 离线队列同步
  // ============================================================
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

      for (const msg of pending) {
        try {
          const ctx = await this.buildContext(msg.text);
          const result = await sendChatWithContext(ctx);

          const chatItem = this.chatList.find(c => c.offlineId === msg.id);
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

  // ============================================================
  // UI Builders
  // ============================================================
  @Builder
  bubble(item: ChatItem) {
    Column() {
      Text(item.text)
        .fontSize(15)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius(12)
        .constraintSize({ maxWidth: "80%" })
        .backgroundColor(item.role === "user" ? "#1677FF" :
                         item.role === "system" ? "#FFE8D6" : "#F0F0F0")
        .fontColor(item.role === "user" ? Color.White :
                   item.role === "system" ? "#B85C00" : "#333333")

      Row() {
        Text(item.time).fontSize(11).fontColor("#AAAAAA")
        if (item.role === "user" && item.status === "pending") {
          Text("  ⏳ 待发送").fontSize(11).fontColor("#FF9800")
        } else if (item.role === "user" && item.status === "failed") {
          Text("  ⚠ 失败").fontSize(11).fontColor("#F44336")
        }
        if (item.emotion && item.role === "user") {
          Text(`  · ${item.emotion}`).fontSize(11).fontColor("#9E9E9E")
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
        LoadingProgress().width(16).height(16).color("#FFFFFF")
        Text(this.syncProgress || "同步中...").fontSize(11).fontColor("#FFFFFF").margin({ left: 6 })
      } else if (this.atHome) {
        Circle({ width: 8, height: 8 }).fill("#4CAF50")
        Text("在宿舍").fontSize(12).fontColor("#FFFFFF").margin({ left: 6 })
        if (this.pendingCount > 0) {
          Text(`· ${this.pendingCount} 条待同步`).fontSize(12).fontColor("#FFE082").margin({ left: 6 })
        }
        if (this.memoryStats) {
          Text(`· ${this.memoryStats}`).fontSize(11).fontColor("#BBDEFB").margin({ left: 6 })
        }
        if (this.predictionAccuracy) {
          Text(`· ${this.predictionAccuracy}`).fontSize(11).fontColor("#C8E6C9").margin({ left: 6 })
        }
      } else {
        Circle({ width: 8, height: 8 }).fill("#FF9800")
        Text("外出模式").fontSize(12).fontColor("#FFFFFF").margin({ left: 6 })
        if (this.pendingCount > 0) {
          Text(`· ${this.pendingCount} 条待回宿舍同步`).fontSize(12).fontColor("#FFE082").margin({ left: 6 })
        }
      }
    }
    .width("100%").height(24)
    .backgroundColor(this.atHome ? "#0D47A1" : "#E65100")
    .justifyContent(FlexAlign.Center)
  }

  /** 预测卡片面板（可折叠） */
  @Builder
  predictionPanel() {
    if (this.predictions.length > 0) {
      Column() {
        // 标题行（可点击折叠）
        Row() {
          Text("🔮 知心预测").fontSize(14).fontWeight(FontWeight.Bold).fontColor("#333333")
          Blank()
          Text(this.showPredictions ? "收起 ▲" : "展开 ▼")
            .fontSize(12).fontColor("#1677FF")
        }
        .width("100%")
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
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
                    .fontColor("#333333")
                    .layoutWeight(1)
                    .margin({ left: 6 })
                  Text(`${(p.confidence * 100).toFixed(0)}%`)
                    .fontSize(11)
                    .fontColor(this.confidenceColor(p.confidence))
                }
                .width("100%")

                Text(`⏰ ${p.targetTime}`)
                  .fontSize(11)
                  .fontColor("#999999")
                  .margin({ top: 4 })

                if (p.reasoning) {
                  Text(`💡 ${p.reasoning}`)
                    .fontSize(11)
                    .fontColor("#888888")
                    .margin({ top: 2 })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width("100%")
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .backgroundColor("#F8F9FA")
            .borderRadius(8)
            .margin({ left: 12, right: 12, bottom: 4 })
          }, (p: PredictionCard) => p.id.toString())
        }
      }
      .width("100%")
      .backgroundColor("#FFFFFF")
      .borderRadius(12)
      .margin({ left: 8, right: 8, top: 8 })
    }
  }

  /** 预测类型图标 */
  private predictionTypeIcon(type: string): string {
    switch (type) {
      case "location": return "📍";
      case "behavior": return "🎯";
      case "emotion": return "😊";
      default: return "🔮";
    }
  }

  /** 置信度颜色 */
  private confidenceColor(conf: number): ResourceColor {
    if (conf >= 0.7) return "#4CAF50";  // 绿
    if (conf >= 0.4) return "#FF9800";  // 橙
    return "#F44336";                    // 红
  }

  build() {
    Column() {
      // 顶部标题
      Row() {
        // 决策入口
        Text("🤔").fontSize(20)
          .onClick(() => {
            router.pushUrl({ url: "pages/DecisionPage" });
          })
        Blank()
        Text("知心").fontSize(20).fontWeight(FontWeight.Bold).fontColor("#FFFFFF")
        Blank()
        // 进入记忆可视化页
        Text("🧠").fontSize(20)
          .onClick(() => {
            router.pushUrl({ url: "pages/MemoryPage" });
          })
      }
      .width("100%").height(48)
      .backgroundColor("#1677FF")
      .padding({ left: 16, right: 16 })

      this.statusBar()
      Divider().height(0.5).color("#E0E0E0")

      // 消息列表
      Scroll(this.scroller) {
        Column() {
          // 预测面板（在消息列表顶部）
          this.predictionPanel()

          ForEach(this.chatList, (item: ChatItem) => {
            Column() { this.bubble(item) }
              .padding({ left: 16, right: 16, top: 8, bottom: 4 })
              .width("100%")
          }, (item: ChatItem) => item.id.toString())
        }.width("100%")
      }
      .layoutWeight(1).scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)

      Divider().height(0.5).color("#E0E0E0")

      // 输入区
      Row() {
        TextInput({
          placeholder: this.atHome ? "想和知心聊聊..." : "外出模式，消息将暂存，回宿舍自动发送",
          text: this.inputText
        })
          .onChange((value: string) => { this.inputText = value; })
          .onSubmit(() => { this.send(); })
          .layoutWeight(1).height(44)
          .backgroundColor("#F5F5F5").borderRadius(22)
          .padding({ left: 16, right: 16 })

        Button(this.atHome ? "发送" : "暂存")
          .fontSize(15).height(44)
          .padding({ left: 16, right: 16 }).borderRadius(22)
          .backgroundColor(this.atHome ? "#1677FF" : "#FF9800")
          .fontColor(Color.White)
          .margin({ left: 10 })
          .enabled(this.inputText.trim().length > 0)
          .onClick(() => { this.send(); })
      }
      .width("100%")
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor("#FFFFFF")
    }
    .width("100%").height("100%")
    .backgroundColor("#FAFAFA")
  }
}
