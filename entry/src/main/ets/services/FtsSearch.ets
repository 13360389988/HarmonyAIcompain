/**
 * FtsSearch.ets
 * --------------
 * 轻量级语义检索 — 用 SQLite FTS5 替代向量检索。
 *
 * 为什么不用向量检索？
 *   - ChromaDB 需要 sentence-transformers 模型（几百 MB）
 *   - 手机端推理慢、耗电
 *   - FTS5 是 SQLite 内置的全文检索引擎，零额外算力
 *
 * FTS5 能力：
 *   - 中文分词（按字 + 双字组合）
 *   - BM25 相关度排序
 *   - MATCH 查询，毫秒级响应
 *   - 支持 AND / OR / NEAR 等高级查询
 *
 * 检索范围：
 *   - episodic_memory（情景记忆）
 *   - short_term_memory（短期对话）
 *   - semantic_memory（语义记忆）
 */

import { MemoryDatabase } from "./DatabaseSchema";
import relationalStore from "@ohos.data.relationalStore";

export interface SearchResult {
  id: number;
  table_name: string;
  content: string;
  rank: number;  // BM25 相关度（越小越相关）
  meta: Record<string, Object>;
}

export class FtsSearch {
  private db: MemoryDatabase;
  private initialized: boolean = false;

  constructor(db: MemoryDatabase) {
    this.db = db;
  }

  /** 初始化 FTS 索引（在数据库初始化后调用一次） */
  async init(): Promise<void> {
    if (this.initialized) return;
    const store = this.db.getStore();

    // 创建 FTS5 虚拟表（对情景记忆建索引）
    await store.executeSql(`
      CREATE VIRTUAL TABLE IF NOT EXISTS episodic_fts USING fts5(
        title,
        description,
        content='episodic_memory',
        content_rowid='id',
        tokenize='unicode61'
      );
    `);

    // 创建短期记忆的 FTS 索引
    await store.executeSql(`
      CREATE VIRTUAL TABLE IF NOT EXISTS short_term_fts USING fts5(
        content,
        content='short_term_memory',
        content_rowid='id',
        tokenize='unicode61'
      );
    `);

    // 创建语义记忆的 FTS 索引
    await store.executeSql(`
      CREATE VIRTUAL TABLE IF NOT EXISTS semantic_fts USING fts5(
        key,
        value,
        content='semantic_memory',
        content_rowid='id',
        tokenize='unicode61'
      );
    `);

    this.initialized = true;
    console.info("[FtsSearch] FTS5 索引初始化完成");
  }

  /** 同步单条记录到 FTS 索引（写入记忆后调用） */
  async indexEpisodic(id: number, title: string, description: string): Promise<void> {
    const store = this.db.getStore();
    await store.executeSql(
      "INSERT OR REPLACE INTO episodic_fts(rowid, title, description) VALUES (?, ?, ?)",
      [id, title, description ?? ""]
    );
  }

  async indexShortTerm(id: number, content: string): Promise<void> {
    const store = this.db.getStore();
    await store.executeSql(
      "INSERT OR REPLACE INTO short_term_fts(rowid, content) VALUES (?, ?)",
      [id, content]
    );
  }

  async indexSemantic(id: number, key: string, value: string): Promise<void> {
    const store = this.db.getStore();
    await store.executeSql(
      "INSERT OR REPLACE INTO semantic_fts(rowid, key, value) VALUES (?, ?)",
      [id, key, value]
    );
  }

  /** 从 FTS 索引删除 */
  async removeEpisodic(id: number): Promise<void> {
    const store = this.db.getStore();
    await store.executeSql("DELETE FROM episodic_fts WHERE rowid = ?", [id]);
  }

  // ============================================================
  // 搜索接口
  // ============================================================

  /** 全局搜索（跨所有记忆层） */
  async search(query: string, limit: number = 20): Promise<SearchResult[]> {
    const ftsQuery = this.buildFtsQuery(query);
    if (!ftsQuery) return [];

    const store = this.db.getStore();
    const results: SearchResult[] = [];

    // 搜索情景记忆
    const epResults = await this.searchEpisodic(ftsQuery, limit);
    for (let i = 0; i < epResults.length; i++) {
      results.push(epResults[i]);
    }

    // 搜索短期记忆
    const stResults = await this.searchShortTerm(ftsQuery, limit);
    for (let i = 0; i < stResults.length; i++) {
      results.push(stResults[i]);
    }

    // 搜索语义记忆
    const semResults = await this.searchSemantic(ftsQuery, limit);
    for (let i = 0; i < semResults.length; i++) {
      results.push(semResults[i]);
    }

    // 按 rank 排序（越小越相关）
    results.sort((a, b) => a.rank - b.rank);
    return results.slice(0, limit);
  }

