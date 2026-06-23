"""
模型调用模块
------------
封装 DeepSeek API 调用，底层使用 OpenAI 兼容接口。
配置项（base_url, api_key, 默认模型）统一从 config.py 读取。
"""

from openai import OpenAI
from config import DEEPSEEK_CONFIG, get_deepseek_client

# 模块级客户端，惰性初始化
_client: OpenAI | None = None


def _ensure_client() -> OpenAI:
    """获取或创建 OpenAI 兼容客户端（单例模式）。"""
    global _client
    if _client is None:
        _client = get_deepseek_client()
    return _client


# ============================================================
# 基础对话
# ============================================================
def chat(messages: list[dict], temperature: float = 0.7) -> str:
    """
    发送消息到 DeepSeek，返回模型回复文本。

    Args:
        messages: 标准 OpenAI 消息列表，每条为 {"role": "system"|"user"|"assistant", "content": "..."}
        temperature: 采样温度，默认 0.7

    Returns:
        模型回复的纯文本内容
    """
    client = _ensure_client()

    response = client.chat.completions.create(
        model=DEEPSEEK_CONFIG["default_model"],
        messages=messages,
        temperature=temperature,
        max_tokens=DEEPSEEK_CONFIG["max_tokens"],
    )

    return response.choices[0].message.content


# ============================================================
# 对话摘要
# ============================================================
_SUMMARY_SYSTEM_PROMPT = """你是一位专业的对话分析助手。请将以下对话总结为一段第三人称摘要（不超过150字）。

请提取并包含以下要素：
1. 用户的情绪状态（如愉快、焦虑、困惑、平静等）
2. 对话中提到的重要事件或背景信息
3. 用户表达出的偏好、倾向或习惯
4. 后续需要跟进的事项（如用户的待办、疑虑、计划等）

格式要求：
- 使用第三人称叙述，以"用户"指代对话中的用户
- 控制在150字以内
- 语言简洁、客观
- 按"情绪 → 事件 → 偏好 → 跟进"的顺序组织"""


def generate_summary(conversation_text: str) -> str:
    """
    将一段对话文本总结为第三人称摘要（≤150字）。

    摘要包含：用户情绪、重要事件、偏好、后续跟进点。

    Args:
        conversation_text: 原始对话文本

    Returns:
        ≤150字的第三人称摘要
    """
    client = _ensure_client()

    messages = [
        {"role": "system", "content": _SUMMARY_SYSTEM_PROMPT},
        {"role": "user", "content": f"请分析以下对话并生成摘要：\n\n{conversation_text}"},
    ]

    response = client.chat.completions.create(
        model=DEEPSEEK_CONFIG["default_model"],
        messages=messages,
        temperature=0.5,  # 摘要任务用稍低温度以保证稳定
        max_tokens=300,
    )

    return response.choices[0].message.content
