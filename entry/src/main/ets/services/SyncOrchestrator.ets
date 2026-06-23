/**
 * SyncOrchestrator.ets
 * --------------------
 * 同步编排器 — 回到宿舍（后端可达）后，自动批量处理所有积压任务。
 *
 * 触发时机：
 *   1. HomeDetector 检测到回到宿舍
 *   2. 应用启动时如果在宿舍
 *   3. 用户手动触发
 *
 * 执行的批量任务（按顺序）：
 *   ① 同步离线消息队列 → 每条消息调 LLM → 提取画像/事件/人物
 *   ② 挖掘行为模式（PatternMiner）
 *   ③ 验证历史预测（PredictionService.verifyPending）
 *   ④ 生成新一轮预测
 *   ⑤ 上传同步摘要（SyncService）
 *   ⑥ 触发主动关怀检查
 *
 * 所有任务串行执行，避免并发压垮后端。
 * 每个任务独立 try-catch，单个失败不影响其他。
 */

import { MemoryService } from "./MemoryService";
import { OfflineQueue, OfflineMessage } from "./OfflineQueue";
import { PatternMiner } from "./PatternMiner";
import { PredictionService } from "./PredictionService";
import { SyncService } from "./SyncService";
import { sendChatWithContext, ChatResult } from "./ApiService";

export interface SyncProgress {
  step: string;
  current: number;
  total: number;
  detail: string;
}

export type SyncProgressCallback = (progress: SyncProgress) => void;

export class SyncOrchestrator {
  private memory: MemoryService;
  private offlineQueue: OfflineQueue;
  private patternMiner: PatternMiner;
  private predictionService: PredictionService;
  private syncService: SyncService;
  private onProgress: SyncProgressCallback | null = null;
  private isRunning: boolean = false;
  private lastSyncTime: number = 0;
  private readonly MIN_INTERVAL = 5 * 60 * 1000;  // 最少间隔 5 分钟

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

  /** 设置进度回调 */
  setProgressCallback(cb: SyncProgressCallback): void {
    this.onProgress = cb;
  }

  /** 是否正在同步 */
  getIsRunning(): boolean {
    return this.isRunning;
  }

  /** 上次同步时间 */
  getLastSyncTime(): number {
    return this.lastSyncTime;
  }

