/* 截图/自动化基础脚本：等待应用就绪，并提供调用服务端 API 的辅助方法。 */
const API = new URLSearchParams(location.search).get('api');
let TOKEN = '';

async function serverApi(path) {
  const res = await fetch(API.replace(/\/$/, '') + path, { headers: { 'X-Winfile-Token': TOKEN } });
  return res.json();
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function waitFor(predicate, timeout = 30000, interval = 120) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try { if (await predicate()) return true; } catch (err) { /* 继续等待 */ }
    await sleep(interval);
  }
  return false;
}

(async function init() {
  // 未提供 api= 参数（例如被误加载进普通页面）时直接退出，避免污染页面
  if (!API) return;
  const boot = await (await fetch(API.replace(/\/$/, '') + '/api/boot')).json();
  TOKEN = boot.token;
  await waitFor(() => window.__winfile && window.__winfile.state.boot);
  await waitFor(() => window.__winfile.state.entries.length > 0 || window.__winfile.state.loading === 0, 25000);
  await sleep(600);
  const view = document.body.dataset.view || '';
  try {
    if (view === 'apps') await window.__winfile.loadApps();
    else if (view === 'recent') await window.__winfile.loadRecent({ days: 30 });
    else if (view === 'category') await window.__winfile.loadCategory('image');
    else if (view === 'tiles') {
      const target = boot.home + '/Documents/winfile-mac/web';
      await window.__winfile.openPath(target, { pushHistory: false });
      window.__winfile.state.layout = 'tiles';
      window.__winfile.renderList();
    } else if (view === 'complete') {
      await window.__winfile.openPath(boot.home + '/Documents', { pushHistory: false });
      window.__winfile.state.selection = new Set();
      window.__winfile.enterEditMode();
      const input = document.getElementById('pathInput');
      input.value = boot.home + '/Doc';
      await window.__winfile.refreshSuggestions(input.value);
      await sleep(700);
    } else if (view === 'opener') {
      const target = boot.home + '/Documents/winfile-mac/README.md';
      await window.__winfile.openPath(boot.home + '/Documents/winfile-mac', { pushHistory: false });
      await sleep(800);
      const entry = window.__winfile.state.entries.find((e) => e.name === 'README.md')
        || window.__winfile.state.entries.find((e) => e.kind === 'file');
      if (entry) {
        window.__winfile.state.selection = new Set([entry.path]);
        const row = document.querySelector(`[data-path="${CSS.escape(entry.path)}"]`);
        row?.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 460, clientY: 300 }));
        await sleep(400);
        [...document.querySelectorAll('.ctxmenu__item')].find((n) => n.textContent.includes('打开方式'))?.click();
        await sleep(3000);
      }
    } else if (view === 'menu') {
      const entry = window.__winfile.state.entries.find((item) => item.kind === 'directory') || window.__winfile.state.entries[0];
      if (entry) {
        window.__winfile.state.selection = new Set([entry.path]);
        window.__winfile.showEntryMenu({ clientX: 620, clientY: 300 }, entry);
        await sleep(300);
      }
    }
  } catch (err) {
    document.title = 'SHOT-ERROR: ' + err.message;
  }
  document.body.dataset.shotReady = '1';
})();
