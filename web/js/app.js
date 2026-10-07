/* ============================================================
 * WinFile — Windows 资源管理器风格的 macOS 文件管理器
 * 纯前端（ES Module，无构建步骤），通过 /api/* 与本地 Python 服务通信
 * ============================================================ */

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
};

const state = {
  token: '',
  boot: null,
  view: 'files',            // files | apps | recent | category | search
  category: null,
  path: '',
  entries: [],
  selection: new Set(),
  anchorIndex: null,
  sort: 'name',
  order: 'asc',
  layout: 'details',        // details | tiles
  showHidden: false,
  filter: '',
  history: [],
  historyIndex: -1,
  clipboard: null,          // { mode: 'copy'|'cut', paths: [], names: [] }
  tabs: [],
  activeTab: 0,
  apps: [],
  categoryCounts: {},
  categories: [],
  loading: 0,
  suggestions: [],
  suggestIndex: -1,
  detailOpen: true,
  lastClickedPath: null,
  sortMenu: null,
};

const ICON = {
  folder: '📁', image: '🖼️', video: '🎬', audio: '🎵', document: '📄',
  spreadsheet: '📊', presentation: '📽️', pdf: '📕', archive: '🗜️',
  code: '🧩', app: '🚀', font: '🔤', disk: '💿', executable: '⚙️',
  database: '🗄️', ebook: '📚', design: '🎨', other: '📦',
};

/* 矢量图标：emoji 字体常把 📁/📄 渲染成灰色字形，
   这里用内联 SVG 还原 Windows 风格的黄色文件夹与白色文档。 */
const SVG_FOLDER = (size = 18) => `<svg viewBox="0 0 20 16" width="${size}" height="${Math.round(size * 0.8)}" aria-hidden="true">`
  + '<defs><linearGradient id="wff" x1="0" y1="0" x2="0" y2="1">'
  + '<stop offset="0" stop-color="#ffd777"/><stop offset="1" stop-color="#f5b73f"/></linearGradient></defs>'
  + '<path d="M1 2.4C1 1.6 1.6 1 2.4 1h4.1c.5 0 .9.2 1.2.6l1 1.2h8.9c.8 0 1.4.6 1.4 1.4v9.4c0 .8-.6 1.4-1.4 1.4H2.4'
  + 'C1.6 15 1 14.4 1 13.6V2.4z" fill="url(#wff)" stroke="#d99b1c" stroke-width=".7"/></svg>';

const SVG_FILE = (size = 18) => `<svg viewBox="0 0 16 18" width="${Math.round(size * 0.89)}" height="${size}" aria-hidden="true">`
  + '<path d="M2 1.4C2 .6 2.6 0 3.4 0h6.2L14 4.3v12.3c0 .8-.6 1.4-1.4 1.4H3.4C2.6 18 2 17.4 2 16.6V1.4z"'
  + ' fill="#ffffff" stroke="#9aa5b1" stroke-width=".8"/>'
  + '<path d="M9.4 0L14 4.4H9.9c-.3 0-.5-.2-.5-.5V0z" fill="#dde3ea"/>'
  + '<g stroke="#b6c0cb" stroke-width=".7"><path d="M4 8h7M4 10.5h7M4 13h4.5"/></g></svg>';

function iconSvgFor(entry, size = 18) {
  if (entry.icon_url) {
    return `<img src="${escapeAttr(withToken(entry.icon_url))}" alt="" width="${size}" height="${size}">`;
  }
  if (entry.kind === 'directory') return SVG_FOLDER(size);
  return null;
}

/* ============================================================ API */

async function api(path, { method = 'GET', body = null, params = {} } = {}) {
  const url = new URL(path, location.origin);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, value);
  }
  const options = { method, headers: { 'X-Winfile-Token': state.token } };
  if (body) {
    options.headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(body);
  }
  const response = await fetch(url, options);
  let data = null;
  try { data = await response.json(); } catch (err) { data = { ok: false, error: `响应解析失败 (${response.status})` }; }
  if (!response.ok && data && !data.error) data.error = `HTTP ${response.status}`;
  return data;
}

function withToken(path) {
  const url = new URL(path, location.origin);
  url.searchParams.set('token', state.token);
  return url.toString();
}

/* ============================================================ 小工具 */

function fmtSize(bytes) {
  if (bytes === null || bytes === undefined) return '';
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
}

function fmtTime(ts) {
  if (!ts) return '';
  const date = new Date(ts * 1000);
  const now = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const hm = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  if (date.toDateString() === now.toDateString()) return `今天 ${hm}`;
  const yesterday = new Date(now.getTime() - 86400000);
  if (date.toDateString() === yesterday.toDateString()) return `昨天 ${hm}`;
  if (date.getFullYear() === now.getFullYear()) return `${pad(date.getMonth() + 1)}/${pad(date.getDate())} ${hm}`;
  return `${date.getFullYear()}/${pad(date.getMonth() + 1)}/${pad(date.getDate())} ${hm}`;
}

function fmtFull(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function entryLabel(entry) {
  return entry.display_name || entry.name;
}

function isContainer(entry) {
  return entry.kind === 'directory' || entry.kind === 'bundle';
}

const TEXT_CATEGORIES = new Set(['document', 'code', 'spreadsheet']);
function isTextEntry(entry) {
  if (isContainer(entry)) return false;
  return TEXT_CATEGORIES.has(entry.category) && (entry.size || 0) < 2 * 1024 * 1024;
}

function entryIcon(entry, size = 18) {
  const svg = iconSvgFor(entry, size);
  if (svg) return svg;
  return ICON[entry.category] || entry.icon || '📦';
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}
const escapeAttr = escapeHtml;

function toast(message, kind = '') {
  const node = el('div', `toast${kind ? ` toast--${kind}` : ''}`, message);
  $('toasts').appendChild(node);
  setTimeout(() => { node.style.opacity = '0'; node.style.transition = 'opacity .3s'; }, 3200);
  setTimeout(() => node.remove(), 3600);
}

function busy(on, text = '正在读取…') {
  state.loading += on ? 1 : -1;
  if (state.loading < 0) state.loading = 0;
  $('loadingText').textContent = text;
  $('loading').hidden = state.loading === 0;
}

function debounce(fn, wait) {
  let timer = null;
  return (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), wait); };
}

function joinPath(dir, name) {
  return dir.endsWith('/') ? dir + name : `${dir}/${name}`;
}

function parentPath(path) {
  if (!path || path === '/') return null;
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  if (idx <= 0) return '/';
  return trimmed.slice(0, idx);
}

function tildePath(path) {
  const home = state.boot?.home || '';
  if (!home) return path;
  if (path === home) return '~';
  if (path.startsWith(home + '/')) return '~' + path.slice(home.length);
  return path;
}

/* ============================================================ 启动 */

async function boot() {
  busy(true, '正在启动…');
  try {
    const res = await fetch('/api/boot');
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || '启动失败');
    state.boot = data;
    state.token = data.token;
    state.categories = data.categories || [];
    state.path = data.home;
    $('windowTitle').textContent = `WinFile — ${data.hostname || 'macOS'}`;
    renderNav();
    renderVolumes(data.volumes || []);
    state.tabs = [{ view: 'files', path: data.home, category: null, label: '个人文件夹', icon: '🏠' }];
    state.activeTab = 0;
    renderTabs();
    await openPath(data.home, { pushHistory: true });
    refreshCategoryCounts();
    refreshApps();
  } catch (err) {
    toast(`启动失败：${err.message}`, 'error');
    $('emptyTitle').textContent = '无法连接到本地服务';
    $('emptyHint').textContent = String(err.message);
    $('emptyState').hidden = false;
  } finally {
    busy(false);
  }
}

async function refreshCategoryCounts(force = false) {
  try {
    const res = await api('/api/categories', { params: { refresh: force ? 1 : 0 } });
    if (res.ok) {
      state.categoryCounts = res.counts || {};
      state.categories = res.categories || state.categories;
      renderNav();
      $('statusSource').textContent = res.source === 'spotlight' ? '索引：Spotlight' : '索引：本地扫描';
    }
  } catch (err) { /* 忽略 */ }
}

async function refreshApps() {
  try {
    const res = await api('/api/apps');
    if (res.ok) state.apps = res.apps || [];
  } catch (err) { /* 忽略 */ }
}

/* ============================================================ 导航窗格 */

function renderNav() {
  const host = $('navTree');
  host.innerHTML = '';
  const places = state.boot?.places?.groups || [];
  for (const group of places) {
    const section = el('div', 'navsection');
    section.appendChild(el('div', 'navsection__head', group.title));
    const list = el('div', 'navlist');
    for (const item of group.items) {
      list.appendChild(navItem({
        label: item.name, icon: item.icon, path: item.path, kind: 'place',
      }));
    }
    section.appendChild(list);
    host.appendChild(section);
  }

  const special = el('div', 'navsection');
  special.appendChild(el('div', 'navsection__head', '快捷视图'));
  const specialList = el('div', 'navlist');
  specialList.appendChild(navItem({ label: '应用程序', icon: '🚀', view: 'apps' }));
  specialList.appendChild(navItem({ label: '最近使用', icon: '🕘', view: 'recent' }));
  special.appendChild(specialList);
  host.appendChild(special);

  const catHost = $('categoryList');
  catHost.innerHTML = '';
  const skip = new Set(['folder', 'other']);
  for (const category of state.categories) {
    if (skip.has(category.id)) continue;
    const count = state.categoryCounts[category.id];
    const node = navItem({
      label: category.name, icon: category.icon, view: 'category', category: category.id,
      dot: category.color, badge: count ? String(count) : '',
    });
    catHost.appendChild(node);
  }

  // 导航重建会丢弃之前的选中样式，这里重新应用一次
  markActiveNav();
}

