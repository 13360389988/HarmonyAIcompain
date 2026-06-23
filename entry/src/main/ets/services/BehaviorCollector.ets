/**
 * BehaviorCollector.ets
 * ---------------------
 * 后台行为采集服务。
 */

import geoLocationManager from "@ohos.geoLocationManager";
import { MemoryService } from "./MemoryService";

export interface SleepPatternResult {
  wakeTime: number;
  sleepTime: number;
}

interface AppStartData {
  timestamp: number;
  offline: boolean;
}

interface AppEndData {
  timestamp: number;
  duration_ms: number;
  duration_min: number;
}

interface LastActiveData {
  timestamp: number;
}

interface LocationData {
  latitude: number;
  longitude: number;
  altitude: number;
  accuracy: number;
}

interface AppSwitchData {
  from: string;
  to: string;
}

interface TypingData {
  duration_ms: number;
  char_count: number;
  delete_count: number;
  delete_ratio: number;
  typing_speed: number;
  message_length: number;
}

export class BehaviorCollector {
  private memory: MemoryService;
  private locationTimer: number | null = null;
  private lastLocation: string = "";
  private lastLocationTime: number = 0;
  private appStartTime: number = Date.now();
  private lastActiveTime: number = Date.now();
  private isOffline: boolean = true;

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  setOnlineStatus(online: boolean): void {
    this.isOffline = !online;
  }

  start(): void {
    this.appStartTime = Date.now();
    this.lastActiveTime = Date.now();

    const startData: AppStartData = {
      timestamp: this.appStartTime,
      offline: this.isOffline,
    };
    this.memory.logBehavior("app_start", startData).catch(() => {});

    this.startLocationTracking();
  }

  stop(): void {
    const now = Date.now();
    const duration = now - this.appStartTime;
    const endData: AppEndData = {
      timestamp: now,
      duration_ms: duration,
      duration_min: Math.round(duration / 60000),
    };
    this.memory.logBehavior("app_end", endData).catch(() => {});

    const activeData: LastActiveData = {
      timestamp: this.lastActiveTime,
    };
    this.memory.logBehavior("last_active", activeData).catch(() => {});

    this.stopLocationTracking();
  }

  onUserActive(): void {
    this.lastActiveTime = Date.now();
  }

  private startLocationTracking(): void {
    this.locationTimer = setInterval(() => {
      this.captureLocation();
    }, 10 * 60 * 1000);

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
      geoLocationManager.getCurrentLocation({
        priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
        scenario: geoLocationManager.LocationRequestScenario.DAILY_LIFE_SERVICE,
      }, (err: Error, location: geoLocationManager.Location) => {
        if (err) return;
        if (location) {
          const locStr = `${location.latitude.toFixed(4)},${location.longitude.toFixed(4)}`;
          const now = Date.now();

          if (locStr !== this.lastLocation ||
              now - this.lastLocationTime > 30 * 60 * 1000) {
            this.lastLocation = locStr;
            this.lastLocationTime = now;

            const locData: LocationData = {
              latitude: location.latitude,
              longitude: location.longitude,
              altitude: location.altitude,
              accuracy: location.accuracy,
            };
            this.memory.logBehavior("location", locData, locStr).catch(() => {});
          }
        }
      });
    } catch {
      // 定位权限未授予或服务不可用
    }
  }

  onAppSwitch(fromApp: string, toApp: string): void {
    const switchData: AppSwitchData = {
      from: fromApp,
      to: toApp,
    };
    this.memory.logBehavior("app_switch", switchData).catch(() => {});
  }

  private typingStart: number = 0;
  private deleteCount: number = 0;
  private charCount: number = 0;

  onTypingStart(): void {
    this.typingStart = Date.now();
    this.deleteCount = 0;
    this.charCount = 0;
  }

  onCharInput(): void {
    this.charCount++;
    this.onUserActive();
  }

  onDelete(): void {
    this.deleteCount++;
    this.onUserActive();
  }

  onMessageSent(messageText: string): void {
    if (this.typingStart === 0) return;

    const duration = Date.now() - this.typingStart;
    const chars = messageText.length;
    const deleteRatio = this.charCount > 0 ? this.deleteCount / this.charCount : 0;
    const speed = duration > 0 ? (chars / duration) * 1000 : 0;

    const typingData: TypingData = {
      duration_ms: duration,
      char_count: chars,
      delete_count: this.deleteCount,
      delete_ratio: deleteRatio,
      typing_speed: speed,
      message_length: chars,
    };
    this.memory.logBehavior("typing_pattern", typingData).catch(() => {});

    this.typingStart = 0;
    this.deleteCount = 0;
    this.charCount = 0;
  }

  async inferSleepPattern(): Promise<SleepPatternResult | Record<string, never>> {
    const now = Date.now();
    const dayStart = new Date();
    dayStart.setHours(0, 0, 0, 0);
    const dayStartTime = dayStart.getTime();

    const logs = await this.memory.getBehaviorByRange(dayStartTime, now);

    if (logs.length === 0) return {};

    const wakeTime = logs[0].timestamp;
    const sleepTime = 0;

    return { wakeTime, sleepTime };
  }
}
