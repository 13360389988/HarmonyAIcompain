/**
 * DatabaseSchema.ets
 * ------------------
 * 知心数字孪生 — 本地 SQLite 数据库 Schema
 *
 * 六层记忆架构 + 行为日志 + 关系网络
 * 所有数据纯本地存储，后端只做无状态 LLM 推理。
 */

import relationalStore from "@ohos.data.relationalStore";

const DB_NAME = "zhixin_memory.db";

const CREATE_TABLES = `
CREATE TABLE IF NOT EXISTS short_term_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  emotion TEXT,
  location TEXT,
  timestamp INTEGER NOT NULL,
  session_id TEXT
);

CREATE TABLE IF NOT EXISTS episodic_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_time INTEGER NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  location TEXT,
  people TEXT,
  emotion TEXT,
  outcome TEXT,
  embedding_id TEXT,
  importance REAL DEFAULT 0.5,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS semantic_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  confidence REAL DEFAULT 0.5,
  source TEXT,
  evidence_count INTEGER DEFAULT 1,
  updated_at INTEGER NOT NULL,
  UNIQUE(category, key)
);

CREATE TABLE IF NOT EXISTS procedural_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  pattern_type TEXT NOT NULL,
  description TEXT NOT NULL,
  trigger_condition TEXT,
  action TEXT,
  frequency TEXT,
  confidence REAL DEFAULT 0.5,
  last_triggered INTEGER,
  trigger_count INTEGER DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS prediction_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  predicted_at INTEGER NOT NULL,
  target_time INTEGER NOT NULL,
  prediction_type TEXT NOT NULL,
  prediction TEXT NOT NULL,
  confidence REAL DEFAULT 0.5,
  reasoning TEXT,
  actual_result TEXT,
  verified_at INTEGER,
  error_score REAL,
  status TEXT DEFAULT 'pending'
);

CREATE TABLE IF NOT EXISTS behavior_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp INTEGER NOT NULL,
  action_type TEXT NOT NULL,
  data TEXT,
  location TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS relation_network (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_name TEXT NOT NULL,
  relation_type TEXT,
  relation_detail TEXT,
  first_mentioned INTEGER,
  last_mentioned INTEGER,
  mention_count INTEGER DEFAULT 1,
  sentiment REAL DEFAULT 0,
  notes TEXT,
  UNIQUE(person_name)
);

CREATE INDEX IF NOT EXISTS idx_stm_timestamp ON short_term_memory(timestamp);
CREATE INDEX IF NOT EXISTS idx_stm_session ON short_term_memory(session_id);
CREATE INDEX IF NOT EXISTS idx_em_event_time ON episodic_memory(event_time);
CREATE INDEX IF NOT EXISTS idx_em_importance ON episodic_memory(importance);
CREATE INDEX IF NOT EXISTS idx_sm_category ON semantic_memory(category);
CREATE INDEX IF NOT EXISTS idx_sm_key ON semantic_memory(key);
CREATE INDEX IF NOT EXISTS idx_pm_type ON procedural_memory(pattern_type);
CREATE INDEX IF NOT EXISTS idx_pm_frequency ON procedural_memory(frequency);
CREATE INDEX IF NOT EXISTS idx_pred_target ON prediction_memory(target_time);
CREATE INDEX IF NOT EXISTS idx_pred_status ON prediction_memory(status);
CREATE INDEX IF NOT EXISTS idx_bl_timestamp ON behavior_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_bl_type ON behavior_log(action_type);
CREATE INDEX IF NOT EXISTS idx_rn_name ON relation_network(person_name);
CREATE INDEX IF NOT EXISTS idx_rn_type ON relation_network(relation_type);
`;

export class MemoryDatabase {
  private store: relationalStore.RdbStore | null = null;

  async init(context: Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    };

    this.store = await relationalStore.getRdbStore(context, config);
    await this.store.executeSql(CREATE_TABLES);
    console.info("[MemoryDB] 数据库初始化完成");
  }

  getStore(): relationalStore.RdbStore {
    if (!this.store) throw new Error("MemoryDB 未初始化，请先调用 init()");
    return this.store;
  }

  async cleanupShortTerm(): Promise<void> {
    const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const store = this.getStore();
    await store.executeSql(
      "DELETE FROM short_term_memory WHERE timestamp < ?",
      [cutoff]
    );
  }

  async getStats(): Promise<Record<string, number>> {
    const store = this.getStore();
    const tables = [
      "short_term_memory",
      "episodic_memory",
      "semantic_memory",
      "procedural_memory",
      "prediction_memory",
      "behavior_log",
      "relation_network",
    ];
    const stats: Record<string, number> = {};
    for (let i = 0; i < tables.length; i++) {
      const t = tables[i];
      const rs = await store.querySql(`SELECT COUNT(*) as cnt FROM ${t}`);
      if (rs.goToFirstRow()) {
        stats[t] = rs.getLong(rs.getColumnIndex("cnt"));
      }
      rs.close();
    }
    return stats;
  }
}
