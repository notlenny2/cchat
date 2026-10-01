// cChat relay: lets a phone reach its computer from anywhere, without a VPN and without opening ports.
//
// The computer keeps one WebSocket open to its mailbox here. The phone POSTs a request to the same
// mailbox; the relay hands it to the computer over that socket and returns whatever the computer answers.
//
// The relay never sees a chat. Every body it carries is already sealed (ChaCha20-Poly1305) with the
// pairing key that only the phone and the computer have, and the computer refuses anything stale or
// replayed. The mailbox name and the computer's token are both derived from that key with HMAC, so the
// relay can't work the key back out, and nobody without the key can find the mailbox or pose as the computer.

const MAILBOX = /^[A-Za-z0-9_-]{43}$/;
const MAX_BODY = 25 * 1024 * 1024; // a few phone pictures, sealed
const CHUNK = 512 * 1024; // WebSocket messages max out at 1 MiB on Cloudflare
const MAX_PENDING = 64;
const DEFAULT_WAIT = 60; // seconds; the sync long-poll is 25s on the computer
const MAX_WAIT = 16 * 60; // `ask` with wait can take up to 15 minutes
const BUCKET = 240; // burst (the phone fetches every contact's picture at start)
const REFILL = 8; // requests per second, sustained

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return text(200, "cChat relay");
    }
    const m = url.pathname.match(/^\/v1\/m\/([^/]+)\/(mac|rpc)$/);
    if (!m || !MAILBOX.test(m[1])) return text(404, "not found");
    const stub = env.MAILBOXES.get(env.MAILBOXES.idFromName(m[1]));
    return stub.fetch(request);
  },
};

export class Mailbox {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.pending = new Map(); // id -> { resolve, status, parts, timer }
    this.tokens = BUCKET;
    this.refilled = Date.now();
    // Keep-alive pings from the computer are answered without waking this object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname.endsWith("/mac")) return this.attachMac(request);
    if (request.method !== "POST") return text(405, "POST only");
    return this.forward(request, url);
  }

  // The computer connects. The first one to connect with a token claims the mailbox; after that only
  // the same token gets in. The token is only stored hashed.
  async attachMac(request) {
    if (request.headers.get("Upgrade") !== "websocket") return text(426, "websocket only");
    const auth = request.headers.get("Authorization") || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!MAILBOX.test(token)) return text(401, "no");
    const hash = await sha256(token);
    const known = await this.ctx.storage.get("mac");
    if (known && !timingSafeEqual(known, hash)) return text(401, "no");
    if (!known) await this.ctx.storage.put("mac", hash);
    await this.ctx.storage.put("seen", Date.now());

    // A newer connection from the computer replaces the old one.
    for (const old of this.ctx.getWebSockets()) {
      try { old.close(1000, "replaced"); } catch {}
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  // The phone asks. Hand it to the computer, wait for the answer, pass it back unopened.
  async forward(request, url) {
    if (!this.take()) return text(429, "slow down");
    const len = Number(request.headers.get("Content-Length") || "0");
    if (len > MAX_BODY) return text(413, "too big");
    const sockets = this.ctx.getWebSockets().filter((s) => s.readyState === WebSocket.OPEN);
    const mac = sockets[sockets.length - 1];
    if (!mac) return text(503, "computer offline");
    if (this.pending.size >= MAX_PENDING) return text(429, "busy");

    const body = new Uint8Array(await request.arrayBuffer());
    if (body.length > MAX_BODY) return text(413, "too big");
    const wait = Math.min(MAX_WAIT, Math.max(5, Number(url.searchParams.get("t")) || DEFAULT_WAIT));
    const id = crypto.randomUUID();

    const answer = new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve(text(504, "computer didn't answer"));
      }, wait * 1000);
      this.pending.set(id, { resolve, status: 200, parts: [], timer });
    });
    try {
      for (const frame of frames(id, body)) mac.send(frame);
    } catch {
      const p = this.pending.get(id);
      if (p) { clearTimeout(p.timer); this.pending.delete(id); }
      return text(503, "computer offline");
    }
    return answer;
  }

  // Answers from the computer, in chunks: [4-byte header length][header JSON][bytes].
  async webSocketMessage(ws, message) {
    if (typeof message === "string") return; // pings are handled by the auto-response
    const buf = new Uint8Array(message);
    if (buf.length < 4) return;
    const hlen = new DataView(buf.buffer, buf.byteOffset).getUint32(0);
    if (hlen > 1024 || 4 + hlen > buf.length) return;
    let head;
    try { head = JSON.parse(new TextDecoder().decode(buf.subarray(4, 4 + hlen))); } catch { return; }
    const p = this.pending.get(head.id);
    if (!p) return;
    if (Number.isInteger(head.status)) p.status = head.status;
    p.parts.push(buf.slice(4 + hlen));
    p.size = (p.size || 0) + buf.length - 4 - hlen;
    if (p.size > 220 * 1024 * 1024) { // a video is the biggest thing that comes back
      clearTimeout(p.timer); this.pending.delete(head.id);
      return p.resolve(text(502, "answer too big"));
    }
    if (head.last) {
      clearTimeout(p.timer);
      this.pending.delete(head.id);
      const status = [200, 401, 404, 500].includes(p.status) ? p.status : 502;
      p.resolve(new Response(new Blob(p.parts), {
        status,
        headers: { "Content-Type": "application/octet-stream", "Cache-Control": "no-store" },
      }));
    }
  }

  async webSocketClose(ws) {
    // If that was the only computer connection, nobody is left to answer.
    const left = this.ctx.getWebSockets().filter((s) => s !== ws && s.readyState === WebSocket.OPEN);
    if (left.length === 0) {
      for (const [id, p] of this.pending) {
        clearTimeout(p.timer);
        p.resolve(text(503, "computer offline"));
      }
      this.pending.clear();
    }
  }

  async webSocketError(ws) { return this.webSocketClose(ws); }

  take() {
    const now = Date.now();
    this.tokens = Math.min(BUCKET, this.tokens + ((now - this.refilled) / 1000) * REFILL);
    this.refilled = now;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}

function* frames(id, body) {
  const enc = new TextEncoder();
  let seq = 0;
  for (let off = 0; off < body.length || seq === 0; off += CHUNK) {
    const part = body.subarray(off, Math.min(body.length, off + CHUNK));
    const last = off + CHUNK >= body.length;
    const head = enc.encode(JSON.stringify({ id, seq, last }));
    const out = new Uint8Array(4 + head.length + part.length);
    new DataView(out.buffer).setUint32(0, head.length);
    out.set(head, 4);
    out.set(part, 4 + head.length);
    seq++;
    yield out;
  }
}

function text(status, s) {
  return new Response(s, { status, headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" } });
}

async function sha256(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