function navItem({ label, icon, path, view = 'files', category = null, dot = null, badge = '', depth = 0 }) {
  const node = el('div', 'navitem');
  node.dataset.label = label;
  if (path) node.dataset.path = path;
  if (category) node.dataset.category = category;
  node.dataset.view = view;
  node.style.paddingLeft = `${8 + depth * 12}px`;

  const twisty = el('span', 'navitem__twisty', path && !(view === 'files' && category === null) ? '' : '');
  if (path && view === 'files') {
    twisty.textContent = '▸';
    twisty.addEventListener('click', (event) => { event.stopPropagation(); toggleTree(node, path); });
  } else {
    twisty.style.visibility = 'hidden';
  }
  node.appendChild(twisty);
  node.appendChild(el('span', 'navitem__icon', icon || '📁'));
  node.appendChild(el('span', 'navitem__label', label));
  if (badge) node.appendChild(el('span', 'navitem__badge', badge));
  if (dot) {
    const dotNode = el('span', 'navitem__dot');
    dotNode.style.background = dot;
    node.appendChild(dotNode);
  }

  node.addEventListener('click', () => {
    if (view === 'files' && path) return openPath(path, { pushHistory: true });
    if (view === 'apps') return loadApps();
    if (view === 'recent') return loadRecent();
    if (view === 'category') return loadCategory(category);
  });
  if (path) {
    node.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      showContextMenu(event, [
        { label: '在新标签页打开', icon: '🗂️', action: () => addTab({ view: 'files', path, label, icon }) },
        { label: '在访达中显示', icon: '🔍', action: () => api('/api/reveal', { method: 'POST', body: { paths: [path] } }) },
        { label: '在此打开终端', icon: '⌨️', action: () => api('/api/reveal', { method: 'POST', body: { paths: [path], terminal: true } }) },
        { label: '复制路径', icon: '⧉', action: () => copyText(path) },
      ]);
    });
  }
  return node;
}

async function toggleTree(node, path) {
  const existing = node.nextElementSibling;
  if (existing && existing.classList.contains('navchildren')) {
    existing.remove();
    node.querySelector('.navitem__twisty').textContent = '▸';
    return;
  }
  node.querySelector('.navitem__twisty').textContent = '▾';
  const wrap = el('div', 'navchildren');
  wrap.appendChild(el('div', 'navitem', '载入中…'));
  node.after(wrap);
  const res = await api('/api/tree', { params: { path } });
  wrap.innerHTML = '';
  if (!res.ok || !res.children.length) {
    wrap.appendChild(el('div', 'navitem', res.error || '（无子文件夹）'));
    return;
  }
  for (const child of res.children) {
    wrap.appendChild(navItem({ label: child.name, icon: child.is_bundle ? '🚀' : '📁', path: child.path, depth: 1 }));
  }
}

function renderVolumes(volumes) {
  const host = $('volumeList');
  host.innerHTML = '';
  for (const volume of volumes) {
    const pct = volume.percent ? `${volume.percent}%` : '';
    const node = navItem({
      label: volume.name, icon: volume.icon, path: volume.path,
      badge: volume.free_h ? `空闲 ${volume.free_h}` : '',
    });
    node.title = `${volume.path}\n总容量 ${volume.total_h || '?'} · 已用 ${volume.used_h || '?'} (${pct})`;
    host.appendChild(node);
  }
}

function markActiveNav() {
  document.querySelectorAll('.navitem').forEach((node) => node.classList.remove('navitem--active'));
  let selector = null;
  if (state.view === 'apps') selector = '.navitem[data-view="apps"]';
  else if (state.view === 'recent') selector = '.navitem[data-view="recent"]';
  else if (state.view === 'category') selector = `.navitem[data-category="${state.category}"]`;
  else selector = `.navitem[data-path="${CSS.escape(state.path)}"][data-view="files"]`;
  const node = document.querySelector(selector || '');
  if (node) node.classList.add('navitem--active');
}

/* ============================================================ 标签页 */

function renderTabs() {
  const host = $('tabStrip');
  host.innerHTML = '';
  state.tabs.forEach((tab, index) => {
    const node = el('div', `tab${index === state.activeTab ? ' tab--active' : ''}`);
    node.appendChild(el('span', 'tab__icon', tab.icon || '📁'));
    node.appendChild(el('span', 'tab__label', tab.label || '文件夹'));
    const close = el('button', 'tab__close', '✕');
    close.addEventListener('click', (event) => { event.stopPropagation(); closeTab(index); });
    node.appendChild(close);
    node.addEventListener('click', () => activateTab(index));
    node.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      showContextMenu(event, [
        { label: '复制标签页', icon: '⧉', action: () => addTab({ ...tab }) },
        { label: '关闭标签页', icon: '✕', action: () => closeTab(index) },
        { label: '关闭其它标签页', icon: '🧹', action: () => { state.tabs = [state.tabs[index]]; state.activeTab = 0; activateTab(0); } },
      ]);
    });
    host.appendChild(node);
  });
  const add = el('div', 'tab tab--add', '＋ 新标签页');
  add.addEventListener('click', () => addTab({ view: 'files', path: state.boot.home, label: '个人文件夹', icon: '🏠' }));
  host.appendChild(add);
}

function addTab(tab) {
  state.tabs.push(tab);
  state.activeTab = state.tabs.length - 1;
  renderTabs();
  applyTab(tab);
}

function closeTab(index) {
  if (state.tabs.length <= 1) return;
  state.tabs.splice(index, 1);
  state.activeTab = Math.max(0, Math.min(state.activeTab, state.tabs.length - 1));
  renderTabs();
  applyTab(state.tabs[state.activeTab]);
}

function activateTab(index) {
  state.activeTab = index;
  renderTabs();
  applyTab(state.tabs[index]);
}

function applyTab(tab) {
  if (tab.view === 'files') return openPath(tab.path, { pushHistory: false, keepTab: true });
  if (tab.view === 'apps') return loadApps();
  if (tab.view === 'recent') return loadRecent();
  if (tab.view === 'category') return loadCategory(tab.category);
}

function updateCurrentTab() {
  const tab = state.tabs[state.activeTab];
  if (!tab) return;
  tab.view = state.view;
  tab.path = state.path;
  tab.category = state.category;
  tab.label = currentTitle();
  tab.icon = currentIcon();
  renderTabs();
}

function currentTitle() {
  if (state.view === 'apps') return '应用程序';
  if (state.view === 'recent') return '最近使用';
  if (state.view === 'category') {
    const found = state.categories.find((c) => c.id === state.category);
    return found ? found.name : '分类';
  }
  if (state.path === '/') return 'Macintosh HD';
  return state.path.split('/').filter(Boolean).pop() || state.path;
}

function currentIcon() {
  if (state.view === 'apps') return '🚀';
  if (state.view === 'recent') return '🕘';
  if (state.view === 'category') {
    const found = state.categories.find((c) => c.id === state.category);
    return found ? found.icon : '📂';
  }
  return state.path === '/' ? '💽' : '📁';
}

/* ============================================================ 数据加载 */

async function openPath(path, { pushHistory = true, keepTab = false } = {}) {
  if (!path) return;
  state.view = 'files';
  busy(true, '正在读取文件夹…');
  try {
    const res = await api('/api/files', {
      params: {
        path,
        sort: state.sort,
        order: state.order,
        hidden: state.showHidden ? 1 : 0,
      },
    });
    state.path = res.path || path;
    state.entries = res.entries || [];
    state.selection.clear();
    state.anchorIndex = null;
    state.lastClickedPath = null;
    if (res.error && !res.permission_denied) toast(res.error, 'error');
    if (res.permission_denied) {
      $('emptyTitle').textContent = '没有访问权限';
      $('emptyHint').textContent = res.error;
      $('emptyState').hidden = false;
    }
    updateVolumeStatus(res.volume);
    $('statusCount').textContent = res.counts
      ? `${res.counts.total} 个项目（${res.counts.dirs} 个文件夹，${res.counts.files} 个文件）`
      : '就绪';
    state.detailEntry = null;
    if (pushHistory) pushHistoryState({ view: 'files', path: state.path, category: null });
    if (!keepTab) updateCurrentTab();
    renderAll();
  } catch (err) {
    toast(`打开失败：${err.message}`, 'error');
  } finally {
    busy(false);
  }
}

async function loadApps({ refresh = false } = {}) {
  state.view = 'apps';
  state.category = null;
  busy(true, '正在扫描应用程序…');
  try {
    const res = await api('/api/apps', { params: { refresh: refresh ? 1 : 0 } });
    state.entries = res.apps || [];
    state.apps = res.apps || [];
    state.selection.clear();
    $('statusCount').textContent = `共 ${res.total} 个应用程序`;
    $('embedNote') && $('embedNote').remove();
    pushHistoryState({ view: 'apps', path: '', category: null });
    updateCurrentTab();
    renderAll();
  } finally { busy(false); }
}

async function loadRecent({ days = 30, refresh = false } = {}) {
  state.view = 'recent';
  state.category = null;
  busy(true, '正在读取最近使用…');
  try {
    const res = await api('/api/recent', { params: { days, limit: 800, refresh: refresh ? 1 : 0 } });
    state.entries = res.entries || [];
    state.selection.clear();
    state.recentMeta = res;
    $('statusCount').textContent = `最近 ${days} 天：${res.total} 个文件（今天 ${res.counts?.today || 0}）`;
    $('statusSource').textContent = res.source === 'spotlight'
      ? '来源：Spotlight 索引'
      : (res.source === 'spotlight+walk' ? '来源：Spotlight 索引 + 本地扫描' : '来源：本地扫描');
    pushHistoryState({ view: 'recent', path: '', category: null });
    updateCurrentTab();
    renderAll();
  } finally { busy(false); }
}

