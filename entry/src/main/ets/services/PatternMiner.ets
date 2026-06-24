/**
 * PatternMiner.ets
 * ----------------
 * 行为模式挖掘器。
 */

import { MemoryService, BehaviorLog } from "./MemoryService";

export interface PatternCandidate {
  pattern_type: string;
  description: string;
  trigger_condition: string;
  action: string;
  frequency: string;
  confidence: number;
  evidence_count: number;
}

export interface MineResult {
  found: number;
  saved: number;
}

interface DayEntry {
  first: number;
  last: number;
}

interface WeekdayEntry {
  emotions: Map<string, number>;
  total: number;
}

interface SlotDisplayName {
  morning: string;
  afternoon: string;
  evening: string;
  night: string;
}

export class PatternMiner {
  private memory: MemoryService;
  private lastMineTime: number = 0;
  private readonly MIN_EVIDENCE: number = 3;
  private readonly MIN_CONFIDENCE: number = 0.5;
  private readonly MINE_INTERVAL: number = 6 * 60 * 60 * 1000;

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  async mine(): Promise<MineResult> {
    const now = Date.now();
    if (now - this.lastMineTime < this.MINE_INTERVAL) {
      return { found: 0, saved: 0 };
    }
    this.lastMineTime = now;

    const since = now - 30 * 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now);

    if (logs.length < 10) {
      return { found: 0, saved: 0 };
    }

    const candidates: PatternCandidate[] = [];

    const sleepCandidates = await this.mineSleepPattern(logs);
    for (let i = 0; i < sleepCandidates.length; i++) {
      candidates.push(sleepCandidates[i]);
    }

    const locationCandidates = await this.mineLocationPattern(logs);
    for (let i = 0; i < locationCandidates.length; i++) {
      candidates.push(locationCandidates[i]);
    }

    const appCandidates = await this.mineAppUsagePattern(logs);
    for (let i = 0; i < appCandidates.length; i++) {
      candidates.push(appCandidates[i]);
    }

    const emotionCandidates = await this.mineEmotionRhythm(logs);
    for (let i = 0; i < emotionCandidates.length; i++) {
      candidates.push(emotionCandidates[i]);
    }

    const typingCandidates = await this.mineTypingPattern(logs);
    for (let i = 0; i < typingCandidates.length; i++) {
      candidates.push(typingCandidates[i]);
    }

    const valid: PatternCandidate[] = [];
    for (let i = 0; i < candidates.length; i++) {
      const p = candidates[i];
      if (p.evidence_count >= this.MIN_EVIDENCE && p.confidence >= this.MIN_CONFIDENCE) {
        valid.push(p);
      }
    }

    let saved = 0;
    for (let i = 0; i < valid.length; i++) {
      const p = valid[i];
      const exists = await this.patternExists(p.description);
      if (!exists) {
        await this.memory.addProcedural({
          pattern_type: p.pattern_type,
          description: p.description,
          trigger_condition: p.trigger_condition,
          action: p.action,
          frequency: p.frequency,
          confidence: p.confidence,
          trigger_count: p.evidence_count,
        });
        saved++;
      }
    }