  /** 搜索情景记忆 */
  async searchEpisodic(ftsQuery: string, limit: number = 10): Promise<SearchResult[]> {
    const store = this.db.getStore();
    const rs = await store.querySql(`
      SELECT e.id, e.title, e.description, e.event_time, e.importance,
             bm25(episodic_fts) as rank
      FROM episodic_fts
      JOIN episodic_memory e ON e.id = episodic_fts.rowid
      WHERE episodic_fts MATCH ?
      ORDER BY rank
      LIMIT ?
    `, [ftsQuery, limit]);

    const results: SearchResult[] = [];
    if (rs.goToFirstRow()) {
      do {
        results.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          table_name: "episodic_memory",
          content: `${rs.getString(rs.getColumnIndex("title"))} ${rs.getString(rs.getColumnIndex("description"))}`,
          rank: rs.getDouble(rs.getColumnIndex("rank")),
          meta: {
            event_time: rs.getLong(rs.getColumnIndex("event_time")),
            importance: rs.getDouble(rs.getColumnIndex("importance")),
          },
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return results;
  }

  /** 搜索短期记忆 */
  async searchShortTerm(ftsQuery: string, limit: number = 10): Promise<SearchResult[]> {
    const store = this.db.getStore();
    const rs = await store.querySql(`
      SELECT s.id, s.content, s.role, s.timestamp,
             bm25(short_term_fts) as rank
      FROM short_term_fts
      JOIN short_term_memory s ON s.id = short_term_fts.rowid
      WHERE short_term_fts MATCH ?
      ORDER BY rank
      LIMIT ?
    `, [ftsQuery, limit]);

    const results: SearchResult[] = [];
    if (rs.goToFirstRow()) {
      do {
        results.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          table_name: "short_term_memory",
          content: rs.getString(rs.getColumnIndex("content")),
          rank: rs.getDouble(rs.getColumnIndex("rank")),
          meta: {
            role: rs.getString(rs.getColumnIndex("role")),
            timestamp: rs.getLong(rs.getColumnIndex("timestamp")),
          },
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return results;
  }

  /** 搜索语义记忆 */
  async searchSemantic(ftsQuery: string, limit: number = 10): Promise<SearchResult[]> {
    const store = this.db.getStore();
    const rs = await store.querySql(`
      SELECT s.id, s.key, s.value, s.category, s.confidence,
             bm25(semantic_fts) as rank
      FROM semantic_fts
      JOIN semantic_memory s ON s.id = semantic_fts.rowid
      WHERE semantic_fts MATCH ?
      ORDER BY rank
      LIMIT ?
    `, [ftsQuery, limit]);

    const results: SearchResult[] = [];
    if (rs.goToFirstRow()) {
      do {
        results.push({
          id: rs.getLong(rs.getColumnIndex("id")),
          table_name: "semantic_memory",
          content: `${rs.getString(rs.getColumnIndex("key"))}: ${rs.getString(rs.getColumnIndex("value"))}`,
          rank: rs.getDouble(rs.getColumnIndex("rank")),
          meta: {
            category: rs.getString(rs.getColumnIndex("category")),
            confidence: rs.getDouble(rs.getColumnIndex("confidence")),
          },
        });
      } while (rs.goToNextRow());
    }
    rs.close();
    return results;
  }

  // ============================================================
  // FTS 查询构建
  // ============================================================

  /**
   * 将用户输入转为 FTS5 查询语法。
   *
   * 策略：
   *   - 中文按字分词，用 OR 连接（提高召回）
   *   - 双字组合也加入查询（提高精度）
   *   - 自动加 * 前缀匹配
   *
   * 例："和小李聊项目" → "小* OR 李* OR 聊* OR 项* OR 目* OR 小李* OR 聊项*"
   */
  private buildFtsQuery(input: string): string {
    const trimmed = input.trim();
    if (!trimmed) return "";

    // 按非中文字符分割
    const rawChars = Array.from(trimmed);
    const chars: string[] = [];
    for (let i = 0; i < rawChars.length; i++) {
      if (rawChars[i].trim()) {
        chars.push(rawChars[i]);
      }
    }

    // 单字查询（OR 连接，加前缀 *）
    const singleCharQueries: string[] = [];
    for (let i = 0; i < chars.length; i++) {
      singleCharQueries.push(`"${chars[i]}"*`);
    }

    // 双字组合查询（提高精度）
    const bigramQueries: string[] = [];
    for (let i = 0; i < chars.length - 1; i++) {
      bigramQueries.push(`"${chars[i]}${chars[i + 1]}"*`);
    }

    // 组合：单字 OR 双字
    const allQueries: string[] = [];
    for (let i = 0; i < singleCharQueries.length; i++) {
      allQueries.push(singleCharQueries[i]);
    }
    for (let i = 0; i < bigramQueries.length; i++) {
      allQueries.push(bigramQueries[i]);
    }

    // FTS5 查询长度限制
    const limit = Math.min(20, allQueries.length);
    const resultArr: string[] = [];
    for (let i = 0; i < limit; i++) {
      resultArr.push(allQueries[i]);
    }
    return resultArr.join(" OR ");
  }

  /** 重建所有索引（数据迁移或修复时用） */
  async rebuildAllIndexes(): Promise<void> {
    const store = this.db.getStore();

    // 清空并重建情景记忆索引
    await store.executeSql("DELETE FROM episodic_fts;");
    const epRs = await store.querySql("SELECT id, title, description FROM episodic_memory");
    if (epRs.goToFirstRow()) {
      do {
        await this.indexEpisodic(
          epRs.getLong(epRs.getColumnIndex("id")),
          epRs.getString(epRs.getColumnIndex("title")),
          epRs.getString(epRs.getColumnIndex("description"))
        );
      } while (epRs.goToNextRow());
    }
    epRs.close();

    // 清空并重建短期记忆索引
    await store.executeSql("DELETE FROM short_term_fts;");
    const stRs = await store.querySql("SELECT id, content FROM short_term_memory");
    if (stRs.goToFirstRow()) {
      do {
        await this.indexShortTerm(
          stRs.getLong(stRs.getColumnIndex("id")),
          stRs.getString(stRs.getColumnIndex("content"))
        );
      } while (stRs.goToNextRow());
    }
    stRs.close();

    console.info("[FtsSearch] 所有索引重建完成");
  }
}
