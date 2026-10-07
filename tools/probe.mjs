// 一次性 DOM 探针：检查侧边栏图标与高亮状态
import { spawn } from 'node:child_process';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const url = process.argv[2];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const userDataDir = await mkdtemp(path.join(tmpdir(), 'wf-probe-'));
const port = 9555;
const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${port}`, `--user-data-dir=${userDataDir}`, '--window-size=1560,980', 'about:blank'], { stdio: 'ignore' });

for (let i = 0; i < 60; i += 1) {
  try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(300); }
}
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve) => ws.addEventListener('open', resolve, { once: true }));
let id = 0;
const pending = new Map();
ws.addEventListener('message', (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
});
const send = (method, params = {}) => new Promise((resolve) => {
  const mid = ++id; pending.set(mid, resolve);
  ws.send(JSON.stringify({ id: mid, method, params }));
});
await send('Page.enable');
await send('Page.navigate', { url });
await sleep(Number(process.argv[3] || 12000));

const probes = [
  ['侧边栏活动项', `[...document.querySelectorAll('.navitem--active')].map(n => n.dataset.label || n.textContent.trim()).join(' | ')`],
  ['侧边栏图标HTML(桌面)', `document.querySelector('.navitem[data-path="/Users/mac/Desktop"] .navitem__icon')?.innerHTML.slice(0,60)`],
  ['侧边栏图标数量统计', `JSON.stringify([...document.querySelectorAll('.navitem__icon')].reduce((acc,n)=>{const k = n.innerHTML.startsWith('<svg')?'svg':(n.textContent.trim()||'empty');acc[k]=(acc[k]||0)+1;return acc;},{}))`],
  ['列表首行图标', `document.querySelector('.drow .drow__icon')?.innerHTML.slice(0,60)`],
  ['详情窗格图标', `document.querySelector('.dp__glyph')?.innerHTML.slice(0,60)`],
  ['当前视图', `window.__winfile.state.view + ' / ' + (window.__winfile.state.path||'')`],
  ['错误覆盖层', `document.getElementById('emptyState').hidden ? '隐藏' : '可见: '+document.getElementById('emptyTitle').textContent`],
  ['侧边栏 data-path 列表', `[...document.querySelectorAll('.navitem[data-path]')].map(n=>n.dataset.path).join(' , ')`],
  ['home 元素存在', `!!document.querySelector('.navitem[data-path="/Users/mac"]')`],
  ['CSS.escape 结果', `CSS.escape('/Users/mac')`],
  ['选择器匹配数', `document.querySelectorAll('.navitem[data-path="/Users/mac"][data-view="files"]').length`],
  ['手动 querySelector+class', `(()=>{ const n=document.querySelector('.navitem[data-path="/Users/mac"][data-view="files"]'); if(!n) return '未找到'; n.classList.add('navitem--active'); return n.className + ' / matches=' + document.querySelectorAll('.navitem--active').length; })()`],
  ['state.view', `window.__winfile.state.view`],
  ['markActiveNav 是否可见', `typeof window.__winfile.state`],
];
for (const [label, expr] of probes) {
  const res = await send('Runtime.evaluate', { expression: expr, returnByValue: true });
  console.log(`  ${label}: ${JSON.stringify(res.result?.result?.value ?? res.result?.exceptionDetails?.text)}`);
}
chrome.kill('SIGKILL');
process.exit(0);
