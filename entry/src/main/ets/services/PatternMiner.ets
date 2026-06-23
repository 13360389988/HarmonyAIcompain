/**
 * PatternMiner.ets
 * ----------------
 * 行为模式挖掘器。
 *
 * 从 behavior_log 表中挖掘规律，自动写入 procedural_memory。
 *
 * 挖掘策略：
 *   1. 时段规律 — "每天 8:00 左右活跃"（作息）
 *   2. 位置规律 — "工作日 9:00-18:00 在公司"（地点）
 *   3. 应用使用规律 — "睡前 30 分钟打开知心"
 *   4. 情绪节奏 — "周一上午情绪偏低"
 *   5. 打字模式 — "压力大时打字速度变慢、删除率高"
 *
 * 触发时机：
 *   - 每天首次启动时
 *   - 累计 50 条新日志时
 */

import { MemoryService } from "./MemoryService";
import { BehaviorLog } from "./MemoryService";

interface PatternCandidate {
  pattern_type: string;       // routine / habit / trigger / rhythm
  description: string;
  trigger_condition?: string;
  action?: string;
  frequency?: string;         // daily / weekly / monthly / irregular
  confidence: number;
  evidence_count: number;
}

export class PatternMiner {
  private memory: MemoryService;
  private lastMineTime: number = 0;
  private readonly MIN_EVIDENCE = 3;        // 至少 3 次证据才算规律
  private readonly MIN_CONFIDENCE = 0.5;    // 最低置信度
  private readonly MINE_INTERVAL = 6 * 60 * 60 * 1000;  // 6 小时挖一次

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  /** 主入口：执行一次挖掘（带频率限制） */
  async mine(): Promise<{ found: number; saved: number }> {
    const now = Date.now();
    if (now - this.lastMineTime < this.MINE_INTERVAL) {
      return { found: 0, saved: 0 };
    }
    this.lastMineTime = now;

    // 取最近 30 天的日志
    const since = now - 30 * 24 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(since, now);

    if (logs.length < 10) {
      return { found: 0, saved: 0 };
    }

    const candidates: PatternCandidate[] = [];

    // 1. 作息规律
    candidates.push(...await this.mineSleepPattern(logs));

    // 2. 位置规律
    candidates.push(...await this.mineLocationPattern(logs));

    // 3. 应用使用规律
    candidates.push(...await this.mineAppUsagePattern(logs));

    // 4. 情绪节奏
    candidates.push(...await this.mineEmotionRhythm(logs));

    // 5. 打字模式
    candidates.push(...await this.mineTypingPattern(logs));

    // 过滤：证据不足或置信度过低
    const valid = candidates.filter(p =>
      p.evidence_count >= this.MIN_EVIDENCE &&
      p.confidence >= this.MIN_CONFIDENCE
    );

    // 写入 procedural_memory（去重：相同 description 不重复写）
    let saved = 0;
    for (const p of valid) {
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

  // ============================================================
  // 1. 作息规律挖掘
  // ============================================================
  private async mineSleepPattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];

    // 按天分组，找出每天的首条/末条日志时间
    const byDay: Map<string, { first?: number; last?: number }> = new Map();
    for (const log of logs) {
      const day = new Date(log.timestamp).toISOString().slice(0, 10);
      if (!byDay.has(day)) byDay.set(day, {});
      const entry = byDay.get(day)!;
      if (entry.first === undefined || log.timestamp < entry.first) {
        entry.first = log.timestamp;
      }
      if (entry.last === undefined || log.timestamp > entry.last) {
        entry.last = log.timestamp;
      }
    }

    // 统计起床时间分布
    const wakeHours: number[] = [];
    for (const [, entry] of byDay) {
      if (entry.first) {
        wakeHours.push(new Date(entry.first).getHours());
      }
    }

    if (wakeHours.length >= this.MIN_EVIDENCE) {
      const avgWake = this.average(wakeHours);
      const stdDev = this.stdDev(wakeHours);
      // 标准差 ≤ 1.5 小时算稳定
      if (stdDev <= 1.5) {
        candidates.push({
          pattern_type: "routine",
          description: `通常在 ${Math.floor(avgWake)}:${Math.round((avgWake % 1) * 60).toString().padStart(2, "0")} 左右开始活动`,
          action: "起床/首次使用手机",
          frequency: "daily",
          confidence: Math.max(0.5, 1 - stdDev / 3),
          evidence_count: wakeHours.length,
        });
      }
    }

    return candidates;
  }

  // ============================================================
  // 2. 位置规律挖掘
  // ============================================================
  private async mineLocationPattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const locationLogs = logs.filter(l => l.action_type === "location" && l.location);

    // 按时段统计位置出现频率
    const slotLocation: Map<string, Map<string, number>> = new Map();
    // 时段：早 6-12 / 午 12-18 / 晚 18-24 / 夜 0-6
    const slots = ["morning", "afternoon", "evening", "night"];

