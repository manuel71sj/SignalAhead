import type { FastifyInstance } from "fastify";
import type { WebSocket } from "ws";
import type { CatalogStore } from "../catalog/catalogStore.js";
import type { ApproachCatalog } from "../catalog/types.js";
import type { SignalEventCache } from "../collection/signalEventCache.js";
import { parseClientMessage, StreamProtocol, type StreamMessage, type SubscribeRequest } from "../realtime/protocol.js";
import { signalResult } from "./signals.js";

const MAX_SUBSCRIPTIONS = 32;
const MAX_CONNECTIONS = 64;
const MAX_BUFFER_BYTES = 65536;
type Subscription = { request: SubscribeRequest; last: string | null };
type Connection = { socket: WebSocket; protocol: StreamProtocol; subscriptions: Map<string, Subscription>; alive: boolean };

export function registerStreamRoutes(app: FastifyInstance, signalCache: SignalEventCache, catalogStore: CatalogStore): void {
  const connections = new Set<Connection>();
  let refreshing = false;

  function send(connection: Connection, message: StreamMessage): void {
    const { socket } = connection;
    if (socket.readyState !== socket.OPEN) return;
    const payload = JSON.stringify(message);
    if (socket.bufferedAmount + Buffer.byteLength(payload) > MAX_BUFFER_BYTES) {
      socket.terminate();
      return;
    }
    socket.send(payload, (error) => { if (error) socket.terminate(); });
  }

  function update(connection: Connection, subscription: Subscription, catalog: ApproachCatalog | null): void {
    if (connection.subscriptions.get(subscription.request.requestId) !== subscription) return;
    const request = subscription.request;
    const result = signalResult(request.approachKey, request.movement, request.catalogVersion, catalog, signalCache);
    const fingerprint = JSON.stringify(result);
    if (subscription.last === fingerprint) return;
    subscription.last = fingerprint;
    send(connection, connection.protocol.result(request.requestId, result));
  }

  // One shared database read per tick, not one per client/subscription. The same
  // safety gate supplies initial state, cache updates, expiry and catalog invalidation.
  const refresh = setInterval(async () => {
    if (refreshing || connections.size === 0) return;
    refreshing = true;
    try {
      const catalog = await catalogStore.getActive().catch(() => null);
      for (const connection of connections) for (const subscription of connection.subscriptions.values()) update(connection, subscription, catalog);
    } finally {
      refreshing = false;
    }
  }, 250);
  refresh.unref();
  const heartbeat = setInterval(() => {
    for (const connection of connections) {
      if (!connection.alive) { connection.socket.terminate(); continue; }
      connection.alive = false;
      connection.socket.ping();
    }
  }, 30000);
  heartbeat.unref();
  app.addHook("preClose", async () => {
    clearInterval(refresh);
    clearInterval(heartbeat);
    for (const connection of connections) connection.socket.terminate();
    connections.clear();
  });

  app.get("/v1/stream", { websocket: true }, (socket) => {
    if (connections.size >= MAX_CONNECTIONS) { socket.close(1013, "Connection limit"); return; }
    const connection: Connection = { socket, protocol: new StreamProtocol(), subscriptions: new Map(), alive: true };
    connections.add(connection);
    let windowStart = Date.now();
    let messages = 0;
    socket.on("pong", () => { connection.alive = true; });
    const cleanup = () => { connections.delete(connection); connection.subscriptions.clear(); };
    socket.on("close", cleanup);
    socket.on("error", () => { cleanup(); socket.terminate(); });
    socket.on("message", (message, binary) => {
      if (binary) { socket.close(1003, "Text JSON required"); return; }
      const now = Date.now();
      if (now - windowStart >= 1000) { windowStart = now; messages = 0; }
      if (++messages > 20) { socket.close(1008, "Message rate limit"); return; }
      const parsed = parseClientMessage(message.toString());
      if (parsed === null) { send(connection, connection.protocol.error(null, "INVALID_MESSAGE")); return; }
      if (parsed.type === "unsubscribe") { connection.subscriptions.delete(parsed.requestId); return; }
      if (connection.subscriptions.size >= MAX_SUBSCRIPTIONS && !connection.subscriptions.has(parsed.requestId)) { send(connection, connection.protocol.error(parsed.requestId, "SUBSCRIPTION_LIMIT")); return; }
      const subscription: Subscription = { request: parsed, last: null };
      connection.subscriptions.set(parsed.requestId, subscription);
    });
  });
}