async function loadCategory(category, { refresh = false } = {}) {
  state.view = 'category';
  state.category = category;
  busy(true, '正在按类型归类…');
  try {
    const res = await api('/api/category', { params: { id: category, limit: 1200, refresh: refresh ? 1 : 0 } });
    state.entries = res.entries || [];
    state.selection.clear();
    $('statusCount').textContent = `${res.category_name || '分类'}：${res.total} 个文件`;
    $('statusSource').textContent = res.source === 'spotlight' ? '来源：Spotlight 索引' : '来源：本地扫描';
    pushHistoryState({ view: 'category', path: '', category });
    updateCurrentTab();
    renderAll();
  } finally { busy(false); }
}

function pushHistoryState(item) {
  const last = state.history[state.historyIndex];
  const same = last && last.view === item.view && last.path === item.path && last.category === item.category;
  if (same) return;
  state.history = state.history.slice(0, state.historyIndex + 1);
  state.history.push(item);
  if (state.history.length > 100) state.history.shift();
  state.historyIndex = state.history.length - 1;
  updateNavButtons();
}

function goHistory(delta) {
  const index = state.historyIndex + delta;
  if (index < 0 || index >= state.history.length) return;
  state.historyIndex = index;
  const item = state.history[index];
  updateNavButtons();
  if (item.view === 'files') return openPath(item.path, { pushHistory: false });
  if (item.view === 'apps') return loadApps();
  if (item.view === 'recent') return loadRecent();
  if (item.view === 'category') return loadCategory(item.category);
}

function updateNavButtons() {
  $('btnBack').disabled = state.historyIndex <= 0;
  $('btnForward').disabled = state.historyIndex >= state.history.length - 1;
  $('btnUp').disabled = state.view !== 'files' || !parentPath(state.path);
}

function updateVolumeStatus(volume) {
  if (!volume || !volume.total) { $('statusDisk').textContent = ''; return; }
  $('statusDisk').textContent = `${volume.free_h} 可用，共 ${volume.total_h}`;
}

/* ============================================================ 渲染 */

function visibleEntries() {
  if (!state.filter) return state.entries;
  const needle = state.filter.toLowerCase();
  return state.entries.filter((entry) => entry.name.toLowerCase().includes(needle));
}

function renderAll() {
  renderCrumbs();
  markActiveNav();
  renderList();
  renderDetails();
  updateCommandState();
  updateNavButtons();
}

function renderCrumbs() {
  const host = $('crumbs');
  host.innerHTML = '';
  if (state.view !== 'files') {
    host.appendChild(el('span', 'crumb crumb--last', currentTitle()));
    $('addressIcon').textContent = currentIcon();
    return;
  }
  const path = state.path;
  $('addressIcon').textContent = path === '/' ? '💽' : '📁';
  const parts = path.split('/').filter(Boolean);
  const root = el('span', 'crumb', path === '/' ? 'Macintosh HD' : 'Macintosh HD');
  root.addEventListener('click', () => openPath('/'));
  host.appendChild(root);
  let accumulated = '';
  parts.forEach((part, index) => {
    accumulated += '/' + part;
    host.appendChild(el('span', 'crumb__sep', '›'));
    const node = el('span', `crumb${index === parts.length - 1 ? ' crumb--last' : ''}`, part);
    const target = accumulated;
    node.addEventListener('click', () => openPath(target));
    if (index < parts.length - 1) {
      node.addEventListener('contextmenu', (event) => {
        event.preventDefault();
        showContextMenu(event, [
          { label: '在新标签页打开', icon: '🗂️', action: () => addTab({ view: 'files', path: target, label: part, icon: '📁' }) },
          { label: '复制路径', icon: '⧉', action: () => copyText(target) },
        ]);
      });
    }
    host.appendChild(node);
  });
}

function columnDefs() {
  if (state.view === 'apps') {
    return [
      { key: 'name', label: '名称', cls: 'col-name' },
      { key: 'location', label: '位置', cls: 'col-type' },
      { key: 'version', label: '版本', cls: 'col-size' },
    ];
  }
  if (state.view === 'recent') {
    return [
      { key: 'name', label: '名称', cls: 'col-name' },
      { key: 'path', label: '所在位置', cls: 'col-type' },
      { key: 'modified', label: '修改时间', cls: 'col-mtime' },
      { key: 'size', label: '大小', cls: 'col-size' },
    ];
  }
  if (state.view === 'category') {
    return [
      { key: 'name', label: '名称', cls: 'col-name' },
      { key: 'path', label: '所在位置', cls: 'col-type' },
      { key: 'modified', label: '修改时间', cls: 'col-mtime' },
      { key: 'size', label: '大小', cls: 'col-size' },
    ];
  }
  return [
    { key: 'name', label: '名称', cls: 'col-name' },
    { key: 'modified', label: '修改日期', cls: 'col-mtime' },
    { key: 'type', label: '类型', cls: 'col-type' },
    { key: 'size', label: '大小', cls: 'col-size' },
  ];
}

function cellValue(entry, key) {
  switch (key) {
    case 'name': return '';
    case 'modified': return fmtTime(entry.modified);
    case 'type': return entry.type || '';
    case 'size': return entry.size_h || '';
    case 'path': {
      const dir = parentPath(entry.path) || '';
      return tildePath(dir);
    }
    case 'location': return tildePath(entry.location || parentPath(entry.path) || '');
    case 'version': return entry.app?.version || '';
    default: return '';
  }
}

function renderList() {
  const entries = visibleEntries();
  const host = $('listView');
  const tiles = $('tileView');
  const empty = $('emptyState');

  if (!entries.length) {
    host.innerHTML = '';
    tiles.innerHTML = '';
    tiles.hidden = true;
    host.hidden = false;
    if (!empty.dataset.locked) {
      $('emptyTitle').textContent = state.filter ? '没有匹配的项目' : '此文件夹为空';
      $('emptyHint').textContent = state.filter
        ? `未找到包含“${state.filter}”的项目`
        : '可以按 Ctrl+Shift+N 新建文件夹，或从其它位置拖入文件。';
    }
    empty.hidden = false;
    return;
  }
  empty.hidden = true;
  empty.dataset.locked = '';

  if (state.layout === 'tiles') {
    host.hidden = true;
    tiles.hidden = false;
    renderTiles(entries, tiles);
  } else {
    tiles.hidden = true;
    host.hidden = false;
    renderTable(entries, host);
  }
}

function renderTable(entries, host) {
  const columns = columnDefs();
  const table = el('table', 'dtable');
  const thead = el('thead');
  const headRow = el('tr');
  for (const column of columns) {
    const th = el('th', column.cls);
    const inner = el('div', 'th');
    inner.appendChild(el('span', null, column.label));
    if (state.sort === column.key) inner.appendChild(el('span', 'sortmark', state.order === 'asc' ? '▲' : '▼'));
    th.appendChild(inner);
    th.addEventListener('click', () => {
      if (state.sort === column.key) state.order = state.order === 'asc' ? 'desc' : 'asc';
      else { state.sort = column.key; state.order = 'asc'; }
      if (['name', 'modified', 'type', 'size'].includes(state.sort) && state.view === 'files') {
        openPath(state.path, { pushHistory: false });
      } else {
        state.entries.sort(compareEntries);
        renderAll();
      }
    });
    headRow.appendChild(th);
  }
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = el('tbody');
  entries.forEach((entry) => {
    const row = el('tr', 'drow');
    row.dataset.path = entry.path;
    if (state.selection.has(entry.path)) row.classList.add('drow--selected');
    if (state.clipboard?.mode === 'cut' && state.clipboard.paths.includes(entry.path)) row.classList.add('drow--cut');
    if (!entry.exists && entry.exists !== undefined) row.classList.add('drow--missing');

    columns.forEach((column) => {
      const td = el('td', column.cls);
      if (column.key === 'name') {
        const wrap = el('div', 'drow__name');
        const isImg = entry.category === 'image' && entry.size && entry.size < 4 * 1024 * 1024;
        const iconNode = el('span', 'drow__icon');
        if (isImg) {
          const img = el('img');
          img.src = withToken(`/api/thumb?path=${encodeURIComponent(entry.path)}&size=48`);
          img.loading = 'lazy';
          img.alt = '';
          iconNode.appendChild(img);
        } else {
          iconNode.innerHTML = entryIcon(entry);
        }
        wrap.appendChild(iconNode);
        const label = el('span', 'drow__label');
        label.innerHTML = escapeHtml(entryLabel(entry));
        if (entry.is_bundle && entry.kind === 'bundle' && entry.category !== 'app') label.classList.add('drow__label--bundle');
        wrap.appendChild(label);
        if (entry.app?.bundle_id && state.view === 'apps') wrap.appendChild(el('span', 'drow__sub', entry.app.bundle_id));
        td.appendChild(wrap);
      } else {
        const value = cellValue(entry, column.key);
        td.textContent = value;
        if (column.key === 'size') td.classList.add('cell-num');
        if (column.key !== 'size') td.classList.add('cell-dim');
      }
      row.appendChild(td);
    });

    bindRowEvents(row, entry, entries);
    tbody.appendChild(row);
  });
  table.appendChild(tbody);
  host.innerHTML = '';
  host.appendChild(table);
  $('statusSel').textContent = state.selection.size ? `已选择 ${state.selection.size} 项` : '';
}

function compareEntries(a, b) {
  const dir = state.order === 'desc' ? -1 : 1;
  const key = state.sort;
  let left;
  let right;
  if (key === 'size') { left = a.size ?? -1; right = b.size ?? -1; }
  else if (key === 'modified') { left = a.modified || 0; right = b.modified || 0; }
  else if (key === 'path') { left = parentPath(a.path) || ''; right = parentPath(b.path) || ''; }
  else if (key === 'type') { left = a.type || ''; right = b.type || ''; }
  else { left = (a.name || '').toLowerCase(); right = (b.name || '').toLowerCase(); }
  if (typeof left === 'string') return left.localeCompare(right, 'zh-Hans-CN') * dir;
  return (left - right) * dir;
}

