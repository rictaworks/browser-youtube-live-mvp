'use strict';
// 実ブラウザ（Playwright の Chromium）で、能力検出（src/frontend/core/capability）を実測し、ブラウザの API を直接問い合わせた事実と突き合わせる。
// 事前確認と実測（WORK/factcheck/20261007_external-facts.md の項目 10〜12）を再現する：
//   - MediaStreamTrackProcessor は Window にあるが、ワーカー内では使えない。MediaStreamTrack は、ワーカーへ転送できない（DataCloneError）
//   - メインスレッドで作った MediaStreamTrackProcessor の readable（VideoFrame のストリーム）は、ワーカーへ転送でき、ワーカーで VideoFrame を読める
//   - H.264（Main・Constrained Baseline）の VideoEncoder.isConfigSupported。AAC-LC の AudioEncoder.isConfigSupported（Linux の Chromium では偽が設計どおり）
//   - タブ間の排他（TabLockGuard）を、本物の navigator.locks（Web Locks API）で、同じオリジンの複数のタブ（ページ）から確かめる。タブを閉じると、ロックは自動で解放される
// core の TypeScript は、リポジトリの TypeScript で、その場で JavaScript にして、ローカルの HTTP サーバー（127.0.0.1）から、ページへ配る（ビルド成果物を作らない）。
//
// 使い方: node probe_capabilities.cjs --repo <リポジトリのルート> [--playwright-dir <Playwright を導入したディレクトリ>] [--channel <chrome|msedge>] [--json]
//   Playwright の場所：--playwright-dir、または環境変数 ISSUE24_PLAYWRIGHT_DIR（その下の node_modules/playwright）、または src/frontend/node_modules/playwright
//   ブラウザの場所：Playwright の既定（~/.cache/ms-playwright）、または環境変数 PLAYWRIGHT_BROWSERS_PATH
//   --channel（または環境変数 ISSUE24_BROWSER_CHANNEL）：Playwright の Chromium の代わりに、インストール済みの Google Chrome（chrome）・Microsoft Edge（msedge）を使う。
//     Windows・macOS の Chrome で、AAC のエンコードを実際に確認するために使う（Linux の Chrome・Chromium では、AAC は使えない）
// 終了コード: 0 = すべて一致 / 1 = 食い違いがある / 3 = 確認できなかった（Playwright・Chromium・TypeScript が無い）。3 は成功ではない

const fs = require('fs');
const http = require('http');
const path = require('path');

const EXIT_OK = 0;
const EXIT_MISMATCH = 1;
const EXIT_UNAVAILABLE = 3;

function parseArguments(argv) {
  const options = { repo: null, playwrightDir: process.env.ISSUE24_PLAYWRIGHT_DIR || null, channel: process.env.ISSUE24_BROWSER_CHANNEL || null, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--repo') {
      options.repo = argv[(index += 1)];
    } else if (argument === '--playwright-dir') {
      options.playwrightDir = argv[(index += 1)];
    } else if (argument === '--channel') {
      options.channel = argv[(index += 1)];
    } else if (argument === '--json') {
      options.json = true;
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!options.repo) {
    throw new Error('--repo is required');
  }
  return options;
}

function unavailable(reason) {
  console.log(`SKIP 確認できなかった: ${reason}`);
  process.exit(EXIT_UNAVAILABLE);
}

function loadModule(label, candidates) {
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch (error) {
      if (error && error.code !== 'MODULE_NOT_FOUND') {
        throw error;
      }
    }
  }
  return unavailable(`${label} が見つかりません（探した場所: ${candidates.join(', ')}）`);
}

// ---------------------------------------------------------------------------
// core の TypeScript を、その場で JavaScript にして配るサーバー
// ---------------------------------------------------------------------------

