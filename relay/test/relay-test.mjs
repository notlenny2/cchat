// Drives a running relay (npm run dev) with a fake computer and a fake phone.
// node test/relay-test.mjs [http://127.0.0.1:8787]
import { createHmac, randomBytes } from "node:crypto";

const BASE = process.argv[2] || "http://127.0.0.1:8787";
const b64u = (b) => Buffer.from(b).toString("base64url");
const key = randomBytes(32);
const mbox = b64u(createHmac("sha256", key).update("cchat relay mailbox v1").digest());
const token = b64u(createHmac("sha256", key).update("cchat relay mac v1").digest());
let failed = 0;
const check = (name, ok, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"} ${name} ${extra}`); if (!ok) failed++; };

function frame(id, seq, last, status, bytes) {
  const head = Buffer.from(JSON.stringify({ id, seq, last, status }));
  const len = Buffer.alloc(4); len.writeUInt32BE(head.length);
  return Buffer.concat([len, head, bytes]);
}
function parse(buf) {
  const b = Buffer.from(buf);
  const hl = b.readUInt32BE(0);
  return { head: JSON.parse(b.subarray(4, 4 + hl)), body: b.subarray(4 + hl) };
}

function connectMac(tok, onRequest) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${BASE.replace("http", "ws")}/v1/m/${mbox}/mac`, { headers: { Authorization: `Bearer ${tok}` } });
    ws.binaryType = "arraybuffer";
    const parts = new Map();
    ws.onopen = () => resolve(ws);
    ws.onerror = (e) => reject(new Error("ws error"));
    ws.onclose = (e) => reject(new Error("closed " + e.code));
    ws.onmessage = async (ev) => {
      if (typeof ev.data === "string") return;
      const { head, body } = parse(ev.data);
      const arr = parts.get(head.id) || []; arr.push(body); parts.set(head.id, arr);
      if (!head.last) return;
      parts.delete(head.id);
      const { status, out } = await onRequest(Buffer.concat(arr));
      // answer in 512 KB chunks like the real computer will
      const C = 512 * 1024;
      for (let off = 0, seq = 0; off < out.length || seq === 0; off += C, seq++) {
        ws.send(frame(head.id, seq, off + C >= out.length, status, out.subarray(off, off + C)));
      }
    };
  });
}

const rpc = (body, t) => fetch(`${BASE}/v1/m/${mbox}/rpc${t ? `?t=${t}` : ""}`, { method: "POST", body });

// 1. no computer yet
let r = await rpc(Buffer.from("hello"));
check("offline before the computer connects", r.status === 503, r.status);

// 2. wrong-shaped token is refused
try { await connectMac("short", async () => ({})); check("bad token refused", false); }
catch { check("bad token refused", true); }

// 3. computer connects, echoes reversed
const mac = await connectMac(token, async (body) => ({ status: 200, out: Buffer.from(body).reverse() }));
check("computer connects", true);
r = await rpc(Buffer.from("abc"));
check("round trip", r.status === 200 && (await r.text()) === "cba");

// 4. another token can't take the mailbox over
const other = b64u(randomBytes(32));
try { await connectMac(other, async () => ({})); check("someone else's token refused", false); }
catch { check("someone else's token refused", true); }

// 5. big body both ways (3 MB, crosses chunks)
const big = randomBytes(3 * 1024 * 1024);
r = await rpc(big);
const back = Buffer.from(await r.arrayBuffer());
check("3 MB both ways", r.status === 200 && back.equals(Buffer.from(big).reverse()), back.length);

// 6. empty body
r = await rpc(Buffer.alloc(0));
check("empty body", r.status === 200 && (await r.arrayBuffer()).byteLength === 0);

// 7. many at once
const many = await Promise.all([...Array(30)].map((_, i) => rpc(Buffer.from("n" + i)).then((x) => x.text())));
check("30 at once, each gets its own answer", many.every((t, i) => t === ("n" + i).split("").reverse().join("")));

// 8. 401 from the computer passes through
mac.close();
await new Promise((s) => setTimeout(s, 300));
const mac2 = await connectMac(token, async () => ({ status: 401, out: Buffer.alloc(0) }));
r = await rpc(Buffer.from("x"));
check("computer's 401 passes through", r.status === 401, r.status);

// 9. slow computer -> timeout
mac2.close();
await new Promise((s) => setTimeout(s, 300));
const mac3 = await connectMac(token, () => new Promise(() => {}));
const t0 = Date.now();
r = await rpc(Buffer.from("x"), 5);
check("computer that never answers times out", r.status === 504 && Date.now() - t0 < 9000, `${r.status} ${Date.now() - t0}ms`);

// 10. computer disconnects mid-wait -> 503 right away
const pending = rpc(Buffer.from("x"), 60);
await new Promise((s) => setTimeout(s, 300));
mac3.close();
r = await pending;
check("computer drops mid-request", r.status === 503, r.status);

// 11. bad mailbox names
r = await fetch(`${BASE}/v1/m/notamailbox/rpc`, { method: "POST", body: "x" });
check("bad mailbox name", r.status === 404);
r = await fetch(`${BASE}/v1/m/${mbox}/rpc`);
check("GET refused", r.status === 405, r.status);

// 12. rate limit kicks in
const mac4 = await connectMac(token, async (b) => ({ status: 200, out: b }));
const burst = await Promise.all([...Array(300)].map(() => rpc(Buffer.from("y")).then((x) => x.status)));
check("rate limit stops a flood", burst.filter((s) => s === 429).length > 0, `${burst.filter((s) => s === 429).length} limited`);
mac4.close();

console.log(failed ? `${failed} FAILED` : "all passed");
process.exit(failed ? 1 : 0);