function renderTiles(entries, host) {
  host.innerHTML = '';
  const frag = document.createDocumentFragment();
  entries.forEach((entry) => {
    const tile = el('div', `tile${state.selection.has(entry.path) ? ' tile--selected' : ''}`);
    tile.dataset.path = entry.path;
    const glyph = el('div', 'tile__glyph');
    if (entry.icon_url) {
      const img = el('img');
      img.src = withToken(entry.icon_url);
      img.alt = '';
      glyph.appendChild(img);
    } else if (entry.category === 'image' && entry.size && entry.size < 8 * 1024 * 1024) {
      const img = el('img', 'tile__thumb');
      img.src = withToken(`/api/thumb?path=${encodeURIComponent(entry.path)}&size=128`);
      img.loading = 'lazy';
      img.alt = '';
      glyph.appendChild(img);
    } else {
      glyph.innerHTML = entry.kind === 'directory' ? SVG_FOLDER(46) : entryIcon(entry, 44);
    }
    tile.appendChild(glyph);
    tile.appendChild(el('div', 'tile__label', entryLabel(entry)));
    tile.appendChild(el('div', 'tile__meta', isContainer(entry) ? (entry.type || '文件夹') : (entry.size_h || entry.type || '')));
    bindRowEvents(tile, entry, entries, true);
    frag.appendChild(tile);
  });
  host.appendChild(frag);
  $('statusSel').textContent = state.selection.size ? `已选择 ${state.selection.size} 项` : '';
}

function bindRowEvents(node, entry, entries, tileMode = false) {
  node.addEventListener('click', (event) => {
    const index = entries.indexOf(entry);
    if (event.metaKey || event.ctrlKey) {
      if (state.selection.has(entry.path)) state.selection.delete(entry.path);
      else state.selection.add(entry.path);
      state.anchorIndex = index;
    } else if (event.shiftKey && state.anchorIndex !== null) {
      const [from, to] = [Math.min(state.anchorIndex, index), Math.max(state.anchorIndex, index)];
      state.selection.clear();
      for (let i = from; i <= to; i += 1) state.selection.add(entries[i].path);
    } else {
      state.selection.clear();
      state.selection.add(entry.path);
      state.anchorIndex = index;
    }
    state.lastClickedPath = entry.path;
    state.detailEntry = entry;
    syncSelection();
  });

  node.addEventListener('dblclick', () => activateEntry(entry));

  node.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    if (!state.selection.has(entry.path)) {
      state.selection.clear();
      state.selection.add(entry.path);
      state.detailEntry = entry;
      syncSelection();
    }
    showEntryMenu(event, entry);
  });

  node.setAttribute('draggable', 'true');
  node.addEventListener('dragstart', (event) => {
    if (!state.selection.has(entry.path)) {
      state.selection.clear();
      state.selection.add(entry.path);
      syncSelection();
    }
    const payload = { paths: [...state.selection] };
    event.dataTransfer.setData('application/x-winfile', JSON.stringify(payload));
    event.dataTransfer.setData('text/plain', payload.paths.join('\n'));
    event.dataTransfer.effectAllowed = 'copyMove';
  });
  if (isContainer(entry)) {
    node.addEventListener('dragover', (event) => {
      const types = event.dataTransfer.types;
      if (types.includes('application/x-winfile') || types.includes('Files')) {
        event.preventDefault();
        event.dataTransfer.dropEffect = event.altKey ? 'copy' : 'move';
        node.classList.add('drop-target');
      }
    });
    node.addEventListener('dragleave', () => node.classList.remove('drop-target'));
    node.addEventListener('drop', async (event) => {
      node.classList.remove('drop-target');
      const raw = event.dataTransfer.getData('application/x-winfile');
      if (!raw) return;
      event.preventDefault();
      event.stopPropagation();
      const payload = JSON.parse(raw);
      const paths = payload.paths.filter((p) => p !== entry.path);
      if (!paths.length) return;
      const mode = event.altKey ? 'copy' : 'move';
      const res = await api('/api/transfer', { method: 'POST', body: { paths, dest: entry.path, mode } });
      if (res.ok) toast(`已${mode === 'copy' ? '复制' : '移动'} ${paths.length} 项到 ${entry.name}`, 'ok');
      else toast(res.error || '操作失败', 'error');
      reloadCurrent();
    });
  }
}

function syncSelection() {
  document.querySelectorAll('.drow').forEach((row) => {
    row.classList.toggle('drow--selected', state.selection.has(row.dataset.path));
  });
  document.querySelectorAll('.tile').forEach((tile) => {
    tile.classList.toggle('tile--selected', state.selection.has(tile.dataset.path));
  });
  $('statusSel').textContent = state.selection.size ? `已选择 ${state.selection.size} 项` : '';
  const count = state.selection.size;
  const single = count === 1;
  $('btnCut').disabled = !count;
  $('btnCopy').disabled = !count;
  $('btnCopyPath').disabled = !count;
  $('btnRename').disabled = !single;
  $('btnDelete').disabled = !count;
  $('btnOpen').disabled = !count;
  $('btnReveal').disabled = !count;
  renderDetails();
}

/* ============================================================ 详细信息窗格 */

function selectedEntries() {
  return state.entries.filter((entry) => state.selection.has(entry.path));
}

async function renderDetails() {
  const body = $('detailBody');
  body.innerHTML = '';
  const selected = selectedEntries();
  if (selected.length === 1) return renderDetailSingle(body, selected[0]);
  if (selected.length > 1) {
    const totalSize = selected.reduce((sum, e) => sum + (e.size || 0), 0);
    $('detailHead').textContent = `${selected.length} 个项目`;
    body.appendChild(el('div', 'dp__type', '已选择的项目'));
    const rows = el('div', 'dp__rows');
    rows.appendChild(el('div', 'dp__k', '名称'));
    rows.appendChild(el('div', 'dp__v', selected.slice(0, 30).map((e) => entryLabel(e)).join('、') + (selected.length > 30 ? ' …' : '')));
    rows.appendChild(el('div', 'dp__k', '总大小'));
    rows.appendChild(el('div', 'dp__v', fmtSize(totalSize)));
    body.appendChild(rows);
    const actions = el('div', 'dp__actions');
    actions.appendChild(button('全部打开', () => openSelection()));
    actions.appendChild(button('复制', () => setClipboard('copy')));
    actions.appendChild(button('删除', () => deleteSelection()));
    body.appendChild(actions);
    return;
  }

  // 无选择：显示当前视图信息
  if (state.view === 'files') {
    $('detailHead').textContent = '当前文件夹';
    body.appendChild(el('div', 'dp__hero', ''));
    const folderGlyph = el('div', 'dp__glyph');
    folderGlyph.innerHTML = state.path === '/' ? '💽' : SVG_FOLDER(60);
    body.querySelector('.dp__hero').appendChild(folderGlyph);
    body.querySelector('.dp__hero').appendChild(el('div', 'dp__name', currentTitle()));
    body.querySelector('.dp__hero').appendChild(el('div', 'dp__type', tildePath(state.path)));
    const rows = el('div', 'dp__rows');
    const folderCount = state.entries.filter((e) => isContainer(e)).length;
    rows.appendChild(el('div', 'dp__k', '项目数'));
    rows.appendChild(el('div', 'dp__v', String(state.entries.length)));
    rows.appendChild(el('div', 'dp__k', '文件夹'));
    rows.appendChild(el('div', 'dp__v', String(folderCount)));
    body.appendChild(rows);
    const actions = el('div', 'dp__actions');
    actions.appendChild(button('在终端打开', () => api('/api/reveal', { method: 'POST', body: { paths: [state.path], terminal: true } })));
    actions.appendChild(button('新标签页', () => addTab({ view: 'files', path: state.path, label: currentTitle(), icon: '📁' })));
    body.appendChild(actions);
    return;
  }
  $('detailHead').textContent = currentTitle();
  body.appendChild(el('div', 'dp__type', `共 ${state.entries.length} 项`));
}

function button(label, handler, cls = 'btn') {
  const node = el('button', cls, label);
  node.addEventListener('click', handler);
  return node;
}

