// 诊断：查看截图脚本在页面里的实际状态
import { spawn } from 'node:child_process';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const url = process.argv[2];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const userDataDir = await mkdtemp(path.join(tmpdir(), 'wf-diag-'));
const port = 9444;
const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--no-first-run',
  `--remote-debugging-port=${port}`, `--user-data-dir=${userDataDir}`, 'about:blank'], { stdio: 'ignore' });

let version = null;
for (let i = 0; i < 60; i += 1) {
  try { version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(300); }
}
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve) => ws.addEventListener('open', resolve, { once: true }));
let id = 0;
const pending = new Map();
ws.addEventListener('message', (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  if (msg.method === 'Runtime.consoleAPICalled') {
    console.log('  [console]', msg.params.args.map((a) => a.value ?? a.description).join(' '));
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    console.log('  [异常]', msg.params.exceptionDetails.text, msg.params.exceptionDetails.exception?.description?.split('\n')[0] || '');
  }
});
const send = (method, params = {}) => new Promise((resolve) => {
  const mid = ++id;
  pending.set(mid, resolve);
  ws.send(JSON.stringify({ id: mid, method, params }));
});
await send('Runtime.enable');
await send('Page.enable');
await send('Page.navigate', { url });
await sleep(Number(process.argv[3] || 12000));
for (const expr of [
  'typeof window.__winfile',
  'document.body?.dataset.view',
  'document.body?.dataset.shotReady',
  'window.__winfile ? window.__winfile.state.view : "n/a"',
  'window.__winfile ? window.__winfile.state.entries.length : -1',
  'window.__winfile?.state.boot ? "boot-ok" : "boot-missing"',
  'document.querySelectorAll(".drow").length',
  'document.getElementById("statusCount").textContent',
  'typeof TOKEN !== "undefined" ? TOKEN : "TOKEN-undefined"',
]) {
  const res = await send('Runtime.evaluate', { expression: expr, returnByValue: true });
  console.log(`  ${expr} => ${JSON.stringify(res.result?.result?.value ?? res.result?.exceptionDetails?.text)}`);
}
chrome.kill('SIGKILL');
process.exit(0);
