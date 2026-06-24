/**
 * NetworkMonitor.ets
 * ------------------
 * 网络状态监听器。
 * 基于 @ohos.net.connection 实时感知在线/离线切换。
 */

import connection from "@ohos.net.connection";

export type NetStatusCallback = (online: boolean) => void;

export class NetworkMonitor {
  private static instance: NetworkMonitor | null = null;
  private netManager: connection.NetConnection = connection.createNetConnection();
  private callbacks: Set<NetStatusCallback> = new Set();
  private _online: boolean = true;

  static getInstance(): NetworkMonitor {
    if (!NetworkMonitor.instance) {
      NetworkMonitor.instance = new NetworkMonitor();
    }
    return NetworkMonitor.instance;
  }

  isOnline(): boolean {
    return this._online;
  }

  onStatusChange(cb: NetStatusCallback): () => void {
    this.callbacks.add(cb);
    cb(this._online);
    return () => this.callbacks.delete(cb);
  }

  start(): void {
    this.netManager.on("netAvailable", () => {
      this._online = true;
      this.notify();
    });
    this.netManager.on("netLost", () => {
      this._online = false;
      this.notify();
    });
    this.netManager.on("netUnavailable", () => {
      this._online = false;
      this.notify();
    });
    this.netManager.register(() => {});
  }

  stop(): void {
    this.netManager.unregister(() => {});
  }

  private notify(): void {
    const cbArray = Array.from(this.callbacks);
    for (let i = 0; i < cbArray.length; i++) {
      try {
        cbArray[i](this._online);
      } catch (e) {
        // 忽略回调异常
      }
    }
  }
}
