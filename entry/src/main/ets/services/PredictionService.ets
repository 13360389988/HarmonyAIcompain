/**
 * PredictionService.ets
 * ---------------------
 * 预测服务 — 调用后端 /predict 接口，存储预测，验证结果。
 *
 * 工作流：
 *   1. generate() — 打包上下文，调用后端，存入 prediction_memory
 *   2. verifyPending() — 检查待验证预测，对比实际行为，计算误差
 *   3. getActivePredictions() — 获取当前生效的预测（用于 UI 展示）
 */

import { predictNext, PredictionResult } from "./ApiService";
import { MemoryService, PredictionRecord } from "./MemoryService";

export interface PredictionCard {
  id: number;
  targetTime: string;       // 显示用
  type: string;             // location / behavior / emotion
  content: string;
  confidence: number;       // 0-1
  reasoning: string;
  status: "pending" | "verified" | "failed";
}

export class PredictionService {
  private memory: MemoryService;

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  /** 生成新一轮预测（每次对话后或定时触发） */
  async generate(currentLocation: string = ""): Promise<PredictionCard[]> {
    // 1. 打包上下文
    const userProfile = await this.memory.getFullProfile();
    const patterns = await this.memory.getAllProcedural();
    const behaviorPatterns = patterns.slice(0, 10).map(p => ({
      description: p.description,
      confidence: p.confidence ?? 0.5,
    }));

    // 2. 取最近 24h 行为日志
    const now = Date.now();
    const since = now - 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now);
    const recentBehaviors = logs.slice(-20).map(l => ({
      time: new Date(l.timestamp).toLocaleString(),
      action: `${l.action_type}${l.location ? `@${l.location}` : ""}`,
    }));

    // 3. 调用后端
    const result: PredictionResult = await predictNext({
      current_time: new Date().toLocaleString(),
      current_location: currentLocation,
      user_profile: userProfile,
      behavior_patterns: behaviorPatterns,
      recent_behaviors: recentBehaviors,
    });

    // 4. 存入 prediction_memory
    const cards: PredictionCard[] = [];
    for (const p of result.predictions ?? []) {
      const targetTime = this.parseTime(p.target_time);
      const id = await this.memory.addPrediction({
        predicted_at: now,
        target_time: targetTime,
        prediction_type: p.prediction_type,
        prediction: p.prediction,
        confidence: p.confidence,
        reasoning: p.reasoning,
        status: "pending",
      });
      cards.push({
        id,
        targetTime: p.target_time,
        type: p.prediction_type,
        content: p.prediction,
        confidence: p.confidence,
        reasoning: p.reasoning,
        status: "pending",
      });
    }

    return cards;
  }

  /** 验证所有待验证的预测（target_time 已到） */
  async verifyPending(): Promise<{ verified: number; avgError: number }> {
    const pending = await this.memory.getPendingPredictions();
    if (pending.length === 0) return { verified: 0, avgError: 0 };

    let totalError = 0;
    let count = 0;

    for (const pred of pending) {
      const actual = await this.lookupActualResult(pred);
      if (actual === null) continue;  // 暂时无法验证

      // 误差分数：0=完全正确，1=完全错误
      const error = this.calculateError(pred, actual);
      await this.memory.verifyPrediction(pred.id!, actual, error);
      totalError += error;
      count++;
    }

    return {
      verified: count,
      avgError: count > 0 ? totalError / count : 0,
    };
  }

  /** 获取当前生效的预测（未到目标时间 + 未验证） */
  async getActivePredictions(): Promise<PredictionCard[]> {
    const now = Date.now();
    // 取未来 24h 内的待验证预测
    const all = await this.memory.getPredictionAccuracy();
    // 注意：MemoryService 没有直接查询"未来预测"的方法，这里用行为日志范围查询的思路
    // 简化处理：取最近 10 条 pending 预测
    const pending = await this.memory.getPendingPredictions();
    // 过滤掉已过期的（target_time < now 的应该已被 verifyPending 处理）
    return pending
      .filter(p => p.target_time >= now)
      .slice(0, 5)
      .map(p => ({
        id: p.id!,
        targetTime: new Date(p.target_time).toLocaleString(),
        type: p.prediction_type,
        content: p.prediction,
        confidence: p.confidence ?? 0.5,
        reasoning: p.reasoning ?? "",
        status: p.status as "pending" | "verified" | "failed",
      }));
  }

  /** 获取历史预测准确率 */
  async getAccuracy(): Promise<{ total: number; avgError: number; accuracy: number }> {
    const stats = await this.memory.getPredictionAccuracy();
    return {
      total: stats.total,
      avgError: stats.avgError,
      accuracy: 1 - stats.avgError,  // 准确率 = 1 - 误差
    };
  }

  // ============================================================
  // 私有：查询实际结果
  // ============================================================
  private async lookupActualResult(pred: PredictionRecord): Promise<string | null> {
    // 根据 prediction_type 查询对应的行为日志
    const targetTime = pred.target_time;
    // 取目标时间前后 30 分钟的日志
    const window = 30 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(
      targetTime - window,
      targetTime + window,
      this.mapTypeToAction(pred.prediction_type)
    );

    if (logs.length === 0) return null;

    // 取最接近目标时间的那条
    const closest = logs.reduce((best, l) =>
      Math.abs(l.timestamp - targetTime) < Math.abs(best.timestamp - targetTime) ? l : best
    );

    if (pred.prediction_type === "location") {
      return closest.location ?? "";
    } else if (pred.prediction_type === "behavior") {
      return closest.action_type;
    } else if (pred.prediction_type === "emotion") {
      try {
        const data = JSON.parse(closest.data);
        return data.emotion ?? "";
      } catch {
        return null;
      }
    }
    return null;
  }

  private mapTypeToAction(type: string): string | undefined {
    switch (type) {
      case "location": return "location";
      case "behavior": return "app_start";
      case "emotion": return "chat";
      default: return undefined;
    }
  }

  /** 计算误差分数（0=完全正确，1=完全错误） */
  private calculateError(pred: PredictionRecord, actual: string): number {
    const expected = pred.prediction.toLowerCase();
    const actualLower = actual.toLowerCase();

    // 简单的字符串包含匹配
    if (expected.includes(actualLower) || actualLower.includes(expected)) {
      return 0;  // 完全匹配
    }

    // 关键词重叠度
    const expectedWords = expected.split(/[\s,，。.]+/).filter(w => w.length > 1);
    const actualWords = actualLower.split(/[\s,，。.]+/).filter(w => w.length > 1);
    if (expectedWords.length === 0 || actualWords.length === 0) return 0.8;

    let overlap = 0;
    for (const w of expectedWords) {
      if (actualWords.some(aw => aw.includes(w) || w.includes(aw))) {
        overlap++;
      }
    }
    const ratio = overlap / Math.max(expectedWords.length, actualWords.length);
    return 1 - ratio;
  }

  private parseTime(timeStr: string): number {
    const t = Date.parse(timeStr);
    return isNaN(t) ? Date.now() + 3600_000 : t;  // 解析失败默认 1 小时后
  }
}
