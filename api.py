"""
FastAPI 无状态推理服务
---------------------
本服务不存储任何用户数据，只做 LLM 推理。
所有用户上下文由前端（鸿蒙端）打包传入，结果返回后前端自行写入本地六层记忆。

接口：
  POST /chat        — 对话（带上下文）
  POST /extract     — 单独提取结构化信息
  POST /summarize   — 生成对话摘要
  POST /predict     — 预测用户下一步动向
  POST /decision    — 决策辅助
  POST /morning     — 生成早安问候
  POST /evening     — 生成晚间复盘
  POST /sync/upload   — 上传加密摘要（多设备同步）
  POST /sync/download — 下载加密摘要（换机恢复）
  GET  /            — 健康检查
"""

from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import logging
import uvicorn
import time
import os
from pathlib import Path

from fastapi import FastAPI
from pydantic import BaseModel, Field
from typing import Any, Optional

from brain import CompanionBrain
from config import SERVER_CONFIG

logger = logging.getLogger(__name__)

# ---- 应用初始化 ----
class UTF8JSONResponse(JSONResponse):
    media_type = "application/json; charset=utf-8"

app = FastAPI(default_response_class=UTF8JSONResponse)

# 允许所有来源跨域（开发期；上线请收紧 origins）
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 无状态推理引擎（不持有任何用户数据）
brain = CompanionBrain()

# 同步数据存储目录（只存加密摘要，不解读）
SYNC_DIR = Path(__file__).parent / "sync_data"
SYNC_DIR.mkdir(exist_ok=True)


# ============================================================
# 请求/响应模型
# ============================================================
class ChatRequest(BaseModel):
    message: str
    current_time: Optional[str] = None
    current_location: Optional[str] = None
    user_profile: dict = {}
    recent_conversations: list = []      # [{"user": "...", "assistant": "..."}]
    relevant_episodes: list = []         # [{"title": "...", "description": "...", "time": "..."}]
    behavior_patterns: list = []         # [{"description": "...", "confidence": 0.8}]
    relations: list = []                 # [{"name": "...", "relation": "...", "mentions": 3}]
    pending_predictions: list = []


class ChatResponse(BaseModel):
    reply: str
    extracted: dict = {}


class SummarizeRequest(BaseModel):
    conversation_text: str


class PredictRequest(BaseModel):
    current_time: Optional[str] = None
    current_location: Optional[str] = None
    user_profile: dict = {}
    behavior_patterns: list = []
    recent_behaviors: list = []          # [{"time": "...", "action": "..."}]


class DecisionRequest(BaseModel):
    decision_question: str
    options: list = []
    user_profile: dict = {}
    relevant_episodes: list = []
    similar_decisions: list = []         # [{"question": "...", "choice": "...", "outcome": "..."}]


class GreetingRequest(BaseModel):
    current_time: Optional[str] = None
    user_profile: dict = {}
    relevant_episodes: list = []
    behavior_patterns: list = []


# ============================================================
# POST /chat — 对话（带完整上下文）
# ============================================================
@app.post("/chat", response_model=ChatResponse)
def chat_endpoint(req: ChatRequest):
    """
    发送一条消息给 AI 伙伴，返回回复文本 + 结构化提取结果。

    前端拿到 extracted 后，自行写入本地六层记忆：
      - extracted.emotion → short_term_memory.emotion
      - extracted.profile_updates → semantic_memory
      - extracted.episodes → episodic_memory
      - extracted.persons → relation_network
    """
    result = brain.respond(req.model_dump())
    return ChatResponse(
        reply=result.get("reply", ""),
        extracted=result.get("extracted", {}),
    )


# ============================================================
# POST /summarize — 生成对话摘要
# ============================================================
@app.post("/summarize")
def summarize_endpoint(req: SummarizeRequest):
    """生成对话摘要，供前端存入情景记忆。"""
    summary = brain.summarize_conversation(req.conversation_text)
    return {"summary": summary}


