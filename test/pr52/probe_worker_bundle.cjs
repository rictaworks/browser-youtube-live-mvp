'use strict';
// 配信パイプラインのワーカーが、Next.js（Turbopack）のバンドルで動くことを、実ブラウザで確かめる（issue #27）。
//   製品の既定のワーカーの作り方（lib/pipeline/defaultWorker.ts: new Worker(new URL(...), { type: "module" })）は、バンドラーが解釈する書き方で、
//   Jest・素の TypeScript の変換では確かめられない。そこで、確認用のアプリ（bundle_probe/）に、製品の core・lib・workers を写して、
//   next build + next start（本番）と next dev（開発）の両方で起動し、Playwright の Chromium で、ワーカーが起動する（PipelineClient.start が解決し、
//   get_stats の応答が返る）ことを確かめる。
//
//   - 作業用のディレクトリ（--work-dir。既定は OS の一時ディレクトリの下の issue27-bundle-probe）に、確認用のアプリと、製品の core・lib・workers の写しを置く
//     （src/frontend の中に確認用の画面を置かないため）。node_modules は、src/frontend/node_modules への参照
//   - 開発サーバー（next dev）は、localhost で開く（127.0.0.1 は、開発サーバーが許可していない）。本番は 127.0.0.1
//   - 起動したサーバーは、プロセスグループごと終了する
//
// 使い方: node probe_worker_bundle.cjs --repo <リポジトリのルート> [--playwright-dir <Playwright を導入したディレクトリ>] [--work-dir <作業用のディレクトリ>] [--only build|dev|all]
// 終了コード: 0 = すべて確認できた / 1 = 食い違い / 3 = 確認できなかった（Playwright・Next.js が無い）。3 は成功ではない

const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const support = require('./browser_support.cjs');

const { check } = support;
const COPIED_ROOTS = ['core', 'lib', 'workers'];
const SERVER_READY_TIMEOUT_MS = 120000;
const PAGE_TIMEOUT_MS = 60000;

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

/** 確認用のアプリと、製品の core・lib・workers の写しを、作業用のディレクトリに用意する（上書きだけ。何も消さない）。 */
function prepareWorkDirectory(options, frontendRoot) {
  const workDir = options.workDir || path.join(os.tmpdir(), 'issue27-bundle-probe');
  fs.mkdirSync(workDir, { recursive: true });
  const probeApp = path.join(__dirname, 'bundle_probe');
  fs.cpSync(probeApp, workDir, { recursive: true, force: true });
  for (const root of COPIED_ROOTS) {
    fs.cpSync(path.join(frontendRoot, root), path.join(workDir, root), { recursive: true, force: true });
  }
  const link = path.join(workDir, 'node_modules');
  if (!fs.existsSync(link)) {
    fs.symlinkSync(path.join(frontendRoot, 'node_modules'), link, 'dir');
  }
  return workDir;
}

function nextBinary(workDir) {
  return path.join(workDir, 'node_modules', 'next', 'dist', 'bin', 'next');
}

function runBuild(workDir) {
  const started = Date.now();
  const result = spawnSync(process.execPath, [nextBinary(workDir), 'build'], {
    cwd: workDir,
    env: { ...process.env, NEXT_TELEMETRY_DISABLED: '1' },
    encoding: 'utf8',
    timeout: 240000,
    maxBuffer: 16 * 1024 * 1024,
  });
  return { ok: result.status === 0, seconds: (Date.now() - started) / 1000, output: `${result.stdout || ''}${result.stderr || ''}` };
}