function createServer(ts, coreRoot) {
  function rewriteImports(javascript, directory) {
    return javascript.replace(/(\bfrom\s+["'])(\.{1,2}\/[^"']*)(["'])/g, (_match, head, specifier, tail) => {
      const base = path.resolve(directory, specifier);
      if (fs.existsSync(`${base}.ts`)) {
        return `${head}${specifier}.js${tail}`;
      }
      if (fs.existsSync(path.join(base, 'index.ts'))) {
        return `${head}${specifier.replace(/\/$/, '')}/index.js${tail}`;
      }
      throw new Error(`unresolved import ${specifier} in ${directory}`);
    });
  }

  function transpile(file) {
    const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      fileName: file,
      compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2020, isolatedModules: true },
    });
    return rewriteImports(output.outputText, path.dirname(file));
  }

  const page = [
    '<!doctype html><meta charset="utf-8"><title>issue24 capability probe</title>',
    '<script type="module">',
    '  import { readBrowserCapabilities, evaluateCapabilities, WORKER_PROBE_TIMEOUT_MS } from "/core/capability/index.js";',
    '  import { TabLockGuard } from "/core/tablock/index.js";',
    '  window.__issue24 = { readBrowserCapabilities, evaluateCapabilities, WORKER_PROBE_TIMEOUT_MS, TabLockGuard };',
    '  window.__issue24Ready = true;',
    '</script>',
  ].join('\n');

  return http.createServer((request, response) => {
    try {
      const url = new URL(request.url, 'http://127.0.0.1');
      if (url.pathname === '/') {
        response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        response.end(page);
        return;
      }
      if (url.pathname === '/csp') {
        // worker-src を同じオリジンだけにする（blob: を許さない）。Blob URL のワーカーは、禁止される
        response.writeHead(200, {
          'content-type': 'text/html; charset=utf-8',
          'content-security-policy': "default-src 'self'; script-src 'self' 'unsafe-inline'; worker-src 'self'",
        });
        response.end(page);
        return;
      }
      const match = /^\/core\/(.+)\.js$/.exec(url.pathname);
      const source = match ? path.resolve(coreRoot, `${match[1]}.ts`) : null;
      if (!source || !source.startsWith(coreRoot + path.sep) || !fs.existsSync(source)) {
        response.writeHead(404, { 'content-type': 'text/plain' });
        response.end('not found');
        return;
      }
      response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
      response.end(transpile(source));
    } catch (error) {
      response.writeHead(500, { 'content-type': 'text/plain' });
      response.end(String(error && error.stack ? error.stack : error));
    }
  });
}

// ---------------------------------------------------------------------------
// ページの中で実行する、独立した実測（core を使わず、ブラウザへ直接問い合わせる）
// ---------------------------------------------------------------------------

