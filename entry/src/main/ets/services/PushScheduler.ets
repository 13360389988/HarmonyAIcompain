/**
 * PushScheduler.ets
 * -----------------
 * 增强推送系统 — 高频多类型主动推送。
 *
 * 推送类型：
 *   1. 预测推送  — "我猜你接下来要去健身房"
 *   2. 督促推送  — "你说过要写报告，进展如何？"
 *   3. 提醒推送  — "明天有小李的会议"
 *   4. 关怀推送  — "今天情绪有点低，要不要聊聊？"
 *   5. 作息提醒  — "已经 23:00 了，该休息了"
 *   6. 行为异常  — "你今天还没运动"
 *
 * 推送频率（系统级 reminderAgent，不耗电）：
 *   08:00  早安 + 今日预测
 *   10:30  上午督促/提醒
 *   12:30  午间关怀
 *   15:00  下午督促
 *   18:00  傍晚预测
 *   21:00  晚间复盘提醒
 *   23:00  作息提醒
 */

import reminderAgent from "@ohos.reminderAgentManager";
import notificationManager from "@ohos.notificationManager";
import { MemoryService } from "./MemoryService";
import { PredictionService } from "./PredictionService";
import { generateMorningGreeting, generateEveningReview, predictNext } from "./ApiService";

// 推送类型枚举
export type PushType =
  | "morning"        // 早安
  | "prediction"     // 预测
  | "urge"           // 督促
  | "remind"         // 提醒
  | "care"           // 关怀
  | "evening"        // 晚间复盘
  | "sleep_remind"   // 作息提醒
  | "anomaly";       // 行为异常

interface PushSlot {
  hour: number;
  minute: number;
  type: PushType;
  title: string;
}

// 每日推送时间表
const DAILY_SLOTS: PushSlot[] = [
  { hour: 8,  minute: 0,  type: "morning",       title: "早安" },
  { hour: 10, minute: 30, type: "urge",          title: "上午督促" },
  { hour: 12, minute: 30, type: "care",          title: "午间关怀" },
  { hour: 15, minute: 0,  type: "remind",        title: "下午提醒" },
  { hour: 18, minute: 0,  type: "prediction",    title: "傍晚预测" },
  { hour: 21, minute: 0,  type: "evening",       title: "晚间复盘" },
  { hour: 23, minute: 0,  type: "sleep_remind",  title: "作息提醒" },
];

export class PushScheduler {
  private memory: MemoryService;
  private predictionService: PredictionService;
  private reminderIds: number[] = [];

  constructor(memory: MemoryService, predictionService: PredictionService) {
    this.memory = memory;
    this.predictionService = predictionService;
  }

  /** 初始化：注册所有定时推送 */
  async init(): Promise<void> {
    // 请求通知权限
    try {
      await notificationManager.requestEnableNotification();
    } catch { /* 权限被拒绝也能用 reminder */ }

    // 注册每日定时推送
    for (let i = 0; i < DAILY_SLOTS.length; i++) {
      const slot = DAILY_SLOTS[i];
      const id = await this.registerDailyReminder(slot);
      this.reminderIds.push(id);
    }
    console.info(`[PushScheduler] 已注册 ${this.reminderIds.length} 个定时推送`);
  }

  /** 取消所有推送 */
  async cancelAll(): Promise<void> {
    for (let i = 0; i < this.reminderIds.length; i++) {
      try {
        await reminderAgent.cancelReminder(this.reminderIds[i]);
      } catch { /* 忽略 */ }
    }
    this.reminderIds = [];
  }