/** next start / next dev を起動し、Ready まで待つ。プロセスグループごと終了できる stop を返す。 */
async function startServer(workDir, mode, port) {
  const child = spawn(process.execPath, [nextBinary(workDir), mode, '-p', String(port)], {
    cwd: workDir,
    env: { ...process.env, NEXT_TELEMETRY_DISABLED: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  });
  let log = '';
  child.stdout.on('data', (data) => (log += data));
  child.stderr.on('data', (data) => (log += data));
  const stop = () => {
    try {
      process.kill(-child.pid, 'SIGTERM');
    } catch (error) {
      // すでに終了している
    }
  };
  const deadline = Date.now() + SERVER_READY_TIMEOUT_MS;
  while (!/Ready/.test(log) && Date.now() < deadline && child.exitCode === null) {
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  if (!/Ready/.test(log)) {
    stop();
    throw new Error(`next ${mode} did not become ready: ${log.slice(-600)}`);
  }
  return { stop, log: () => log };
}

async function exercise(browser, url) {
  const page = await browser.newPage();
  const errors = [];
  const failed = [];
  const workers = [];
  page.on('pageerror', (error) => errors.push(String(error && error.message).slice(0, 200)));
  page.on('worker', (worker) => workers.push(worker.url()));
  page.on('response', (response) => {
    if (response.status() >= 400 && !/hmr|favicon/i.test(response.url())) {
      failed.push(`${response.status()} ${response.url().slice(0, 120)}`);
    }
  });
  await page.goto(url);
  await page.waitForFunction(() => {
    const element = document.querySelector('[data-testid=status]');
    return element !== null && element.textContent !== 'init';
  }, null, { timeout: PAGE_TIMEOUT_MS });
  const status = await page.textContent('[data-testid=status]');
  const stats = await page.evaluate(() => window.__probeStats || null);
  await page.close();
  return { status, stats, workers, errors, failed };
}

function judge(results, label, measured) {
  check(results, `${label}: ワーカーが起動し、PipelineClient.start が解決して、get_stats の応答が返る（状態 ready）`, measured.status === 'ready' && measured.stats !== null, JSON.stringify({ status: measured.status }));
  check(results, `${label}: get_stats の内容は、プレビューだけの状態（mode が preview・合成のフレーム数が数値）`, measured.stats !== null && measured.stats.mode === 'preview' && Number.isInteger(measured.stats.composedFrames), JSON.stringify(measured.stats));
  check(results, `${label}: バンドラーが別のワーカーのスクリプトとして出力し、ブラウザがワーカーとして起動した（ワーカーの URL を 1 つ以上観測）`, measured.workers.length >= 1, JSON.stringify(measured.workers.map((url) => url.replace(/^https?:\/\/[^/]+/, ''))));
  check(results, `${label}: 読み込みの失敗（HTTP 400 以上）・ページの未処理の例外が 0 件`, measured.failed.length === 0 && measured.errors.length === 0, JSON.stringify({ failed: measured.failed, errors: measured.errors }));
}

async function main() {
  const options = support.parseArguments(process.argv.slice(2), { only: 'all', workDir: null });
  const { frontendRoot, playwright } = support.loadTools(options);
  if (!fs.existsSync(nextBinary(frontendRoot))) {
    return support.unavailable(`Next.js が見つかりません（${frontendRoot}/node_modules）。scripts/dc.sh up -d --wait のあと、依存を導入してください`);
  }
  const workDir = prepareWorkDirectory(options, frontendRoot);
  console.log(`info 作業用のディレクトリ: ${workDir}`);
  const launchOptions = options.channel ? { channel: options.channel } : {};
  const results = [];
  let browser;
  try {
    browser = await playwright.chromium.launch(launchOptions);
  } catch (error) {
    return support.unavailable(`Chromium を起動できません（${String(error && error.message).split('\n')[0]}）`);
  }
  const servers = [];
  // timeout などで中断されたとき、起動したサーバーを残さない
  const abort = () => {
    for (const server of servers) {
      server.stop();
    }
    process.exit(support.EXIT_MISMATCH);
  };
  process.once('SIGTERM', abort);
  process.once('SIGINT', abort);
  try {
    if (options.only === 'all' || options.only === 'build') {
      console.log('--- 本番（next build + next start）');
      const build = runBuild(workDir);
      check(results, `next build が成功する（${build.seconds.toFixed(1)} 秒）`, build.ok, build.ok ? '' : build.output.slice(-800));
      if (build.ok) {
        const port = await freePort();
        const server = await startServer(workDir, 'start', port);
        servers.push(server);
        judge(results, '本番', await exercise(browser, `http://127.0.0.1:${port}/`));
        server.stop();
      }
    }
    if (options.only === 'all' || options.only === 'dev') {
      console.log('--- 開発（next dev）');
      const port = await freePort();
      const server = await startServer(workDir, 'dev', port);
      servers.push(server);
      judge(results, '開発', await exercise(browser, `http://localhost:${port}/`));
      server.stop();
    }
  } finally {
    for (const server of servers) {
      server.stop();
    }
    await browser.close();
  }
  support.finish(results, options, 'ワーカーのバンドルの確認');
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(support.EXIT_MISMATCH);
});
