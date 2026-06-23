/**
 * PredictionService.ets
 * ---------------------
 * 预测服务 — 调用后端 /predict 接口，存储预测，验证结果。
 */

import { predictNext, PredictionResult, PatternInfo, RecentBehavior } from "./ApiService";
import { MemoryService, PredictionRecord } from "./MemoryService";

export interface PredictionCard {
  id: number;
  targetTime: string;
  type: string;
  content: string;
  confidence: number;
  reasoning: string;
  status: string;
}

export interface PredictionAccuracyResult {
  total: number;
  verified: number;
  avgError: number;
  accuracy: number;
}

export class PredictionService {
  private memory: MemoryService;

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  async generate(currentLocation: string = ""): Promise<PredictionCard[]> {
    const userProfile = await this.memory.getFullProfile();
    const patterns = await this.memory.getAllProcedural();
    const behaviorPatterns: PatternInfo[] = patterns.slice(0, 10).map(p => ({
      description: p.description,
      confidence: p.confidence ?? 0.5,
    }));

    const now = Date.now();
    const since = now - 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now);
    const recentBehaviors: RecentBehavior[] = logs.slice(-20).map(l => ({
      time: new Date(l.timestamp).toLocaleString(),
      action: `${l.action_type}${l.location ? `@${l.location}` : ""}`,
    }));

    const result: PredictionResult = await predictNext({
      current_time: new Date().toLocaleString(),
      current_location: currentLocation,
      user_profile: userProfile,
      behavior_patterns: behaviorPatterns,
      recent_behaviors: recentBehaviors,
    });

    const cards: PredictionCard[] = [];
    const predictions = result.predictions ?? [];
    for (let i = 0; i < predictions.length; i++) {
      const p = predictions[i];
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

  async verifyPending(): Promise<PredictionAccuracyResult> {
    const pending = await this.memory.getPendingPredictions();
    if (pending.length === 0) return { total: 0, verified: 0, avgError: 0, accuracy: 1 };

    let totalError = 0;
    let count = 0;

    for (let i = 0; i < pending.length; i++) {
      const pred = pending[i];
      const actual = await this.lookupActualResult(pred);
      if (actual === null) continue;

      const error = this.calculateError(pred, actual);
      await this.memory.verifyPrediction(pred.id, actual, error);
      totalError += error;
      count++;
    }

    return {
      total: pending.length,
      verified: count,
      avgError: count > 0 ? totalError / count : 0,
      accuracy: count > 0 ? 1 - totalError / count : 1,
    };
  }

  async getActivePredictions(): Promise<PredictionCard[]> {
    const now = Date.now();
    const pending = await this.memory.getPendingPredictions();
    const result: PredictionCard[] = [];
    for (let i = 0; i < pending.length; i++) {
      const p = pending[i];
      if (p.target_time >= now && result.length < 5) {
        result.push({
          id: p.id,
          targetTime: new Date(p.target_time).toLocaleString(),
          type: p.prediction_type,
          content: p.prediction,
          confidence: p.confidence ?? 0.5,
          reasoning: p.reasoning ?? "",
          status: p.status ?? "pending",
        });
      }
    }
    return result;
  }

  async getAccuracy(): Promise<PredictionAccuracyResult> {
    const stats = await this.memory.getPredictionAccuracy();
    return {
      total: stats.total,
      verified: stats.verified,
      avgError: stats.avgError,
      accuracy: 1 - stats.avgError,
    };
  }

  private async lookupActualResult(pred: PredictionRecord): Promise<string | null> {
    const targetTime = pred.target_time;
    const window = 30 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(
      targetTime - window,
      targetTime + window,
      this.mapTypeToAction(pred.prediction_type)
    );

    if (logs.length === 0) return null;

    let closest = logs[0];
    for (let i = 1; i < logs.length; i++) {
      if (Math.abs(logs[i].timestamp - targetTime) < Math.abs(closest.timestamp - targetTime)) {
        closest = logs[i];
      }
    }

    if (pred.prediction_type === "location") {
      return closest.location ?? "";
    } else if (pred.prediction_type === "behavior") {
      return closest.action_type;
    } else if (pred.prediction_type === "emotion") {
      try {
        const data = JSON.parse(closest.data) as Record<string, string>;
        return data.emotion || "";
      } catch {
        return null;
      }
    }
    return null;
  }

  private mapTypeToAction(type: string): string {
    switch (type) {
      case "location": return "location";
      case "behavior": return "app_start";
      case "emotion": return "chat";
      default: return "";
    }
  }

  private calculateError(pred: PredictionRecord, actual: string): number {
    const expected = pred.prediction.toLowerCase();
    const actualLower = actual.toLowerCase();

    if (expected.includes(actualLower) || actualLower.includes(expected)) {
      return 0;
    }

    const expectedWords = expected.split(/[\s,，。.]+/).filter(w => w.length > 1);
    const actualWords = actualLower.split(/[\s,，。.]+/).filter(w => w.length > 1);
    if (expectedWords.length === 0 || actualWords.length === 0) return 0.8;

    let overlap = 0;
    for (let i = 0; i < expectedWords.length; i++) {
      for (let j = 0; j < actualWords.length; j++) {
        if (actualWords[j].includes(expectedWords[i]) || expectedWords[i].includes(actualWords[j])) {
          overlap++;
          break;
        }
      }
    }
    const maxLen = expectedWords.length > actualWords.length ? expectedWords.length : actualWords.length;
    const ratio = overlap / maxLen;
    return 1 - ratio;
  }

  private parseTime(timeStr: string): number {
    const t = Date.parse(timeStr);
    return isNaN(t) ? Date.now() + 3600000 : t;
  }
}