async function measureInPage() {
  const withTimeout = (promise, label, milliseconds = 10000) =>
    Promise.race([promise, new Promise((_resolve, reject) => setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds))]);
  const startWorker = (source) => {
    const url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    return { worker: new Worker(url), url };
  };
  const ask = (source, message, transfer) =>
    withTimeout(
      new Promise((resolve, reject) => {
        const { worker, url } = startWorker(source);
        worker.onmessage = (event) => {
          worker.terminate();
          URL.revokeObjectURL(url);
          resolve(event.data);
        };
        worker.onerror = (event) => {
          worker.terminate();
          URL.revokeObjectURL(url);
          reject(new Error(`worker error: ${event.message}`));
        };
        worker.postMessage(message, transfer || []);
      }),
      'worker',
    );

  const raw = {};
  raw.window = {
    MediaStreamTrackProcessor: typeof MediaStreamTrackProcessor,
    AudioWorkletNode: typeof AudioWorkletNode,
    WebSocket: typeof WebSocket,
    getDisplayMedia: typeof (navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia),
    locks: typeof (navigator.locks && navigator.locks.request),
  };

  // ワーカー内の可否（MediaStreamTrackProcessor・OffscreenCanvas・VideoFrame）
  raw.worker = await ask(
    'self.onmessage = () => self.postMessage({ MediaStreamTrackProcessor: typeof MediaStreamTrackProcessor, OffscreenCanvas: typeof OffscreenCanvas, VideoFrame: typeof VideoFrame });',
    'probe',
  );

  // MediaStreamTrack の転送可否と、メインで作った MediaStreamTrackProcessor の readable をワーカーへ転送して、ワーカーで VideoFrame を読めるか
  raw.trackTransfer = 'not-measured';
  raw.processorReadableToWorker = 'not-measured';
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ video: true });
    const track = stream.getVideoTracks()[0];
    const { worker, url } = startWorker('self.onmessage = () => self.postMessage("received")');
    try {
      worker.postMessage({ track }, [track]);
      raw.trackTransfer = 'transferred';
    } catch (error) {
      raw.trackTransfer = error && error.name ? error.name : 'error';
    }
    worker.terminate();
    URL.revokeObjectURL(url);

    if (typeof MediaStreamTrackProcessor === 'function') {
      const processor = new MediaStreamTrackProcessor({ track: stream.getVideoTracks()[0].clone() });
      const readable = processor.readable;
      const frame = await ask(
        'self.onmessage = async (event) => { const reader = event.data.readable.getReader(); const { value } = await reader.read(); self.postMessage({ width: value.displayWidth, height: value.displayHeight, type: typeof value.close }); value.close(); await reader.cancel(); };',
        { readable },
        [readable],
      );
      raw.processorReadableToWorker = frame;
    }
    stream.getTracks().forEach((candidate) => candidate.stop());
  } catch (error) {
    raw.trackTransfer = raw.trackTransfer === 'not-measured' ? `error:${error && error.name}` : raw.trackTransfer;
    raw.processorReadableToWorker = `error:${error && error.name}:${error && error.message}`;
  }

  // 素の ReadableStream の転送（structuredClone と、実際のワーカーへの postMessage）
  try {
    const stream = new ReadableStream();
    structuredClone(stream, { transfer: [stream] });
    raw.structuredCloneReadable = true;
  } catch (error) {
    raw.structuredCloneReadable = error && error.name ? error.name : 'error';
  }

  // エンコーダ（11.7 の設定。Main・Constrained Baseline を、720p・480p で）
  const videoConfig = (codec, width, height, bitrate) => ({
    codec, width, height, bitrate, framerate: 30, bitrateMode: 'constant', latencyMode: 'realtime', avc: { format: 'avc' },
  });
  const ask1 = async (encoder, config) => {
    try {
      const answer = await encoder.isConfigSupported(config);
      return answer.supported === true;
    } catch (error) {
      return `error:${error && error.name}`;
    }
  };
  raw.video = {};
  if (typeof VideoEncoder === 'function') {
    for (const [codec, label] of [['avc1.4D401F', 'main'], ['avc1.42E01F', 'baseline']]) {
      raw.video[`${label}_720p`] = await ask1(VideoEncoder, videoConfig(codec, 1280, 720, 4500000));
      raw.video[`${label}_480p`] = await ask1(VideoEncoder, videoConfig(codec, 854, 480, 1500000));
    }
  }
  raw.audio = {};
  if (typeof AudioEncoder === 'function') {
    raw.audio.aac = await ask1(AudioEncoder, { codec: 'mp4a.40.2', sampleRate: 44100, numberOfChannels: 2, bitrate: 128000, aac: { format: 'aac' } });
    raw.audio.opus = await ask1(AudioEncoder, { codec: 'opus', sampleRate: 48000, numberOfChannels: 2, bitrate: 128000 });
  }

  // 実際の検出（core）
  const before = performance.now();
  const report = await window.__issue24.readBrowserCapabilities(window);
  const elapsedMilliseconds = Math.round(performance.now() - before);
  const evaluation = window.__issue24.evaluateCapabilities(report);

  return { raw, report, evaluation, elapsedMilliseconds, userAgent: navigator.userAgent, workerProbeTimeoutMilliseconds: window.__issue24.WORKER_PROBE_TIMEOUT_MS };
}

// ---------------------------------------------------------------------------
// 突き合わせ
// ---------------------------------------------------------------------------

function check(results, label, condition, detail) {
  results.push({ label, ok: Boolean(condition), detail });
  console.log(`${condition ? 'ok  ' : 'FAIL'} ${label}${detail === undefined ? '' : `（${detail}）`}`);
}

function expectedVideoCodec(video) {
  if (video.main_720p === true && video.main_480p === true) {
    return 'avc1.4D401F';
  }
  if (video.baseline_720p === true && video.baseline_480p === true) {
    return 'avc1.42E01F';
  }
  return null;
}

