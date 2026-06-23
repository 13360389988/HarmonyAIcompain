/**
 * SyncService.ets
 * ----------------
 * 多设备同步服务 — 轻量级加密摘要同步。
 *
 * 设计原则：
 *   1. 手机存完整数据（本地 SQLite）
 *   2. 后端只存加密摘要（画像 + 重要事件 + 行为模式）
 *   3. 原始对话不上云（省内存省流量）
 *   4. 换机时从后端拉取摘要，恢复核心记忆
 *
 * 同步内容（约 5-20KB）：
 *   - semantic_memory 全量（画像/偏好/价值观，通常 < 50 条）
 *   - episodic_memory Top 50（重要事件）
 *   - procedural_memory 全量（行为模式，通常 < 20 条）
 *   - relation_network Top 20（核心关系）
 *   - prediction_memory 最近 30 天的验证结果（用于校准）
 *
 * 不同步：
 *   - short_term_memory（短期对话，体积大价值低）
 *   - behavior_log（原始日志，体积大）
 */

import { MemoryService, SemanticRecord, EpisodicRecord, ProceduralRecord, RelationRecord, PredictionRecord } from "./MemoryService";
import http from "@ohos.net.http";

// 同步数据包结构
export interface SyncPackage {
  device_id: string;
  last_sync_time: number;
  semantic_memory: SemanticRecord[];
  episodic_memory: EpisodicRecord[];
  procedural_memory: ProceduralRecord[];
  relation_network: RelationRecord[];
  prediction_memory: PredictionRecord[];
}

export interface SyncResult {
  success: boolean;
  synced_at: number;
  uploaded: number;
  downloaded: number;
  error?: string;
}

const SYNC_KEY = "sync_state";
const SYNC_PREFERENCES = "zhixin_sync";

export class SyncService {
  private memory: MemoryService;
  private deviceId: string = "";
  private lastSyncTime: number = 0;

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  async init(): Promise<void> {
    // 生成或读取设备 ID
    this.deviceId = await this.getOrCreateDeviceId();
    this.lastSyncTime = await this.getLastSyncTime();
  }