    for (const log of locationLogs) {
      const hour = new Date(log.timestamp).getHours();
      const slot = hour < 6 ? "night" : hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening";
      if (!slotLocation.has(slot)) slotLocation.set(slot, new Map());
      const locMap = slotLocation.get(slot)!;
      const loc = log.location!;
      locMap.set(loc, (locMap.get(loc) ?? 0) + 1);
    }

    // 每个时段出现频率最高的位置
    for (const slot of slots) {
      const locMap = slotLocation.get(slot);
      if (!locMap) continue;
      let topLoc = "";
      let topCount = 0;
      let total = 0;
      for (const [loc, cnt] of locMap) {
        total += cnt;
        if (cnt > topCount) {
          topCount = cnt;
          topLoc = loc;
        }
      }
      // 出现频率 ≥ 60% 才算规律
      if (topCount / total >= 0.6 && topCount >= this.MIN_EVIDENCE) {
        const slotName = { morning: "上午", afternoon: "下午", evening: "晚上", night: "深夜" }[slot];
        candidates.push({
          pattern_type: "routine",
          description: `${slotName}通常在 ${topLoc} 附近活动`,
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

  // ============================================================
  // 3. 应用使用规律
  // ============================================================
  private async mineAppUsagePattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const appStarts = logs.filter(l => l.action_type === "app_start");

    // 按小时统计启动次数
    const byHour: Map<number, number> = new Map();
    for (const log of appStarts) {
      const h = new Date(log.timestamp).getHours();
      byHour.set(h, (byHour.get(h) ?? 0) + 1);
    }

    // 找出启动次数最高的时段
    let topHour = -1;
    let topCount = 0;
    let totalStarts = 0;
    for (const [h, c] of byHour) {
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

  // ============================================================
  // 4. 情绪节奏挖掘
  // ============================================================
  private async mineEmotionRhythm(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const chatLogs = logs.filter(l => l.action_type === "chat");

    // 按星期统计情绪
    const byWeekday: Map<number, { emotions: Map<string, number>; total: number }> = new Map();
    for (const log of chatLogs) {
      try {
        const data = JSON.parse(log.data);
        if (!data.emotion) continue;
        const wd = new Date(log.timestamp).getDay();
        if (!byWeekday.has(wd)) byWeekday.set(wd, { emotions: new Map(), total: 0 });
        const entry = byWeekday.get(wd)!;
        entry.emotions.set(data.emotion, (entry.emotions.get(data.emotion) ?? 0) + 1);
        entry.total++;
      } catch { /* 忽略 */ }
    }

    const weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
    for (const [wd, entry] of byWeekday) {
      if (entry.total < this.MIN_EVIDENCE) continue;
      let topEmotion = "";
      let topCount = 0;
      for (const [e, c] of entry.emotions) {
        if (c > topCount) {
          topCount = c;
          topEmotion = e;
        }
      }
      const ratio = topCount / entry.total;
      // 负面情绪占比高才记录
      const negative = ["焦虑", "疲惫", "低落", "烦躁", "压力", "sad", "anxious", "tired"];
      if (ratio >= 0.5 && negative.some(n => topEmotion.includes(n))) {
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

  // ============================================================
  // 5. 打字模式挖掘
  // ============================================================
  private async mineTypingPattern(logs: BehaviorLog[]): Promise<PatternCandidate[]> {
    const candidates: PatternCandidate[] = [];
    const typingLogs = logs.filter(l => l.action_type === "typing_pattern");

    if (typingLogs.length < this.MIN_EVIDENCE) return candidates;

    // 计算平均打字速度和删除率
    const speeds: number[] = [];
    const deleteRatios: number[] = [];
    for (const log of typingLogs) {
      try {
        const data = JSON.parse(log.data);
        if (data.typing_speed !== undefined) speeds.push(data.typing_speed);
        if (data.delete_ratio !== undefined) deleteRatios.push(data.delete_ratio);
      } catch { /* 忽略 */ }
    }

    if (speeds.length >= this.MIN_EVIDENCE) {
      const avgSpeed = this.average(speeds);
      candidates.push({
        pattern_type: "rhythm",
        description: `平均打字速度 ${avgSpeed.toFixed(1)} 字/秒`,
        action: "打字",
        frequency: "irregular",
        confidence: 0.6,
        evidence_count: speeds.length,
      });
    }

    // 删除率高的场景 = 犹豫/压力
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

  // ============================================================
  // 辅助：检查模式是否已存在
  // ============================================================
  private async patternExists(description: string): Promise<boolean> {
    const all = await this.memory.getAllProcedural();
    return all.some(p => p.description === description);
  }

  // ============================================================
  // 统计辅助
  // ============================================================
  private average(arr: number[]): number {
    if (arr.length === 0) return 0;
    return arr.reduce((a, b) => a + b, 0) / arr.length;
  }

  private stdDev(arr: number[]): number {
    if (arr.length < 2) return 0;
    const avg = this.average(arr);
    const variance = arr.reduce((sum, v) => sum + (v - avg) ** 2, 0) / arr.length;
    return Math.sqrt(variance);
  }
}
