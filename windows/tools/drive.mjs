// Test driver: talks to the running app's WebView2 over the DevTools port and runs a script of steps.
// Usage: node drive.mjs <port> <step-file.js> <out-dir>. Steps get { js, shot, sleep, until }.
import fs from 'node:fs';
const [port, stepsFile, out] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let targets;
for (let i = 0; i < 60; i++) {
  try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); if (targets.find((t) => t.type === 'page')) break; } catch {}
  await sleep(1000);
}
const page = targets.find((t) => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let n = 0; const waiting = new Map();
ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } });
const call = (method, params = {}) => new Promise((r) => { const id = ++n; waiting.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expr) => {
  const r = await call('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};
const shot = async (name) => { const r = await call('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(`${out}/${name}.png`, Buffer.from(r.result.data, 'base64')); console.log('shot', name); };
const until = async (expr, secs = 120) => { for (let i = 0; i < secs * 2; i++) { if (await js(expr)) return true; await sleep(500); } console.log('TIMEOUT', expr); return false; };
fs.mkdirSync(out, { recursive: true });
const steps = (await import('file://' + stepsFile.replace(/\\/g, '/'))).default;
try { await steps({ js, shot, sleep, until, log: console.log }); } catch (e) { console.log('FAILED', e.message); }
ws.close();
