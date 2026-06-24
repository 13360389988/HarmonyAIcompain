/**
 * HomeDetector.ets
 * ----------------
 * 宿舍检测器 — 判断用户是否回到宿舍（后端可达的环境）。
 */

import wifiManager from "@ohos.wifi";
import http from "@ohos.net.http";
import geoLocationManager from "@ohos.geoLocationManager";

export type HomeStateCallback = (atHome: boolean) => void;

export interface HomeLatLng {
  lat: number;
  lng: number;
  radius: number;
}

export interface HomeConfig {
  homeSsid: string;
  serverUrl: string;
  homeLatLng: HomeLatLng;
}

export class HomeDetector {
  private homeSsid: string = "";
  private homeLatLng: HomeLatLng | null = null;
  private serverUrl: string = "";
  private callbacks: Set<HomeStateCallback> = new Set();
  private _atHome: boolean = false;
  private checkTimer: number | null = null;
  private readonly CHECK_INTERVAL: number = 60000;

  config(opts: HomeConfig): void {
    if (opts.homeSsid) this.homeSsid = opts.homeSsid;
    if (opts.serverUrl) this.serverUrl = opts.serverUrl;
    if (opts.homeLatLng) this.homeLatLng = opts.homeLatLng;
  }

  isAtHome(): boolean {
    return this._atHome;
  }

  onHomeStateChange(cb: HomeStateCallback): () => void {
    this.callbacks.add(cb);
    cb(this._atHome);
    return () => this.callbacks.delete(cb);
  }

  start(): void {
    this.check();
    this.checkTimer = setInterval(() => { this.check(); }, this.CHECK_INTERVAL);
  }

  stop(): void {
    if (this.checkTimer !== null) {
      clearInterval(this.checkTimer);
      this.checkTimer = null;
    }
  }

  async check(): Promise<boolean> {
    const wasAtHome = this._atHome;
    const atHome = await this.detect();
    if (atHome !== wasAtHome) {
      this._atHome = atHome;
      this.notify();
    }
    return atHome;
  }

  private async detect(): Promise<boolean> {
    if (this.homeSsid) {
      const ssid = await this.getCurrentSsid();
      if (ssid && ssid === this.homeSsid) {
        return true;
      }
    }

    if (this.serverUrl) {
      const reachable = await this.pingServer();
      if (reachable) return true;
    }

    if (this.homeLatLng) {
      const atLocation = await this.checkLocation();
      if (atLocation) return true;
    }

    return false;
  }

  private async getCurrentSsid(): Promise<string | null> {
    try {
      const info = await this.getWifiInfo();
      if (info && info.ssid) {
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
        wifiManager.getLinkedInfo((err: Error, info: wifiManager.WifiLinkedInfo) => {
          if (err) resolve(null);
          else resolve(info);
        });
      } catch {
        resolve(null);
      }
    });
  }

  private pingServer(): Promise<boolean> {
    return new Promise((resolve) => {
      try {
        const req = http.createHttp();
        req.request(`${this.serverUrl}/`, {
          method: http.RequestMethod.GET,
          connectTimeout: 3000,
          readTimeout: 3000,
        }, (err: Error, data: http.HttpResponse) => {
          req.destroy();
          resolve(!err && data.responseCode === 200);
        });
      } catch {
        resolve(false);
      }
    });
  }

  private async checkLocation(): Promise<boolean> {
    if (!this.homeLatLng) return false;
    try {
      const location = await this.getCurrentLocation();
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

  private getCurrentLocation(): Promise<geoLocationManager.Location | null> {
    return new Promise((resolve) => {
      try {
        geoLocationManager.getCurrentLocation({
          priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
          scenario: geoLocationManager.LocationRequestScenario.DAILY_LIFE_SERVICE,
        }, (err: Error, loc: geoLocationManager.Location) => {
          if (err) resolve(null);
          else resolve(loc);
        });
      } catch {
        resolve(null);
      }
    });
  }

  private haversine(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const R = 6371000;
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
    const cbArray = Array.from(this.callbacks);
    for (let i = 0; i < cbArray.length; i++) {
      try {
        cbArray[i](this._atHome);
      } catch (e) {
        // 忽略
      }
    }
  }
}