function compare(measured, platform) {
  const { raw, report, evaluation } = measured;
  const results = [];

  check(results, 'MediaStreamTrackProcessor は Window にある（Chromium の実測）', raw.window.MediaStreamTrackProcessor === 'function', raw.window.MediaStreamTrackProcessor);
  check(results, '検出：trackProcessorInWindow が、Window の実測と一致する', report.frameCapture.trackProcessorInWindow === (raw.window.MediaStreamTrackProcessor === 'function'));
  check(results, 'MediaStreamTrackProcessor は、ワーカー内では使えない（事前確認と実測の再現）', raw.worker.MediaStreamTrackProcessor === 'undefined', raw.worker.MediaStreamTrackProcessor);
  check(results, 'MediaStreamTrack は、ワーカーへ転送できない（DataCloneError。事前確認と実測の再現）', raw.trackTransfer === 'DataCloneError', raw.trackTransfer);
  check(
    results,
    'メインで作った MediaStreamTrackProcessor の readable を、ワーカーへ転送し、ワーカーで VideoFrame を読める（#27 の構成）',
    raw.processorReadableToWorker && typeof raw.processorReadableToWorker === 'object' && raw.processorReadableToWorker.width > 0,
    JSON.stringify(raw.processorReadableToWorker),
  );
  check(results, '検出：readableStreamTransfer が、structuredClone の実測と一致する', report.frameCapture.readableStreamTransfer === (raw.structuredCloneReadable === true), String(raw.structuredCloneReadable));
  check(results, '検出：offscreenCanvasInWorker が、ワーカー内の実測と一致する', report.frameCapture.offscreenCanvasInWorker === (raw.worker.OffscreenCanvas === 'function'), raw.worker.OffscreenCanvas);
  check(results, '検出：videoFrameInWorker が、ワーカー内の実測と一致する', report.frameCapture.videoFrameInWorker === (raw.worker.VideoFrame === 'function'), raw.worker.VideoFrame);
  check(results, '検出：audioWorklet・webSocket・screenCapture・tabLock が、Window の実測と一致する',
    report.audioWorklet === (raw.window.AudioWorkletNode === 'function') &&
      report.webSocket === (raw.window.WebSocket === 'function') &&
      report.screenCapture === (raw.window.getDisplayMedia === 'function') &&
      report.tabLock === (raw.window.locks === 'function'),
    JSON.stringify(raw.window));

  const expectedCodec = expectedVideoCodec(raw.video);
  check(results, '検出：videoCodec が、isConfigSupported の実測（Main -> Constrained Baseline、両プロファイル）から導いた値と一致する', report.videoCodec === expectedCodec, `${report.videoCodec} / ${JSON.stringify(raw.video)}`);
  check(results, '検出：aacEncode が、AudioEncoder.isConfigSupported（mp4a.40.2）の実測と一致する', report.aacEncode === (raw.audio.aac === true), JSON.stringify(raw.audio));
  check(results, '検出：判定できなかった検査（failures）が無い', report.failures.length === 0, JSON.stringify(report.failures));

  const expectedMissing = [];
  if (expectedCodec === null) expectedMissing.push('h264_encode');
  if (raw.audio.aac !== true) expectedMissing.push('aac_encode');
  if (!(raw.window.MediaStreamTrackProcessor === 'function' && raw.structuredCloneReadable === true && raw.worker.OffscreenCanvas === 'function' && raw.worker.VideoFrame === 'function')) expectedMissing.push('worker_frame_capture');
  if (raw.window.AudioWorkletNode !== 'function') expectedMissing.push('audio_processing');
  if (raw.window.WebSocket !== 'function') expectedMissing.push('websocket');
  check(results, '評価：開始に必須で不足している能力が、実測から導いた集合と一致する。canStart は、不足が無いときだけ真', JSON.stringify(evaluation.missingRequired) === JSON.stringify(expectedMissing) && evaluation.canStart === (expectedMissing.length === 0), JSON.stringify(evaluation));

  if (platform === 'linux') {
    check(results, 'Linux の Chromium：AAC は使えない（設計どおり）。aacEncode は偽、canStart は偽（配信の開始を提供しない）', report.aacEncode === false && evaluation.canStart === false && evaluation.missingRequired.includes('aac_encode'), `aac=${raw.audio.aac}`);
  } else {
    console.log(`info ${platform}：AAC の可否は、この環境の実測のとおり（${raw.audio.aac}）。Linux 以外では、期待値を固定しない（Windows・macOS の Chrome では、AAC を使えるのが期待）`);
  }
  return results;
}

