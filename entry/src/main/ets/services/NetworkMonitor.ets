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

  /** 当前是否在线（默认 true，监听启动后会立即校正） */
  isOnline(): boolean {
    return this._online;
  }

  /** 注册状态变化回调，返回取消注册函数 */
  onStatusChange(cb: NetStatusCallback): () => void {
    this.callbacks.add(cb);
    // 立即推送一次当前状态
    cb(this._online);
    return () => this.callbacks.delete(cb);
  }

  /** 启动监听（应用启动时调用一次即可） */
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
    // 默认按有网络处理，后续事件会校正
    this.netManager.register(() => {});
  }

  stop(): void {
    this.netManager.unregister(() => {});
  }

  private notify(): void {
    this.callbacks.forEach(cb => {
      try { cb(this._online); } catch (e) { /* 忽略回调异常 */ }
    });
  }
}
