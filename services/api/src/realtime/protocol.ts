import { randomUUID } from "node:crypto";
import type { SignalResult } from "../routes/signals.js";

export type StreamMessage =
  | { type: "snapshot"; requestId: string; streamEpoch: string; sequence: number; snapshot: unknown }
  | { type: "unavailable"; requestId: string; streamEpoch: string; sequence: number; reason: string }
  | { type: "error"; requestId: string | null; streamEpoch: string; sequence: number; error: string };
export type SubscribeRequest = { type: "subscribe"; requestId: string; approachKey: string; movement: "straight"; catalogVersion: string };
export type UnsubscribeRequest = { type: "unsubscribe"; requestId: string };

export class StreamProtocol {
  readonly streamEpoch = randomUUID();
  #sequence = 0;

  result(requestId: string, result: SignalResult): StreamMessage {
    const envelope = { requestId, streamEpoch: this.streamEpoch, sequence: ++this.#sequence };
    return result.available ? { ...envelope, type: "snapshot", snapshot: result.snapshot } : { ...envelope, type: "unavailable", reason: result.reason };
  }

  error(requestId: string | null, error: string): StreamMessage {
    return { type: "error", requestId, streamEpoch: this.streamEpoch, sequence: ++this.#sequence, error };
  }
}

export function parseClientMessage(raw: string): SubscribeRequest | UnsubscribeRequest | null {
  if (Buffer.byteLength(raw, "utf8") > 2048) return null;
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return null; }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed) || !("type" in parsed) || !("requestId" in parsed) || typeof parsed.requestId !== "string" || !parsed.requestId.trim() || parsed.requestId.length > 128) return null;
  if (parsed.type === "unsubscribe" && Object.keys(parsed).length === 2) return { type: "unsubscribe", requestId: parsed.requestId };
  if (parsed.type !== "subscribe" || Object.keys(parsed).length !== 5 || !("approachKey" in parsed) || typeof parsed.approachKey !== "string" || !parsed.approachKey.trim() || parsed.approachKey.length > 512 || !("movement" in parsed) || parsed.movement !== "straight" || !("catalogVersion" in parsed) || typeof parsed.catalogVersion !== "string" || !parsed.catalogVersion.trim() || parsed.catalogVersion.length > 512) return null;
  return { type: "subscribe", requestId: parsed.requestId, approachKey: parsed.approachKey, movement: "straight", catalogVersion: parsed.catalogVersion };
}
