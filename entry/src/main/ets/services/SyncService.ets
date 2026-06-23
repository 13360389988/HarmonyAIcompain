import { MemoryService, SemanticRecord, EpisodicRecord, ProceduralRecord, RelationRecord, PredictionRecord } from "./MemoryService";
import http from "@ohos.net.http";

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
  error: string;
}

export interface SyncUploadRequest {
  device_id: string;
  data: string;
  timestamp: number;
}

export interface SyncDownloadRequest {
  device_id: string;
}
  success: boolean;
  error: string;
  data: string;
}

const SYNC_KEY = "sync_state";

export class SyncService {
  private memory: MemoryService;
  private deviceId: string = "";
  private lastSyncTime: number = 0;

  constructor(memory: MemoryService) {
    this.memory = memory;
  }

  async init(): Promise<void> {
    this.deviceId = `dev_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
    this.lastSyncTime = 0;
  }

  async upload(): Promise<SyncResult> {
    if (!this.deviceId) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: "设备未初始化" };
    }

    try {
      const profileRecords = await this.memory.getSemanticByCategory("profile");
      const prefRecords = await this.memory.getSemanticByCategory("preference");
      const valueRecords = await this.memory.getSemanticByCategory("value");
      const factRecords = await this.memory.getSemanticByCategory("fact");
      const allSemantic: SemanticRecord[] = [];
      for (let i = 0; i < profileRecords.length; i++) allSemantic.push(profileRecords[i]);
      for (let i = 0; i < prefRecords.length; i++) allSemantic.push(prefRecords[i]);
      for (let i = 0; i < valueRecords.length; i++) allSemantic.push(valueRecords[i]);
      for (let i = 0; i < factRecords.length; i++) allSemantic.push(factRecords[i]);

      const pkg: SyncPackage = {
        device_id: this.deviceId,
        last_sync_time: this.lastSyncTime,
        semantic_memory: allSemantic,
        episodic_memory: await this.memory.getTopEpisodic(50),
        procedural_memory: await this.memory.getAllProcedural(),
        relation_network: await this.memory.getAllRelations(),
        prediction_memory: [],
      };

      const uploadReq: SyncUploadRequest = {
        device_id: this.deviceId,
        data: JSON.stringify(pkg),
        timestamp: Date.now(),
      };
      const response = await this.httpPost("/sync/upload", uploadReq);

      if (response.success) {
        this.lastSyncTime = Date.now();
        return {
          success: true,
          synced_at: this.lastSyncTime,
          uploaded: pkg.semantic_memory.length + pkg.episodic_memory.length +
                    pkg.procedural_memory.length + pkg.relation_network.length,
          downloaded: 0,
          error: "",
        };
      }

      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: response.error };
    } catch (e) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: (e as Error).message };
    }
  }

  async download(): Promise<SyncResult> {
    if (!this.deviceId) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: "设备未初始化" };
    }

    try {
      const downloadReq: SyncDownloadRequest = { device_id: this.deviceId };
      const response = await this.httpPost("/sync/download", downloadReq);

      if (!response.success || !response.data) {
        return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: response.error || "无数据" };
      }

      const pkg: SyncPackage = JSON.parse(response.data);

      let downloaded = 0;

      for (let i = 0; i < pkg.semantic_memory.length; i++) {
        const r = pkg.semantic_memory[i];
        await this.memory.setSemantic({
          category: r.category,
          key: r.key,
          value: r.value,
          confidence: r.confidence || 0.5,
          source: "sync",
        });
        downloaded++;
      }

      const localEpisodes = await this.memory.getTopEpisodic(1000);
      for (let i = 0; i < pkg.episodic_memory.length; i++) {
        const e = pkg.episodic_memory[i];
        let exists = false;
        for (let j = 0; j < localEpisodes.length; j++) {
          if (localEpisodes[j].title === e.title && Math.abs(localEpisodes[j].event_time - e.event_time) < 60000) {
            exists = true;
            break;
          }
        }
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
            embedding_id: e.embedding_id,
          });
          downloaded++;
        }
      }

      const localPatterns = await this.memory.getAllProcedural();
      for (let i = 0; i < pkg.procedural_memory.length; i++) {
        const p = pkg.procedural_memory[i];
        let exists = false;
        for (let j = 0; j < localPatterns.length; j++) {
          if (localPatterns[j].description === p.description) {
            exists = true;
            break;
          }
        }
        if (!exists) {
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

      for (let i = 0; i < pkg.relation_network.length; i++) {
        const r = pkg.relation_network[i];
        await this.memory.mentionPerson(
          r.person_name,
          r.relation_type,
          r.sentiment || 0,
          r.notes
        );
        downloaded++;
      }

      this.lastSyncTime = Date.now();

      return {
        success: true,
        synced_at: this.lastSyncTime,
        uploaded: 0,
        downloaded,
        error: "",
      };
    } catch (e) {
      return { success: false, synced_at: 0, uploaded: 0, downloaded: 0, error: (e as Error).message };
    }
  }

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

  shouldSync(): boolean {
    return Date.now() - this.lastSyncTime > 6 * 60 * 60 * 1000;
  }

  private httpPost(path: string, body: object): Promise<SyncHttpResult> {
    const BASE = "http://192.168.1.100:8000";
    return new Promise((resolve) => {
      const req = http.createHttp();
      req.request(`${BASE}${path}`, {
        method: http.RequestMethod.POST,
        header: { "Content-Type": "application/json" },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.OBJECT,
        readTimeout: 30000,
        connectTimeout: 10000,
      }, (err: Error, data: http.HttpResponse) => {
        if (err || data.responseCode !== 200) {
          const errMsg = err ? err.message : `HTTP ${data.responseCode}`;
          resolve({ success: false, data: "", error: errMsg });
          return;
        }
        try {
          const result: Record<string, string | number | boolean> = typeof data.result === "string"
            ? JSON.parse(data.result) as Record<string, string | number | boolean> : data.result as Record<string, string | number | boolean>;
          resolve({ success: true, data: JSON.stringify(result), error: "" });
        } catch (e) {
          resolve({ success: false, data: "", error: "JSON 解析失败" });
        }
      });
    });
  }
}
