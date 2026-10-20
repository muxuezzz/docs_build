#!/usr/bin/env node
/**
 * 用真实浏览器验证构建产物是不是「打开就零外网请求」。
 *
 * 用法:
 *   node check-site-offline.mjs <站点目录> [--pages a,b] [--sample 6] [--port 8123]
 *
 * 做什么:
 *   1. 起一个本地静态服务器（产物里大多是 / 开头的绝对路径，file:// 打不开）
 *   2. 用本机 Edge/Chrome 无头模式打开若干页面，拦截所有发往非 127.0.0.1 的请求
 *   3. 打印每页的首屏时间、DOMContentLoaded、load，以及被拦截的外链
 *
 * 需要 puppeteer-core（不下载浏览器，直接驱动本机已有的 Edge/Chrome）。
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
let puppeteer;
try {
  puppeteer = require('puppeteer-core');
} catch {
  console.error('缺少 puppeteer-core：npm i puppeteer-core');
  process.exit(2);
}

const args = process.argv.slice(2);
if (!args.length) {
  console.error('用法: node check-site-offline.mjs <站点目录> [--pages a,b] [--sample 6] [--port 8123]');
  process.exit(2);
}
const site = path.resolve(args[0]);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const port = Number(opt('port', 8123));
const sample = Number(opt('sample', 6));
const explicit = opt('pages', '');

const MIME = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp',
  '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2',
  '.ttf': 'font/ttf', '.mp4': 'video/mp4', '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml', '.webmanifest': 'application/manifest+json',
};

const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = path.join(site, urlPath);
  try {
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) {
      res.writeHead(404, { 'content-type': 'text/html; charset=utf-8' });
      res.end('<h1>404</h1>');
      return;
    }
    const body = fs.readFileSync(file);
    res.writeHead(200, {
      'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
      'content-length': body.length,
      'cache-control': 'no-store',
    });
    res.end(body);
  } catch (e) {
    res.writeHead(500).end(String(e));
  }
});

function findBrowser() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
  ].filter(Boolean);
  for (const c of candidates) if (fs.existsSync(c)) return c;
  throw new Error('找不到 Edge/Chrome，可用 CHROME_PATH 指定');
}

/** 挑几页做代表：首页 + 若干深层页面 */
function pickPages() {
  if (explicit) return explicit.split(',').map((s) => s.trim()).filter(Boolean);
  const found = [];
  const walk = (dir, depth = 0) => {
    if (depth > 6) return;
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      const st = fs.statSync(full);
      if (st.isDirectory()) walk(full, depth + 1);
      else if (name === 'index.html') {
        const rel = '/' + path.relative(site, full).replace(/\\/g, '/');
        found.push(rel.replace(/\/index\.html$/, '/'));
      }
    }
  };
  walk(site);
  const home = found.filter((p) => p === '/' || p.split('/').filter(Boolean).length <= 1);
  const deep = found.filter((p) => p.split('/').filter(Boolean).length >= 3);
  const out = [];
  if (found.includes('/')) out.push('/');
  for (const p of home.slice(0, 2)) if (!out.includes(p)) out.push(p);
  // 深层页面等距抽样，避免全是最相似的 API 页
  const step = Math.max(1, Math.floor(deep.length / Math.max(1, sample - out.length)));
  for (let i = 0; i < deep.length && out.length < sample; i += step) out.push(deep[i]);
  return out.slice(0, sample);
}

(async () => {
  await new Promise((r) => server.listen(port, '127.0.0.1', r));
  const pages = pickPages();
  console.log(`站点: ${site}\n本地服务: http://127.0.0.1:${port}\n抽查 ${pages.length} 页\n`);

  const browser = await puppeteer.launch({
    executablePath: findBrowser(),
    headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });

  const rows = [];
  const external = new Map();

  for (const p of pages) {
    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 900 });
    const seen = [];
    await page.setRequestInterception(true);
    page.on('request', (req) => {
      const u = req.url();
      if (u.startsWith(`http://127.0.0.1:${port}`) || u.startsWith('data:') || u.startsWith('blob:')) {
        req.continue();
      } else {
        // 模拟断网：直接拦死，页面仍要继续渲染
        seen.push(u);
        req.abort('failed').catch(() => {});
      }
    });

    const t0 = Date.now();
    try {
      await page.goto(`http://127.0.0.1:${port}${p}`, { waitUntil: 'load', timeout: 30000 });
    } catch {
      /* 超时也把已测到的数据记下来 */
    }
    const timing = await page.evaluate(() => {
      const nav = performance.getEntriesByType('navigation')[0];
      const paint = performance.getEntriesByName('first-contentful-paint')[0];
      return {
        fcp: paint ? Math.round(paint.startTime) : null,
        dcl: nav ? Math.round(nav.domContentLoadedEventEnd) : null,
        load: nav ? Math.round(nav.loadEventEnd) : null,
        nodes: document.querySelectorAll('*').length,
      };
    }).catch(() => ({ fcp: null, dcl: null, load: null, nodes: 0 }));

    rows.push({ page: p, wall: Date.now() - t0, ...timing, ext: seen.length });
    for (const u of seen) external.set(u, (external.get(u) || 0) + 1);
    await page.close();
  }

  await browser.close();
  server.close();

  console.log('页面'.padEnd(52), 'FCP', 'DCL', 'load', '节点', '外链');
  for (const r of rows) {
    console.log(
      r.page.slice(0, 50).padEnd(52),
      `${r.fcp ?? '-'}ms`.padStart(6),
      `${r.dcl ?? '-'}ms`.padStart(6),
      `${r.load ?? '-'}ms`.padStart(6),
      String(r.nodes).padStart(5),
      String(r.ext).padStart(4),
    );
  }

  console.log();
  if (external.size) {
    console.log(`[!] 共 ${external.size} 个外链请求被拦截（模拟断网下页面仍能打开，但这些资源加载不出来）`);
    for (const [u, c] of [...external.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15)) {
      console.log(`    x${c}  ${u.slice(0, 110)}`);
    }
    process.exitCode = 1;
  } else {
    console.log('[OK] 零外网请求：断网环境下打开这些页面不会有任何等待');
  }
})();