  /** 注册一个每日定时提醒 */
  private async registerDailyReminder(slot: PushSlot): Promise<number> {
    const reminder: reminderAgent.ReminderRequestCalendar = {
      reminderType: reminderAgent.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: new Date().getFullYear(),
        month: new Date().getMonth() + 1,
        day: new Date().getDate(),
        hour: slot.hour,
        minute: slot.minute,
        second: 0,
      },
      repeatMonths: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],  // 每月重复
      repeatDays: [1, 2, 3, 4, 5, 6, 7],  // 每天重复
      title: `知心 · ${slot.title}`,
      content: "点击查看",
      notificationId: slot.hour * 100 + slot.minute,
      slotConfig: {
        type: reminderAgent.SlotType.SOCIAL_COMMUNICATION,
      },
      actionButton: [
        { title: "查看", type: reminderAgent.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE },
      ],
      wantAgent: {
        pkgName: "com.zhixin.companion",
        abilityName: "EntryAbility",
      },
    };

    const id = await reminderAgent.publishReminder(reminder);
    return id;
  }

  // ============================================================
  // 即时推送（不通过定时，直接发通知）
  // ============================================================

  /** 即时推送一条通知 */
  async pushNow(title: string, content: string, type: PushType): Promise<void> {
    try {
      notificationManager.publish({
        id: Date.now() % 100000,
        content: {
          contentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: `知心 · ${title}`,
            text: content,
          },
        },
        deliveryTime: new Date().getTime(),
        classification: notificationManager.NotificationClassification.RECOMMENDATION,
      });
      // 同时记录到行为日志
      await this.memory.logBehavior("push_sent", {
        type, title, content,
      });
    } catch (e) {
      console.error("[PushScheduler] 推送失败:", JSON.stringify(e));
    }
  }

  // ============================================================
  // 各类推送内容生成（被定时触发时调用）
  // ============================================================

  /** 早安推送（08:00） */
  async generateMorningPush(): Promise<{ title: string; content: string }> {
    const profile = await this.memory.getFullProfile();
    const episodes = await this.memory.getTopEpisodic(3);
    const patterns = await this.memory.getAllProcedural();

    try {
      const relevantEpisodes: { title: string; description: string }[] = [];
      for (let i = 0; i < episodes.length; i++) {
        const e = episodes[i];
        const desc = e.description ? e.description : "";
        relevantEpisodes.push({ title: e.title, description: desc });
      }
      const behaviorPatterns: { description: string; confidence: number }[] = [];
      const patternCount = Math.min(5, patterns.length);
      for (let i = 0; i < patternCount; i++) {
        const p = patterns[i];
        const conf = p.confidence ? p.confidence : 0.5;
        behaviorPatterns.push({ description: p.description, confidence: conf });
      }
      const result = await generateMorningGreeting({
        current_time: new Date().toLocaleString(),
        user_profile: profile,
        relevant_episodes: relevantEpisodes,
        behavior_patterns: behaviorPatterns,
      });
      return { title: "早安", content: result.content };
    } catch {
      // 后端不可用时用本地兜底
      return { title: "早安", content: this.localMorningFallback(profile, patterns) };
    }
  }

  /** 傍晚预测推送（18:00） */
  async generatePredictionPush(): Promise<{ title: string; content: string }> {
    try {
      const cards = await this.predictionService.generate();
      if (cards.length === 0) {
        return { title: "预测", content: "暂无足够数据预测你的动向，多用几天看看" };
      }
      // 取置信度最高的一条
      let top = cards[0];
      for (let i = 1; i < cards.length; i++) {
        if (cards[i].confidence > top.confidence) {
          top = cards[i];
        }
      }
      const typeMap: Record<string, string> = { location: "行踪", behavior: "行为", emotion: "情绪" };
      const typeText = typeMap[top.type] ? typeMap[top.type] : "动向";
      return {
        title: "预测",
        content: `我猜你接下来${typeText}：${top.content}（置信度 ${(top.confidence * 100).toFixed(0)}%）`,
      };
    } catch {
      return { title: "预测", content: "预测服务暂时不可用" };
    }
  }

  /** 督促推送（10:30 / 15:00） */
  async generateUrgePush(): Promise<{ title: string; content: string }> {
    // 从情景记忆找最近的"待办/计划/未完成"
    const todos = await this.memory.searchEpisodic("待办");
    const plans = await this.memory.searchEpisodic("计划");

    if (todos.length > 0) {
      const latest = todos[0];
      return {
        title: "督促",
        content: `你之前提到：${latest.title}。现在进展如何了？`,
      };
    }
    if (plans.length > 0) {
      const latest = plans[0];
      return {
        title: "督促",
        content: `别忘了你的计划：${latest.title}`,
      };
    }
    return {
      title: "督促",
      content: "今天有什么想完成的事吗？说出来我帮你记着",
    };
  }

  /** 提醒推送（15:00） */
  async generateRemindPush(): Promise<{ title: string; content: string }> {
    // 查明天的事件
    const tomorrow = Date.now() + 24 * 60 * 60 * 1000;
    const tomorrowStart = new Date(tomorrow);
    tomorrowStart.setHours(0, 0, 0, 0);
    const tomorrowEnd = new Date(tomorrowStart);
    tomorrowEnd.setDate(tomorrowEnd.getDate() + 1);

    const events = await this.memory.getEpisodicByTime(tomorrowStart.getTime(), tomorrowEnd.getTime());
    if (events.length > 0) {
      return {
        title: "提醒",
        content: `明天有 ${events.length} 件事：${events.map(e => e.title).join("、")}`,
      };
    }
    return {
      title: "提醒",
      content: "明天暂时没有安排，要不要规划一下？",
    };
  }

  /** 午间关怀推送（12:30） */
  async generateCarePush(): Promise<{ title: string; content: string }> {
    const hour = new Date().getHours();
    const messages = [
      "中午了，记得吃饭，别亏待自己",
      "午休一会儿，下午更有精神",
      "今天辛苦了，中午好好休息",
      "吃饭别看手机，细嚼慢咽",
    ];
    return {
      title: "关怀",
      content: messages[Math.floor(Math.random() * messages.length)],
    };
  }

  /** 晚间复盘推送（21:00） */
  async generateEveningPush(): Promise<{ title: string; content: string }> {
    const profile = await this.memory.getFullProfile();
    const episodes = await this.memory.getTopEpisodic(3);
    const patterns = await this.memory.getAllProcedural();

    try {
      const relevantEpisodes: { title: string; description: string }[] = [];
      for (let i = 0; i < episodes.length; i++) {
        const e = episodes[i];
        const desc = e.description ? e.description : "";
        relevantEpisodes.push({ title: e.title, description: desc });
      }
      const behaviorPatterns: { description: string; confidence: number }[] = [];
      const patternCount = Math.min(5, patterns.length);
      for (let i = 0; i < patternCount; i++) {
        const p = patterns[i];
        const conf = p.confidence ? p.confidence : 0.5;
        behaviorPatterns.push({ description: p.description, confidence: conf });
      }
      const result = await generateEveningReview({
        current_time: new Date().toLocaleString(),
        user_profile: profile,
        relevant_episodes: relevantEpisodes,
        behavior_patterns: behaviorPatterns,
      });
      return { title: "晚间复盘", content: result.content };
    } catch {
      return { title: "晚间复盘", content: "今天过得怎么样？和知心聊聊吧" };
    }
  }

  /** 作息提醒（23:00） */
  async generateSleepRemindPush(): Promise<{ title: string; content: string }> {
    const hour = new Date().getHours();
    if (hour >= 23) {
      return {
        title: "作息提醒",
        content: "已经 23 点了，该休息了。熬夜伤身，明天的事明天再说",
      };
    }
    return {
      title: "作息提醒",
      content: "快到休息时间了，放下手机准备睡觉吧",
    };
  }

  // ============================================================
  // 主动关怀（基于实时状态触发，非定时）
  // ============================================================

  /** 检测到负面情绪时触发 */
  async triggerEmotionCare(emotion: string): Promise<void> {
    const negative = ["焦虑", "疲惫", "低落", "烦躁", "压力", "难过", "伤心"];
    let hasNegative = false;
    for (let i = 0; i < negative.length; i++) {
      if (emotion.includes(negative[i])) {
        hasNegative = true;
        break;
      }
    }
    if (!hasNegative) return;

    await this.pushNow("情绪关怀", `感觉到你有些${emotion}，要不要和知心聊聊？我一直都在`, "care");
  }

  /** 检测到作息异常（凌晨还在用） */
  async triggerSleepAnomaly(): Promise<void> {
    const hour = new Date().getHours();
    if (hour >= 1 && hour <= 5) {
      await this.pushNow("作息异常", "凌晨了还没睡？明天会很难受的，早点休息吧", "anomaly");
    }
  }

  /** 检测到久坐（基于位置不变 + 时间） */
  async triggerSedentaryRemind(): Promise<void> {
    const now = Date.now();
    const twoHoursAgo = now - 2 * 60 * 60 * 1000;
    const logs = await this.memory.getBehaviorByRange(twoHoursAgo, now, "location");
    if (logs.length === 0) return;

    // 检查位置是否一直没变
    const locations = new Set(logs.map(l => l.location));
    if (locations.size === 1 && logs.length >= 3) {
      await this.pushNow("久坐提醒", "已经两小时没动了，起来活动活动吧", "anomaly");
    }
  }

  // ============================================================
  // 本地兜底（后端不可用时）
  // ============================================================
  private localMorningFallback(profile: Record<string, string>, patterns: any[]): string {
    const hour = new Date().getHours();
    let greeting = "早安";
    if (hour >= 11) greeting = "中午好";

    const parts: string[] = [greeting];

    // 提及画像
    if (profile["职业"]) parts.push(`新的一天，工作顺利`);
    if (profile["偏好"]) parts.push(`记得做自己喜欢的事`);

    // 提及规律
    let routine: any = null;
    for (let i = 0; i < patterns.length; i++) {
      if (patterns[i].pattern_type === "routine") {
        routine = patterns[i];
        break;
      }
    }
    if (routine) parts.push(`按你的规律，${routine.description}`);

    parts.push("有什么想聊的随时找我");
    return parts.join("，") + "。";
  }
}
