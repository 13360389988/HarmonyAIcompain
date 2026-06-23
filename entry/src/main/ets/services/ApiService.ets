import http from "@ohos.net.http";
import webSocket from "@ohos.net.webSocket";

const BASE_HTTP = "http://192.168.1.100:8000";
const BASE_WS = "ws://192.168.1.100:8000";

export interface ConversationPair {
  user: string;
  assistant: string;
}

export interface EpisodeInfo {
  title: string;
  description: string;
  time: string;
}

export interface PatternInfo {
  description: string;
  confidence: number;
}

export interface RelationInfo {
  name: string;
  relation: string;
  mentions: number;
}

export interface PredictionInfo {
  target_time: string;
  prediction_type: string;
  prediction: string;
  confidence: number;
  reasoning: string;
}

export interface ProfileUpdate {
  category: string;
  key: string;
  value: string;
  confidence: number;
}

export interface EpisodeUpdate {
  title: string;
  description: string;
  importance: number;
  people: string[];
  outcome: string;
}

export interface PersonUpdate {
  name: string;
  relation: string;
  sentiment: number;
}

export interface ExtractedData {
  emotion: string;
  profile_updates: ProfileUpdate[];
  episodes: EpisodeUpdate[];
  persons: PersonUpdate[];
  should_summarize: boolean;
}

export interface ChatContext {
  message: string;
  current_time: string;
  current_location: string;
  user_profile: Record<string, string>;
  recent_conversations: ConversationPair[];
  relevant_episodes: EpisodeInfo[];
  behavior_patterns: PatternInfo[];
  relations: RelationInfo[];
  pending_predictions: Record<string, Object>[];
}

export interface ChatResult {
  reply: string;
  extracted: ExtractedData;
}

export interface PredictContext {
  current_time: string;
  current_location: string;
  user_profile: Record<string, string>;
  behavior_patterns: PatternInfo[];
  recent_behaviors: RecentBehavior[];
}

export interface RecentBehavior {
  time: string;
  action: string;
}

export interface PredictionResult {
  predictions: PredictionInfo[];
}

export interface DecisionOption {
  question: string;
  choice: string;
  outcome: string;
}

export interface DecisionContext {
  decision_question: string;
  options: string[];
  user_profile: Record<string, string>;
  relevant_episodes: EpisodeInfo[];
  similar_decisions: DecisionOption[];
}

export interface Recommendation {
  option: string;
  reason: string;
  confidence: number;
}

export interface DecisionResult {
  analysis: string;
  recommendation: Recommendation;
  risks: string[];
  alternatives: string[];
}

export interface MorningGreetingContext {
  current_time: string;
  user_profile: Record<string, string>;
  relevant_episodes: EpisodeInfo[];
  behavior_patterns: PatternInfo[];
}

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
        readTimeout: 60000,
        connectTimeout: 15000,
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

export function sendChatWithContext(ctx: ChatContext): Promise<ChatResult> {
  return postJSON<ChatResult>("/chat", ctx);
}

export interface SummaryResult {
  summary: string;
}

export interface ContentResult {
  content: string;
}

export interface SummarizeRequest {
  conversation_text: string;
}

export interface SummarizeRequest {
  conversation_text: string;
}

export function summarizeConversation(text: string): Promise<SummaryResult> {
  const req: SummarizeRequest = { conversation_text: text };
  return postJSON<SummaryResult>("/summarize", req);
}

export function predictNext(ctx: PredictContext): Promise<PredictionResult> {
  return postJSON<PredictionResult>("/predict", ctx);
}

export function assistDecision(ctx: DecisionContext): Promise<DecisionResult> {
  return postJSON<DecisionResult>("/decision", ctx);
}

export function generateMorningGreeting(ctx: MorningGreetingContext): Promise<ContentResult> {
  return postJSON<ContentResult>("/morning", ctx);
}

export function generateEveningReview(ctx: MorningGreetingContext): Promise<ContentResult> {
  return postJSON<ContentResult>("/evening", ctx);
}

export function sendChatMessage(text: string): Promise<string> {
  return sendChatWithContext({
    message: text,
    current_time: new Date().toLocaleString(),
    current_location: "",
    user_profile: {},
    recent_conversations: [],
    relevant_episodes: [],
    behavior_patterns: [],
    relations: [],
    pending_predictions: [],
  }).then(result => result.reply);
}

export interface WsMessage {
  type: string;
  content: string;
  timestamp: string;
}

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
