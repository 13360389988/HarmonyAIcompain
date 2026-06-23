/**
 * OfflineQueue.ets
 * ----------------
 * 离线消息队列。
 */

import preferences from "@ohos.data.preferences";

const STORE_NAME = "offline_queue";
const KEY_COUNTER = "__counter__";

export interface OfflineMessage {
  id: number;
  text: string;
  createdAt: number;
}

export class OfflineQueue {
  private store: preferences.Preferences | null = null;

  async init(context: Context): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
  }

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

  async getAll(): Promise<OfflineMessage[]> {
    if (!this.store) return [];
    const all = await this.store.getAll() as Record<string, string>;
    const list: OfflineMessage[] = [];
    const keys = Object.keys(all);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      if (k === KEY_COUNTER) continue;
      try {
        list.push(JSON.parse(all[k]) as OfflineMessage);
      } catch { /* 跳过损坏数据 */ }
    }
    list.sort((a, b) => a.id - b.id);
    return list;
  }

  async remove(id: number): Promise<void> {
    if (!this.store) return;
    await this.store.delete(this._key(id));
    await this.store.flush();
  }

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
