"""
ai_companion 全局配置
----------------------
DeepSeek API 兼容 OpenAI SDK 调用格式。
API Key 请从 https://platform.deepseek.com/api_keys 获取后填入下方。
"""

import os
from pathlib import Path

# ============================================================
# 项目路径
# ============================================================
PROJECT_ROOT = Path(__file__).resolve().parent
DATA_DIR = PROJECT_ROOT / "data"

# ============================================================
# DeepSeek API 配置（兼容 OpenAI SDK）
# ============================================================
DEEPSEEK_CONFIG = {
    "base_url": "https://api.deepseek.com/v1",
    "api_key": "sk-12bbe914ea634db687fa128379447115",  # 留空，通过环境变量或直接填写
    # 常用模型：
    #   deepseek-chat       — 通用对话（V3）
    #   deepseek-reasoner   — 深度推理（R1）
    "default_model": "deepseek-chat",
    "temperature": 0.7,
    "max_tokens": 4096,
}

# ============================================================
# SQLite 配置（用户画像）
# ============================================================
SQLITE_DB_PATH = str(DATA_DIR / "profile.db")

# ============================================================
# 向量数据库配置（ChromaDB）
# ============================================================
CHROMA_CONFIG = {
    "persist_directory": str(DATA_DIR / "chroma_db"),
    "collection_name": "ai_companion_memory",
}

# ============================================================
# 短期记忆配置
# ============================================================
SHORT_TERM_CONFIG = {
    "max_rounds": 10,  # 最多缓存 10 轮对话
}

# ============================================================
# 嵌入模型配置（sentence-transformers）
# ============================================================
EMBEDDING_CONFIG = {
    "model_name": "all-MiniLM-L6-v2",
}

# ============================================================
# 大脑核心配置（CompanionBrain）
# ============================================================
BRAIN_CONFIG = {
    "summary_threshold": 3,           # 未总结轮数达到此值时触发摘要
    "memory_retrieval_k": 3,          # 每次对话检索的相关记忆条数
    "profile_extraction_threshold": 3,  # 每隔多少轮提取一次画像
}

# 系统提示词模板 — {current_time} {user_profile} {relevant_memories} 会被动态替换
SYSTEM_PROMPT_TEMPLATE = """你是用户的 AI 伴侣，名字叫知心。你善于倾听、理解和陪伴用户。你有记忆能力，能记住用户说过的话和偏好。

【核心原则 — 务必遵守】
- 用户刚刚发送的消息是你唯一需要回复的对象。请你逐字理解用户说了什么，然后直接回应。
- 绝对不要猜测用户没说过的话，不要凭空假设用户的状态、情绪或处境。只基于用户实际表达的内容来回应。
- 如果用户分享了明确的好消息（如升职、通过考试、完成目标等）或表达了积极情绪（如高兴、兴奋、满足等），你必须首先表达真诚的祝贺或共情，然后再自然展开对话。
- 不要以时间（如"深夜""凌晨"）作为回复的开场或焦点——时间是辅助信息，不是话题本身。

当前时间：{current_time}

=== 你对用户的了解（长期画像） ===
{user_profile}

=== 与当前对话相关的过往记忆 ===
{relevant_memories}

交流准则：
- 用温暖、自然的口吻与用户交流，像一位贴心的老朋友
- 可以自然地提及用户的偏好和过往经历，让对话有连续性，但不要生硬堆砌
- 当用户表达负面情绪时给予共情和支持
- 在合适的时候提醒用户之前提过的待办或计划
- 保持回复简洁有力，一般不超过 300 字"""

# 画像提取 prompt — 要求模型以 JSON 格式输出
PROFILE_EXTRACTION_PROMPT = """请分析以下对话，提取可沉淀为长期用户画像的信息。以 JSON 格式输出，字段说明：

- mood: 用户当前的情绪状态（如愉快/焦虑/平静/兴奋/疲惫等）
- traits: 用户表现出的性格特征或习惯（用逗号分隔的关键词）
- preferences: 用户表达出的偏好或倾向（用逗号分隔）
- important_events: 用户提到的重要事件（如考试、面试、旅行、项目等）
- followups: 后续值得跟进的事项（如用户未解决的问题、待确认的计划等）
- facts: 用户透露的基本事实（如年龄、职业、城市、家庭成员等）

输出格式示例：
{"mood": "平静", "traits": "细心, 拖延", "preferences": "咖啡, 科幻电影, 早起", "important_events": "下周有述职报告", "followups": "述职报告准备进度", "facts": "互联网行业, 居住上海"}

请仅输出 JSON 对象，不要包含任何其他文字。对话内容如下：

{conversation_text}"""

# ============================================================
# 定时任务配置（APScheduler）
# ============================================================
SCHEDULER_CONFIG = {
    "timezone": "Asia/Shanghai",
    "morning_time": {"hour": 8, "minute": 0},    # 早安问候
    "evening_time": {"hour": 22, "minute": 0},    # 晚间复盘
}

# 早安问候 prompt
MORNING_GREETING_PROMPT = """你现在需要为用户生成一段温暖的早安问候。请基于你对用户的了解（画像和过往记忆），生成一段个性化问候。内容可包括：
- 一句温暖的早安开场
- 提及用户今天可能会关注的事项（如待办、计划）
- 一句鼓励或祝福

请直接输出问候文本，不要加前缀或引号。控制在 200 字以内。"""

# 晚间复盘 prompt
EVENING_REVIEW_PROMPT = """你现在需要为用户生成一段晚间复盘。请基于你对用户的了解（画像和过往记忆），生成一段体贴的晚间回顾。内容可包括：
- 对用户一天的关心和共情
- 提醒用户回顾今天完成的事情
- 如果画像中有未完成的待办，温和地提及
- 建议用户放松休息，为明天充电

请直接输出复盘文本，不要加前缀或引号。控制在 200 字以内。"""

# ============================================================
# FastAPI 服务配置
# ============================================================
SERVER_CONFIG = {
    "host": "0.0.0.0",   # 绑定所有网卡，手机才能连上
    "port": 8000,
    "reload": True,
}


# ============================================================
# 快速获取 OpenAI 客户端的工厂函数
# ============================================================
def get_deepseek_client():
    """返回一个配置好的 OpenAI 客户端实例，直连 DeepSeek API。"""
    from openai import OpenAI

    return OpenAI(
        base_url=DEEPSEEK_CONFIG["base_url"],
        api_key=DEEPSEEK_CONFIG["api_key"] or os.getenv("DEEPSEEK_API_KEY", "sk-placeholder"),
    )


def get_deepseek_async_client():
    """返回一个配置好的 AsyncOpenAI 客户端实例。"""
    from openai import AsyncOpenAI

    return AsyncOpenAI(
        base_url=DEEPSEEK_CONFIG["base_url"],
        api_key=DEEPSEEK_CONFIG["api_key"] or os.getenv("DEEPSEEK_API_KEY", "sk-placeholder"),
    )
