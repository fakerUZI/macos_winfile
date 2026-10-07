// 用 Chrome DevTools Protocol 截取界面截图（无需第三方依赖）
// 用法: node tools/capture.mjs <baseUrl> <stageDir> <outDir> [--wait ms]
import { spawn } from 'node:child_process';
import { mkdtemp, copyFile, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const [, , BASE_URL, STAGE_DIR, OUT_DIR, ...rest] = process.argv;
const WAIT = Number(rest.includes('--wait') ? rest[rest.indexOf('--wait') + 1] : 6000);
const SHOTS_DIR = process.env.WF_SHOTS_DIR || path.join(process.cwd(), 'tools', 'shots');

const VIEWS = [
  { view: 'base', name: '01-文件列表', label: '文件列表' },
  { view: 'apps', name: '02-应用程序', label: '应用程序' },
  { view: 'recent', name: '03-最近使用', label: '最近使用' },
  { view: 'category', name: '04-图片分类', label: '图片分类' },
  { view: 'tiles', name: '05-大图标视图', label: '大图标视图' },
  { view: 'complete', name: '06-路径补全', label: '路径补全' },
  { view: 'menu', name: '07-右键菜单', label: '右键菜单' },
  { view: 'opener', name: '08-打开方式面板', label: '打开方式' },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getJson(url) {
  const res = await fetch(url);
  return res.json();
}

class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); }

  static async attach(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, { once: true });
      ws.addEventListener('error', reject, { once: true });
    });
    const cdp = new Cdp(ws);
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && cdp.pending.has(msg.id)) {
        const { resolve, reject } = cdp.pending.get(msg.id);
        cdp.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      }
    });
    return cdp;
  }

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(`${method} 超时`)); }
      }, 120000);
    });
  }

  async eval(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || 'JS 执行异常');
    return result.result?.value;
  }
}

async function main() {
  // 页面地址带上 api= 参数，截图脚本据此访问服务端接口
  const base = BASE_URL.replace(/\/$/, '');
  const apiOrigin = new URL(BASE_URL).origin;
  const pageUrl = `${base}${BASE_URL.includes('?') ? '&' : '?'}api=${encodeURIComponent(apiOrigin)}`;
  const userDataDir = await mkdtemp(path.join(tmpdir(), 'wf-cdp-'));
  const port = 9333;
  const chrome = spawn(CHROME, [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    '--no-first-run',
    '--no-default-browser-check',
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userDataDir}`,
    '--window-size=1560,980',
    'about:blank',
  ], { stdio: 'ignore' });

  const cleanup = () => { try { chrome.kill('SIGKILL'); } catch (err) { /* 忽略 */ } };
  process.on('exit', cleanup);

  // 等待 DevTools 端口就绪
  let version = null;
  for (let i = 0; i < 60; i += 1) {
    try { version = await getJson(`http://127.0.0.1:${port}/json/version`); break; } catch (err) { await sleep(300); }
  }
  if (!version) throw new Error('Chrome DevTools 端口未就绪');

  const target = await getJson(`http://127.0.0.1:${port}/json/new?about:blank`).catch(async () =>
    (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json());
  const cdp = await Cdp.attach(target.webSocketDebuggerUrl);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: 1560, height: 980, deviceScaleFactor: 1, mobile: false,
  });

  await mkdir(OUT_DIR, { recursive: true });

  for (const item of VIEWS) {
    await copyFile(path.join(SHOTS_DIR, `${item.view}.js`), path.join(STAGE_DIR, 'js', 'shot-view.js'));
    await copyFile(path.join(SHOTS_DIR, 'autoshot.js'), path.join(STAGE_DIR, 'js', 'shot-base.js'));
    const url = `${pageUrl}&cb=${Date.now()}${item.view}`;
    await cdp.send('Page.navigate', { url });
    // 等待页面与自动化脚本就绪（轮询 sessionStorage 标记）
    let ready = false;
    for (let i = 0; i < 120; i += 1) {
      await sleep(500);
      try {
        ready = await cdp.eval("document.body && document.body.dataset.shotReady === '1'");
      } catch (err) { ready = false; }
      if (ready) break;
    }
    await sleep(WAIT);
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png' });
    const file = path.join(OUT_DIR, `${item.name}.png`);
    await writeFile(file, Buffer.from(shot.data, 'base64'));
    const title = await cdp.eval('document.title').catch(() => '');
    console.log(`  ${ready ? '✔' : '…'} ${item.name}.png  标题=${title}`);
  }

  console.log('== 截图完成 ==');
  cleanup();
  process.exit(0);
}

main().catch((err) => {
  console.error('截图失败:', err.message);
  process.exit(1);
});