// ---------------------------------------------------------------------------
// タブ間の排他（本物の Web Locks。同じオリジンの複数のページ）
// ---------------------------------------------------------------------------

async function measureTabLock(browser, base) {
  const context = await browser.newContext();
  const open = async () => {
    const page = await context.newPage();
    await page.goto(base);
    await page.waitForFunction(() => window.__issue24Ready === true, null, { timeout: 30000 });
    return page;
  };
  const acquire = (page) =>
    page.evaluate(async () => {
      if (!window.__guard) {
        window.__guard = new window.__issue24.TabLockGuard(navigator.locks);
      }
      const result = await window.__guard.acquire();
      return { result, held: window.__guard.isHeld };
    });
  const release = (page) => page.evaluate(async () => { await window.__guard.release(); return window.__guard.isHeld; });

  const measured = {};
  const tabA = await open();
  const tabB = await open();
  measured.firstTab = await acquire(tabA);
  measured.secondTab = await acquire(tabB);
  measured.heldAfterRelease = await release(tabA);
  measured.secondTabAfterRelease = await acquire(tabB);
  measured.releaseTwice = await tabA.evaluate(async () => { await window.__guard.release(); await window.__guard.release(); return 'ok'; });

  // タブ B を、解放せずに閉じる（タブを閉じる・クラッシュ）。ブラウザがロックを解放するので、別のタブが取得できる（解放は非同期なので、少し待って確かめる）
  await tabB.close();
  measured.afterTabClosed = { result: null, held: false };
  for (let attempt = 0; attempt < 50 && measured.afterTabClosed.result !== true; attempt += 1) {
    measured.afterTabClosed = await acquire(tabA);
    if (measured.afterTabClosed.result !== true) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  await release(tabA);

  // ロック API が無い環境（navigator.locks を渡さない）
  measured.unsupported = await tabA.evaluate(async () => {
    const guard = new window.__issue24.TabLockGuard(undefined);
    return { result: await guard.acquire(), held: guard.isHeld };
  });
  await context.close();
  return measured;
}

// ---------------------------------------------------------------------------
// CSP でワーカー（Blob URL）が禁じられた環境でも、検出が終わり、能力なし（拒否側）になること
// ---------------------------------------------------------------------------

async function measureWithBlockedWorkers(browser, base) {
  const page = await browser.newPage();
  await page.goto(`${base}csp`);
  await page.waitForFunction(() => window.__issue24Ready === true, null, { timeout: 30000 });
  const measured = await page.evaluate(async () => {
    const before = performance.now();
    const report = await window.__issue24.readBrowserCapabilities(window);
    return { report, evaluation: window.__issue24.evaluateCapabilities(report), elapsedMilliseconds: Math.round(performance.now() - before), limit: window.__issue24.WORKER_PROBE_TIMEOUT_MS };
  });
  await page.close();
  return measured;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const repo = path.resolve(options.repo);
  const coreRoot = path.join(repo, 'src', 'frontend', 'core');
  if (!fs.existsSync(path.join(coreRoot, 'capability', 'readBrowserCapabilities.ts'))) {
    throw new Error(`core/capability が見つかりません: ${coreRoot}`);
  }

  const ts = loadModule('TypeScript', [path.join(repo, 'src', 'frontend', 'node_modules', 'typescript')]);
  const playwrightCandidates = [];
  if (options.playwrightDir) {
    playwrightCandidates.push(path.join(path.resolve(options.playwrightDir), 'node_modules', 'playwright'));
  }
  playwrightCandidates.push(path.join(repo, 'src', 'frontend', 'node_modules', 'playwright'));
  const { chromium } = loadModule('Playwright（npm の playwright）', playwrightCandidates);

  const server = createServer(ts, coreRoot);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  let browser;
  try {
    try {
      const launchOptions = { args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required'] };
      if (options.channel) {
        launchOptions.channel = options.channel;
      }
      browser = await chromium.launch(launchOptions);
    } catch (error) {
      server.close();
      return unavailable(`ブラウザを起動できません（${String(error && error.message).split('\n')[0]}）。npx playwright install chromium で導入するか、--channel でインストール済みのブラウザを指定してください`);
    }
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', (error) => pageErrors.push(String(error)));
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.waitForFunction(() => window.__issue24Ready === true, null, { timeout: 30000 });
    const version = browser.version();
    const measured = await page.evaluate(measureInPage);
    console.log(`ブラウザ: ${options.channel || 'Playwright の Chromium'} ${version}（${process.platform}）`);
    if (options.json) {
      console.log(JSON.stringify(measured, null, 2));
    }
    console.log(`検出にかかった時間: ${measured.elapsedMilliseconds} ms（ワーカーの応答の期限は ${measured.workerProbeTimeoutMilliseconds} ms）`);
    const results = compare(measured, process.platform);

    const locks = await measureTabLock(browser, `http://127.0.0.1:${port}/`);
    if (options.json) {
      console.log(JSON.stringify({ tabLock: locks }, null, 2));
    }
    check(results, '本物の Web Locks：最初のタブが取得できる（true）', locks.firstTab.result === true && locks.firstTab.held === true, JSON.stringify(locks.firstTab));
    check(results, '本物の Web Locks：別のタブは取得できない（false。二重開始の試行）。保持していない', locks.secondTab.result === false && locks.secondTab.held === false, JSON.stringify(locks.secondTab));
    check(results, '本物の Web Locks：最初のタブが解放すると、保持していない状態になり、別のタブが取得できる', locks.heldAfterRelease === false && locks.secondTabAfterRelease.result === true, JSON.stringify([locks.heldAfterRelease, locks.secondTabAfterRelease]));
    check(results, '本物の Web Locks：release() を何度呼んでも、例外にならない', locks.releaseTwice === 'ok');
    check(results, '本物の Web Locks：保持しているタブを、解放せずに閉じると、ブラウザがロックを解放し、別のタブが取得できる', locks.afterTabClosed.result === true, JSON.stringify(locks.afterTabClosed));
    check(results, 'ロック API を渡さなければ "unsupported"（成功でも失敗でもない）。保持していない', locks.unsupported.result === 'unsupported' && locks.unsupported.held === false, JSON.stringify(locks.unsupported));

    const blocked = await measureWithBlockedWorkers(browser, `http://127.0.0.1:${port}/`);
    if (options.json) {
      console.log(JSON.stringify({ blockedWorkers: blocked }, null, 2));
    }
    check(
      results,
      'CSP でワーカー（Blob URL）が禁じられた環境：検出は、応答の期限（ワーカーの応答待ち）より前に終わり、ワーカー内の可否は偽（拒否側）。失敗（worker_probe）を 1 件記録し、他の検査は影響を受けない',
      blocked.elapsedMilliseconds < blocked.limit &&
        blocked.report.frameCapture.offscreenCanvasInWorker === false &&
        blocked.report.frameCapture.videoFrameInWorker === false &&
        blocked.report.failures.length === 1 &&
        blocked.report.failures[0].probe === 'worker_probe' &&
        blocked.report.videoCodec === measured.report.videoCodec &&
        blocked.report.audioWorklet === measured.report.audioWorklet,
      JSON.stringify({ failures: blocked.report.failures, elapsedMilliseconds: blocked.elapsedMilliseconds }),
    );
    check(results, 'CSP でワーカーが禁じられた環境：評価は、ワーカー上のフレーム取得が不足（worker_frame_capture）で、開始を提供しない', blocked.evaluation.canStart === false && blocked.evaluation.missingRequired.includes('worker_frame_capture'), JSON.stringify(blocked.evaluation.missingRequired));
    check(results, 'ページの実行中に、捕まえていない例外が無い', pageErrors.length === 0, pageErrors.join(' / '));
    const failed = results.filter((result) => !result.ok).length;
    console.log(`${failed === 0 ? 'PASS' : 'FAIL'} 実ブラウザの検証（能力検出・タブ間の排他）：${results.length - failed} 件一致・${failed} 件の食い違い`);
    return failed === 0 ? EXIT_OK : EXIT_MISMATCH;
  } finally {
    if (browser) {
      await browser.close();
    }
    server.close();
  }
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.error(`FAIL ${error && error.stack ? error.stack : error}`);
    process.exit(EXIT_MISMATCH);
  },
);
