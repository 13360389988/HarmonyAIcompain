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
const DB_VERSION = 1;

// ============================================================
// 建表 SQL
// ============================================================
const CREATE_TABLES = `
-- 1. 短期记忆（最近 7 天对话）
CREATE TABLE IF NOT EXISTS short_term_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  role TEXT NOT NULL,              -- user / assistant / system
  content TEXT NOT NULL,
  emotion TEXT,                    -- 情绪标签（happy/sad/neutral/anxious...）
  location TEXT,                   -- 发送时的位置描述
  timestamp INTEGER NOT NULL,      -- 毫秒时间戳
  session_id TEXT                  -- 会话 ID（同一次对话归为一组）
);

-- 2. 情景记忆（具体事件）
CREATE TABLE IF NOT EXISTS episodic_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_time INTEGER NOT NULL,     -- 事件发生时间
  title TEXT NOT NULL,             -- 事件标题（LLM 生成）
  description TEXT,                -- 详细描述
  location TEXT,                   -- 地点
  people TEXT,                     -- 涉及人物 JSON 数组
  emotion TEXT,                    -- 情绪
  outcome TEXT,                    -- 结果/后续
  embedding_id TEXT,               -- 关联向量 ID（用于语义检索）
  importance REAL DEFAULT 0.5,     -- 重要性 0-1
  created_at INTEGER NOT NULL
);

-- 3. 语义记忆（画像/偏好/价值观/事实）
CREATE TABLE IF NOT EXISTS semantic_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category TEXT NOT NULL,          -- profile / preference / value / fact / skill
  key TEXT NOT NULL,               -- 字段名（如 "职业"、"喜欢的电影类型"）
  value TEXT NOT NULL,             -- 字段值
  confidence REAL DEFAULT 0.5,     -- 置信度 0-1
  source TEXT,                     -- 来源：chat / behavior / location / manual
  evidence_count INTEGER DEFAULT 1,-- 证据次数（多次出现则累加）
  updated_at INTEGER NOT NULL,
  UNIQUE(category, key)
);

-- 4. 程序记忆（行为模式/习惯/规律）
CREATE TABLE IF NOT EXISTS procedural_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  pattern_type TEXT NOT NULL,      -- routine / habit / trigger / rhythm
  description TEXT NOT NULL,       -- "每周三晚 8 点去健身房"
  trigger_condition TEXT,          -- 触发条件 JSON
  action TEXT,                     -- 行为描述
  frequency TEXT,                  -- daily / weekly / monthly / irregular
  confidence REAL DEFAULT 0.5,
  last_triggered INTEGER,          -- 上次触发时间
  trigger_count INTEGER DEFAULT 0, -- 累计触发次数
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- 5. 预测记忆（预测 + 实际结果，用于校准）
CREATE TABLE IF NOT EXISTS prediction_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  predicted_at INTEGER NOT NULL,   -- 预测生成时间
  target_time INTEGER NOT NULL,    -- 预测目标时间
  prediction_type TEXT NOT NULL,   -- location / behavior / emotion / decision
  prediction TEXT NOT NULL,        -- 预测内容
  confidence REAL DEFAULT 0.5,     -- 预测置信度
  reasoning TEXT,                  -- 预测依据
  actual_result TEXT,              -- 实际结果（NULL = 未验证）
  verified_at INTEGER,             -- 验证时间
  error_score REAL,                -- 误差分数（0=完全正确，1=完全错误）
  status TEXT DEFAULT 'pending'    -- pending / verified / failed
);

-- 6. 行为日志（原始数据，用于挖掘模式）
CREATE TABLE IF NOT EXISTS behavior_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp INTEGER NOT NULL,
  action_type TEXT NOT NULL,       -- chat / location / app_switch / emotion / sleep / wake
  data TEXT,                       -- JSON 详细数据
  location TEXT,                   -- 位置描述
  created_at INTEGER NOT NULL
);

-- 7. 关系网络（社交关系）
CREATE TABLE IF NOT EXISTS relation_network (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_name TEXT NOT NULL,       -- 人物姓名/称呼
  relation_type TEXT,              -- family / friend / colleague / lover / acquaintance
  relation_detail TEXT,            -- 关系细节（如"表哥"、"前同事"）
  first_mentioned INTEGER,         -- 首次提及时间
  last_mentioned INTEGER,          -- 最近提及时间
  mention_count INTEGER DEFAULT 1, -- 提及次数
  sentiment REAL DEFAULT 0,        -- 关系情感倾向 -1 到 1
  notes TEXT,                      -- 备注
  UNIQUE(person_name)
);

-- ============================================================
-- 索引
-- ============================================================
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

// ============================================================
// 数据库管理器
// ============================================================
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

  /** 清理 7 天前的短期记忆 */
  async cleanupShortTerm(): Promise<number> {
    const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const store = this.getStore();
    const result = await store.executeSql(
      "DELETE FROM short_term_memory WHERE timestamp < ?",
      [cutoff]
    );
    return result.rowCount;
  }

  /** 数据库统计（用于设置页展示） */
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
    for (const t of tables) {
      const rs = await store.querySql(`SELECT COUNT(*) as cnt FROM ${t}`);
      if (rs.goToFirstRow()) {
        stats[t] = rs.getLong(rs.getColumnIndex("cnt"));
      }
      rs.close();
    }
    return stats;
  }
}
