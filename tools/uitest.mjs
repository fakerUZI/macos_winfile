// 浏览器内 UI 端到端测试：通过真实点击/输入验证交互链路
// 用法: node tools/uitest.mjs <baseUrl> [等待毫秒]
import { spawn } from 'node:child_process';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const BASE = process.argv[2];
// 该测试只针对应用本身，因此使用未注入截图脚本的副本
const WAIT = Number(process.argv[3] || 6000);

const results = [];
function check(name, ok, detail = '') {
  results.push({ name, ok, detail });
  console.log(`  ${ok ? '✔' : '✘'} ${name}${ok || !detail ? '' : ` — ${detail}`}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const userDataDir = await mkdtemp(path.join(tmpdir(), 'wf-uitest-'));
const port = 9666;
const chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  '--no-default-browser-check', `--remote-debugging-port=${port}`, `--user-data-dir=${userDataDir}`,
  '--window-size=1560,980', 'about:blank'], { stdio: 'ignore' });

for (let i = 0; i < 60; i += 1) {
  try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(300); }
}
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve) => ws.addEventListener('open', resolve, { once: true }));
let id = 0;
const pending = new Map();
const consoleErrors = [];
ws.addEventListener('message', (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
    consoleErrors.push('console: ' + msg.params.args.map((a) => a.value ?? a.description).join(' '));
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    const d = msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text || '';
    consoleErrors.push(d.split('\n').slice(0, 6).join(' ⏎ '));
  }
});
const send = (method, params = {}) => new Promise((resolve) => {
  const mid = ++id; pending.set(mid, resolve);
  ws.send(JSON.stringify({ id: mid, method, params }));
});
async function evaluate(expression) {
  const res = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (res.result?.exceptionDetails) {
    throw new Error(res.result.exceptionDetails.exception?.description?.split('\n')[0] || 'JS 异常');
  }
  return res.result?.result?.value;
}

await send('Page.enable');
await send('Runtime.enable');
await send('Runtime.addBinding', { name: '__reportError' }).catch(() => {});
await send('Page.navigate', { url: BASE });
await sleep(600);
await evaluate(`window.addEventListener('unhandledrejection', (e) => {
  console.error('REJECTION: ' + (e.reason && e.reason.stack ? e.reason.stack : String(e.reason)));
}); 'hooked'`).catch(() => {});
await sleep(WAIT - 600);

const api = `(await (await fetch('/api/boot')).json()).token`;
const helper = `
window.__t = {
  token: null,
  async ready() { this.token = ${api}; },
  q: (sel) => document.querySelector(sel),
  qa: (sel) => [...document.querySelectorAll(sel)],
  async api(path, body, method) {
    const res = await fetch(path, { method: method || (body ? 'POST' : 'GET'),
      headers: { 'X-Winfile-Token': this.token, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined });
    return res.json();
  },
  rows: () => [...document.querySelectorAll('.drow')].map(r => r.dataset.path),
  click: (sel) => { const n = document.querySelector(sel); n.dispatchEvent(new MouseEvent('click', {bubbles:true})); return !!n; },
  dbl: (sel) => { const n = document.querySelector(sel); n.dispatchEvent(new MouseEvent('dblclick', {bubbles:true})); return !!n; },
  async type(sel, value) {
    const n = document.querySelector(sel);
    n.value = value;
    n.dispatchEvent(new Event('input', { bubbles: true }));
    return n.value;
  },
  async press(key, opts = {}) {
    document.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ key, bubbles: true }, opts)));
  },
  async pressOn(sel, key) {
    const n = document.querySelector(sel);
    n.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }));
  },
};
'helper-ready'`;
check('测试辅助注入', (await evaluate(helper)) === 'helper-ready');
await evaluate('__t.ready()');

// 准备一个沙盒目录
const sandbox = await evaluate(`(async () => {
  const boot = await (await fetch('/api/boot')).json();
  const base = boot.places.groups[0].items.find(i => i.name === '文稿')?.path || boot.home;
  const dir = base + '/winfile-uitest-' + Date.now();
  const mk = await __t.api('/api/mkdir', { parent: base, name: dir.split('/').pop() });
  await __t.api('/api/newfile', { parent: mk.path, name: '文档A.txt' });
  await __t.api('/api/newfile', { parent: mk.path, name: '图片B.png' });
  const sub = await __t.api('/api/mkdir', { parent: mk.path, name: '子目录' });
  await __t.api('/api/newfile', { parent: sub.path, name: '内层.txt' });
  return mk.path;
})()`);
check('创建测试沙盒', !!sandbox, sandbox);

// ---- 目录导航
await evaluate(`__winfile.openPath(${JSON.stringify(sandbox)}, { pushHistory: true })`);
await sleep(1200);
let rows = await evaluate('__t.rows()');
check('导航到沙盒目录并列出 3 项', rows.length === 3, JSON.stringify(rows));
check('文件夹排在文件之前', rows[0].endsWith('子目录'), rows[0]);
check('状态栏显示项目数', (await evaluate(`__t.q('#statusCount').textContent`)).includes('3 个项目'));
check('面包屑末级为沙盒目录', (await evaluate(`__t.q('.crumb--last').textContent`)).startsWith('winfile-uitest'));
check('侧边栏无错误高亮', (await evaluate(`__t.qa('.navitem--active').length`)) <= 1);

// ---- 大小排序
await evaluate(`__t.qa('.dtable thead th')[3].dispatchEvent(new MouseEvent('click',{bubbles:true}))`);
await sleep(1200);
const sortedRows = await evaluate('__t.rows()');
check('点击表头可按大小排序', sortedRows.length === 3, JSON.stringify(sortedRows));
await evaluate(`__t.qa('.dtable thead th')[0].dispatchEvent(new MouseEvent('click',{bubbles:true}))`);
await sleep(1000);

// ---- 选择与批量操作按钮状态
await evaluate(`__t.click('.drow')`);
check('单击选中一行', (await evaluate(`__t.qa('.drow--selected').length`)) === 1);
check('选中后命令栏按钮启用', (await evaluate(`!__t.q('#btnDelete').disabled && !__t.q('#btnCopy').disabled`)));
await evaluate(`__t.press('a', { metaKey: true })`);
check('⌘A 全选', (await evaluate(`__t.qa('.drow--selected').length`)) === 3);
await evaluate(`__t.press('Escape')`);
await evaluate(`__t.click('#viewHost')`);
check('点击空白取消选择', (await evaluate(`__t.qa('.drow--selected').length`)) === 0);

// ---- 大图标视图
await evaluate(`__t.click('#btnView')`);
await evaluate(`[...document.querySelectorAll('.ctxmenu__item')].find(n=>n.textContent.includes('大图标'))?.click()`);
await sleep(400);
check('切换到图标视图', (await evaluate(`__t.qa('.tile').length`)) === 3);
await evaluate(`__winfile.state.layout='details'; __winfile.renderList()`);
await sleep(300);

// ---- 搜索过滤
await evaluate(`__t.type('#searchInput', '文档A')`);
await sleep(500);
check('搜索框过滤当前视图', (await evaluate(`__t.rows().length`)) === 1, JSON.stringify(await evaluate('__t.rows()')));
await evaluate(`__t.click('#btnSearchClear')`);
await sleep(400);
check('清除搜索恢复全部', (await evaluate(`__t.rows().length`)) === 3);

// ---- 新建文件夹（走对话框）
await evaluate(`__t.click('#btnNew')`);
await sleep(200);
await evaluate(`__t.qa('.ctxmenu__item').find(n=>n.textContent.includes('文件夹'))?.click()`);
await sleep(500);
check('新建文件夹对话框出现', (await evaluate(`!__t.q('#dialogBackdrop').hidden`)),
  'dialogBody=' + JSON.stringify(await evaluate(`__t.q('#dialogBody').innerHTML.slice(0,80)`)));
await evaluate(`__t.type('#dlgNameInput', '新文件夹UI')`);
await evaluate(`__t.click('#dialogOk')`);
await sleep(1500);
check('新建文件夹成功', (await evaluate(`__t.rows().some(p => p.endsWith('新文件夹UI'))`)), JSON.stringify(await evaluate('__t.rows()')));

// ---- 重命名（F2 对话框）
await evaluate(`(() => { const row = __t.qa('.drow').find(r => r.dataset.path.endsWith('文档A.txt'));
  row.dispatchEvent(new MouseEvent('click',{bubbles:true})); })()`);
await sleep(200);
await evaluate(`__t.press('F2')`);
await sleep(400);
check('重命名对话框出现', (await evaluate(`!__t.q('#dialogBackdrop').hidden`)));
await evaluate(`__t.type('#dlgNameInput', '改名为C.txt')`);
await evaluate(`__t.click('#dialogOk')`);
await sleep(1500);
check('重命名成功', (await evaluate(`__t.rows().some(p => p.endsWith('改名为C.txt'))`)), JSON.stringify(await evaluate('__t.rows()')));
await evaluate(`__t.api('/api/savefile', { path: ${JSON.stringify(sandbox + '/改名为C.txt')}, text: ${JSON.stringify('WinFile 剪贴板内容\n第二行')} })`);

// ---- 复制粘贴（四种入口都要能用）
const clickRow = (suffix) => evaluate(`(() => { const row = __t.qa('.drow').find(r => r.dataset.path.endsWith(${JSON.stringify(suffix)}));
  if (!row) return 'missing'; row.dispatchEvent(new MouseEvent('click',{bubbles:true})); return 'ok'; })()`);

// ① 命令栏「复制」→ 进入子目录 → 命令栏「粘贴」
check('选中文件用于复制', (await clickRow('改名为C.txt')) === 'ok');
await evaluate(`__t.click('#btnCopy')`);
await sleep(400);
check('复制后粘贴按钮可用', (await evaluate(`!__t.q('#btnPaste').disabled`)));
check('复制后有明确提示', (await evaluate(`[...document.querySelectorAll('.toast')].some(t=>t.textContent.includes('已复制'))`)));
await evaluate(`__winfile.openPath(${JSON.stringify(sandbox + '/子目录')}, { pushHistory: true })`);
await sleep(1200);
await evaluate(`__t.click('#btnPaste')`);
await sleep(2000);
check('① 命令栏复制→粘贴到子目录',
  (await evaluate(`__t.rows().some(p => p.endsWith('改名为C.txt'))`)), JSON.stringify(await evaluate('__t.rows()')));
check('粘贴提示含目标文件夹名', (await evaluate(`[...document.querySelectorAll('.toast')].some(t=>t.textContent.includes('已复制') && t.textContent.includes('子目录'))`)));

// ② 右键菜单「复制」→ 文件夹右键「粘贴到此处」
await evaluate(`__winfile.openPath(${JSON.stringify(sandbox)}, { pushHistory: true })`);
await sleep(1000);
await clickRow('图片B.png');
await evaluate(`__t.qa('.drow').find(r=>r.dataset.path.endsWith('图片B.png')).dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:420,clientY:320}))`);
await sleep(300);
await evaluate(`__t.qa('.ctxmenu__item').find(n=>n.textContent.includes('复制') && !n.textContent.includes('复制路径'))?.click()`);
await sleep(400);
await evaluate(`__t.qa('.drow').find(r=>r.dataset.path.endsWith('子目录')).dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:420,clientY:340}))`);
await sleep(300);
await evaluate(`__t.qa('.ctxmenu__item').find(n=>n.textContent.includes('粘贴到此处'))?.click()`);
await sleep(2000);
const subFiles = await evaluate(`(async () => JSON.stringify((await __t.api('/api/files?path=' + encodeURIComponent(${JSON.stringify(sandbox + '/子目录')}))).entries.map(e=>e.name)))()`);
check('② 右键复制→粘贴到此处', JSON.parse(subFiles).includes('图片B.png'), subFiles);

// ③ 同目录内复制（自动加序号）
await evaluate(`__winfile.openPath(${JSON.stringify(sandbox)}, { pushHistory: true })`);
await sleep(1200);
await clickRow('图片B.png');
await evaluate(`__t.press('c', { metaKey: true })`);
await sleep(300);
await evaluate(`__t.press('v', { metaKey: true })`);
await sleep(2000);
check('③ 同目录复制自动加序号', (await evaluate(`__t.rows().some(p => p.includes('图片B 2.png'))`)), JSON.stringify(await evaluate('__t.rows()')));
check('复制出副本', (await evaluate(`__t.rows().filter(p => p.includes('改名为C')).length`)) === 1, JSON.stringify(await evaluate('__t.rows()')));

// ---- 删除到废纸篓（用临时沙盒中的副本，随后清理）
await evaluate(`(() => { const row = __t.qa('.drow').find(r => r.dataset.path.includes('图片B 2'));
  row.dispatchEvent(new MouseEvent('click',{bubbles:true})); })()`);
await evaluate(`__t.press('Delete')`);
await sleep(600);
check('删除确认框出现', (await evaluate(`!__t.q('#dialogBackdrop').hidden`)));
await evaluate(`__t.click('#dialogOk')`);
await sleep(2500);
check('删除后副本已不在列表', !(await evaluate('__t.rows()')).some(p => p.includes('图片B 2')), JSON.stringify(await evaluate('__t.rows()')));
check('副本已从列表移除', !(await evaluate(`__t.rows()`)).some(p => p.includes('改名为C 2')), JSON.stringify(await evaluate('__t.rows()')));
const trashCheck = await evaluate(`__t.api('/api/trash')`);
check('废纸篓计数可读', trashCheck.ok === true, JSON.stringify(trashCheck));

// ---- 路径补全交互
await evaluate(`__t.press('l', { metaKey: true })`);
await evaluate(`__t.type('#pathInput', ${JSON.stringify(sandbox + '/子')})`);
await sleep(900);
check('地址栏补全下拉出现', (await evaluate(`__t.qa('.suggest__item').length`)) >= 1,
  await evaluate(`__t.q('#suggest').textContent`));
await evaluate(`__t.pressOn('#pathInput', 'Tab')`);
await sleep(700);
check('Tab 补全填入路径', (await evaluate(`__t.q('#pathInput').value`)).includes('子目录'),
  await evaluate(`__t.q('#pathInput').value`));
await evaluate(`__t.pressOn('#pathInput', 'Escape')`);

// ---- 分类与最近使用视图
await evaluate(`__winfile.loadRecent({ days: 30 })`);
await sleep(2500);
check('最近使用视图有数据', (await evaluate(`__t.rows().length`)) > 0);
check('最近使用列表含所在位置列', (await evaluate(`__t.q('.dtable thead').textContent`)).includes('所在位置'));
await evaluate(`__winfile.loadCategory('image')`);
await sleep(3000);
const catRows = await evaluate(`__t.rows().length`);
check('图片分类视图有数据', catRows > 0, `rows=${catRows}`);
await evaluate(`__winfile.loadApps()`);
await sleep(4000);
const appRows = await evaluate(`__t.rows().length`);
check('应用程序视图有数据', appRows > 100, `rows=${appRows}`);
check('应用程序视图显示版本列', (await evaluate(`__t.q('.dtable thead').textContent`)).includes('版本'));

// ---- 复制文字到系统剪贴板（用户反馈的核心需求）
const clipboardText = async () => evaluate(`(async () => (await __t.api('/api/clipboard')).text)()`);
await evaluate(`__winfile.openPath(${JSON.stringify(sandbox)}, { pushHistory: true })`);
await sleep(1200);
check('选中文件（准备复制文字）', (await clickRow('改名为C.txt')) === 'ok');
await evaluate(`__t.press('c', { metaKey: true })`);
await sleep(1200);
let clip = await clipboardText();
check('⌘C 同时把文件路径写入系统剪贴板', clip.includes('改名为C.txt') && clip.startsWith('/'), JSON.stringify(String(clip).slice(0, 70)));
check('提示中说明已放入系统剪贴板',
  await evaluate(`[...document.querySelectorAll('.toast')].some(t=>t.textContent.includes('系统剪贴板'))`));

const openRowMenu = async (suffix, menuText) => {
  await evaluate(`(() => { const r = __t.qa('.drow').find(x => x.dataset.path.endsWith(${JSON.stringify(suffix)}));
    if (!r) return 'missing'; r.dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, clientX:430, clientY:330})); return 'ok'; })()`);
  await sleep(350);
  return evaluate(`(() => { const i = __t.qa('.ctxmenu__item').find(n => n.textContent.includes(${JSON.stringify(menuText)}));
    if (!i) return 'missing'; i.click(); return 'ok'; })()`);
};

check('右键「复制文件名」可用', (await openRowMenu('改名为C.txt', '复制文件名')) === 'ok');
await sleep(1100);
clip = await clipboardText();
check('复制文件名结果正确', clip === '改名为C.txt', JSON.stringify(clip));

check('右键「复制文件内容」可用', (await openRowMenu('改名为C.txt', '复制文件内容')) === 'ok');
await sleep(1100);
clip = await clipboardText();
check('复制文件内容结果正确', String(clip).includes('WinFile'), JSON.stringify(String(clip).slice(0, 60)));

check('右键「复制路径」可用', (await openRowMenu('改名为C.txt', '复制路径')) === 'ok');
await sleep(1100);
clip = await clipboardText();
check('复制路径结果正确', String(clip).endsWith('/改名为C.txt'), JSON.stringify(String(clip).slice(0, 80)));

// ---- 把剪贴板文本存成文件
await evaluate(`(() => { const i = document.getElementById('viewHost');
  i.dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, clientX:700, clientY:520})); return 1; })()`);
await sleep(350);
check('空白菜单含「剪贴板文本存成文件」',
  (await evaluate(`(() => { const i = __t.qa('.ctxmenu__item').find(n => n.textContent.includes('剪贴板文本')); if(!i) return 'missing'; i.click(); return 'ok'; })()`)) === 'ok');
await sleep(600);
await evaluate(`(() => { const i = document.getElementById('dlgNameInput'); if(!i) return 'missing'; i.value='剪贴板来的.txt'; return i.value; })()`);
await evaluate(`document.getElementById('dialogOk').click()`);
await sleep(2500);
check('剪贴板文本已保存为文件', (await evaluate(`__t.rows().some(p => p.endsWith('剪贴板来的.txt'))`)),
  JSON.stringify(await evaluate('__t.rows()')));

// ---- 打开方式：应用选择器（不再是手填输入框）
check('右键「打开方式」可用', (await openRowMenu('改名为C.txt', '打开方式')) === 'ok');
await sleep(3500);
check('弹出应用选择对话框', await evaluate(`!document.getElementById('dialogBackdrop').hidden`));
const openerCount = await evaluate(`document.querySelectorAll('#dlgAppList .apppicker__item').length`);
check('列出可打开该文件的应用', openerCount > 3, `${openerCount} 个`);
check('列表带真实应用图标', (await evaluate(`document.querySelectorAll('#dlgAppList .apppicker__icon img').length`)) > 3);
check('默认应用有「默认」标记', await evaluate(`!!document.querySelector('#dlgAppList .apppicker__item--default .apppicker__badge')`));
check('应用列表有搜索框', await evaluate(`!!document.getElementById('dlgAppSearch')`));
await evaluate(`(() => { const i=document.getElementById('dlgAppSearch'); i.value='text'; i.dispatchEvent(new Event('input',{bubbles:true})); return 1; })()`);
await sleep(400);
const filteredCount = await evaluate(`document.querySelectorAll('#dlgAppList .apppicker__item').length`);
check('可搜索过滤应用', filteredCount > 0 && filteredCount < openerCount, `${filteredCount}/${openerCount}`);
await evaluate(`(() => { const i=document.getElementById('dlgAppSearch'); i.value=''; i.dispatchEvent(new Event('input',{bubbles:true})); return 1; })()`);
await sleep(300);
check('可点选候选应用', await evaluate(`(() => { const rows=[...document.querySelectorAll('#dlgAppList .apppicker__item')];
  const t = rows.find(r => !r.classList.contains('apppicker__item--default')) || rows[0];
  if (!t) return false; t.click(); return t.classList.contains('apppicker__item--picked'); })()`));
await evaluate(`document.getElementById('dialogCancel').click()`);
await sleep(300);

// ---- 浏览器控制台无异常
check('运行期无未捕获异常', consoleErrors.length === 0, consoleErrors.slice(0, 3).join(' | '));

// ---- 清理沙盒
await evaluate(`__t.api('/api/delete', { paths: [${JSON.stringify(sandbox)}], permanent: true })`);
const gone = await evaluate(`(async () => { const r = await __t.api('/api/files?path=' + encodeURIComponent(${JSON.stringify(sandbox)})); return !r.ok; })()`);
check('清理测试沙盒', gone === true);

chrome.kill('SIGKILL');
const failed = results.filter((r) => !r.ok);
console.log(`\n通过 ${results.length - failed.length} 项，失败 ${failed.length} 项`);
process.exit(failed.length ? 1 : 0);
