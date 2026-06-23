/**
 * SyncOrchestrator.ets
 * --------------------
 * 同步协调器 — 编排离线队列同步、模式挖掘、预测验证、云端同步。
 */

import { MemoryService } from "./MemoryService";
import { OfflineQueue, OfflineMessage } from "./OfflineQueue";
import { PatternMiner } from "./PatternMiner";
import { PredictionService, PredictionCard } from "./PredictionService";
import { SyncService } from "./SyncService";
import { sendChatWithContext, ChatContext, ChatResult, ConversationPair, EpisodeInfo, PatternInfo, RelationInfo, ExtractedData } from "./ApiService";

export interface SyncProgress {
  step: string;
  current: number;
  total: number;
  detail: string;
}

export type SyncProgressCallback = (progress: SyncProgress) => void;

export interface SyncLogData {
  messages_synced: number;
  patterns_mined: number;
  predictions_verified: number;
  new_predictions: number;
  sync_uploaded: boolean;
  errors: number;
}

export interface ChatLogData {
  user_msg: string;
  ai_reply: string;
  emotion: string;
  synced: boolean;
}

export interface SyncFullResult {
  messagesSynced: number;
  patternsMined: number;
  predictionsVerified: number;
  newPredictions: number;
  syncUploaded: boolean;
  errors: string[];
}

export class SyncOrchestrator {
  private memory: MemoryService;
  private offlineQueue: OfflineQueue;
  private patternMiner: PatternMiner;
  private predictionService: PredictionService;
  private syncService: SyncService;
  private onProgress: SyncProgressCallback | null = null;
  private isRunning: boolean = false;
  private lastSyncTime: number = 0;
  private readonly MIN_INTERVAL: number = 5 * 60 * 1000;

  constructor(
    memory: MemoryService,
    offlineQueue: OfflineQueue,
    patternMiner: PatternMiner,
    predictionService: PredictionService,
    syncService: SyncService
  ) {
    this.memory = memory;
    this.offlineQueue = offlineQueue;
    this.patternMiner = patternMiner;
    this.predictionService = predictionService;
    this.syncService = syncService;
  }

  setProgressCallback(cb: SyncProgressCallback): void {
    this.onProgress = cb;
  }

  getIsRunning(): boolean {
    return this.isRunning;
  }

  getLastSyncTime(): number {
    return this.lastSyncTime;
  }

