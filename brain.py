"""
大脑核心（无状态版）
--------------------
CompanionBrain 现在是纯推理引擎，不持有任何用户数据。
所有用户上下文由前端打包传入，brain 只负责：
  1. 组装系统提示词
  2. 调用 LLM
  3. 返回回复 + 结构化提取结果（画像/事件/人物等）

前端拿到提取结果后，自行写入本地六层记忆。
"""

import json
import logging
import re
from datetime import datetime
from typing import Any

from model import chat, generate_summary
from config import (
    SYSTEM_PROMPT_TEMPLATE,
    PROFILE_EXTRACTION_PROMPT,
    MORNING_GREETING_PROMPT,
    EVENING_REVIEW_PROMPT,
)

logger = logging.getLogger(__name__)


# ============================================================
# 上下文数据结构（前端打包传入）
# ============================================================
class ConversationContext:
    """前端打包传入的对话上下文。"""

    def __init__(self, data: dict):
        self.user_message: str = data.get("message", "")
        self.current_time: str = data.get("current_time", datetime.now().strftime("%Y年%m月%d日 %H:%M"))
        self.current_location: str = data.get("current_location", "")
        self.user_profile: dict = data.get("user_profile", {})  # 语义记忆
        self.recent_conversations: list = data.get("recent_conversations", [])  # 短期记忆
        self.relevant_episodes: list = data.get("relevant_episodes", [])  # 情景记忆
        self.behavior_patterns: list = data.get("behavior_patterns", [])  # 程序记忆
        self.relations: list = data.get("relations", [])  # 关系网络
        self.pending_predictions: list = data.get("pending_predictions", [])  # 待验证预测