async function renderDetailSingle(body, entry) {
  $('detailHead').textContent = entryLabel(entry);
  const hero = el('div', 'dp__hero');
  const glyph = el('div', 'dp__glyph');
  if (entry.icon_url) {
    const img = el('img');
    img.src = withToken(entry.icon_url);
    glyph.appendChild(img);
  } else if (entry.category === 'image' && !isContainer(entry)) {
    const img = el('img', 'dp__thumb');
    img.src = withToken(`/api/thumb?path=${encodeURIComponent(entry.path)}&size=256`);
    glyph.appendChild(img);
  } else {
    const svg = iconSvgFor(entry, 60);
    if (svg) glyph.innerHTML = svg;
    else glyph.textContent = entry.icon || ICON[entry.category] || '📦';
  }
  hero.appendChild(glyph);
  hero.appendChild(el('div', 'dp__name', entryLabel(entry)));
  hero.appendChild(el('div', 'dp__type', entry.type || ''));
  body.appendChild(hero);

  const rows = el('div', 'dp__rows');
  const add = (key, value) => {
    if (value === undefined || value === null || value === '') return;
    rows.appendChild(el('div', 'dp__k', key));
    const node = el('div', 'dp__v', String(value));
    node.title = String(value);
    rows.appendChild(node);
  };
  if (isContainer(entry) && !entry.is_bundle) add('大小', '（双击查看）');
  else add('大小', `${entry.size_h}${entry.size !== null ? ` (${entry.size.toLocaleString()} 字节)` : ''}`);
  add('修改时间', fmtFull(entry.modified));
  add('创建时间', fmtFull(entry.created));
  add('位置', tildePath(parentPath(entry.path) || ''));
  if (entry.app?.bundle_id) add('标识符', entry.app.bundle_id);
  if (entry.app?.version) add('版本', entry.app.version);
  if (entry.link_target) add('链接目标', entry.link_target);
  body.appendChild(rows);

  const actions = el('div', 'dp__actions');
  actions.appendChild(button('打开', () => activateEntry(entry), 'btn btn--primary'));
  actions.appendChild(button('在访达中显示', () => api('/api/reveal', { method: 'POST', body: { paths: [entry.path] } })));
  actions.appendChild(button('重命名', () => promptRename(entry)));
  actions.appendChild(button('删除', () => deleteSelection(), 'btn btn--danger'));
  body.appendChild(actions);

  if (isContainer(entry) && !entry.is_bundle) {
    const group = el('div', 'dp__group');
    group.appendChild(el('div', 'dp__group-title', '文件夹大小'));
    const info = el('div', 'dp__v', '正在统计…');
    group.appendChild(info);
    body.appendChild(group);
    api('/api/folderinfo', { params: { path: entry.path } }).then((res) => {
      if (!res.ok) { info.textContent = res.error || '统计失败'; return; }
      info.textContent = `${res.size_h} · ${res.files} 个文件 · ${res.dirs} 个文件夹${res.partial ? '（部分统计）' : ''}`;
      const volume = state.boot?.volumes?.find((v) => v.path === '/');
      if (volume && volume.total) {
        const pct = Math.min(100, (res.size / volume.total) * 100);
        const chart = el('div', 'dp__chart');
        const span = el('span');
        span.style.width = `${Math.max(pct, 0.4)}%`;
        chart.appendChild(span);
        group.appendChild(chart);
        group.appendChild(el('div', 'dp__group-title', `占磁盘 ${pct.toFixed(3)}%`));
      }
    });
  }

  // 打开方式
  const group = el('div', 'dp__group');
  group.appendChild(el('div', 'dp__group-title', '打开方式'));
  const appsBox = el('div', 'dp__apps');
  const candidates = state.apps.slice(0, 400);
  if (!candidates.length) appsBox.appendChild(el('div', 'dp__type', '应用列表加载中…'));
  for (const app of candidates.slice(0, 12)) {
    const node = el('div', 'dp__app', entryLabel(app));
    node.addEventListener('click', () => openWith(entry, app.path));
    appsBox.appendChild(node);
  }
  group.appendChild(appsBox);
  const picker = button('选择其它应用…', () => chooseApp(entry));
  group.appendChild(picker);
  body.appendChild(group);
}

function openWith(entry, appPath) {
  api('/api/open', { method: 'POST', body: { paths: [entry.path], app: appPath } }).then((res) => {
    if (!res.ok) toast(res.error || '打开失败', 'error');
  });
}

async function chooseApp(entry) {
  const res = await api('/api/openers', { params: { path: entry.path, limit: 80 } });
  if (!res.ok) { toast(res.error || '无法获取打开方式', 'error'); return; }
  const apps = res.apps || [];
  const params = new URLSearchParams({ path: entry.path, name: entryLabel(entry) });

  showDialog({
    title: `打开方式 — ${entryLabel(entry)}`,
    size: 'wide',
    okLabel: '用选中的应用打开',
    body: (host) => {
      if (res.default_name) {
        const hint = el('div', 'field__hint', `系统默认：${res.default_name}`);
        host.appendChild(hint);
      }
      const field = el('div', 'field');
      const input = el('input');
      input.type = 'text';
      input.id = 'dlgAppSearch';
      input.placeholder = `搜索应用（共 ${apps.length} 个可打开此文件）`;
      input.autocomplete = 'off';
      field.appendChild(input);
      host.appendChild(field);

      const list = el('div', 'apppicker');
      list.id = 'dlgAppList';
      host.appendChild(list);

      const manual = el('div', 'field');
      manual.appendChild(el('label', null, '其它应用（可选）：输入应用名或路径'));
      const manualInput = el('input');
      manualInput.type = 'text';
      manualInput.id = 'dlgAppInput';
      manualInput.placeholder = '例如 Visual Studio Code 或 /Applications/Safari.app';
      manual.appendChild(manualInput);
      host.appendChild(manual);

      const renderList = (filter) => {
        const needle = (filter || '').trim().toLowerCase();
        const matched = apps.filter((a) => !needle
          || a.name.toLowerCase().includes(needle)
          || (a.bundle_id || '').toLowerCase().includes(needle));
        list.innerHTML = '';
        if (!matched.length) {
          list.appendChild(el('div', 'apppicker__empty', `没有匹配的应用（共 ${apps.length} 个）`));
          return;
        }
        for (const app of matched) {
          const row = el('div', `apppicker__item${app.is_default ? ' apppicker__item--default' : ''}`);
          row.dataset.app = app.path;
          const icon = el('span', 'apppicker__icon');
          if (app.icon_url) {
            const img = el('img');
            img.src = withToken(app.icon_url);
            img.alt = '';
            img.loading = 'lazy';
            icon.appendChild(img);
          } else {
            icon.textContent = '🚀';
          }
          row.appendChild(icon);
          const text = el('span', 'apppicker__text');
          text.appendChild(el('span', 'apppicker__name', app.name));
          const sub = [app.bundle_id, app.version ? `v${app.version}` : ''].filter(Boolean).join(' · ');
          if (sub) text.appendChild(el('span', 'apppicker__sub', sub));
          row.appendChild(text);
          if (app.is_default) row.appendChild(el('span', 'apppicker__badge', '默认'));
          row.addEventListener('click', () => {
            list.querySelectorAll('.apppicker__item--picked').forEach((n) => n.classList.remove('apppicker__item--picked'));
            row.classList.add('apppicker__item--picked');
            manualInput.value = '';
          });
          row.addEventListener('dblclick', () => {
            row.classList.add('apppicker__item--picked');
            $('dialogOk').click();
          });
          list.appendChild(row);
        }
        const first = list.querySelector('.apppicker__item');
        (list.querySelector('.apppicker__item--default') || first)?.classList.add('apppicker__item--picked');
      };
      renderList('');
      input.addEventListener('input', () => renderList(input.value));
      setTimeout(() => input.focus(), 40);
    },
    onOk: async () => {
      const manual = $('dlgAppInput')?.value?.trim();
      const picked = $('dlgAppList')?.querySelector('.apppicker__item--picked')?.dataset.app;
      const target = manual || picked;
      if (!target) { toast('请选择一个应用', 'error'); return false; }
      const result = await api('/api/open', { method: 'POST', body: { paths: [entry.path], app: target } });
      if (!result.ok) { toast(result.error || '打开失败', 'error'); return false; }
      toast(`已用 ${target.split('/').pop().replace(/\.app$/, '')} 打开`, 'ok');
      return true;
    },
  });
}

/* ============================================================ 操作 */

async function activateEntry(entry) {
  if (entry.kind === 'directory') return openPath(entry.path);
  if (entry.kind === 'bundle' && entry.category === 'app') {
    const res = await api('/api/open', { method: 'POST', body: { paths: [entry.path] } });
    if (!res.ok) toast(res.error || '无法启动应用', 'error');
    else toast(`正在启动 ${entry.name}`, 'ok');
    return;
  }
  if (entry.kind === 'bundle' && entry.path.endsWith('.app')) {
    const res = await api('/api/open', { method: 'POST', body: { paths: [entry.path] } });
    if (!res.ok) toast(res.error || '无法启动应用', 'error');
    return;
  }
  const res = await api('/api/open', { method: 'POST', body: { paths: [entry.path] } });
  if (!res.ok) toast(res.error || '无法打开', 'error');
}

function openSelection() {
  const paths = [...state.selection];
  if (!paths.length) return;
  api('/api/open', { method: 'POST', body: { paths } }).then((res) => {
    if (!res.ok) toast(res.error || '打开失败', 'error');
  });
}

async function setClipboard(mode) {
  const paths = [...state.selection];
  if (!paths.length) return;
  state.clipboard = { mode, paths, names: paths.map((p) => p.split('/').pop()) };
  document.querySelectorAll('.drow').forEach((row) => {
    row.classList.toggle('drow--cut', mode === 'cut' && paths.includes(row.dataset.path));
  });
  updateCommandState();
  const verb = mode === 'cut' ? '剪切' : '复制';
  toast(`已${verb} ${paths.length} 项（可粘贴到文件夹，路径也已放入系统剪贴板）`, 'ok');
  // 同步到系统剪贴板：粘贴到终端/编辑器时得到文件路径
  try {
    const res = await api('/api/clipboard', { method: 'POST', body: { mode: 'file', paths } });
    if (!res.ok) toast(`系统剪贴板写入失败：${res.error || '未知原因'}`, 'error');
  } catch (err) {
    toast(`系统剪贴板写入失败：${err.message}`, 'error');
  }
}

/** 把文本写入系统剪贴板（复制路径、文件名、文件内容等） */
async function copyToSystemClipboard(body, successMessage) {
  try {
    const res = await api('/api/clipboard', { method: 'POST', body });
    if (!res.ok) {
      toast(`复制失败：${res.error || '未知原因'}`, 'error');
      return false;
    }
    toast(successMessage || '已复制到系统剪贴板', 'ok');
    return true;
  } catch (err) {
    toast(`复制失败：${err.message}`, 'error');
    return false;
  }
}

/** 复制路径 / 文件名 / 所在目录 / 文件内容 */
async function copySelectionAs(mode) {
  const paths = [...state.selection];
  if (!paths.length) return;
  const label = { file: '完整路径', name: '文件名', dir: '所在目录', content: '文件内容' }[mode] || '内容';
  const single = paths.length === 1 ? `「${paths[0].split('/').pop()}」` : `${paths.length} 项`;
  return copyToSystemClipboard({ mode, paths }, `已复制${single}的${label}`);
}

