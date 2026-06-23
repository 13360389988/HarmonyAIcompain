"""
记忆系统
--------
三层记忆架构：
  1. SQLite 用户画像 — 键值对，持久化存储用户特征、偏好
  2. Chroma 长期记忆  — 语义检索，sentence-transformers 向量化
  3. 列表短期记忆    — 缓存最近 N 轮对话（user + assistant）
"""

import sqlite3
import os
from collections import OrderedDict

from chromadb import PersistentClient
from sentence_transformers import SentenceTransformer

from config import (
    SQLITE_DB_PATH,
    CHROMA_CONFIG,
    SHORT_TERM_CONFIG,
    EMBEDDING_CONFIG,
)


# ============================================================
# 1. SQLite 用户画像（键值对）
# ============================================================
class UserProfile:
    """
    基于 SQLite 的键值对存储，用于持久化用户画像。

    用法：
        profile = UserProfile()
        profile.set("name", "小明")
        profile.get("name")         # "小明"
        profile.get("missing_key")  # None
    """

    def __init__(self, db_path: str = SQLITE_DB_PATH):
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.execute("""
            CREATE TABLE IF NOT EXISTS profile (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
        """)
        self._conn.commit()

    def set(self, key: str, value: str) -> None:
        """写入或覆盖一个画像字段。"""
        self._conn.execute(
            "INSERT INTO profile (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
        self._conn.commit()

    def get(self, key: str) -> str | None:
        """读取画像字段，不存在时返回 None。"""
        row = self._conn.execute(
            "SELECT value FROM profile WHERE key = ?", (key,)
        ).fetchone()
        return row[0] if row else None

    def delete(self, key: str) -> None:
        """删除一个画像字段。"""
        self._conn.execute("DELETE FROM profile WHERE key = ?", (key,))
        self._conn.commit()

    def all(self) -> dict[str, str]:
        """返回所有画像字段的字典副本。"""
        rows = self._conn.execute("SELECT key, value FROM profile").fetchall()
        return dict(rows)

    def close(self) -> None:
        self._conn.close()


# ============================================================
# 2. Chroma 长期记忆（语义检索）
# ============================================================
class LongTermMemory:
    """
    基于 ChromaDB + sentence-transformers 的长期记忆。

    用法：
        ltm = LongTermMemory()
        ltm.add("用户喜欢喝咖啡。")
        ltm.add("用户昨天提到下周有考试。")
        results = ltm.query("用户有什么安排？", k=3)
    """

    def __init__(
        self,
        persist_dir: str = CHROMA_CONFIG["persist_directory"],
        collection_name: str = CHROMA_CONFIG["collection_name"],
        model_name: str = EMBEDDING_CONFIG["model_name"],
    ):
        os.makedirs(persist_dir, exist_ok=True)

        # 嵌入模型
        self._model = SentenceTransformer(model_name)

        # Chroma 客户端
        self._client = PersistentClient(path=persist_dir)
        self._collection = self._client.get_or_create_collection(
            name=collection_name,
            metadata={"hnsw:space": "cosine"},
        )

    def add(self, text: str, metadata: dict | None = None) -> str:
        """
        将一条文本向量化后存入长期记忆。

        Args:
            text: 要记忆的文本
            metadata: 可选的附加元数据

        Returns:
            生成的记录 ID
        """
        embedding = self._model.encode([text]).tolist()
        record_id = f"mem_{os.urandom(6).hex()}"
        self._collection.add(
            ids=[record_id],
            embeddings=embedding,
            documents=[text],
            metadatas=[metadata or {}],
        )
        return record_id

    def query(self, text: str, k: int = 5) -> list[dict]:
        """
        根据查询文本检索最相关的 top-k 条长期记忆。

        Args:
            text: 查询文本
            k: 返回条数

        Returns:
            [{id, document, metadata, distance}, ...]
        """
        embedding = self._model.encode([text]).tolist()
        results = self._collection.query(
            query_embeddings=embedding,
            n_results=k,
            include=["documents", "metadatas", "distances"],
        )

        out = []
        ids = results.get("ids", [[]])[0]
        docs = results.get("documents", [[]])[0]
        metas = results.get("metadatas", [[]])[0]
        dists = results.get("distances", [[]])[0]

        for i, doc_id in enumerate(ids):
            out.append({
                "id": doc_id,
                "document": docs[i] if i < len(docs) else "",
                "metadata": metas[i] if i < len(metas) else {},
                "distance": dists[i] if i < len(dists) else None,
            })
        return out

    def delete(self, record_id: str) -> None:
        """按 ID 删除一条记忆。"""
        self._collection.delete(ids=[record_id])

    def count(self) -> int:
        """返回记忆总数。"""
        return self._collection.count()

    def clear(self) -> None:
        """清空全部长期记忆。"""
        all_ids = self._collection.get()["ids"]
        if all_ids:
            self._collection.delete(ids=all_ids)


# ============================================================
# 3. 短期记忆（滑动窗口）
# ============================================================
class ShortTermMemory:
    """
    基于内存列表的短期记忆，缓存最近 N 轮对话。

    每轮为一个 dict: {"user": ..., "assistant": ...}

    用法：
        stm = ShortTermMemory(max_rounds=10)
        stm.add_round("你好", "你好！有什么可以帮你的？")
        stm.add_round("今天天气如何？", "很晴朗。")
        rounds = stm.get_recent(5)  # 取最近 5 轮
    """

    def __init__(self, max_rounds: int = SHORT_TERM_CONFIG["max_rounds"]):
        self.max_rounds = max_rounds
        self._rounds: list[dict[str, str]] = []

    def add_round(self, user_msg: str, assistant_msg: str) -> None:
        """添加一轮对话，超出上限时自动丢弃最早的。"""
        self._rounds.append({
            "user": user_msg,
            "assistant": assistant_msg,
        })
        # 保持窗口大小
        if len(self._rounds) > self.max_rounds:
            self._rounds = self._rounds[-self.max_rounds:]

    def get_recent(self, n: int | None = None) -> list[dict[str, str]]:
        """
        获取最近的 n 轮对话。

        Args:
            n: 取最近 n 轮，不传则返回全部缓存

        Returns:
            [{"user": ..., "assistant": ...}, ...]
        """
        if n is None:
            return list(self._rounds)
        n = max(0, min(n, len(self._rounds)))
        return self._rounds[-n:]

    def get_all(self) -> list[dict[str, str]]:
        """获取全部缓存的对话轮次。"""
        return list(self._rounds)

    def clear(self) -> None:
        """清空全部短期记忆。"""
        self._rounds.clear()

    @property
    def size(self) -> int:
        """当前缓存的轮数。"""
        return len(self._rounds)

    def to_flat_text(self, n: int | None = None) -> str:
        """
        将最近 n 轮对话展平为一段文本，方便直接作为模型上下文。

        格式：
            用户：xxx
            助手：xxx
            用户：yyy
            助手：yyy
        """
        rounds = self.get_recent(n)
        lines = []
        for r in rounds:
            lines.append(f"用户：{r['user']}")
            lines.append(f"助手：{r['assistant']}")
        return "\n".join(lines)
