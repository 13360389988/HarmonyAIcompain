/**
 * BehaviorCollector.ets
 * ---------------------
 * 后台行为采集服务。
 *
 * 采集维度：
 *   1. 位置变化（GPS + 网络定位）
 *   2. 应用启动/切换事件
 *   3. 作息推断（首次/末次活跃时间）
 *   4. 情绪节奏（打字速度、删除频率）
 *
 * 所有采集结果写入 behavior_log 表，供后续挖掘行为模式。
 *
 * 重要：本服务完全离线工作，不依赖后端。
 * 采集的数据存在本地，回到宿舍后由 SyncOrchestrator 批量处理。
 */

import geoLocationManager from "@ohos.geoLocationManager";
import { MemoryService } from "./MemoryService";

export class BehaviorCollector {
  private memory: MemoryService;
  private locationTimer: number | null = null;
  private lastLocation: string = "";
  private lastLocationTime: number = 0;
  private appStartTime: number = Date.now();
  private lastActiveTime: number = Date.now();
  private isOffline: boolean = true;  // 默认离线采集

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  /** 设置在线/离线状态（由 HomeDetector 触发） */
  setOnlineStatus(online: boolean): void {
    this.isOffline = !online;
  }

  /** 启动采集（应用进入前台时调用） */
  start(): void {
    this.appStartTime = Date.now();
    this.lastActiveTime = Date.now();

    // 记录应用启动
    this.memory.logBehavior("app_start", {
      timestamp: this.appStartTime,
      offline: this.isOffline,
    }).catch(() => {});

    // 启动位置采集（每 10 分钟一次，省电）
    this.startLocationTracking();
  }

  /** 停止采集（应用进入后台时调用） */
  stop(): void {
    // 记录应用退出 + 本次使用时长
    const now = Date.now();
    const duration = now - this.appStartTime;
    this.memory.logBehavior("app_end", {
      timestamp: now,
      duration_ms: duration,
      duration_min: Math.round(duration / 60000),
    }).catch(() => {});

    // 记录末次活跃时间（用于推断作息）
    this.memory.logBehavior("last_active", {
      timestamp: this.lastActiveTime,
    }).catch(() => {});

    this.stopLocationTracking();
  }

  /** 用户有交互时调用（更新活跃时间） */
  onUserActive(): void {
    this.lastActiveTime = Date.now();
  }

  // ============================================================
  // 位置采集
  // ============================================================
  private startLocationTracking(): void {
    // 每 10 分钟采集一次位置
    this.locationTimer = setInterval(() => {
      this.captureLocation();
    }, 10 * 60 * 1000);

    // 启动时立即采集一次
    this.captureLocation();
  }

  private stopLocationTracking(): void {
    if (this.locationTimer !== null) {
      clearInterval(this.locationTimer);
      this.locationTimer = null;
    }
  }

  private captureLocation(): void {
    try {
      const request: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
        scenario: geoLocationManager.LocationRequestScenario.DAILY_LIFE_SERVICE,
        timeoutMs: 10_000,
        maxAccuracy: 0,
      };

      geoLocationManager.getCurrentLocation(request, (err, location) => {
        if (err) {
          // 定位失败不报错，静默跳过
          return;
        }
        if (location) {
          const locStr = `${location.latitude.toFixed(4)},${location.longitude.toFixed(4)}`;
          const now = Date.now();

          // 位置变化超过阈值才记录（避免重复记录同一位置）
          if (locStr !== this.lastLocation ||
              now - this.lastLocationTime > 30 * 60 * 1000) {
            this.lastLocation = locStr;
            this.lastLocationTime = now;

            this.memory.logBehavior("location", {
              latitude: location.latitude,
              longitude: location.longitude,
              altitude: location.altitude,
              accuracy: location.accuracy,
            }, locStr).catch(() => {});
          }
        }
      });
    } catch {
      // 定位权限未授予或服务不可用
    }
  }

  // ============================================================
  // 应用切换采集
  // ============================================================
  onAppSwitch(fromApp: string, toApp: string): void {
    this.memory.logBehavior("app_switch", {
      from: fromApp,
      to: toApp,
    }).catch(() => {});
  }

  // ============================================================
  // 情绪节奏采集（基于打字行为）
  // ============================================================
  private typingStart: number = 0;
  private deleteCount: number = 0;
  private charCount: number = 0;

  /** 用户开始打字 */
  onTypingStart(): void {
    this.typingStart = Date.now();
    this.deleteCount = 0;
    this.charCount = 0;
  }

  /** 用户输入字符 */
  onCharInput(): void {
    this.charCount++;
    this.onUserActive();
  }

  /** 用户删除字符 */
  onDelete(): void {
    this.deleteCount++;
    this.onUserActive();
  }

  /** 用户发送消息时，记录打字节奏 */
  onMessageSent(messageText: string): void {
    if (this.typingStart === 0) return;

    const duration = Date.now() - this.typingStart;
    const chars = messageText.length;
    const deleteRatio = this.charCount > 0 ? this.deleteCount / this.charCount : 0;
    const speed = duration > 0 ? (chars / duration) * 1000 : 0; // 字/秒

    this.memory.logBehavior("typing_pattern", {
      duration_ms: duration,
      char_count: chars,
      delete_count: this.deleteCount,
      delete_ratio: deleteRatio,
      typing_speed: speed,
      message_length: chars,
    }).catch(() => {});

    // 重置
    this.typingStart = 0;
    this.deleteCount = 0;
    this.charCount = 0;
  }

  // ============================================================
  // 作息推断
  // ============================================================
  /** 推断今天的作息（基于历史行为日志） */
  async inferSleepPattern(): Promise<{ wakeTime?: number; sleepTime?: number }> {
    const now = Date.now();
    const dayStart = new Date();
    dayStart.setHours(0, 0, 0, 0);
    const dayStartTime = dayStart.getTime();

    // 取今天的所有行为日志
    const logs = await this.memory.getBehaviorByRange(dayStartTime, now);

    if (logs.length === 0) return {};

    // 第一条日志 ≈ 起床时间
    const wakeTime = logs[0].timestamp;
    // 最后一条日志 ≈ 还没睡
    const sleepTime = undefined; // 睡眠时间需要跨天推断

    return { wakeTime, sleepTime };
  }
}