  /**
   * 触发完整同步（回到宿舍时调用）
   * @returns 同步结果摘要
   */
  async triggerFullSync(): Promise<{
    messagesSynced: number;
    patternsMined: number;
    predictionsVerified: number;
    newPredictions: number;
    syncUploaded: boolean;
    errors: string[];
  }> {
    // 防止重复触发
    if (this.isRunning) {
      return { messagesSynced: 0, patternsMined: 0, predictionsVerified: 0, newPredictions: 0, syncUploaded: false, errors: ["已有同步在进行中"] };
    }

    // 频率限制
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
      // ============================================================
      // ① 同步离线消息队列（最核心）
      // ============================================================
      this.report("正在同步离线消息", 0, 1, "获取队列");
      const pending: OfflineMessage[] = await this.offlineQueue.getAll();

      if (pending.length > 0) {
        this.report("正在同步离线消息", 0, pending.length, `共 ${pending.length} 条`);

        for (let i = 0; i < pending.length; i++) {
          const msg = pending[i];
          this.report("正在同步离线消息", i + 1, pending.length, msg.text.slice(0, 20));

          try {
            // 打包上下文
            const ctx = await this.buildContext(msg.text);
            // 调用后端
            const result: ChatResult = await sendChatWithContext(ctx);
            // 处理提取结果，写入记忆
            await this.processExtracted(msg.text, result.reply, result.extracted);
            // 从队列移除
            await this.offlineQueue.remove(msg.id);
            messagesSynced++;
          } catch (e) {
            errors.push(`消息 ${msg.id} 同步失败: ${(e as Error).message}`);
            // 失败的消息保留在队列，下次再试
          }
        }
      }

      // ============================================================
      // ② 挖掘行为模式
      // ============================================================
      this.report("正在挖掘行为模式", 0, 1, "分析日志");
      try {
        const mineResult = await this.patternMiner.mine();
        patternsMined = mineResult.saved;
      } catch (e) {
        errors.push(`行为模式挖掘失败: ${(e as Error).message}`);
      }

      // ============================================================
      // ③ 验证历史预测
      // ============================================================
      this.report("正在验证历史预测", 0, 1, "对比实际行为");
      try {
        const verifyResult = await this.predictionService.verifyPending();
        predictionsVerified = verifyResult.verified;
      } catch (e) {
        errors.push(`预测验证失败: ${(e as Error).message}`);
      }

      // ============================================================
      // ④ 生成新一轮预测
      // ============================================================
      this.report("正在生成预测", 0, 1, "基于最新数据");
      try {
        const cards = await this.predictionService.generate();
        newPredictions = cards.length;
      } catch (e) {
        errors.push(`预测生成失败: ${(e as Error).message}`);
      }

      // ============================================================
      // ⑤ 上传同步摘要
      // ============================================================
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

      // ============================================================
      // ⑥ 记录同步完成
      // ============================================================
      this.lastSyncTime = Date.now();
      await this.memory.logBehavior("sync_complete", {
        messages_synced: messagesSynced,
        patterns_mined: patternsMined,
        predictions_verified: predictionsVerified,
        new_predictions: newPredictions,
        sync_uploaded: syncUploaded,
        errors: errors.length,
      });

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

  // ============================================================
  // 辅助：打包上下文（与 Index.ets 中的逻辑一致）
  // ============================================================
  private async buildContext(userMessage: string): Promise<any> {
    const userProfile = await this.memory.getFullProfile();
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
    const topEpisodes = await this.memory.getTopEpisodic(5);
    const relevantEpisodes = topEpisodes.map(e => ({
      title: e.title,
      description: e.description ?? "",
      time: new Date(e.event_time).toLocaleString(),
    }));
    const patterns = await this.memory.getAllProcedural();
    const behaviorPatterns = patterns.slice(0, 5).map(p => ({
      description: p.description,
      confidence: p.confidence ?? 0.5,
    }));
    const relations = await this.memory.getAllRelations();
    const relationList = relations.slice(0, 10).map(r => ({
      name: r.person_name,
      relation: r.relation_type ?? "acquaintance",
      mentions: r.mention_count ?? 1,
    }));

    return {
      message: userMessage,
      current_time: new Date().toLocaleString(),
      current_location: "",
      user_profile: userProfile,
      recent_conversations: recentConversations,
      relevant_episodes: relevantEpisodes,
      behavior_patterns: behaviorPatterns,
      relations: relationList,
    };
  }

  /** 处理 LLM 提取结果，写入对应记忆层 */
  private async processExtracted(
    userMessage: string,
    aiReply: string,
    extracted: ChatResult["extracted"]
  ): Promise<void> {
    // 写入短期记忆
    await this.memory.addShortTerm({
      role: "user",
      content: userMessage,
      emotion: extracted.emotion,
    });
    await this.memory.addShortTerm({
      role: "assistant",
      content: aiReply,
    });

    // 记录行为日志
    await this.memory.logBehavior("chat", {
      user_msg: userMessage,
      ai_reply: aiReply,
      emotion: extracted.emotion,
      synced: true,
    });

    // 更新语义记忆
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

    // 写入情景记忆
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

    // 更新关系网络
    if (extracted.persons) {
      for (const p of extracted.persons) {
        await this.memory.mentionPerson(p.name, p.relation, p.sentiment ?? 0);
      }
    }
  }

  private report(step: string, current: number, total: number, detail: string): void {
    if (this.onProgress) {
      this.onProgress({ step, current, total, detail });
    }
  }
}