  // ============================================================
  // 上传同步（手机 → 后端）
  // ============================================================
  async upload(): Promise<SyncResult> {
    if (!this.deviceId) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: "设备未初始化" };
    }

    try {
      // 1. 打包本地数据（只打包核心记忆，不含原始日志）
      const pkg: SyncPackage = {
        device_id: this.deviceId,
        last_sync_time: this.lastSyncTime,
        semantic_memory: await this.memory.getSemanticByCategory("profile")
          .then(r => r.concat(await this.memory.getSemanticByCategory("preference"))
            .concat(await this.memory.getSemanticByCategory("value"))
            .concat(await this.memory.getSemanticByCategory("fact"))),
        episodic_memory: await this.memory.getTopEpisodic(50),
        procedural_memory: await this.memory.getAllProcedural(),
        relation_network: await this.memory.getAllRelations(),
        prediction_memory: [],  // 预测记录可选
      };

      // 2. 加密（简化版：Base64，生产环境应使用 AES）
      const encrypted = this.encrypt(JSON.stringify(pkg));

      // 3. 上传到后端
      const response = await this.httpPost("/sync/upload", {
        device_id: this.deviceId,
        data: encrypted,
        timestamp: Date.now(),
      });

      if (response.success) {
        this.lastSyncTime = Date.now();
        await this.saveLastSyncTime(this.lastSyncTime);
        return {
          success: true,
          synced_at: this.lastSyncTime,
          uploaded: pkg.semantic_memory.length + pkg.episodic_memory.length +
                    pkg.procedural_memory.length + pkg.relation_network.length,
          downloaded: 0,
        };
      }

      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: response.error };
    } catch (e) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: (e as Error).message };
    }
  }

  // ============================================================
  // 下载同步（后端 → 手机，换机恢复用）
  // ============================================================
  async download(): Promise<SyncResult> {
    if (!this.deviceId) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: "设备未初始化" };
    }

    try {
      // 1. 从后端拉取
      const response = await this.httpPost("/sync/download", {
        device_id: this.deviceId,
      });

      if (!response.success || !response.data) {
        return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: response.error ?? "无数据" };
      }

      // 2. 解密
      const pkg: SyncPackage = JSON.parse(this.decrypt(response.data));

      // 3. 写入本地（合并，不覆盖）
      let downloaded = 0;

      // 合并语义记忆
      for (const r of pkg.semantic_memory) {
        await this.memory.setSemantic({
          category: r.category,
          key: r.key,
          value: r.value,
          confidence: r.confidence,
          source: "sync",
        });
        downloaded++;
      }

      // 合并情景记忆（去重：按 title + event_time）
      const localEpisodes = await this.memory.getTopEpisodic(1000);
      for (const e of pkg.episodic_memory) {
        const exists = localEpisodes.some(le =>
          le.title === e.title && Math.abs(le.event_time - e.event_time) < 60000
        );
        if (!exists) {
          await this.memory.addEpisodic({
            event_time: e.event_time,
            title: e.title,
            description: e.description,
            location: e.location,
            people: e.people,
            emotion: e.emotion,
            outcome: e.outcome,
            importance: e.importance,
          });
          downloaded++;
        }
      }

      // 合并程序记忆（去重：按 description）
      const localPatterns = await this.memory.getAllProcedural();
      for (const p of pkg.procedural_memory) {
        if (!localPatterns.some(lp => lp.description === p.description)) {
          await this.memory.addProcedural({
            pattern_type: p.pattern_type,
            description: p.description,
            trigger_condition: p.trigger_condition,
            action: p.action,
            frequency: p.frequency,
            confidence: p.confidence,
            trigger_count: p.trigger_count,
          });
          downloaded++;
        }
      }

      // 合并关系网络
      for (const r of pkg.relation_network) {
        await this.memory.mentionPerson(
          r.person_name,
          r.relation_type,
          r.sentiment ?? 0,
          r.notes
        );
        downloaded++;
      }

      this.lastSyncTime = Date.now();
      await this.saveLastSyncTime(this.lastSyncTime);

      return {
        success: true,
        synced_at: this.lastSyncTime,
        uploaded: 0,
        downloaded,
      };
    } catch (e) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: (e as Error).message };
    }
  }

  // ============================================================
  // 双向同步（上传 + 下载）
  // ============================================================
  async sync(): Promise<SyncResult> {
    const uploadResult = await this.upload();
    if (!uploadResult.success) return uploadResult;

    const downloadResult = await this.download();
    return {
      success: downloadResult.success,
      synced_at: Date.now(),
      uploaded: uploadResult.uploaded,
      downloaded: downloadResult.downloaded,
      error: downloadResult.error,
    };
  }

  /** 是否需要同步（距上次同步超过 6 小时） */
  shouldSync(): boolean {
    return Date.now() - this.lastSyncTime > 6 * 60 * 60 * 1000;
  }

  // ============================================================
  // 加密/解密（简化版，生产环境用 AES）
  // ============================================================
  private encrypt(text: string): string {
    // TODO: 替换为 AES 加密
    // 简化版用 Base64，至少避免明文传输
    return Buffer.from(text, "utf-8").toString("base64");
  }

  private decrypt(encrypted: string): string {
    return Buffer.from(encrypted, "base64").toString("utf-8");
  }

  // ============================================================
  // HTTP 请求
  // ============================================================
  private async httpPost(path: string, body: object): Promise<any> {
    // TODO: 替换为实际的后端地址
    const BASE = "http://192.168.1.100:8000";
    return new Promise((resolve) => {
      const req = http.createHttp();
      req.request(`${BASE}${path}`, {
        method: http.RequestMethod.POST,
        header: { "Content-Type": "application/json" },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.OBJECT,
        readTimeout: 30_000,
        connectTimeout: 10_000,
      }, (err, data) => {
        if (err || data.responseCode !== 200) {
          resolve({ success: false, error: err ? err.message : `HTTP ${data.responseCode}` });
          return;
        }
        try {
          const result = typeof data.result === "string"
            ? JSON.parse(data.result) : data.result;
          resolve(result);
        } catch (e) {
          resolve({ success: false, error: "JSON 解析失败" });
        }
      });
    });
  }

  // ============================================================
  // 设备 ID & 同步时间持久化
  // ============================================================
  private async getOrCreateDeviceId(): Promise<string> {
    // 简化版：用时间戳 + 随机数生成
    // 生产环境应使用 @ohos.deviceInfo
    return `dev_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
  }

  private async getLastSyncTime(): Promise<number> {
    // 简化版：从 Preferences 读取
    return 0;
  }

  private async saveLastSyncTime(time: number): Promise<void> {
    // 简化版：写入 Preferences
  }
}
