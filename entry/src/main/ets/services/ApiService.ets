/**
 * ApiService.ets
 * ---------------
 * 知心数字孪生 — 前端通信层
 *
 * 后端为无状态推理服务，所有用户数据在本地。
 * 每次请求需要把本地记忆打包成 context 传给后端。
 *
 * ⚠️ 真机调试前，请把下面的 IP 改成你电脑的局域网 IP（cmd 运行 ipconfig 查看）。
 */

import http from "@ohos.net.http";
import webSocket from "@ohos.net.webSocket";

// TODO: 改成你电脑的局域网 IP，例如 "192.168.1.100"
const BASE_HTTP = "http://192.168.1.100:8000";
const BASE_WS = "ws://192.168.1.100:8000";

// ============================================================
// 类型定义 — 与后端 Pydantic 模型对应
// ============================================================

/** 对话上下文（打包本地记忆传给后端） */
export interface ChatContext {
  message: string;
  current_time?: string;
  current_location?: string;
  user_profile: Record<string, string>;           // 语义记忆
  recent_conversations: Array<{ user: string; assistant: string }>;  // 短期记忆
  relevant_episodes: Array<{ title: string; description: string; time: string }>;  // 情景记忆
  behavior_patterns: Array<{ description: string; confidence: number }>;  // 程序记忆
  relations: Array<{ name: string; relation: string; mentions: number }>;  // 关系网络
  pending_predictions?: Array<Record<string, Object>>;
}

/** 对话响应（后端返回） */
export interface ChatResult {
  reply: string;
  extracted: {
    emotion?: string;
    profile_updates?: Array<{
      category: string;
      key: string;
      value: string;
      confidence?: number;
    }>;
    episodes?: Array<{
      title: string;
      description: string;
      importance?: number;
      people?: string[];
      outcome?: string;
    }>;
    persons?: Array<{
      name: string;
      relation: string;
      sentiment?: number;
    }>;
    should_summarize?: boolean;
  };
}

/** 预测请求 */
export interface PredictContext {
  current_time?: string;
  current_location?: string;
  user_profile: Record<string, string>;
  behavior_patterns: Array<{ description: string; confidence: number }>;
  recent_behaviors: Array<{ time: string; action: string }>;
}

export interface PredictionResult {
  predictions: Array<{
    target_time: string;
    prediction_type: string;  // location / behavior / emotion
    prediction: string;
    confidence: number;
    reasoning: string;
  }>;
}

/** 决策请求 */
export interface DecisionContext {
  decision_question: string;
  options: string[];
  user_profile: Record<string, string>;
  relevant_episodes: Array<{ title: string; description: string; outcome?: string }>;
  similar_decisions: Array<{ question: string; choice: string; outcome: string }>;
}

export interface DecisionResult {
  analysis: string;
  recommendation: {
    option: string;
    reason: string;
    confidence: number;
  };
  risks: string[];
  alternatives: string[];
}

// ============================================================
// HTTP 请求封装
// ============================================================

/** 通用 POST 请求 */
function postJSON<T>(path: string, body: object): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const httpRequest = http.createHttp();
    httpRequest.request(
      `${BASE_HTTP}${path}`,
      {
        method: http.RequestMethod.POST,
        header: { "Content-Type": "application/json; charset=utf-8" },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.OBJECT,
        readTimeout: 60_000,
        connectTimeout: 15_000,
      },
      (err: Error, data: http.HttpResponse) => {
        if (err) {
          reject(new Error("网络请求失败"));
          return;
        }
        if (data.responseCode === 200) {
          try {
            const result = data.result;
            if (typeof result === "string") {
              resolve(JSON.parse(result) as T);
            } else {
              resolve(result as T);
            }
          } catch (e) {
            reject(new Error("JSON 解析失败"));
          }
        } else {
          reject(new Error("HTTP " + data.responseCode));
        }
      }
    );
  });
}

// ============================================================
// API 接口
// ============================================================

/** POST /chat — 带上下文的对话 */
export function sendChatWithContext(ctx: ChatContext): Promise<ChatResult> {
  return postJSON<ChatResult>("/chat", ctx);
}

/** POST /summarize — 生成对话摘要 */
export function summarizeConversation(text: string): Promise<{ summary: string }> {
  return postJSON<{ summary: string }>("/summarize", { conversation_text: text });
}

/** POST /predict — 预测用户下一步 */
export function predictNext(ctx: PredictContext): Promise<PredictionResult> {
  return postJSON<PredictionResult>("/predict", ctx);
}

/** POST /decision — 决策辅助 */
export function assistDecision(ctx: DecisionContext): Promise<DecisionResult> {
  return postJSON<DecisionResult>("/decision", ctx);
}

/** POST /morning — 早安问候 */
export function generateMorningGreeting(ctx: {
  current_time?: string;
  user_profile: Record<string, string>;
  relevant_episodes: Array<{ title: string; description: string }>;
  behavior_patterns: Array<{ description: string; confidence: number }>;
}): Promise<{ content: string }> {
  return postJSON<{ content: string }>("/morning", ctx);
}

/** POST /evening — 晚间复盘 */
export function generateEveningReview(ctx: {
  current_time?: string;
  user_profile: Record<string, string>;
  relevant_episodes: Array<{ title: string; description: string }>;
  behavior_patterns: Array<{ description: string; confidence: number }>;
}): Promise<{ content: string }> {
  return postJSON<{ content: string }>("/evening", ctx);
}

// ============================================================
// 兼容旧接口（简单对话，不带上下文 — 仅供过渡期使用）
// ============================================================
export function sendChatMessage(text: string): Promise<string> {
  return sendChatWithContext({
    message: text,
    current_time: new Date().toLocaleString(),
    user_profile: {},
    recent_conversations: [],
    relevant_episodes: [],
    behavior_patterns: [],
    relations: [],
  }).then(result => result.reply);
}

// ============================================================
// WebSocket — 主动消息推送（保留，用于未来扩展）
// ============================================================
export class WsClient {
  private ws: webSocket.WebSocket | null = null;
  private url: string;
  private onMessage: (msg: WsMessage) => void = () => {};
  private reconnectTimer: number | null = null;
  private running: boolean = false;

  constructor(url: string = BASE_WS) {
    this.url = url;
  }

  connect(onMessage: (msg: WsMessage) => void): void {
    this.onMessage = onMessage;
    this.running = true;
    this._doConnect();
  }

  private _doConnect(): void {
    if (!this.running) return;
    this.ws = webSocket.createWebSocket();
    this.ws.connect(this.url, (err: Error) => {
      if (err) this._scheduleReconnect();
    });
    this.ws.on("message", (err: Error, value: Object) => {
      if (err) return;
      try {
        this.onMessage(JSON.parse(value as string) as WsMessage);
      } catch { /* 忽略 */ }
    });
    this.ws.on("close", () => { if (this.running) this._scheduleReconnect(); });
    this.ws.on("error", () => { if (this.running) this._scheduleReconnect(); });
  }

  private _scheduleReconnect(): void {
    if (this.reconnectTimer !== null) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this._doConnect();
    }, 5000);
  }

  disconnect(): void {
    this.running = false;
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws !== null) {
      this.ws.close();
      this.ws = null;
    }
  }
}

export interface WsMessage {
  type: string;
  content?: string;
  timestamp?: string;
  meta?: object;
}