async function pasteInto(destDir = state.path) {
  if (!state.clipboard) return;
  if (state.view !== 'files' && !destDir) return;
  if (state.view !== 'files') { toast('请先进入目标文件夹再粘贴', 'error'); return; }
  const { mode, paths } = state.clipboard;
  const verb = mode === 'copy' ? '复制' : '移动';
  const destName = destDir === state.path ? currentTitle() : (destDir.split('/').filter(Boolean).pop() || destDir);
  busy(true, `正在${verb}…`);
  try {
    const res = await api('/api/transfer', { method: 'POST', body: { paths, dest: destDir, mode } });
    const results = res.results || [];
    const good = results.filter((r) => r.ok);
    const bad = results.filter((r) => !r.ok);
    if (good.length) {
      const detail = good.length === 1
        ? `「${good[0].path.split('/').pop()}」→「${destName}」`
        : `${good.length} 项 →「${destName}」`;
      toast(`已${verb} ${detail}`, 'ok');
    }
    for (const failure of bad.slice(0, 3)) {
      const name = failure.path ? `「${failure.path.split('/').pop()}」` : '';
      toast(`${verb}失败${name ? ` ${name}` : ''}：${failure.error || '未知原因'}`, 'error');
    }
    if (!res.ok && !bad.length) toast(res.error || `${verb}失败`, 'error');
    if (mode === 'cut' && good.length) { state.clipboard = null; updateCommandState(); }
  } finally {
    busy(false);
    reloadCurrent();
  }
}

async function deleteSelection({ permanent = false } = {}) {
  const paths = [...state.selection];
  if (!paths.length) return;
  const label = paths.length === 1 ? `“${paths[0].split('/').pop()}”` : `${paths.length} 个项目`;
  const confirmed = await confirmDialog(
    permanent ? '永久删除' : '删除到废纸篓',
    permanent ? `确定要永久删除 ${label} 吗？此操作无法撤销。` : `确定要把 ${label} 移到废纸篓吗？`,
  );
  if (!confirmed) return;
  busy(true, '正在删除…');
  try {
    const res = await api('/api/delete', { method: 'POST', body: { paths, permanent } });
    if (res.ok) toast(`已删除 ${paths.length} 项`, 'ok');
    else {
      const failure = (res.failed || []).find((f) => f.error);
      toast(failure?.error || res.error || '删除失败', 'error');
    }
  } finally {
    busy(false);
    state.selection.clear();
    reloadCurrent();
  }
}

function promptRename(entry) {
  const target = entry || selectedEntries()[0];
  if (!target) return;
  showDialog({
    title: '重命名',
    body: (host) => {
      const field = el('div', 'field');
      field.appendChild(el('label', null, '新名称'));
      const input = el('input');
      input.type = 'text';
      input.id = 'dlgNameInput';
      input.value = target.name;
      input.addEventListener('keydown', (event) => {
        if (event.key === '=' ) return;
      });
      field.appendChild(input);
      host.appendChild(field);
      setTimeout(() => {
        input.focus();
        const dot = target.name.lastIndexOf('.');
        input.setSelectionRange(0, dot > 0 ? dot : target.name.length);
      }, 30);
    },
    onOk: async () => {
      const value = $('dlgNameInput')?.value?.trim();
      if (!value || value === target.name) return true;
      const res = await api('/api/rename', { method: 'POST', body: { path: target.path, name: value } });
      if (!res.ok) { toast(res.error || '重命名失败', 'error'); return false; }
      toast('已重命名', 'ok');
      reloadCurrent();
      return true;
    },
  });
}

function newFolder() {
  if (state.view !== 'files') { toast('请先进入一个文件夹', 'error'); return; }
  showDialog({
    title: '新建文件夹',
    body: (host) => {
      const field = el('div', 'field');
      field.appendChild(el('label', null, '文件夹名称'));
      const input = el('input');
      input.type = 'text';
      input.id = 'dlgNameInput';
      input.value = '新建文件夹';
      field.appendChild(input);
      host.appendChild(field);
      setTimeout(() => { input.focus(); input.select(); }, 30);
    },
    onOk: async () => {
      const value = $('dlgNameInput')?.value?.trim() || '新建文件夹';
      const res = await api('/api/mkdir', { method: 'POST', body: { parent: state.path, name: value } });
      if (!res.ok) { toast(res.error || '创建失败', 'error'); return false; }
      toast(`已创建 ${res.name}`, 'ok');
      reloadCurrent();
      return true;
    },
  });
}

function newFile() {
  if (state.view !== 'files') { toast('请先进入一个文件夹', 'error'); return; }
  showDialog({
    title: '新建文本文档',
    body: (host) => {
      const field = el('div', 'field');
      field.appendChild(el('label', null, '文件名'));
      const input = el('input');
      input.type = 'text';
      input.id = 'dlgNameInput';
      input.value = '新建文本文档.txt';
      field.appendChild(input);
      host.appendChild(field);
      setTimeout(() => { input.focus(); input.select(); }, 30);
    },
    onOk: async () => {
      const value = $('dlgNameInput')?.value?.trim() || '新建文本文档.txt';
      const res = await api('/api/newfile', { method: 'POST', body: { parent: state.path, name: value } });
      if (!res.ok) { toast(res.error || '创建失败', 'error'); return false; }
      toast(`已创建 ${res.name}`, 'ok');
      reloadCurrent();
      return true;
    },
  });
}

function reloadCurrent() {
  if (state.view === 'files') return openPath(state.path, { pushHistory: false });
  if (state.view === 'apps') return loadApps();
  if (state.view === 'recent') return loadRecent();
  if (state.view === 'category') return loadCategory(state.category);
}

