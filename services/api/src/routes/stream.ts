import websocket from "@fastify/websocket";
import type { FastifyInstance } from "fastify";
import type { SignalEventCache } from "../collection/signalEventCache.js";
import { parseClientMessage, StreamProtocol } from "../realtime/protocol.js";

const MAX_MESSAGE_BYTES = 2048;
const MAX_SUBSCRIPTIONS = 32;

export function registerStreamRoutes(app: FastifyInstance, signalCache: SignalEventCache): void {
  app.register(websocket, { options: { maxPayload: MAX_MESSAGE_BYTES } });

  app.get("/v1/stream", { websocket: true }, (socket) => {
    const protocol = new StreamProtocol();
    const subscriptions = new Set<string>();

    socket.on("message", (message: Buffer) => {
      const parsed = parseClientMessage(message.toString("utf8"));
      if (parsed === null) {
        socket.send(JSON.stringify(protocol.error(null, "INVALID_MESSAGE")));
        return;
      }
      if (parsed.type === "unsubscribe") {
        subscriptions.delete(parsed.requestId);
        return;
      }
      if (subscriptions.size >= MAX_SUBSCRIPTIONS && !subscriptions.has(parsed.requestId)) {
        socket.send(JSON.stringify(protocol.error(parsed.requestId, "SUBSCRIPTION_LIMIT")));
        return;
      }
      subscriptions.add(parsed.requestId);
      socket.send(JSON.stringify(protocol.nextSnapshot(parsed, signalCache)));
    });
  });
}