    return { found: valid.length, saved };
  }

  private async mineSleepPattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];

    const byDay: Map<string, DayEntry> = new Map();
    for (let i = 0; i < logs.length; i++) {
      const log = logs[i];
      const day = new Date(log.timestamp).toISOString().slice(0, 10);
      if (!byDay.has(day)) {
        byDay.set(day, { first: 0, last: 0 });
      }
      const entry = byDay.get(day)!;
      if (entry.first === 0 || log.timestamp < entry.first) {
        entry.first = log.timestamp;
      }
      if (entry.last === 0 || log.timestamp > entry.last) {
        entry.last = log.timestamp;
      }
    }

    const wakeHours: number[] = [];
    const entries = Array.from(byDay.values());
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (entry.first > 0) {
        wakeHours.push(new Date(entry.first).getHours());
      }
    }

    if (wakeHours.length >= this.MIN_EVIDENCE) {
      const avgWake = this.average(wakeHours);
      const stdDev = this.stdDev(wakeHours);
      if (stdDev <= 1.5) {
        candidates.push({
          pattern_type: "routine",
          description: `通常在 ${Math.floor(avgWake)}:${Math.round((avgWake % 1) * 60).toString().padStart(2, "0")} 左右开始活动`,
          trigger_condition: "",
          action: "起床/首次使用手机",
          frequency: "daily",
          confidence: Math.max(0.5, 1 - stdDev / 3),
          evidence_count: wakeHours.length,
        });
      }
    }

    return candidates;
  }

  private async mineLocationPattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const locationLogs: BehaviorLog[] = [];
    for (let i = 0; i < logs.length; i++) {
      if (logs[i].action_type === "location" && logs[i].location) {
        locationLogs.push(logs[i]);
      }
    }

    const slotLocation: Map<string, Map<string, number>> = new Map();
    const slotNames = ["morning", "afternoon", "evening", "night"];

    for (let i = 0; i < locationLogs.length; i++) {
      const log = locationLogs[i];
      const hour = new Date(log.timestamp).getHours();
      const slot = hour < 6 ? "night" : hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening";
      if (!slotLocation.has(slot)) slotLocation.set(slot, new Map());
      const locMap = slotLocation.get(slot)!;
      const loc = log.location!;
      const prev = locMap.get(loc) ?? 0;
      locMap.set(loc, prev + 1);
    }

    const slotDisplay: SlotDisplayName = {
      morning: "上午",
      afternoon: "下午",
      evening: "晚上",
      night: "深夜",
    };

    for (let s = 0; s < slotNames.length; s++) {
      const slot = slotNames[s];
      const locMap = slotLocation.get(slot);
      if (!locMap) continue;
      let topLoc = "";
      let topCount = 0;
      let total = 0;
      const entries = Array.from(locMap.entries());
      for (let i = 0; i < entries.length; i++) {
        const loc = entries[i][0];
        const cnt = entries[i][1];
        total += cnt;
        if (cnt > topCount) {
          topCount = cnt;
          topLoc = loc;
        }
      }
      if (topCount / total >= 0.6 && topCount >= this.MIN_EVIDENCE) {
        let slotDisplayText = "";
        if (slot === "morning") slotDisplayText = "上午";
        else if (slot === "afternoon") slotDisplayText = "下午";
        else if (slot === "evening") slotDisplayText = "晚上";
        else if (slot === "night") slotDisplayText = "深夜";
        candidates.push({
          pattern_type: "routine",
          description: `${slotDisplayText}通常在 ${topLoc} 附近活动`,
          trigger_condition: `时段=${slot}`,
          action: `位置=${topLoc}`,
          frequency: "daily",
          confidence: topCount / total,
          evidence_count: topCount,
        });
      }
    }

    return candidates;
  }

  private async mineAppUsagePattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const appStarts: BehaviorLog[] = [];
    for (let i = 0; i < logs.length; i++) {
      if (logs[i].action_type === "app_start") {
        appStarts.push(logs[i]);
      }
    }

    const byHour: Map<number, number> = new Map();
    for (let i = 0; i < appStarts.length; i++) {
      const h = new Date(appStarts[i].timestamp).getHours();
      const prev = byHour.get(h) ?? 0;
      byHour.set(h, prev + 1);
    }

    let topHour = -1;
    let topCount = 0;
    let totalStarts = 0;
    const hourEntries = Array.from(byHour.entries());
    for (let i = 0; i < hourEntries.length; i++) {
      const h = hourEntries[i][0];
      const c = hourEntries[i][1];
      totalStarts += c;
      if (c > topCount) {
        topCount = c;
        topHour = h;
      }
    }

    if (topCount >= this.MIN_EVIDENCE && totalStarts > 0) {
      const ratio = topCount / totalStarts;
      if (ratio >= 0.2) {
        candidates.push({
          pattern_type: "habit",
          description: `经常在 ${topHour}:00 左右打开知心`,
          trigger_condition: `时间=${topHour}:00`,
          action: "打开应用",
          frequency: "daily",
          confidence: Math.min(0.9, ratio + 0.2),
          evidence_count: topCount,
        });
      }
    }

    return candidates;
  }

  private async mineEmotionRhythm(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const chatLogs: BehaviorLog[] = [];
    for (let i = 0; i < logs.length; i++) {
      if (logs[i].action_type === "chat") {
        chatLogs.push(logs[i]);
      }
    }

    const byWeekday: Map<number, WeekdayEntry> = new Map();
    for (let i = 0; i < chatLogs.length; i++) {
      try {
        const data = JSON.parse(chatLogs[i].data) as Record<string, string>;
        if (!data.emotion) continue;
        const wd = new Date(chatLogs[i].timestamp).getDay();
        if (!byWeekday.has(wd)) {
          byWeekday.set(wd, { emotions: new Map(), total: 0 });
        }
        const entry = byWeekday.get(wd)!;
        const prev = entry.emotions.get(data.emotion) ?? 0;
        entry.emotions.set(data.emotion, prev + 1);
        entry.total++;
      } catch { /* 忽略 */ }
    }

    const weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
    const negative = ["焦虑", "疲惫", "低落", "烦躁", "压力", "sad", "anxious", "tired"];

    const wdEntries = Array.from(byWeekday.entries());
    for (let i = 0; i < wdEntries.length; i++) {
      const wd = wdEntries[i][0];
      const entry = wdEntries[i][1];
      if (entry.total < this.MIN_EVIDENCE) continue;
      let topEmotion = "";
      let topCount = 0;
      const emotionEntries = Array.from(entry.emotions.entries());
      for (let j = 0; j < emotionEntries.length; j++) {
        const e = emotionEntries[j][0];
        const c = emotionEntries[j][1];
        if (c > topCount) {
          topCount = c;
          topEmotion = e;
        }
      }
      const ratio = topCount / entry.total;
      let isNegative = false;
      for (let n = 0; n < negative.length; n++) {
        if (topEmotion.includes(negative[n])) {
          isNegative = true;
          break;
        }
      }
      if (ratio >= 0.5 && isNegative) {
        candidates.push({
          pattern_type: "rhythm",
          description: `${weekdayNames[wd]}情绪常为"${topEmotion}"`,
          trigger_condition: `星期=${wd}`,
          action: `情绪=${topEmotion}`,
          frequency: "weekly",
          confidence: ratio,
          evidence_count: entry.total,
        });
      }
    }

    return candidates;
  }

  private async mineTypingPattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const typingLogs: BehaviorLog[] = [];
    for (let i = 0; i < logs.length; i++) {
      if (logs[i].action_type === "typing_pattern") {
        typingLogs.push(logs[i]);
      }
    }

    if (typingLogs.length < this.MIN_EVIDENCE) return candidates;

    const speeds: number[] = [];
    const deleteRatios: number[] = [];
    for (let i = 0; i < typingLogs.length; i++) {
      try {
        const data = JSON.parse(typingLogs[i].data) as Record<string, number>;
        if (data.typing_speed !== undefined) speeds.push(data.typing_speed);
        if (data.delete_ratio !== undefined) deleteRatios.push(data.delete_ratio);
      } catch { /* 忽略 */ }
    }

    if (speeds.length >= this.MIN_EVIDENCE) {
      const avgSpeed = this.average(speeds);
      candidates.push({
        pattern_type: "rhythm",
        description: `平均打字速度 ${avgSpeed.toFixed(1)} 字/秒`,
        trigger_condition: "",
        action: "打字",
        frequency: "irregular",
        confidence: 0.6,
        evidence_count: speeds.length,
      });
    }

    if (deleteRatios.length >= this.MIN_EVIDENCE) {
      const avgRatio = this.average(deleteRatios);
      if (avgRatio > 0.2) {
        candidates.push({
          pattern_type: "trigger",
          description: `打字时删除率偏高（${(avgRatio * 100).toFixed(0)}%），可能存在犹豫或压力`,
          trigger_condition: "打字时",
          action: "高删除率",
          frequency: "irregular",
          confidence: 0.6,
          evidence_count: deleteRatios.length,
        });
      }
    }

    return candidates;
  }

  private async patternExists(description: string): Promise<boolean> {
    const all = await this.memory.getAllProcedural();
    for (let i = 0; i < all.length; i++) {
      if (all[i].description === description) return true;
    }
    return false;
  }

  private average(arr: number[]): number {
    if (arr.length === 0) return 0;
    let sum = 0;
    for (let i = 0; i < arr.length; i++) {
      sum += arr[i];
    }
    return sum / arr.length;
  }

  private stdDev(arr: number[]): number {
    if (arr.length < 2) return 0;
    const avg = this.average(arr);
    let variance = 0;
    for (let i = 0; i < arr.length; i++) {
      variance += (arr[i] - avg) ** 2;
    }
    variance /= arr.length;
    return Math.sqrt(variance);
  }
}