/** 把系统剪贴板里的文本保存为当前文件夹下的新文件 */
async function pasteClipboardAsFile() {
  if (state.view !== 'files') { toast('请先进入一个文件夹', 'error'); return; }
  const res = await api('/api/clipboard');
  if (!res.ok) { toast(res.error || '读取剪贴板失败', 'error'); return; }
  const text = res.text || '';
  if (!text.trim()) { toast('系统剪贴板里没有文本', 'error'); return; }
  const firstLine = text.split('\n')[0].trim().slice(0, 40).replace(/[\/:*?"<>|]/g, '_');
  showDialog({
    title: '把剪贴板文本存成文件',
    body: (host) => {
      const info = el('div', 'field__hint', `剪贴板内容：${text.length} 个字符`);
      host.appendChild(info);
      const field = el('div', 'field');
      field.appendChild(el('label', null, '文件名'));
      const input = el('input');
      input.type = 'text';
      input.id = 'dlgNameInput';
      input.value = `${firstLine || '剪贴板文本'}.txt`;
      field.appendChild(input);
      host.appendChild(field);
      setTimeout(() => { input.focus(); input.select(); }, 30);
    },
    onOk: async () => {
      const name = $('dlgNameInput')?.value?.trim() || '剪贴板文本.txt';
      const created = await api('/api/newfile', { method: 'POST', body: { parent: state.path, name } });
      if (!created.ok) { toast(created.error || '创建失败', 'error'); return false; }
      const saved = await api('/api/savefile', { method: 'POST', body: { path: created.path, text } });
      if (!saved.ok) { toast(saved.error || '保存失败', 'error'); return false; }
      toast(`已保存为「${created.name}」（${text.length} 字符）`, 'ok');
      reloadCurrent();
      return true;
    },
  });
}

function copyText(text) {
  navigator.clipboard?.writeText(text).then(
    () => toast('已复制路径', 'ok'),
    () => toast('复制失败', 'error'),
  );
}

/* ============================================================ 右键菜单 */

function showContextMenu(event, items) {
  const menu = $('ctxMenu');
  menu.innerHTML = '';
  for (const item of items) {
    if (item.separator) { menu.appendChild(el('div', 'ctxmenu__sep')); continue; }
    const node = el('div', `ctxmenu__item${item.disabled ? ' ctxmenu__item--disabled' : ''}${item.danger ? ' ctxmenu__item--danger' : ''}`);
    node.appendChild(el('span', 'ctxmenu__icon', item.icon || ''));
    node.appendChild(el('span', 'ctxmenu__label', item.label));
    if (item.accel) node.appendChild(el('span', 'ctxmenu__accel', item.accel));
    node.addEventListener('click', () => { hideContextMenu(); item.action?.(); });
    menu.appendChild(node);
  }
  menu.hidden = false;
  const rect = menu.getBoundingClientRect();
  const x = Math.min(event.clientX, window.innerWidth - rect.width - 8);
  const y = Math.min(event.clientY, window.innerHeight - rect.height - 8);
  menu.style.left = `${Math.max(4, x)}px`;
  menu.style.top = `${Math.max(4, y)}px`;
}

function hideContextMenu() { $('ctxMenu').hidden = true; }

function showEntryMenu(event, entry) {
  const selected = selectedEntries();
  const many = selected.length > 1;
  const items = [];
  if (!many) {
    items.push({ label: entry.kind === 'directory' ? '打开' : '打开', icon: '↗', accel: 'Enter', action: () => activateEntry(entry) });
    if (entry.kind === 'bundle' && entry.category === 'app') {
      items.push({ label: '显示包内容', icon: '📦', action: () => openPath(joinPath(entry.path, 'Contents')) });
    }
    items.push({
      label: '打开方式', icon: '🧩', action: () => chooseApp(entry),
    });
    items.push({ separator: true });
  }
  items.push({ label: '在新标签页打开', icon: '🗂️', action: () => {
    const target = entry.kind === 'directory' ? entry.path : parentPath(entry.path);
    addTab({ view: 'files', path: target, label: entry.name, icon: entry.icon });
  }, disabled: entry.kind !== 'directory' });
  items.push({ label: '在访达中显示', icon: '🔍', action: () => api('/api/reveal', { method: 'POST', body: { paths: [...state.selection] } }) });
  items.push({ label: '在此打开终端', icon: '⌨️', action: () => api('/api/reveal', { method: 'POST', body: { paths: [entry.path], terminal: true } }) });
  items.push({ separator: true });
  items.push({ label: '复制', icon: '⧉', accel: '⌘C', action: () => setClipboard('copy') });
  items.push({ label: '剪切', icon: '✂', accel: '⌘X', action: () => setClipboard('cut') });
  if (entry.kind === 'directory') {
    items.push({ label: '粘贴到此处', icon: '📋', disabled: !state.clipboard, action: () => pasteInto(entry.path) });
  }
  items.push({ separator: true });
  items.push({ label: '复制路径', icon: '🔗', action: () => copySelectionAs('file') });
  items.push({ label: '复制文件名', icon: '🏷️', action: () => copySelectionAs('name') });
  if (!many && isTextEntry(entry)) {
    items.push({ label: '复制文件内容', icon: '📄', action: () => copySelectionAs('content') });
  }
  items.push({ separator: true });
  items.push({ label: '重命名', icon: '✎', accel: 'F2', disabled: many, action: () => promptRename(entry) });
  items.push({ label: '删除到废纸篓', icon: '🗑', accel: '⌫', danger: true, action: () => deleteSelection() });
  items.push({ label: '永久删除…', icon: '⚠️', danger: true, action: () => deleteSelection({ permanent: true }) });
  items.push({ separator: true });
  items.push({ label: '查看简介', icon: 'ⓘ', action: () => { state.detailEntry = entry; renderDetailSingle($('detailBody'), entry); } });
  showContextMenu(event, items);
}

function showBackgroundMenu(event) {
  const items = [];
  if (state.view === 'files') {
    items.push({ label: '新建文件夹', icon: '🗋', accel: '⇧⌘N', action: newFolder });
    items.push({ label: '新建文本文档', icon: '📄', action: newFile });
    items.push({ separator: true });
    items.push({ label: '粘贴', icon: '📋', accel: '⌘V', disabled: !state.clipboard, action: () => pasteInto(state.path) });
    items.push({ separator: true });
    items.push({ label: '把剪贴板文本存成文件…', icon: '📥', action: pasteClipboardAsFile });
    items.push({ separator: true });
    items.push({ label: '在终端打开', icon: '⌨️', action: () => api('/api/reveal', { method: 'POST', body: { paths: [state.path], terminal: true } }) });
    items.push({ label: '在访达中显示', icon: '🔍', action: () => api('/api/reveal', { method: 'POST', body: { paths: [state.path] } }) });
  }
  items.push({ label: '刷新', icon: '⟳', accel: 'F5', action: () => reloadCurrent() });
  items.push({ separator: true });
  items.push({ label: state.layout === 'details' ? '切换到大图标视图' : '切换到详细信息视图', icon: '▦', action: toggleLayout });
  items.push({ label: state.showHidden ? '隐藏隐藏文件' : '显示隐藏文件', icon: '👁', action: toggleHidden });
  if (state.view !== 'files') {
    items.push({ separator: true });
    items.push({ label: '重新扫描（刷新缓存）', icon: '🔄', action: () => {
      if (state.view === 'apps') return loadApps({ refresh: true });
      if (state.view === 'recent') return loadRecent({ refresh: true });
      if (state.view === 'category') return loadCategory(state.category, { refresh: true });
      return reloadCurrent();
    } });
  }
  showContextMenu(event, items);
}

function toggleLayout() {
  state.layout = state.layout === 'details' ? 'tiles' : 'details';
  try { localStorage.setItem('winfile.layout', state.layout); } catch (err) { /* 忽略 */ }
  renderList();
  $('btnView').querySelector('.cmd__label').textContent = state.layout === 'details' ? '视图' : '视图';
}

function toggleHidden() {
  state.showHidden = !state.showHidden;
  $('btnShowHidden').textContent = `显示隐藏文件：${state.showHidden ? '开' : '关'}`;
  reloadCurrent();
}

/* ============================================================ 对话框 */

let dialogOnOk = null;
let dialogOnCancel = null;

function showDialog({ title, body, onOk, onCancel = null, okLabel = '确定', size = '' }) {
  $('dialogTitle').textContent = title;
  const dialog = $('dialog');
  dialog.classList.toggle('dialog--wide', size === 'wide');
  const host = $('dialogBody');
  host.innerHTML = '';
  body(host);
  $('dialogOk').textContent = okLabel;
  $('dialogBackdrop').hidden = false;
  dialogOnOk = onOk;
  dialogOnCancel = onCancel;
  setTimeout(() => host.querySelector('input')?.focus(), 40);
}

function hideDialog() {
  $('dialogBackdrop').hidden = true;
  $('dialog').classList.remove('dialog--wide');
  dialogOnOk = null;
  dialogOnCancel = null;
}

function cancelDialog() {
  const callback = dialogOnCancel;
  hideDialog();
  callback?.();
}

function confirmDialog(title, message) {
  return new Promise((resolve) => {
    showDialog({
      title,
      body: (host) => {
        const p = el('div', 'field__hint', message);
        p.style.fontSize = '13px';
        p.style.color = 'var(--text)';
        host.appendChild(p);
      },
      onOk: () => { resolve(true); return true; },
      onCancel: () => resolve(false),
    });
  });
}

/* ============================================================ 路径输入与补全 */

function enterEditMode(selectAll = true) {
  const wrap = $('addressWrap');
  wrap.classList.add('address--edit');
  const input = $('pathInput');
  input.value = state.view === 'files' ? state.path : '';
  input.placeholder = state.view === 'files' ? state.path : '输入路径，例如 ~/Documents 或 /Applications';
  input.focus();
  if (selectAll && state.view === 'files') input.select();
  refreshSuggestions(input.value);
}

function exitEditMode() {
  $('addressWrap').classList.remove('address--edit');
  hideSuggestions();
}

function showSuggestions(items, meta) {
  const host = $('suggest');
  host.innerHTML = '';
  if (!items.length) {
    host.hidden = true;
    return;
  }
  state.suggestions = items;
  items.forEach((item, index) => {
    const node = el('div', `suggest__item${index === state.suggestIndex ? ' suggest__item--active' : ''}`);
    node.appendChild(el('span', 'suggest__icon', item.icon || '📁'));
    node.appendChild(el('span', 'suggest__name', item.name));
    node.appendChild(el('span', 'suggest__path', item.is_dir ? '文件夹' : item.display));
    node.addEventListener('mousedown', (event) => {
      event.preventDefault();
      acceptSuggestion(item, false);
    });
    host.appendChild(node);
  });
  if (meta?.truncated) host.appendChild(el('div', 'suggest__hint', `仅显示前 ${items.length} 项（共 ${meta.total} 项匹配）`));
  host.hidden = false;
}

function hideSuggestions() {
  $('suggest').hidden = true;
  state.suggestions = [];
  state.suggestIndex = -1;
}

const refreshSuggestions = debounce(async (value) => {
  if (!value || value.length < 1) { hideSuggestions(); return; }
  const res = await api('/api/complete', { params: { q: value, limit: 24 } });
  if (!res.suggestions || !res.suggestions.length) {
    const host = $('suggest');
    host.innerHTML = '';
    host.appendChild(el('div', 'suggest__hint', '没有匹配的路径'));
    host.hidden = false;
    state.suggestions = [];
    return;
  }
  state.suggestIndex = 0;
  showSuggestions(res.suggestions, res);
}, 90);

function acceptSuggestion(item, keepEditing = false) {
  const input = $('pathInput');
  input.value = item.is_dir ? item.path : item.path;
  if (item.is_dir) {
    if (keepEditing) input.value = item.path.endsWith('/') ? item.path : `${item.path}/`;
    refreshSuggestions(input.value);
    return;
  }
  input.value = item.path;
}

function gotoPath(path) {
  if (!path) return;
  exitEditMode();
  openPath(path, { pushHistory: true });
}

/* ============================================================ 事件绑定 */

function updateCommandState() {
  const hasSelection = state.selection.size > 0;
  const single = state.selection.size === 1;
  $('btnCut').disabled = !hasSelection;
  $('btnCopy').disabled = !hasSelection;
  $('btnCopyPath').disabled = !hasSelection;
  const canPaste = !!state.clipboard && state.view === 'files';
  $('btnPaste').disabled = !canPaste;
  const pasteBtn = $('btnPaste');
  pasteBtn.title = canPaste
    ? `粘贴到「${currentTitle()}」 (⌘V) — 剪贴板：${state.clipboard.mode === 'copy' ? '复制' : '剪切'} ${state.clipboard.paths.length} 项`
    : '粘贴 (⌘V)';
  $('btnRename').disabled = !single || state.view !== 'files';
  $('btnDelete').disabled = !hasSelection;
  $('btnOpen').disabled = !hasSelection;
  $('btnReveal').disabled = !hasSelection;
}

function bindEvents() {
  // 命令栏
  $('btnNew').addEventListener('click', (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    showContextMenu({ clientX: rect.left, clientY: rect.bottom + 4 }, [
      { label: '文件夹', icon: '📁', action: newFolder },
      { label: '文本文档', icon: '📄', action: newFile },
      { separator: true },
      { label: '新标签页', icon: '🗂️', action: () => addTab({ view: 'files', path: state.boot.home, label: '个人文件夹', icon: '🏠' }) },
    ]);
  });
  $('btnCut').addEventListener('click', () => setClipboard('cut'));
  $('btnCopy').addEventListener('click', () => setClipboard('copy'));
  $('btnCopyPath').addEventListener('click', (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    showContextMenu({ clientX: rect.left, clientY: rect.bottom + 4 }, [
      { label: '完整路径', icon: '🔗', action: () => copySelectionAs('file') },
      { label: '文件名', icon: '🏷️', action: () => copySelectionAs('name') },
      { label: '所在目录', icon: '📂', action: () => copySelectionAs('dir') },
      { separator: true },
      { label: '文件内容（文本文件）', icon: '📄', action: () => copySelectionAs('content') },
    ]);
  });
  $('btnPaste').addEventListener('click', () => pasteInto(state.path));
  $('btnRename').addEventListener('click', () => promptRename());
  $('btnDelete').addEventListener('click', () => deleteSelection());
  $('btnOpen').addEventListener('click', () => openSelection());
  $('btnReveal').addEventListener('click', () => {
    api('/api/reveal', { method: 'POST', body: { paths: [...state.selection] } }).then((res) => {
      if (!res.ok) toast(res.error || '无法在访达中显示', 'error');
    });
  });

  $('btnSort').addEventListener('click', (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    const options = [
      { key: 'name', label: '名称' },
      { key: 'modified', label: '修改日期' },
      { key: 'type', label: '类型' },
      { key: 'size', label: '大小' },
      { key: 'path', label: '位置' },
    ];
    showContextMenu({ clientX: rect.left - 60, clientY: rect.bottom + 4 }, [
      ...options.map((option) => ({
        label: option.label,
        icon: state.sort === option.key ? (state.order === 'asc' ? '▲' : '▼') : '',
        action: () => {
          if (state.sort === option.key) state.order = state.order === 'asc' ? 'desc' : 'asc';
          else { state.sort = option.key; state.order = 'asc'; }
          if (state.view === 'files' && ['name', 'modified', 'type', 'size'].includes(state.sort)) {
            openPath(state.path, { pushHistory: false });
          } else {
            state.entries.sort(compareEntries);
            renderAll();
          }
        },
      })),
      { separator: true },
      { label: '切换 升序/降序', icon: '⇅', action: () => { state.order = state.order === 'asc' ? 'desc' : 'asc'; state.entries.sort(compareEntries); renderAll(); } },
    ]);
  });

  $('btnView').addEventListener('click', (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    showContextMenu({ clientX: rect.left - 40, clientY: rect.bottom + 4 }, [
      { label: '详细信息', icon: state.layout === 'details' ? '●' : '', action: () => { state.layout = 'details'; renderList(); } },
      { label: '大图标', icon: state.layout === 'tiles' ? '●' : '', action: () => { state.layout = 'tiles'; renderList(); } },
      { separator: true },
      { label: state.showHidden ? '隐藏隐藏文件' : '显示隐藏文件', icon: '👁', action: toggleHidden },
    ]);
  });

  $('btnDetails').addEventListener('click', () => {
    state.detailOpen = !state.detailOpen;
    $('detailpane').classList.toggle('detailpane--hidden', !state.detailOpen);
  });

  // 导航
  $('btnBack').addEventListener('click', () => goHistory(-1));
  $('btnForward').addEventListener('click', () => goHistory(1));
  $('btnUp').addEventListener('click', () => { const parent = parentPath(state.path); if (parent) openPath(parent); });
  $('btnRefresh').addEventListener('click', () => reloadCurrent());
  $('btnShowHidden').addEventListener('click', toggleHidden);

  // 地址栏
  const wrap = $('addressWrap');
  wrap.addEventListener('click', (event) => {
    if (event.target.closest('.crumb') || event.target.closest('button')) return;
    if (!wrap.classList.contains('address--edit')) enterEditMode();
  });
  const input = $('pathInput');
  input.addEventListener('input', () => {
    state.suggestIndex = 0;
    refreshSuggestions(input.value);
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      state.suggestIndex = Math.min(state.suggestIndex + 1, state.suggestions.length - 1);
      showSuggestions(state.suggestions, {});
      wrap.querySelectorAll('.suggest__item')[state.suggestIndex]?.scrollIntoView({ block: 'nearest' });
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      state.suggestIndex = Math.max(state.suggestIndex - 1, 0);
      showSuggestions(state.suggestions, {});
    } else if (event.key === 'Tab') {
      event.preventDefault();
      const item = state.suggestions[state.suggestIndex] || state.suggestions[0];
      if (item) acceptSuggestion(item, true);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const item = state.suggestions[state.suggestIndex];
      const typed = input.value.trim();
      if (item && item.is_dir && item.path.toLowerCase().startsWith(typed.toLowerCase()) && typed.length < item.path.length && state.suggestions.length > 1) {
        acceptSuggestion(item, true);
        return;
      }
      gotoPath(typed);
    } else if (event.key === 'Escape') {
      exitEditMode();
    }
  });
  $('btnGo').addEventListener('click', () => gotoPath(input.value.trim()));

  // 搜索（当前视图过滤）
  const search = $('searchInput');
  search.addEventListener('input', debounce(() => {
    state.filter = search.value.trim();
    $('btnSearchClear').hidden = !state.filter;
    renderList();
  }, 120));
  $('btnSearchClear').addEventListener('click', () => {
    search.value = '';
    state.filter = '';
    $('btnSearchClear').hidden = true;
    renderList();
  });

  // 空白区右键
  $('viewHost').addEventListener('contextmenu', (event) => {
    if (event.target.closest('.drow') || event.target.closest('.tile')) return;
    event.preventDefault();
    state.selection.clear();
    syncSelection();
    showBackgroundMenu(event);
  });
  $('viewHost').addEventListener('click', (event) => {
    if (event.target.closest('.drow') || event.target.closest('.tile')) return;
    state.selection.clear();
    syncSelection();
  });
  // 拖到文件夹背景 = 移动到当前目录
  $('viewHost').addEventListener('dragover', (event) => {
    if (event.dataTransfer.types.includes('application/x-winfile')) {
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
    }
  });
  $('viewHost').addEventListener('drop', async (event) => {
    const raw = event.dataTransfer.getData('application/x-winfile');
    if (!raw || state.view !== 'files') return;
    event.preventDefault();
    const payload = JSON.parse(raw);
    const paths = payload.paths.filter((p) => parentPath(p) !== state.path);
    if (!paths.length) return;
    const mode = event.altKey ? 'copy' : 'move';
    const res = await api('/api/transfer', { method: 'POST', body: { paths, dest: state.path, mode } });
    if (res.ok) toast(`已${mode === 'copy' ? '复制' : '移动'} ${paths.length} 项`, 'ok');
    else toast(res.error || '操作失败', 'error');
    reloadCurrent();
  });

  document.addEventListener('click', (event) => {
    if (!event.target.closest('#ctxMenu')) hideContextMenu();
    if (!event.target.closest('#addressWrap')) exitEditMode();
  });

  // 调试/自动化入口：便于外部脚本驱动界面（截图、端到端验证）
  window.__winfile = {
    state,
    openPath,
    loadApps,
    loadRecent,
    loadCategory,
    toggleLayout,
    toggleHidden,
    showEntryMenu,
    enterEditMode,
    refreshSuggestions,
    renderList,
    renderAll,
    activateEntry,
  };

  document.addEventListener('keydown', (event) => {
    const inInput = ['INPUT', 'TEXTAREA'].includes(event.target.tagName);
    const meta = event.metaKey || event.ctrlKey;

    if (event.key === 'Escape') {
      hideContextMenu();
      if (!$('dialogBackdrop').hidden) cancelDialog();
      if (inInput) event.target.blur();
      return;
    }
    if (inInput && !(meta && ['a', 'c'].includes(event.key.toLowerCase()))) return;

    if (meta && event.key.toLowerCase() === 'a') { event.preventDefault(); state.selection = new Set(visibleEntries().map((e) => e.path)); syncSelection(); return; }
    if (meta && event.key.toLowerCase() === 'c') { event.preventDefault(); setClipboard('copy'); return; }
    if (meta && event.key.toLowerCase() === 'x') { event.preventDefault(); setClipboard('cut'); return; }
    if (meta && event.key.toLowerCase() === 'v') { event.preventDefault(); pasteInto(state.path); return; }
    if (meta && event.shiftKey && event.key.toLowerCase() === 'n') { event.preventDefault(); newFolder(); return; }
    if (meta && event.key.toLowerCase() === 'l') { event.preventDefault(); enterEditMode(); return; }
    if (meta && event.key.toLowerCase() === 'i') { event.preventDefault(); $('btnDetails').click(); return; }
    if (event.key === 'F5') { event.preventDefault(); reloadCurrent(); return; }
    if (event.key === 'F2') { event.preventDefault(); promptRename(); return; }
    if (event.key === 'Delete' || event.key === 'Backspace') {
      if (state.selection.size) { event.preventDefault(); deleteSelection(); }
      else if (event.key === 'Backspace') { const parent = parentPath(state.path); if (parent && state.view === 'files') openPath(parent); }
      return;
    }
    if (event.key === 'Enter') {
      if (state.selection.size) { event.preventDefault(); openSelection(); }
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      const entries = visibleEntries();
      if (!entries.length) return;
      event.preventDefault();
      const current = state.lastClickedPath;
      let index = entries.findIndex((e) => e.path === current);
      index = event.key === 'ArrowDown' ? Math.min(index + 1, entries.length - 1) : Math.max(index - 1, 0);
      if (current === null || index < 0) index = 0;
      const entry = entries[index];
      if (!event.shiftKey) state.selection.clear();
      state.selection.add(entry.path);
      state.lastClickedPath = entry.path;
      state.anchorIndex = index;
      state.detailEntry = entry;
      syncSelection();
      const node = document.querySelector(`[data-path="${CSS.escape(entry.path)}"]`);
      node?.scrollIntoView({ block: 'nearest' });
      return;
    }
    if (event.altKey && event.key === 'ArrowLeft') { event.preventDefault(); goHistory(-1); return; }
    if (event.altKey && event.key === 'ArrowRight') { event.preventDefault(); goHistory(1); return; }
    if (event.altKey && event.key === 'ArrowUp') { event.preventDefault(); const parent = parentPath(state.path); if (parent && state.view === 'files') openPath(parent); }
  });

  $('dialogOk').addEventListener('click', async () => {
    if (!dialogOnOk) return hideDialog();
    const result = await dialogOnOk();
    if (result !== false) hideDialog();
  });
  $('dialogCancel').addEventListener('click', cancelDialog);
  $('dialogBackdrop').addEventListener('click', (event) => {
    if (event.target === $('dialogBackdrop')) cancelDialog();
  });
  $('dialogBody').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); $('dialogOk').click(); }
  });
  window.addEventListener('resize', hideContextMenu);
}

/* ============================================================ 入口 */

(async function main() {
  try {
    const saved = localStorage.getItem('winfile.layout');
    if (saved) state.layout = saved;
  } catch (err) { /* 忽略 */ }
  bindEvents();
  await boot();
})();