# ============================================================
# POST /predict — 预测用户下一步动向
# ============================================================
@app.post("/predict")
def predict_endpoint(req: PredictRequest):
    """基于历史行为模式预测用户未来 24 小时动向。"""
    result = brain.predict_next(req.model_dump())
    return result


# ============================================================
# POST /decision — 决策辅助
# ============================================================
@app.post("/decision")
def decision_endpoint(req: DecisionRequest):
    """辅助重大决策。"""
    result = brain.assist_decision(req.model_dump())
    return result


# ============================================================
# POST /morning — 早安问候
# ============================================================
@app.post("/morning")
def morning_endpoint(req: GreetingRequest):
    """生成早安问候（前端定时调用）。"""
    text = brain.generate_morning_greeting(req.model_dump())
    return {"content": text}


# ============================================================
# POST /evening — 晚间复盘
# ============================================================
@app.post("/evening")
def evening_endpoint(req: GreetingRequest):
    """生成晚间复盘（前端定时调用）。"""
    text = brain.generate_evening_review(req.model_dump())
    return {"content": text}


# ============================================================
# GET / — 健康检查
# ============================================================
@app.get("/")
def root():
    return {
        "status": "running",
        "mode": "stateless",
        "description": "无状态推理服务 — 不存储任何用户数据",
        "endpoints": [
            "POST /chat - 对话（带上下文）",
            "POST /summarize - 生成摘要",
            "POST /predict - 预测下一步",
            "POST /decision - 决策辅助",
            "POST /morning - 早安问候",
            "POST /evening - 晚间复盘",
            "POST /sync/upload - 上传同步",
            "POST /sync/download - 下载同步",
        ],
    }


# ============================================================
# 同步接口（多设备同步 — 只存加密摘要，不解读内容）
# ============================================================
class SyncUploadRequest(BaseModel):
    device_id: str
    data: str           # 加密后的数据
    timestamp: int


class SyncDownloadRequest(BaseModel):
    device_id: str


@app.post("/sync/upload")
def sync_upload(req: SyncUploadRequest):
    """上传加密摘要。后端只存储，不解读。"""
    try:
        # 按设备 ID 存储到文件
        file_path = SYNC_DIR / f"{req.device_id}.dat"
        file_path.write_text(req.data)
        logger.info(f"[Sync] 设备 {req.device_id} 上传成功，大小 {len(req.data)} 字节")
        return {"success": True, "synced_at": int(time.time() * 1000)}
    except Exception as e:
        logger.exception("[Sync] 上传失败")
        return {"success": False, "error": str(e)}


@app.post("/sync/download")
def sync_download(req: SyncDownloadRequest):
    """下载加密摘要（换机恢复用）。"""
    try:
        file_path = SYNC_DIR / f"{req.device_id}.dat"
        if not file_path.exists():
            return {"success": False, "error": "无同步数据"}
        data = file_path.read_text()
        logger.info(f"[Sync] 设备 {req.device_id} 下载成功，大小 {len(data)} 字节")
        return {"success": True, "data": data}
    except Exception as e:
        logger.exception("[Sync] 下载失败")
        return {"success": False, "error": str(e)}


# ============================================================
# 启动入口
# ============================================================
if __name__ == "__main__":
    print("=" * 60)
    print("[Server] 知心无状态推理服务")
    print(f"[Server] 监听 → http://{SERVER_CONFIG['host']}:{SERVER_CONFIG['port']}")
    print(f"[Server] 手机端 → http://<电脑局域网IP>:{SERVER_CONFIG['port']}")
    print("[Server] 模式 → 无状态（不存储用户数据）")
    print("=" * 60)
    uvicorn.run(
        "api:app",
        host=SERVER_CONFIG["host"],
        port=SERVER_CONFIG["port"],
        reload=SERVER_CONFIG["reload"],
    )