  async triggerFullSync(): Promise<SyncFullResult> {
    if (this.isRunning) {
      return { messagesSynced: 0, patternsMined: 0, predictionsVerified: 0, newPredictions: 0, syncUploaded: false, errors: ["已有同步在进行中"] };
    }

    if (Date.now() - this.lastSyncTime < this.MIN_INTERVAL) {
      return { messagesSynced: 0, patternsMined: 0, predictionsVerified: 0, newPredictions: 0, syncUploaded: false, errors: ["距上次同步不足 5 分钟，跳过"] };
    }

    this.isRunning = true;
    const errors: string[] = [];
    let messagesSynced = 0;
    let patternsMined = 0;
    let predictionsVerified = 0;
    let newPredictions = 0;
    let syncUploaded = false;

    try {
      this.report("正在同步离线消息", 0, 1, "获取队列");
      const pending: OfflineMessage[] = await this.offlineQueue.getAll();

      if (pending.length > 0) {
        this.report("正在同步离线消息", 0, pending.length, `共 ${pending.length} 条`);

        for (let i = 0; i < pending.length; i++) {
          const msg = pending[i];
          this.report("正在同步离线消息", i + 1, pending.length, msg.text.slice(0, 20));

          try {
            const ctx = await this.buildContext(msg.text);
            const result: ChatResult = await sendChatWithContext(ctx);
            await this.processExtracted(msg.text, result.reply, result.extracted);
            await this.offlineQueue.remove(msg.id);
            messagesSynced++;
          } catch (e) {
            errors.push(`消息 ${msg.id} 同步失败: ${(e as Error).message}`);
          }
        }
      }

      this.report("正在挖掘行为模式", 0, 1, "分析日志");
      try {
        const mineResult = await this.patternMiner.mine();
        patternsMined = mineResult.saved;
      } catch (e) {
        errors.push(`行为模式挖掘失败: ${(e as Error).message}`);
      }

      this.report("正在验证历史预测", 0, 1, "对比实际行为");
      try {
        const verifyResult = await this.predictionService.verifyPending();
        predictionsVerified = verifyResult.verified;
      } catch (e) {
        errors.push(`预测验证失败: ${(e as Error).message}`);
      }

      this.report("正在生成预测", 0, 1, "基于最新数据");
      try {
        const cards = await this.predictionService.generate();
        newPredictions = cards.length;
      } catch (e) {
        errors.push(`预测生成失败: ${(e as Error).message}`);
      }

      this.report("正在上传同步摘要", 0, 1, "加密上传");
      try {
        const syncResult = await this.syncService.upload();
        syncUploaded = syncResult.success;
        if (!syncResult.success && syncResult.error) {
          errors.push(`同步上传失败: ${syncResult.error}`);
        }
      } catch (e) {
        errors.push(`同步上传失败: ${(e as Error).message}`);
      }

      this.lastSyncTime = Date.now();
      const logData: SyncLogData = {
        messages_synced: messagesSynced,
        patterns_mined: patternsMined,
        predictions_verified: predictionsVerified,
        new_predictions: newPredictions,
        sync_uploaded: syncUploaded ? 1 : 0,
        errors: errors.length,
      };
      await this.memory.logBehavior("sync_complete", logData);

      this.report("同步完成", 1, 1, `消息${messagesSynced} 模式${patternsMined} 预测${newPredictions}`);

    } finally {
      this.isRunning = false;
    }

    return {
      messagesSynced,
      patternsMined,
      predictionsVerified,
      newPredictions,
      syncUploaded,
      errors,
    };
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
      relevantEpisodes.push({
        title: e.title,
        description: e.description || "",
        time: new Date(e.event_time).toLocaleString(),
      });
    }
    const patterns = await this.memory.getAllProcedural();
    const behaviorPatterns: PatternInfo[] = [];
    for (let i = 0; i < patterns.length && i < 5; i++) {
      behaviorPatterns.push({
        description: patterns[i].description,
        confidence: patterns[i].confidence || 0.5,
      });
    }
    const relations = await this.memory.getAllRelations();
    const relationList: RelationInfo[] = [];
    for (let i = 0; i < relations.length && i < 10; i++) {
      relationList.push({
        name: relations[i].person_name,
        relation: relations[i].relation_type || "acquaintance",
        mentions: relations[i].mention_count || 1,
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
      location: "",
    });
    await this.memory.addShortTerm({
      role: "assistant",
      content: aiReply,
      emotion: "",
      location: "",
    });

    const chatLogData: ChatLogData = {
      user_msg: userMessage,
      ai_reply: aiReply,
      emotion: extracted.emotion || "",
      synced: true,
    };
    await this.memory.logBehavior("chat", chatLogData);

    if (extracted.profile_updates) {
      for (let i = 0; i < extracted.profile_updates.length; i++) {
        const p = extracted.profile_updates[i];
        await this.memory.setSemantic({
          category: p.category,
          key: p.key,
          value: p.value,
          confidence: p.confidence || 0.5,
          source: "chat",
        });
      }
    }

    if (extracted.episodes) {
      for (let i = 0; i < extracted.episodes.length; i++) {
        const e = extracted.episodes[i];
        await this.memory.addEpisodic({
          event_time: Date.now(),
          title: e.title,
          description: e.description,
          importance: e.importance || 0.5,
          people: e.people ? JSON.stringify(e.people) : "",
          outcome: e.outcome,
          emotion: extracted.emotion,
          location: "",
          embedding_id: "",
        });
      }
    }

    if (extracted.persons) {
      for (let i = 0; i < extracted.persons.length; i++) {
        const p = extracted.persons[i];
        await this.memory.mentionPerson(p.name, p.relation, p.sentiment || 0);
      }
    }
  }

  private report(step: string, current: number, total: number, detail: string): void {
    if (this.onProgress) {
      this.onProgress({ step, current, total, detail });
    }
  }
}
