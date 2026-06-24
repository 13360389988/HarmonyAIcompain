/**
 * MemoryService.ets
 * -----------------
 * 六层记忆管理服务。
 */

import { MemoryDatabase } from "./DatabaseSchema";
import relationalStore from "@ohos.data.relationalStore";

export interface ShortTermRecord {
  id: number;
  role: string;
  content: string;
  emotion: string;
  location: string;
  timestamp: number;
  session_id: string;
}

export interface EpisodicRecord {
  id: number;
  event_time: number;
  title: string;
  description: string;
  location: string;
  people: string;
  emotion: string;
  outcome: string;
  embedding_id: string;
  importance: number;
  created_at: number;
}

export interface SemanticRecord {
  id: number;
  category: string;
  key: string;
  value: string;
  confidence: number;
  source: string;
  evidence_count: number;
  updated_at: number;
}

export interface ProceduralRecord {
  id: number;
  pattern_type: string;
  description: string;
  trigger_condition: string;
  action: string;
  frequency: string;
  confidence: number;
  last_triggered: number;
  trigger_count: number;
  created_at: number;
  updated_at: number;
}

export interface PredictionRecord {
  id: number;
  predicted_at: number;
  target_time: number;
  prediction_type: string;
  prediction: string;
  confidence: number;
  reasoning: string;
  actual_result: string;
  verified_at: number;
  error_score: number;
  status: string;
}

export interface BehaviorLog {
  id: number;
  timestamp: number;
  action_type: string;
  data: string;
  location: string;
  created_at: number;
}

export interface RelationRecord {
  id: number;
  person_name: string;
  relation_type: string;
  relation_detail: string;
  first_mentioned: number;
  last_mentioned: number;
  mention_count: number;
  sentiment: number;
  notes: string;
}

export interface WorkingMessage {
  role: string;
  content: string;
}

export interface AddShortTermInput {
  role: string;
  content: string;
  emotion?: string;
  location?: string;
  timestamp?: number;
  session_id?: string;
}

export interface AddEpisodicInput {
  event_time: number;
  title: string;
  description?: string;
  location?: string;
  people?: string;
  emotion?: string;
  outcome?: string;
  embedding_id?: string;
  importance?: number;
  created_at?: number;
}

export interface SetSemanticInput {
  category: string;
  key: string;
  value: string;
  confidence?: number;
  source?: string;
  evidence_count?: number;
  id?: number;
}

export interface AddProceduralInput {
  pattern_type: string;
  description: string;
  trigger_condition?: string;
  action?: string;
  frequency?: string;
  confidence?: number;
  last_triggered?: number;
  trigger_count?: number;
  created_at?: number;
  updated_at?: number;
}

export interface AddPredictionInput {
  predicted_at: number;
  target_time: number;
  prediction_type: string;
  prediction: string;
  confidence?: number;
  reasoning?: string;
  actual_result?: string;
  verified_at?: number;
  error_score?: number;
  status?: string;
}

export interface PredictionAccuracy {
  total: number;
  verified: number;
  avgError: number;
}

export class MemoryService {
  private db: MemoryDatabase = new MemoryDatabase();
  private sessionId: string = "";

