import type { SignalEventCache } from "../collection/signalEventCache.js";

export type StreamMessage =
  | { type: "snapshot"; requestId: string; streamEpoch: string; sequence: number; snapshot: unknown }
  | { type: "unavailable"; requestId: string; streamEpoch: string; sequence: number; reason: string }
  | { type: "error"; requestId: string | null; streamEpoch: string; sequence: number; error: string };

export type SubscribeRequest = {
  type: "subscribe";
  requestId: string;
  approachKey: string;
  movement: "straight";
  catalogVersion: string;
};

export type UnsubscribeRequest = { type: "unsubscribe"; requestId: string };

export class StreamProtocol {
  readonly streamEpoch = crypto.randomUUID();
  #sequence = 0;

  nextSnapshot(request: SubscribeRequest, signalCache: SignalEventCache): StreamMessage {
    this.#sequence += 1;
    const cached = signalCache.get(request.approachKey);
    if (cached === undefined) {
      return { type: "unavailable", requestId: request.requestId, streamEpoch: this.streamEpoch, sequence: this.#sequence, reason: "TARGET_UNKNOWN" };
    }
    if (cached.observation.catalogVersion !== request.catalogVersion) {
      return { type: "unavailable", requestId: request.requestId, streamEpoch: this.streamEpoch, sequence: this.#sequence, reason: "CATALOG_MISMATCH" };
    }
    return { type: "snapshot", requestId: request.requestId, streamEpoch: this.streamEpoch, sequence: this.#sequence, snapshot: cached.observation };
  }

  error(requestId: string | null, error: string): StreamMessage {
    this.#sequence += 1;
    return { type: "error", requestId, streamEpoch: this.streamEpoch, sequence: this.#sequence, error };
  }
}

export function parseClientMessage(raw: string): SubscribeRequest | UnsubscribeRequest | null {
  const parsed = JSON.parse(raw) as unknown;
  if (typeof parsed !== "object" || parsed === null || !("type" in parsed)) {
    return null;
  }
  if (parsed.type === "unsubscribe" && "requestId" in parsed && typeof parsed.requestId === "string") {
    return { type: "unsubscribe", requestId: parsed.requestId };
  }
  if (
    parsed.type === "subscribe" &&
    "requestId" in parsed && typeof parsed.requestId === "string" &&
    "approachKey" in parsed && typeof parsed.approachKey === "string" &&
    "movement" in parsed && parsed.movement === "straight" &&
    "catalogVersion" in parsed && typeof parsed.catalogVersion === "string"
  ) {
    return {
      type: "subscribe",
      requestId: parsed.requestId,
      approachKey: parsed.approachKey,
      movement: "straight",
      catalogVersion: parsed.catalogVersion
    };
  }
  return null;
}
