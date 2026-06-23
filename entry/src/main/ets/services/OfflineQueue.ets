/**
 * OfflineQueue.ets
 * ----------------
 * 离线消息队列。
 * 使用 @ohos.data.preferences 持久化用户离线时输入的消息，
 * 联网后自动同步到后端。
 *
 * 数据结构：
 *   key   = "msg_<id>"，id 为自增数字
 *   value = JSON 字符串 { id, text, createdAt }
 */

import preferences from "@ohos.data.preferences";

const STORE_NAME = "offline_queue";
const KEY_COUNTER = "__counter__";

export interface OfflineMessage {
  id: number;
  text: string;
  createdAt: number; // 毫秒时间戳
}

export class OfflineQueue {
  private store: preferences.Preferences | null = null;

  /** 初始化（在 aboutToAppear 中调用） */
  async init(context: Context): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
  }

  /** 入队一条离线消息，返回分配的 id */
  async enqueue(text: string): Promise<number> {
    if (!this.store) throw new Error("OfflineQueue 未初始化");
    const id = await this._nextId();
    const msg: OfflineMessage = {
      id,
      text,
      createdAt: Date.now(),
    };
    await this.store.put(this._key(id), JSON.stringify(msg));
    await this.store.flush();
    return id;
  }

  /** 取出所有待发送消息（按 id 升序） */
  async getAll(): Promise<OfflineMessage[]> {
    if (!this.store) return [];
    const all = await this.store.getAll() as Record<string, string>;
    const list: OfflineMessage[] = [];
    for (const k of Object.keys(all)) {
      if (k === KEY_COUNTER) continue;
      try {
        list.push(JSON.parse(all[k]) as OfflineMessage);
      } catch { /* 跳过损坏数据 */ }
    }
    list.sort((a, b) => a.id - b.id);
    return list;
  }

  /** 发送成功后移除 */
  async remove(id: number): Promise<void> {
    if (!this.store) return;
    await this.store.delete(this._key(id));
    await this.store.flush();
  }

  /** 当前队列长度 */
  async size(): Promise<number> {
    return (await this.getAll()).length;
  }

  private async _nextId(): Promise<number> {
    const cur = (await this.store!.get(KEY_COUNTER, 0)) as number;
    const next = cur + 1;
    await this.store!.put(KEY_COUNTER, next);
    return next;
  }

  private _key(id: number): string {
    return `msg_${id}`;
  }
}
