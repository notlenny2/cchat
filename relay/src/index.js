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
const PUSH_BUCKET = 30; // notifications: a burst when a group of agents all answer at once
const PUSH_REFILL = 1 / 10; // then one every 10 seconds
// Only cChat's own phone apps can be notified through this relay.
const TOPICS = new Set(["io.github.notlenny2.cchat.mobile"]);
const DEVICE = /^[0-9a-f]{64,200}$/;
const UUID = /^[0-9A-Fa-f-]{36}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return text(200, "cChat relay");
    }
    const m = url.pathname.match(/^\/v1\/m\/([^/]+)\/(mac|rpc|push)$/);
    if (!m || !MAILBOX.test(m[1])) return text(404, "not found");
    const stub = env.MAILBOXES.get(env.MAILBOXES.idFromName(m[1]));
    return stub.fetch(request);
  },
};

export class Mailbox {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.pushTokens = PUSH_BUCKET;
    this.pushRefilled = Date.now();
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
    if (url.pathname.endsWith("/push")) return this.push(request);
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

  // The computer asks for a notification on its phone ("Website: done, the page is up").
  // Only the computer that owns this mailbox may ask. Nothing is stored; the text goes straight on to Apple.
  async push(request) {
    const auth = request.headers.get("Authorization") || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const known = await this.ctx.storage.get("mac");
    if (!known || !MAILBOX.test(token) || !timingSafeEqual(known, await sha256(token))) return text(401, "no");
    if (!this.takePush()) return text(429, "slow down");
    if (Number(request.headers.get("Content-Length") || "0") > 4096) return text(413, "too big");
    let n;
    const raw = await request.text();
    if (raw.length > 4096) return text(413, "too big");
    try { n = JSON.parse(raw); } catch { return text(400, "bad json"); }
    if (!n || !DEVICE.test(n.device || "") || !TOPICS.has(n.topic)) return text(400, "bad device");
    const title = String(n.title || "").slice(0, 80);
    const body = String(n.body || "").slice(0, 240);
    if (!body) return text(400, "empty");
    const payload = { aps: { alert: { title, body }, sound: "default", "thread-id": UUID.test(n.conv || "") ? n.conv : "cchat" } };
    if (UUID.test(n.conv || "")) payload.conv = n.conv;
    if (Number.isInteger(n.badge) && n.badge >= 0 && n.badge < 10000) payload.aps.badge = n.badge;
    const res = await apns(this.env, n.device, n.topic, payload);
    return new Response(JSON.stringify(res), { status: 200, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
  }

  takePush() {
    const now = Date.now();
    this.pushTokens = Math.min(PUSH_BUCKET, this.pushTokens + ((now - this.pushRefilled) / 1000) * PUSH_REFILL);
    this.pushRefilled = now;
    if (this.pushTokens < 1) return false;
    this.pushTokens -= 1;
    return true;
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

// Apple push. A phone app installed straight from Xcode only exists on Apple's sandbox, an App Store or
// TestFlight one only on production, so try production and fall back to the sandbox on BadDeviceToken.
async function apns(env, device, topic, payload) {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return { ok: false, reason: "not set up" };
  const jwt = await apnsJWT(env);
  let last;
  for (const host of ["api.push.apple.com", "api.sandbox.push.apple.com"]) {
    const r = await fetch(`https://${host}/3/device/${device}`, {
      method: "POST",
      headers: { authorization: `bearer ${jwt}`, "apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10" },
      body: JSON.stringify(payload),
    });
    if (r.status === 200) return { ok: true };
    let reason = "";
    try { reason = (await r.json()).reason || ""; } catch {}
    last = { ok: false, status: r.status, reason };
    if (reason !== "BadDeviceToken") break;
  }
  return last;
}

let cachedJWT = null; // { jwt, made }
async function apnsJWT(env) {
  // Apple wants the same token reused for 20-60 minutes, not a new one per push.
  if (cachedJWT && Date.now() - cachedJWT.made < 40 * 60 * 1000) return cachedJWT.jwt;
  const pem = env.APNS_KEY_P8.replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const input = `${enc({ alg: "ES256", kid: env.APNS_KEY_ID })}.${enc({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) })}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  cachedJWT = { jwt: `${input}.${b64url(new Uint8Array(sig))}`, made: Date.now() };
  return cachedJWT.jwt;
}

function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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