# ============================================================
# 无状态推理引擎
# ============================================================
class CompanionBrain:
    """
    无状态 AI 推理引擎。

    用法：
        brain = CompanionBrain()
        result = brain.respond({
            "message": "我今天心情不太好",
            "user_profile": {...},
            "recent_conversations": [...],
            ...
        })
        # result = {"reply": "...", "extracted": {...}}
    """

    def __init__(self):
        pass  # 完全无状态，无需初始化任何存储

    # ================================================================
    # 主入口：对话
    # ================================================================
    def respond(self, context_data: dict) -> dict:
        """
        响应用户消息。

        Args:
            context_data: 前端打包的上下文（见 ConversationContext）

        Returns:
            {
                "reply": "AI 回复文本",
                "extracted": {
                    "emotion": "用户当前情绪",
                    "profile_updates": [{"category": "...", "key": "...", "value": "..."}],
                    "episodes": [{"title": "...", "description": "..."}],
                    "persons": [{"name": "...", "relation": "..."}],
                    "should_summarize": bool
                }
            }
        """
        ctx = ConversationContext(context_data)

        # 1. 构建系统提示词
        system_prompt = self._build_system_prompt(ctx)

        # 2. 拼装消息列表
        messages = [{"role": "system", "content": system_prompt}]
        for conv in ctx.recent_conversations:
            messages.append({"role": "user", "content": conv.get("user", "")})
            messages.append({"role": "assistant", "content": conv.get("assistant", "")})
        messages.append({"role": "user", "content": ctx.user_message})

        # 3. 调用 LLM 生成回复
        try:
            reply = chat(messages)
        except Exception as e:
            logger.exception("LLM 调用失败")
            return {
                "reply": "抱歉，我暂时无法响应，请稍后再试。",
                "extracted": {},
                "error": str(e),
            }

        # 4. 异步提取结构化信息（同步执行，但异常不影响主流程）
        extracted = {}
        try:
            extracted = self._extract_info(ctx.user_message, reply, ctx)
        except Exception:
            logger.warning("信息提取失败，但不影响主回复", exc_info=True)

        return {
            "reply": reply,
            "extracted": extracted,
        }

    # ================================================================
    # 系统提示词组装
    # ================================================================
    def _build_system_prompt(self, ctx: ConversationContext) -> str:
        """组装完整的系统提示词，注入前端传来的上下文。"""

        # 用户画像
        if ctx.user_profile:
            profile_lines = [f"  - {k}: {v}" for k, v in ctx.user_profile.items()]
            user_profile_text = "\n".join(profile_lines)
        else:
            user_profile_text = "  （尚无画像信息）"

        # 相关情景记忆
        if ctx.relevant_episodes:
            ep_lines = [f"  - [{e.get('time', '')}] {e.get('title', '')}: {e.get('description', '')}"
                        for e in ctx.relevant_episodes]
            relevant_memories_text = "\n".join(ep_lines)
        else:
            relevant_memories_text = "  （暂无相关记忆）"

        # 行为模式
        patterns_text = ""
        if ctx.behavior_patterns:
            pat_lines = [f"  - {p.get('description', '')}（置信度: {p.get('confidence', 0.5)}）"
                         for p in ctx.behavior_patterns[:5]]
            patterns_text = "\n=== 用户行为规律 ===\n" + "\n".join(pat_lines)

        # 关系网络
        relations_text = ""
        if ctx.relations:
            rel_lines = [f"  - {r.get('name', '')}（{r.get('relation', '关系不明')}，提及 {r.get('mentions', 0)} 次）"
                         for r in ctx.relations[:10]]
            relations_text = "\n=== 用户社交关系 ===\n" + "\n".join(rel_lines)

        # 位置信息
        location_text = f"\n当前位置：{ctx.current_location}" if ctx.current_location else ""

        prompt = SYSTEM_PROMPT_TEMPLATE.format(
            current_time=ctx.current_time,
            user_profile=user_profile_text,
            relevant_memories=relevant_memories_text,
        )
        return prompt + location_text + patterns_text + relations_text

    # ================================================================
    # 结构化信息提取
    # ================================================================
    def _extract_info(self, user_msg: str, ai_reply: str, ctx: ConversationContext) -> dict:
        """
        从本轮对话中提取结构化信息，供前端写入对应记忆层。

        提取内容：
          - emotion: 用户情绪
          - profile_updates: 画像更新（语义记忆）
          - episodes: 值得记录的事件（情景记忆）
          - persons: 提及的人物（关系网络）
          - should_summarize: 是否建议生成摘要
        """
        extraction_prompt = """请分析以下用户消息和 AI 回复，提取结构化信息。以 JSON 格式输出。

用户消息：{user_msg}
AI回复：{ai_reply}

请提取以下字段（如果没有相关信息，对应字段留空数组或空字符串）：

{{
  "emotion": "用户当前的情绪状态（如愉快/焦虑/平静/兴奋/疲惫等），无则留空字符串",
  "profile_updates": [
    {{
      "category": "profile/preference/value/fact/skill",
      "key": "字段名（如 职业、喜欢的电影、年龄等）",
      "value": "字段值",
      "confidence": 0.5到1.0之间的置信度
    }}
  ],
  "episodes": [
    {{
      "title": "事件标题（10字以内）",
      "description": "事件描述",
      "importance": 0.0到1.0之间的重要性分数",
      "people": ["涉及的人物姓名"],
      "outcome": "事件结果或后续（如有）"
    }}
  ],
  "persons": [
    {{
      "name": "人物姓名或称呼",
      "relation": "family/friend/colleague/lover/acquaintance",
      "sentiment": -1.0到1.0之间的情感倾向
    }}
  ],
  "should_summarize": false
}}

注意：
- 只提取用户明确表达的信息，不要猜测
- profile_updates 只提取用户透露的新信息或对已有信息的更新
- episodes 只记录值得长期记住的具体事件，日常寒暄不算
- persons 只提取明确提到的人物
- should_summarize 设为 true 当本轮对话包含重要事件或决策时

请仅输出 JSON 对象："""

        messages = [
            {"role": "system", "content": "你是一位精准的 JSON 数据提取器。请严格按要求输出 JSON，不要添加任何其他文字。"},
            {"role": "user", "content": extraction_prompt.format(
                user_msg=user_msg,
                ai_reply=ai_reply,
            )},
        ]

        try:
            raw = chat(messages, temperature=0.2)
            parsed = self._parse_json_from_response(raw)
            return parsed if parsed else {}
        except Exception:
            logger.warning("结构化提取失败", exc_info=True)
            return {}

    # ================================================================
    # 摘要生成
    # ================================================================
    def summarize_conversation(self, conversation_text: str) -> str:
        """生成对话摘要（供前端存入情景记忆）。"""
        return generate_summary(conversation_text)

    # ================================================================
    # 早安问候 / 晚间复盘（基于前端传入的上下文）
    # ================================================================
    def generate_morning_greeting(self, context_data: dict) -> str:
        """生成早安问候。context_data 包含 user_profile, relevant_episodes 等。"""
        ctx = ConversationContext(context_data)

        profile_text = "\n".join(f"  {k}: {v}" for k, v in ctx.user_profile.items()) if ctx.user_profile else "尚无画像"
        ep_text = "\n".join(f"  - {e.get('title', '')}: {e.get('description', '')}"
                            for e in ctx.relevant_episodes) if ctx.relevant_episodes else "暂无相关记忆"
        pat_text = "\n".join(f"  - {p.get('description', '')}"
                             for p in ctx.behavior_patterns) if ctx.behavior_patterns else "暂无规律"

        prompt = MORNING_GREETING_PROMPT + f"""

当前用户画像：
{profile_text}

相关长期记忆：
{ep_text}

已知行为规律：
{pat_text}

当前时间：{ctx.current_time}"""

        messages = [
            {"role": "system", "content": "你是用户的 AI 伴侣知心，任务是为用户生成早安问候。"},
            {"role": "user", "content": prompt},
        ]
        return chat(messages, temperature=0.7)

    def generate_evening_review(self, context_data: dict) -> str:
        """生成晚间复盘。"""
        ctx = ConversationContext(context_data)

        profile_text = "\n".join(f"  {k}: {v}" for k, v in ctx.user_profile.items()) if ctx.user_profile else "尚无画像"
        ep_text = "\n".join(f"  - {e.get('title', '')}: {e.get('description', '')}"
                            for e in ctx.relevant_episodes) if ctx.relevant_episodes else "暂无相关记忆"
        pat_text = "\n".join(f"  - {p.get('description', '')}"
                             for p in ctx.behavior_patterns) if ctx.behavior_patterns else "暂无规律"

        prompt = EVENING_REVIEW_PROMPT + f"""

当前用户画像：
{profile_text}

今日相关记忆：
{ep_text}

已知行为规律：
{pat_text}

当前时间：{ctx.current_time}"""

        messages = [
            {"role": "system", "content": "你是用户的 AI 伴侣知心，任务是为用户生成晚间复盘。"},
            {"role": "user", "content": prompt},
        ]
        return chat(messages, temperature=0.7)

    # ================================================================
    # 预测引擎
    # ================================================================
    def predict_next(self, context_data: dict) -> dict:
        """
        基于历史行为模式预测用户下一步动向。

        context_data 需包含：
          - current_time
          - current_location
          - behavior_patterns: 历史行为规律
          - recent_behaviors: 最近 24h 的行为日志
          - user_profile

        Returns:
            {
                "predictions": [
                    {
                        "target_time": "预测目标时间",
                        "prediction_type": "location/behavior/emotion",
                        "prediction": "预测内容",
                        "confidence": 0.0-1.0,
                        "reasoning": "预测依据"
                    }
                ]
            }
        """
        ctx = ConversationContext(context_data)
        recent_behaviors = context_data.get("recent_behaviors", [])

        predict_prompt = """你是用户的数字孪生，基于以下信息预测用户未来 24 小时的动向。

当前时间：{current_time}
当前位置：{current_location}

用户画像：
{profile}

已知行为规律：
{patterns}

最近 24 小时行为日志：
{recent_behaviors}

请预测用户接下来可能的行为、位置变化、情绪状态。以 JSON 格式输出：

{{
  "predictions": [
    {{
      "target_time": "YYYY-MM-DD HH:MM 格式的预测目标时间",
      "prediction_type": "location/behavior/emotion",
      "prediction": "具体预测内容",
      "confidence": 0.0到1.0,
      "reasoning": "预测依据（引用具体规律或历史）"
    }}
  ]
}}

要求：
- 至少给出 3 条预测，覆盖不同时间点
- 置信度基于历史规律的稳定程度
- 只输出 JSON"""

        profile_text = "\n".join(f"  {k}: {v}" for k, v in ctx.user_profile.items()) if ctx.user_profile else "无"
        patterns_text = "\n".join(f"  - {p.get('description', '')}"
                                  for p in ctx.behavior_patterns) if ctx.behavior_patterns else "无"
        recent_text = "\n".join(f"  - [{b.get('time', '')}] {b.get('action', '')}"
                                for b in recent_behaviors) if recent_behaviors else "无"

        messages = [
            {"role": "system", "content": "你是用户的数字孪生预测引擎。请严格按要求输出 JSON。"},
            {"role": "user", "content": predict_prompt.format(
                current_time=ctx.current_time,
                current_location=ctx.current_location or "未知",
                profile=profile_text,
                patterns=patterns_text,
                recent_behaviors=recent_text,
            )},
        ]

        try:
            raw = chat(messages, temperature=0.4)
            parsed = self._parse_json_from_response(raw)
            return parsed if parsed else {"predictions": []}
        except Exception:
            logger.exception("预测生成失败")
            return {"predictions": []}

    # ================================================================
    # 决策辅助
    # ================================================================
    def assist_decision(self, context_data: dict) -> dict:
        """
        辅助重大决策。

        context_data 需包含：
          - decision_question: 决策问题
          - options: 可选项列表
          - user_profile: 用户画像（价值观、偏好）
          - relevant_episodes: 相关历史事件
          - similar_decisions: 过去类似的决策及结果

        Returns:
            {
                "analysis": "决策分析",
                "recommendation": "推荐选项 + 理由",
                "risks": ["风险1", "风险2"],
                "alternatives": ["备选方案"]
            }
        """
        question = context_data.get("decision_question", "")
        options = context_data.get("options", [])
        similar = context_data.get("similar_decisions", [])
        ctx = ConversationContext(context_data)

        decision_prompt = """你是用户的数字孪生，基于你对用户的深度了解，辅助其做出重大决策。

决策问题：{question}

可选方案：
{options}

用户画像（价值观、偏好、性格）：
{profile}

相关历史事件：
{episodes}

过去类似决策及结果：
{similar}

请基于以上信息，以 JSON 格式输出决策建议：

{{
  "analysis": "对当前决策情境的分析（200字内）",
  "recommendation": {{
    "option": "推荐的选项",
    "reason": "推荐理由（结合用户画像和历史）",
    "confidence": 0.0到1.0
  }},
  "risks": ["风险1", "风险2", "风险3"],
  "alternatives": ["备选方案1", "备选方案2"]
}}

要求：
- 推荐必须基于用户的价值观和历史选择，不是通用建议
- 风险要具体、可操作
- 只输出 JSON"""

        profile_text = "\n".join(f"  {k}: {v}" for k, v in ctx.user_profile.items()) if ctx.user_profile else "无"
        ep_text = "\n".join(f"  - {e.get('title', '')}: {e.get('outcome', '无结果')}"
                            for e in ctx.relevant_episodes) if ctx.relevant_episodes else "无"
        sim_text = "\n".join(f"  - 问题: {s.get('question', '')} → 选择: {s.get('choice', '')} → 结果: {s.get('outcome', '')}"
                             for s in similar) if similar else "无"
        opt_text = "\n".join(f"  {i+1}. {o}" for i, o in enumerate(options)) if options else "  无明确选项"

        messages = [
            {"role": "system", "content": "你是用户的数字孪生决策辅助引擎。请严格按要求输出 JSON。"},
            {"role": "user", "content": decision_prompt.format(
                question=question,
                options=opt_text,
                profile=profile_text,
                episodes=ep_text,
                similar=sim_text,
            )},
        ]

        try:
            raw = chat(messages, temperature=0.5)
            parsed = self._parse_json_from_response(raw)
            return parsed if parsed else {}
        except Exception:
            logger.exception("决策辅助失败")
            return {}

    # ================================================================
    # JSON 解析
    # ================================================================
    @staticmethod
    def _parse_json_from_response(raw: str) -> dict | None:
        """从模型回复中提取 JSON 对象。"""
        # 匹配 ```json ... ``` 代码块
        code_block = re.search(r"```(?:json)?\s*([\s\S]*?)```", raw)
        if code_block:
            raw = code_block.group(1).strip()

        # 匹配 JSON 对象 {}
        obj_match = re.search(r"\{[\s\S]*\}", raw)
        if obj_match:
            try:
                return json.loads(obj_match.group(0))
            except json.JSONDecodeError:
                pass

        # 整体解析
        try:
            return json.loads(raw.strip())
        except json.JSONDecodeError:
            return None