  async init(context: Context): Promise<void> {
    await this.db.init(context);
    this.sessionId = `s_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    await this.db.cleanupShortTerm();
  }

  private get store(): relationalStore.RdbStore {
    return this.db.getStore();
  }

  // Working memory
  private workingMemory: WorkingMessage[] = [];

  addWorkingMessage(role: string, content: string): void {
    this.workingMemory.push({ role, content });
    if (this.workingMemory.length > 20) {
      this.workingMemory.shift();
    }
  }

  getWorkingMemory(): WorkingMessage[] {
    const result: WorkingMessage[] = [];
    for (let i = 0; i < this.workingMemory.length; i++) {
      result.push(this.workingMemory[i]);
    }
    return result;
  }

  clearWorkingMemory(): void {
    this.workingMemory = [];
  }

  // Short-term memory
  async addShortTerm(rec: AddShortTermInput): Promise<number> {
    const record: ShortTermRecord = {
      id: 0,
      role: rec.role,
      content: rec.content,
      emotion: rec.emotion || "",
      location: rec.location || "",
      timestamp: rec.timestamp || Date.now(),
      session_id: rec.session_id || this.sessionId,
    };
    const values: relationalStore.ValuesBucket = {
      role: record.role,
      content: record.content,
      emotion: record.emotion,
      location: record.location,
      timestamp: record.timestamp,
      session_id: record.session_id,
    };
    const result = await this.store.insert("short_term_memory", values);
    return result;
  }

  async getRecentRounds(rounds: number = 10): Promise<ShortTermRecord[]> {
    const rs = await this.store.querySql(
      `SELECT * FROM short_term_memory ORDER BY timestamp DESC LIMIT ${rounds * 2}`
    );
    const list: ShortTermRecord[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push(this._rowToShortTerm(rs));
      } while (rs.goToNextRow());
    }
    rs.close();
    const reversed: ShortTermRecord[] = [];
    for (let i = list.length - 1; i >= 0; i--) {
      reversed.push(list[i]);
    }
    return reversed;
  }

  async getShortTermByRange(start: number, end: number): Promise<ShortTermRecord[]> {
    const rs = await this.store.querySql(
      "SELECT * FROM short_term_memory WHERE timestamp BETWEEN ? AND ? ORDER BY timestamp ASC",
      [start, end]
    );
    const list: ShortTermRecord[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push(this._rowToShortTerm(rs));
      } while (rs.goToNextRow());
    }
    rs.close();
    return list;
  }

  // Episodic memory
  async addEpisodic(rec: AddEpisodicInput): Promise<number> {
    const now = Date.now();
    const values: relationalStore.ValuesBucket = {
      event_time: rec.event_time,
      title: rec.title,
      description: rec.description || "",
      location: rec.location || "",
      people: rec.people || "",
      emotion: rec.emotion || "",
      outcome: rec.outcome || "",
      embedding_id: rec.embedding_id || "",
      importance: rec.importance || 0.5,
      created_at: rec.created_at || now,
    };
    return await this.store.insert("episodic_memory", values);
  }

  async getEpisodicByTime(start: number, end: number): Promise<EpisodicRecord[]> {
    const rs = await this.store.querySql(
      "SELECT * FROM episodic_memory WHERE event_time BETWEEN ? AND ? ORDER BY event_time DESC",
      [start, end]
    );
    return this._rowsToEpisodic(rs);
  }

  async getTopEpisodic(limit: number = 10): Promise<EpisodicRecord[]> {
    const rs = await this.store.querySql(
      `SELECT * FROM episodic_memory ORDER BY importance DESC, event_time DESC LIMIT ${limit}`
    );
    return this._rowsToEpisodic(rs);
  }

  async searchEpisodic(keyword: string): Promise<EpisodicRecord[]> {
    const rs = await this.store.querySql(
      "SELECT * FROM episodic_memory WHERE title LIKE ? OR description LIKE ? ORDER BY event_time DESC",
      [`%${keyword}%`, `%${keyword}%`]
    );
    return this._rowsToEpisodic(rs);
  }

  // Semantic memory
  async setSemantic(rec: SetSemanticInput): Promise<void> {
    const now = Date.now();
    const rs = await this.store.querySql(
      "SELECT id, evidence_count, confidence FROM semantic_memory WHERE category = ? AND key = ?",
      [rec.category, rec.key]
    );
    if (rs.goToFirstRow()) {
      const id = rs.getLong(rs.getColumnIndex("id"));
      const evidence = rs.getLong(rs.getColumnIndex("evidence_count")) + 1;
      const oldConf = rs.getDouble(rs.getColumnIndex("confidence"));
      const newConf = Math.min(1.0, oldConf + 0.1);
      rs.close();
      const confValue: number = rec.confidence !== undefined ? rec.confidence : newConf;
      const sourceValue: string = rec.source !== undefined ? rec.source : "";
      const updateValues: relationalStore.ValuesBucket = {
        value: rec.value,
        confidence: confValue,
        source: sourceValue,
        evidence_count: evidence,
        updated_at: now,
      };
      await this.store.update(
        "semantic_memory",
        updateValues,
        "id = ?",
        [id]
      );
    } else {
      rs.close();
      await this.store.insert("semantic_memory", {
        category: rec.category,
        key: rec.key,
        value: rec.value,
        confidence: rec.confidence || 0.5,
        source: rec.source || "",
        evidence_count: rec.evidence_count || 1,
        updated_at: now,
      });
    }
  }

  async getSemanticByCategory(category: string): Promise<SemanticRecord[]> {
    const rs = await this.store.querySql(
      "SELECT * FROM semantic_memory WHERE category = ? ORDER BY updated_at DESC",
      [category]
    );
    return this._rowsToSemantic(rs);
  }

  async getFullProfile(): Promise<Record<string, string>> {
    const rs = await this.store.querySql(
      "SELECT key, value FROM semantic_memory ORDER BY confidence DESC, updated_at DESC"
    );
    const profile: Record<string, string> = {};
    if (rs.goToFirstRow()) {
      do {
        const k = rs.getString(rs.getColumnIndex("key"));
        const v = rs.getString(rs.getColumnIndex("value"));
        profile[k] = v;
      } while (rs.goToNextRow());
    }
    rs.close();
    return profile;
  }

  // Procedural memory
  async addProcedural(rec: AddProceduralInput): Promise<number> {
    const now = Date.now();
    const values: relationalStore.ValuesBucket = {
      pattern_type: rec.pattern_type,
      description: rec.description,
      trigger_condition: rec.trigger_condition || "",
      action: rec.action || "",
      frequency: rec.frequency || "",
      confidence: rec.confidence || 0.5,
      last_triggered: rec.last_triggered || 0,
      trigger_count: rec.trigger_count || 0,
      created_at: rec.created_at || now,
      updated_at: rec.updated_at || now,
    };
    return await this.store.insert("procedural_memory", values);
  }

  async getAllProcedural(): Promise<ProceduralRecord[]> {
    const rs = await this.store.querySql(
      "SELECT * FROM procedural_memory ORDER BY confidence DESC, trigger_count DESC"
    );
    return this._rowsToProcedural(rs);
  }

  async triggerProcedural(id: number): Promise<void> {
    const now = Date.now();
    await this.store.executeSql(
      "UPDATE procedural_memory SET trigger_count = trigger_count + 1, last_triggered = ?, updated_at = ? WHERE id = ?",
      [now, now, id]
    );
  }

  // Prediction memory
  async addPrediction(rec: AddPredictionInput): Promise<number> {
    const values: relationalStore.ValuesBucket = {
      predicted_at: rec.predicted_at,
      target_time: rec.target_time,
      prediction_type: rec.prediction_type,
      prediction: rec.prediction,
      confidence: rec.confidence || 0.5,
      reasoning: rec.reasoning || "",
      actual_result: rec.actual_result || "",
      verified_at: rec.verified_at || 0,
      error_score: rec.error_score || 0,
      status: rec.status || "pending",
    };
    return await this.store.insert("prediction_memory", values);
  }

  async getPendingPredictions(): Promise<PredictionRecord[]> {
    const now = Date.now();
    const rs = await this.store.querySql(
      "SELECT * FROM prediction_memory WHERE status = 'pending' AND target_time <= ? ORDER BY target_time ASC",
      [now]
    );
    return this._rowsToPrediction(rs);
  }

  async verifyPrediction(id: number, actualResult: string, errorScore: number): Promise<void> {
    const now = Date.now();
    const updateValues: relationalStore.ValuesBucket = {
      actual_result: actualResult,
      verified_at: now,
      error_score: errorScore,
      status: "verified",
    };
    await this.store.update(
      "prediction_memory",
      updateValues,
      "id = ?",
      [id]
    );
  }

  async getPredictionAccuracy(): Promise<PredictionAccuracy> {
    const rs = await this.store.querySql(
      "SELECT COUNT(*) as total, AVG(error_score) as avg_err FROM prediction_memory WHERE status = 'verified'"
    );
    let total = 0;
    let avgErr = 0;
    if (rs.goToFirstRow()) {
      total = rs.getLong(rs.getColumnIndex("total"));
      avgErr = rs.getDouble(rs.getColumnIndex("avg_err"));
    }
    rs.close();
    return {
      total,
      verified: total,
      avgError: avgErr,
    };
  }

  // Behavior log
  async logBehavior(actionType: string, data: Record<string, string | number | boolean>, location?: string): Promise<void> {
    const now = Date.now();
    await this.store.insert("behavior_log", {
      timestamp: now,
      action_type: actionType,
      data: JSON.stringify(data),
      location: location || "",
      created_at: now,
    });
  }

  async getBehaviorByRange(start: number, end: number, actionType?: string): Promise<BehaviorLog[]> {
    let sql = "SELECT * FROM behavior_log WHERE timestamp BETWEEN ? AND ?";
    const args: (string | number)[] = [start, end];
    if (actionType) {
      sql += " AND action_type = ?";
      args.push(actionType);
    }
    sql += " ORDER BY timestamp ASC";
    const rs = await this.store.querySql(sql, args);
    const list: BehaviorLog[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          timestamp: rs.getLong(rs.getColumnIndex("timestamp")),
          action_type: rs.getString(rs.getColumnIndex("action_type")),
          data: rs.getString(rs.getColumnIndex("data")),
          location: rs.getString(rs.getColumnIndex("location")),
          created_at: rs.getLong(rs.getColumnIndex("created_at")),
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return list;
  }

  // Relations
  async mentionPerson(name: string, relationType?: string, sentiment: number = 0, notes?: string): Promise<void> {
    const now = Date.now();
    const rs = await this.store.querySql(
      "SELECT id, mention_count FROM relation_network WHERE person_name = ?",
      [name]
    );
    if (rs.goToFirstRow()) {
      const id = rs.getLong(rs.getColumnIndex("id"));
      const count = rs.getLong(rs.getColumnIndex("mention_count")) + 1;
      rs.close();
      await this.store.update(
        "relation_network",
        {
          last_mentioned: now,
          mention_count: count,
          relation_type: relationType || "",
          sentiment: sentiment,
          notes: notes || "",
        } as relationalStore.ValuesBucket,
        "id = ?",
        [id]
      );
    } else {
      rs.close();
      await this.store.insert("relation_network", {
        person_name: name,
        relation_type: relationType || "",
        first_mentioned: now,
        last_mentioned: now,
        mention_count: 1,
        sentiment: sentiment,
        notes: notes || "",
      });
    }
  }

  async getAllRelations(): Promise<RelationRecord[]> {
    const rs = await this.store.querySql(
      "SELECT * FROM relation_network ORDER BY mention_count DESC, last_mentioned DESC"
    );
    const list: RelationRecord[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          person_name: rs.getString(rs.getColumnIndex("person_name")),
          relation_type: rs.getString(rs.getColumnIndex("relation_type")),
          relation_detail: rs.getString(rs.getColumnIndex("relation_detail")),
          first_mentioned: rs.getLong(rs.getColumnIndex("first_mentioned")),
          last_mentioned: rs.getLong(rs.getColumnIndex("last_mentioned")),
          mention_count: rs.getLong(rs.getColumnIndex("mention_count")),
          sentiment: rs.getDouble(rs.getColumnIndex("sentiment")),
          notes: rs.getString(rs.getColumnIndex("notes")),
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return list;
  }

  // Helper: row to object
  private _rowToShortTerm(rs: relationalStore.ResultSet): ShortTermRecord {
    return {
      id: rs.getLong(rs.getColumnIndex("id")),
      role: rs.getString(rs.getColumnIndex("role")),
      content: rs.getString(rs.getColumnIndex("content")),
      emotion: rs.getString(rs.getColumnIndex("emotion")),
      location: rs.getString(rs.getColumnIndex("location")),
      timestamp: rs.getLong(rs.getColumnIndex("timestamp")),
      session_id: rs.getString(rs.getColumnIndex("session_id")),
    };
  }

  private _rowsToEpisodic(rs: relationalStore.ResultSet): EpisodicRecord[] {
    const list: EpisodicRecord[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          event_time: rs.getLong(rs.getColumnIndex("event_time")),
          title: rs.getString(rs.getColumnIndex("title")),
          description: rs.getString(rs.getColumnIndex("description")),
          location: rs.getString(rs.getColumnIndex("location")),
          people: rs.getString(rs.getColumnIndex("people")),
          emotion: rs.getString(rs.getColumnIndex("emotion")),
          outcome: rs.getString(rs.getColumnIndex("outcome")),
          embedding_id: rs.getString(rs.getColumnIndex("embedding_id")),
          importance: rs.getDouble(rs.getColumnIndex("importance")),
          created_at: rs.getLong(rs.getColumnIndex("created_at")),
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return list;
  }

  private _rowsToSemantic(rs: relationalStore.ResultSet): SemanticRecord[] {
    const list: SemanticRecord[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          category: rs.getString(rs.getColumnIndex("category")),
          key: rs.getString(rs.getColumnIndex("key")),
          value: rs.getString(rs.getColumnIndex("value")),
          confidence: rs.getDouble(rs.getColumnIndex("confidence")),
          source: rs.getString(rs.getColumnIndex("source")),
          evidence_count: rs.getLong(rs.getColumnIndex("evidence_count")),
          updated_at: rs.getLong(rs.getColumnIndex("updated_at")),
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return list;
  }

  private _rowsToProcedural(rs: relationalStore.ResultSet): ProceduralRecord[] {
    const list: ProceduralRecord[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          pattern_type: rs.getString(rs.getColumnIndex("pattern_type")),
          description: rs.getString(rs.getColumnIndex("description")),
          trigger_condition: rs.getString(rs.getColumnIndex("trigger_condition")),
          action: rs.getString(rs.getColumnIndex("action")),
          frequency: rs.getString(rs.getColumnIndex("frequency")),
          confidence: rs.getDouble(rs.getColumnIndex("confidence")),
          last_triggered: rs.getLong(rs.getColumnIndex("last_triggered")),
          trigger_count: rs.getLong(rs.getColumnIndex("trigger_count")),
          created_at: rs.getLong(rs.getColumnIndex("created_at")),
          updated_at: rs.getLong(rs.getColumnIndex("updated_at")),
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return list;
  }

  private _rowsToPrediction(rs: relationalStore.ResultSet): PredictionRecord[] {
    const list: PredictionRecord[] = [];
    if (rs.goToFirstRow()) {
      do {
        list.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          predicted_at: rs.getLong(rs.getColumnIndex("predicted_at")),
          target_time: rs.getLong(rs.getColumnIndex("target_time")),
          prediction_type: rs.getString(rs.getColumnIndex("prediction_type")),
          prediction: rs.getString(rs.getColumnIndex("prediction")),
          confidence: rs.getDouble(rs.getColumnIndex("confidence")),
          reasoning: rs.getString(rs.getColumnIndex("reasoning")),
          actual_result: rs.getString(rs.getColumnIndex("actual_result")),
          verified_at: rs.getLong(rs.getColumnIndex("verified_at")),
          error_score: rs.getDouble(rs.getColumnIndex("error_score")),
          status: rs.getString(rs.getColumnIndex("status")),
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return list;
  }

  async getStats(): Promise<Record<string, number>> {
    return await this.db.getStats();
  }
}
