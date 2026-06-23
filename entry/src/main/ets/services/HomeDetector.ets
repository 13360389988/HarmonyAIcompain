/**
 * HomeDetector.ets
 * ----------------
 * 宿舍检测器 — 判断用户是否回到宿舍（后端可达的环境）。
 *
 * 检测策略（多重判断，任一命中即认为在宿舍）：
 *   1. WiFi SSID 匹配（最准）— 连上宿舍 WiFi 就算
 *   2. 后端可达性探测（最可靠）— ping 后端 /health
 *   3. 位置围栏（备用）— GPS 在宿舍坐标范围内
 *
 * 用法：
 *   const detector = new HomeDetector();
 *   detector.init("你的宿舍WiFi名");
 *   detector.onHomeStateChange((atHome) => {
 *     if (atHome) syncOrchestrator.triggerFullSync();
 *   });
 */

import wifiManager from "@ohos.wifi";
import http from "@ohos.net.http";
import geoLocationManager from "@ohos.geoLocationManager";

export type HomeStateCallback = (atHome: boolean) => void;

export class HomeDetector {
  private homeSsid: string = "";           // 宿舍 WiFi 名
  private homeLatLng: { lat: number; lng: number; radius: number } | null = null;
  private serverUrl: string = "";          // 后端健康检查地址
  private callbacks: Set<HomeStateCallback> = new Set();
  private _atHome: boolean = false;
  private checkTimer: number | null = null;
  private readonly CHECK_INTERVAL = 60_000;  // 每分钟检查一次

  /** 配置宿舍检测条件（至少配一个） */
  config(opts: {
    homeSsid?: string;                     // 宿舍 WiFi 名
    serverUrl?: string;                    // 后端地址，如 http://192.168.137.1:8000
    homeLatLng?: { lat: number; lng: number; radius: number };  // 宿舍坐标 + 半径(米)
  }): void {
    if (opts.homeSsid) this.homeSsid = opts.homeSsid;
    if (opts.serverUrl) this.serverUrl = opts.serverUrl;
    if (opts.homeLatLng) this.homeLatLng = opts.homeLatLng;
  }

  /** 当前是否在宿舍 */
  isAtHome(): boolean {
    return this._atHome;
  }

  /** 注册状态变化回调 */
  onHomeStateChange(cb: HomeStateCallback): () => void {
    this.callbacks.add(cb);
    cb(this._atHome);  // 立即推送一次当前状态
    return () => this.callbacks.delete(cb);
  }

  /** 启动检测 */
  start(): void {
    // 立即检测一次
    this.check();
    // 定时检测
    this.checkTimer = setInterval(() => this.check(), this.CHECK_INTERVAL);
  }

  stop(): void {
    if (this.checkTimer !== null) {
      clearInterval(this.checkTimer);
      this.checkTimer = null;
    }
  }

  /** 手动触发一次检测 */
  async check(): Promise<boolean> {
    const wasAtHome = this._atHome;
    const atHome = await this.detect();
    if (atHome !== wasAtHome) {
      this._atHome = atHome;
      this.notify();
    }
    return atHome;
  }

  // ============================================================
  // 检测逻辑（多重判断，任一命中即认为在宿舍）
  // ============================================================
  private async detect(): Promise<boolean> {
    // 策略 1：WiFi SSID 匹配（最快，无需网络请求）
    if (this.homeSsid) {
      const ssid = await this.getCurrentSsid();
      if (ssid && ssid === this.homeSsid) {
        return true;
      }
    }

    // 策略 2：后端可达性探测（最可靠）
    if (this.serverUrl) {
      const reachable = await this.pingServer();
      if (reachable) return true;
    }

    // 策略 3：位置围栏（备用）
    if (this.homeLatLng) {
      const atLocation = await this.checkLocation();
      if (atLocation) return true;
    }

    return false;
  }

  /** 获取当前连接的 WiFi SSID */
  private async getCurrentSsid(): Promise<string | null> {
    try {
      // 鸿蒙 API：获取当前 WiFi 信息
      const info = await this.getWifiInfo();
      if (info && info.ssid) {
        // 鸿蒙返回的 SSID 带引号，去掉
        return info.ssid.replace(/^"|"$/g, "");
      }
    } catch {
      // WiFi 权限未授予或 WiFi 未开
    }
    return null;
  }

  private getWifiInfo(): Promise<wifiManager.WifiLinkedInfo | null> {
    return new Promise((resolve) => {
      try {
        wifiManager.getLinkedInfo((err, info) => {
          if (err) resolve(null);
          else resolve(info);
        });
      } catch {
        resolve(null);
      }
    });
  }

  /** 探测后端是否可达（GET / 健康检查） */
  private pingServer(): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        const req = http.createHttp();
        req.request(`${this.serverUrl}/`, {
          method: http.RequestMethod.GET,
          connectTimeout: 3_000,
          readTimeout: 3_000,
        }, (err, data) => {
          req.destroy();
          resolve(!err && data.responseCode === 200);
        });
      } catch {
        resolve(false);
      }
    });
  }

  /** 位置围栏检测 */
  private async checkLocation(): Promise<boolean> {
    if (!this.homeLatLng) return false;
    try {
      const request: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
        scenario: geoLocationManager.LocationRequestScenario.DAILY_LIFE_SERVICE,
        timeoutMs: 5_000,
        maxAccuracy: 0,
      };
      const location = await this.getCurrentLocation(request);
      if (location) {
        const distance = this.haversine(
          this.homeLatLng.lat, this.homeLatLng.lng,
          location.latitude, location.longitude
        );
        return distance <= this.homeLatLng.radius;
      }
    } catch { /* 忽略 */ }
    return false;
  }

  private getCurrentLocation(request: geoLocationManager.LocationRequest): Promise<geoLocationManager.Location | null> {
    return new Promise((resolve) => {
      try {
        geoLocationManager.getCurrentLocation(request, (err, loc) => {
          if (err) resolve(null);
          else resolve(loc);
        });
      } catch {
        resolve(null);
      }
    });
  }

  /** 计算两点间距离（米） */
  private haversine(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const R = 6371000;  // 地球半径(米)
    const dLat = this.toRad(lat2 - lat1);
    const dLng = this.toRad(lng2 - lng1);
    const a = Math.sin(dLat / 2) ** 2 +
              Math.cos(this.toRad(lat1)) * Math.cos(this.toRad(lat2)) *
              Math.sin(dLng / 2) ** 2;
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }

  private toRad(deg: number): number {
    return deg * Math.PI / 180;
  }

  private notify(): void {
    this.callbacks.forEach(cb => {
      try { cb(this._atHome); } catch { /* 忽略 */ }
    });
  }
}
