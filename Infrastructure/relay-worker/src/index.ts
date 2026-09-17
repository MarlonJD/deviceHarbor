import { DurableObject } from "cloudflare:workers";

interface Env {
  RELAY_ROOMS: DurableObjectNamespace<DeviceHarborRelayRoom>;
}

interface PeerAttachment {
  joined: boolean;
  peerID: string;
}

interface RelayJoinFrame {
  kind?: string;
  rendezvousID?: string;
  accessToken?: string;
}

interface RelayReadyFrame {
  kind: "relayReady";
  protocolVersion: 1;
  rendezvousID: string;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

function encodeFrame(frame: RelayReadyFrame): string {
  return `${JSON.stringify(frame)}\n`;
}

function decodeMessage(message: string | ArrayBuffer): string {
  return typeof message === "string" ? message : textDecoder.decode(message);
}

async function hashToken(token: string): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(token));
  return new Uint8Array(digest);
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function getAttachment(ws: WebSocket): PeerAttachment | null {
  const attachment = ws.deserializeAttachment();
  if (!attachment || typeof attachment !== "object") return null;
  const candidate = attachment as Partial<PeerAttachment>;
  if (typeof candidate.joined !== "boolean" || typeof candidate.peerID !== "string") return null;
  return { joined: candidate.joined, peerID: candidate.peerID };
}

export class DeviceHarborRelayRoom extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket upgrade required", { status: 426 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({
      joined: false,
      peerID: crypto.randomUUID(),
    } satisfies PeerAttachment);

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = getAttachment(ws);
    if (!attachment) {
      ws.close(1008, "Invalid DeviceHarbor relay attachment");
      return;
    }

    const raw = decodeMessage(message).trim();
    if (!attachment.joined) {
      await this.join(ws, attachment, raw);
      return;
    }

    const recipients = this.ctx
      .getWebSockets()
      .filter((candidate) => candidate !== ws)
      .filter((candidate) => getAttachment(candidate)?.joined === true);
    recipients.forEach((candidate) => candidate.send(message));
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const remaining = this.ctx.getWebSockets().filter((candidate) => candidate !== ws);
    if (remaining.length === 0) {
      await this.ctx.storage.delete("tokenHash");
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws);
  }

  private async join(ws: WebSocket, attachment: PeerAttachment, raw: string): Promise<void> {
    let frame: RelayJoinFrame;
    try {
      frame = JSON.parse(raw) as RelayJoinFrame;
    } catch {
      ws.close(1008, "Invalid relay join frame");
      return;
    }

    if (frame.kind !== "relayJoin" || !frame.rendezvousID || !frame.accessToken) {
      ws.close(1008, "Incomplete relay join frame");
      return;
    }

    const peers = this.ctx.getWebSockets();
    const joinedPeers = peers.filter((candidate) => getAttachment(candidate)?.joined === true);
    if (joinedPeers.length >= 2) {
      ws.close(1008, "DeviceHarbor room is full");
      return;
    }

    const tokenHash = await hashToken(frame.accessToken);
    const storedTokenHash = await this.ctx.storage.get<ArrayBuffer>("tokenHash");
    if (storedTokenHash && !equalBytes(tokenHash, new Uint8Array(storedTokenHash))) {
      ws.close(1008, "DeviceHarbor room token mismatch");
      return;
    }
    if (!storedTokenHash) {
      await this.ctx.storage.put("tokenHash", tokenHash.buffer);
    }

    ws.serializeAttachment({ ...attachment, joined: true } satisfies PeerAttachment);
    const nowJoined = this.ctx
      .getWebSockets()
      .filter((candidate) => getAttachment(candidate)?.joined === true);
    if (nowJoined.length !== 2) return;

    const ready: RelayReadyFrame = {
      kind: "relayReady",
      protocolVersion: 1,
      rendezvousID: frame.rendezvousID,
    };
    const encoded = encodeFrame(ready);
    nowJoined.forEach((candidate) => candidate.send(encoded));
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({ service: "deviceharbor-relay", status: "ok" });
    }

    const match = url.pathname.match(/^\/v1\/rooms\/([A-Za-z0-9_-]{6,64})$/);
    if (!match) {
      return new Response("Not found", { status: 404 });
    }

    const roomID = match[1];
    const room = env.RELAY_ROOMS.getByName(`room:${roomID}`);
    return room.fetch(request);
  },
} satisfies ExportedHandler<Env>;
