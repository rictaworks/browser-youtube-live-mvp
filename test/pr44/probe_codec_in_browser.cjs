'use strict';
// issue #25 の送信まわりの Domain Core（src/frontend/core の transport・queue・governor・probe・report）を、実ブラウザ（Playwright の Chromium）で動かして確かめる。
// core の TypeScript は、リポジトリの TypeScript でその場で JavaScript にして、ローカルの HTTP サーバー（127.0.0.1）からページへ配る（成果物のファイルは作らない）。
// 相手の中継は、Playwright の routeWebSocket による代役（このファイルの中。reference_frame.cjs の、独立した参照実装でフレームを読み書きする）。
//
//   1. 共有ベクタ（src/contracts/ws-frame-vectors.json）を、実ブラウザの TextEncoder・TextDecoder・DataView（BigInt）で通す
//   2. 実ブラウザの API の振る舞い：64 ビットの時刻の往復・不正な UTF-8 と BOM の拒否・Blob とテキストの拒否（WebSocket は binaryType = arraybuffer で使う）
//   3. 本物の WebSocket（Chromium）と、本物のタイマ（setTimeout・performance.now）で、一連の流れを通す：
//      接続通知（hello）-> 接続受理（accepted）-> 回線計測（UplinkProbe。3 秒間、ペース配分）-> プロファイルの選定 -> 開始通知（start）
//      -> 状態通知（確定待ち）-> 映像・音声（SendQueue を通す。バイト列まで、中継の代役の受信と一致）-> 受領応答（ack）-> 滞留時間の評価
//      -> 適応制御（BitrateGovernor）-> 状態報告（ReportBuilder -> report）-> 抑制指示・キーフレーム要求・状態通知・致命通知・テキストのメッセージ -> 終了通知（end）
//
// 使い方: node probe_codec_in_browser.cjs --repo <リポジトリのルート> [--playwright-dir <Playwright を導入したディレクトリ>] [--channel <chrome|msedge>]
//   Playwright の場所：--playwright-dir、または環境変数 ISSUE25_PLAYWRIGHT_DIR（その下の node_modules/playwright。または、その場所そのもの）、
//   または ISSUE24_PLAYWRIGHT_DIR（#24 の検査で導入したもの）、または src/frontend/node_modules/playwright。見つからなければ SKIP（終了コード 3。確認できなかったこと）。
// 終了コード: 0 = 問題なし / 1 = 食い違い / 3 = 確認できなかった（TypeScript・Playwright・ブラウザが無い）
//
// ここで確かめられないこと：実際の中継（Go。#20・#21）との結合、実際の YouTube への送出、AAC のエンコード（Linux の Chromium は AAC のエンコードを持たない）。

const fs = require('fs');
const http = require('http');
const path = require('path');
const { referenceControl, referenceDecode } = require('./reference_frame.cjs');

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_UNAVAILABLE = 3;

function parseArguments(argv) {
  const options = { repo: null, playwrightDir: process.env.ISSUE25_PLAYWRIGHT_DIR || null, channel: process.env.ISSUE25_BROWSER_CHANNEL || null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--repo') options.repo = argv[(index += 1)];
    else if (argv[index] === '--playwright-dir') options.playwrightDir = argv[(index += 1)];
    else if (argv[index] === '--channel') options.channel = argv[(index += 1)];
  }
  return options;
}

const options = parseArguments(process.argv.slice(2));
if (!options.repo || !fs.existsSync(path.join(path.resolve(options.repo), 'src', 'frontend', 'core'))) {
  console.error('使い方: node probe_codec_in_browser.cjs --repo <リポジトリのルート> [--playwright-dir <ディレクトリ>] [--channel <chrome|msedge>]');
  process.exit(EXIT_FINDINGS);
}
const repo = path.resolve(options.repo);
const coreRoot = path.join(repo, 'src', 'frontend', 'core');

function unavailable(reason) {
  console.log(`SKIP 確認できなかった: ${reason}`);
  process.exit(EXIT_UNAVAILABLE);
}

let ts;
try {
  ts = require(path.join(repo, 'src', 'frontend', 'node_modules', 'typescript'));
} catch (error) {
  unavailable('TypeScript（src/frontend/node_modules/typescript）が見つかりません。frontend の依存を導入してください');
}

function locatePlaywright() {
  const candidates = [];
  // #24 の実ブラウザの検査（test/pr40）で導入した Playwright も、使える（ISSUE24_PLAYWRIGHT_DIR）
  for (const directory of [options.playwrightDir, process.env.ISSUE24_PLAYWRIGHT_DIR]) {
    if (directory) {
      candidates.push(path.join(path.resolve(directory), 'node_modules', 'playwright'), path.resolve(directory));
    }
  }
  candidates.push(path.join(repo, 'src', 'frontend', 'node_modules', 'playwright'));
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch (error) {
      // 次の候補へ
    }
  }
  return null;
}

const playwright = locatePlaywright();
if (playwright === null) {
  unavailable('Playwright が見つかりません（--playwright-dir または ISSUE25_PLAYWRIGHT_DIR で、導入したディレクトリを指定してください。手順は README.md）');
}

// ---------------------------------------------------------------------------
// core の TypeScript を、ブラウザで読み込める形（window.__core）にする
// ---------------------------------------------------------------------------

const MODULE_DIRECTORIES = ['contract', 'clock', 'profile', 'transport', 'queue', 'governor', 'probe', 'report'];

function buildModulesScript() {
  const definitions = [];
  for (const directory of MODULE_DIRECTORIES) {
    for (const name of fs.readdirSync(path.join(coreRoot, directory)).sort()) {
      if (!name.endsWith('.ts') || name.endsWith('.test.ts')) continue;
      const file = path.join(coreRoot, directory, name);
      const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true },
        fileName: file,
      }).outputText;
      definitions.push(`${JSON.stringify(`${directory}/${name.slice(0, -3)}`)}: function (exports, require, module) {\n${output}\n}`);
    }
  }
  return `(function () {
  var definitions = {\n${definitions.join(',\n')}\n};
  var cache = {};
  function resolve(from, specifier) {
    var parts = from.split('/');
    parts.pop();
    specifier.split('/').forEach(function (segment) {
      if (segment === '.' || segment === '') return;
      if (segment === '..') parts.pop();
      else parts.push(segment);
    });
    var base = parts.join('/');
    if (definitions[base]) return base;
    if (definitions[base + '/index']) return base + '/index';
    throw new Error('module not found: ' + base + ' (from ' + from + ')');
  }
  function load(name) {
    if (cache[name]) return cache[name].exports;
    var module = { exports: {} };
    cache[name] = module;
    definitions[name](module.exports, function (specifier) { return load(resolve(name, specifier)); }, module);
    return module.exports;
  }
  window.__core = { load: function (directory) { return load(directory + '/index'); } };
})();`;
}

function locateContractsDir() {
  const candidates = [...new Set(['/contracts', path.resolve(process.cwd(), '../contracts'), path.resolve(process.cwd(), '../../contracts'), path.join(repo, 'src', 'contracts')])];
  const found = candidates.find((dir) => fs.existsSync(path.join(dir, 'enums.json')));
  if (found === undefined) {
    throw new Error(['契約のディレクトリが見つかりません。黙ってスキップせず、失敗します。探した場所:', ...candidates.map((dir) => `  - ${dir}`)].join('\n'));
  }
  return found;
}

// ---------------------------------------------------------------------------
// 中継の代役（routeWebSocket）。独立した参照実装でフレームを読み書きし、受けたものを記録する
// ---------------------------------------------------------------------------

function createRelayDouble() {
  const log = {
    ticket: undefined,
    probes: { count: 0, bytes: 0, firstAt: undefined },
    startBody: undefined,
    media: [],
    reports: [],
    endBody: undefined,
    protocolErrors: [],
    textFromBrowser: 0,
  };
  const timers = [];
  let latestVideoUs = BigInt(0);
  let latestAudioUs = BigInt(0);

  function handler(ws) {
    function send(data) {
      ws.send(data);
    }
    ws.onClose(() => {
      timers.forEach((timer) => clearInterval(timer));
    });
    ws.onMessage((message) => {
      if (typeof message === 'string') {
        log.textFromBrowser += 1;
        return;
      }
      const frame = referenceDecode(message, 'browser_to_relay');
      if (frame.error !== undefined) {
        log.protocolErrors.push(frame.error);
        return;
      }
      switch (frame.type) {
        case 'hello':
          log.ticket = frame.bodyBytes.toString('utf8');
          send(referenceControl('accepted', { state: 'reserved', resume: false, profile: null, limits: { time_limit_seconds: 3600 } }));
          break;
        case 'probe': {
          const now = Date.now();
          if (log.probes.firstAt === undefined) {
            log.probes.firstAt = now;
            // 最初の計測データから 3 秒後に、その間に受けた量から、結果を 1 回だけ返す（契約 5.2。メッセージ全体のバイト数 x 8 / 3,000 の切り捨て）
            timers.push(
              setTimeout(() => {
                send(referenceControl('probe_result', { throughput_kbps: Math.floor((log.probes.bytes * 8) / 3000) }));
              }, 3000),
            );
          }
          if (now - log.probes.firstAt < 3000) {
            log.probes.count += 1;
            log.probes.bytes += message.length;
          }
          break;
        }
        case 'start': {
          log.startBody = JSON.parse(frame.bodyBytes.toString('utf8'));
          send(referenceControl('status', { state: 'awaiting_media', watch_url: 'https://www.youtube.com/watch?v=dummyVideoId', warning: null, time_limit_notice_seconds: null, end_reason: null }));
          send(referenceControl('status', { state: 'confirming', watch_url: 'https://www.youtube.com/watch?v=dummyVideoId', warning: null, time_limit_notice_seconds: null, end_reason: null }));
          break;
        }
        case 'video':
        case 'audio': {
          const timestamp = BigInt(frame.timestamp);
          if (frame.type === 'video' && timestamp > latestVideoUs) latestVideoUs = timestamp;
          if (frame.type === 'audio' && timestamp > latestAudioUs) latestAudioUs = timestamp;
          log.media.push({ type: frame.type, timestamp: frame.timestamp, keyframe: frame.keyframe, hex: message.toString('hex') });
          if (log.media.length === 1) {
            // 受領応答は 500 ms 間隔（受けた最大のメディア時刻。契約 5.10）
            timers.push(
              setInterval(() => {
                send(referenceControl('ack', { video_us: Number(latestVideoUs), audio_us: Number(latestAudioUs) }));
              }, 500),
            );
          }
          break;
        }
        case 'report': {
          log.reports.push(JSON.parse(frame.bodyBytes.toString('utf8')));
          // 抑制指示・キーフレーム要求（本文が空）・状態通知・致命通知、そして、仕様にない、テキストのメッセージ
          send(referenceControl('throttle', { target_kbps: 3150 }));
          send(referenceControl('keyframe_request'));
          send(referenceControl('status', { state: 'live', watch_url: 'https://www.youtube.com/watch?v=dummyVideoId', warning: null, time_limit_notice_seconds: 300, end_reason: null }));
          send(referenceControl('fatal', { code: 'stale_epoch' }));
          send('this text message is not part of the protocol');
          break;
        }
        case 'end':
          log.endBody = JSON.parse(frame.bodyBytes.toString('utf8'));
          break;
        default:
          log.protocolErrors.push(`unexpected type ${frame.type}`);
      }
    });
  }
  return { log, handler, stop: () => timers.forEach((timer) => { clearTimeout(timer); clearInterval(timer); }) };
}

// ---------------------------------------------------------------------------
// 検査
// ---------------------------------------------------------------------------

async function main() {
  let contractsDir;
  try {
    contractsDir = locateContractsDir();
  } catch (error) {
    console.log(`FAIL ${error.message}`);
    return EXIT_FINDINGS;
  }
  const vectorsText = fs.readFileSync(path.join(contractsDir, 'ws-frame-vectors.json'), 'utf8');
  const modulesScript = buildModulesScript();
  const pageScript = fs.readFileSync(path.join(__dirname, 'browser_page.js'), 'utf8');

  const server = http.createServer((request, response) => {
    const routes = {
      '/': ['text/html; charset=utf-8', '<!doctype html><meta charset="utf-8"><title>issue25</title><body>issue25</body><script src="/modules.js"></script><script src="/page.js"></script>'],
      '/modules.js': ['text/javascript; charset=utf-8', modulesScript],
      '/page.js': ['text/javascript; charset=utf-8', pageScript],
    };
    const route = routes[request.url];
    if (route === undefined) {
      response.writeHead(404);
      response.end();
      return;
    }
    response.writeHead(200, { 'content-type': route[0], 'cache-control': 'no-store' });
    response.end(route[1]);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  let browser;
  try {
    browser = await playwright.chromium.launch({ headless: true, ...(options.channel ? { channel: options.channel } : {}) });
  } catch (error) {
    server.close();
    console.log(`SKIP 確認できなかった: ブラウザ（Chromium）を起動できません（${String(error.message).split('\n')[0].slice(0, 160)}）。手順は README.md`);
    return EXIT_UNAVAILABLE;
  }

  const relay = createRelayDouble();
  const problems = [];
  const lines = [];
  const expect = (condition, label, detail) => {
    if (condition) lines.push(`ok   ${label}`);
    else {
      lines.push(`FAIL ${label}${detail === undefined ? '' : `：${detail}`}`);
      problems.push(label);
    }
  };

  let outcome;
  try {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', (error) => pageErrors.push(String(error.message || error).slice(0, 200)));
    await page.routeWebSocket('ws://relay.test/ws', relay.handler);
    await page.goto(`http://127.0.0.1:${port}/`);
    const version = await page.evaluate(() => navigator.userAgent);
    console.log(`     ブラウザ：${version.replace(/^Mozilla\/5.0 \(([^)]*)\).*?(HeadlessChrome|Chrome)\/([0-9.]+).*$/, '$2 $3 ($1)')}`);
    outcome = await page.evaluate((vectorsJson) => window.runChecks(JSON.parse(vectorsJson)), vectorsText);
    expect(pageErrors.length === 0, 'ページ内で、捕まえられない例外が起きていない', pageErrors.join(' / '));
  } catch (error) {
    expect(false, '実ブラウザでの実行が完了した', String(error.message || error).split('\n')[0].slice(0, 300));
  } finally {
    relay.stop();
    await browser.close();
    server.close();
  }

  if (outcome !== undefined) {
    outcome.results.forEach((line) => lines.push(line));
    outcome.problems.forEach((label) => problems.push(label));
    const session = outcome.session;
    const { log } = relay;

    expect(log.ticket === 'dummy-ticket-0123456789abcdef', '接続通知（hello）の本文が、UTF-8 のチケットそのものとして、中継の代役に届いた');
    expect(session.accepted.state === 'reserved' && session.accepted.resume === false && session.accepted.profile === null && session.accepted.limits.time_limit_seconds === 3600, '接続受理（accepted）を、型付きで受けた');

    const probe = session.probe;
    expect(probe.sent >= 60 && probe.sent <= 68, `回線計測：3 秒の窓の中に、計測データを ${probe.sent} 個送った（計画は 68 個。タイマの遅れで減ることはあっても、増えない）`);
    expect(probe.firstOffsetMs >= 40 && probe.firstOffsetMs < 400, `回線計測：最初の送信は、窓の開始から ${Math.round(probe.firstOffsetMs)} ms 後`);
    expect(probe.lastOffsetMs < 3000, `回線計測：最後の送信は、窓の開始から ${Math.round(probe.lastOffsetMs)} ms 後（3,000 ms より前）`);
    expect(probe.elapsedMs >= 3000 && probe.elapsedMs < 3800, `回線計測：結果が返るまで ${Math.round(probe.elapsedMs)} ms（3 秒 + 往復の遅れ）`);
    expect(probe.throughputKbps >= 5000 && probe.throughputKbps <= 6000, `回線計測：中継の代役の規則（受けた量 x 8 / 3,000）で得た ${probe.throughputKbps} kbps（最大 6,000 kbps 相当を超えない）`);
    expect(probe.listenersLeft === 0, '回線計測：結果の受信の登録を、解除した');
    expect(log.probes.count >= 60 && log.probes.count <= 68 && log.probes.bytes === log.probes.count * (32768 + 17), `回線計測：中継の代役が受けた計測データ ${log.probes.count} 個は、1 個あたり 32,785 バイト（本文 32,768 + ヘッダ 17）`);

    expect(session.decision.kind === 'selected' && session.decision.profile === '720p', `プロファイルの選定：${probe.throughputKbps} kbps -> 標準（720p）`);
    expect(log.startBody !== undefined && log.startBody.profile === '720p' && log.startBody.video.codec === 'avc1.4D401F' && log.startBody.video.width === 1280 && log.startBody.video.bitrate_kbps === session.decision.startBitrateKbps && log.startBody.audio.sample_rate === 44100, '開始通知（start）が、選定したプロファイルの設定で届いた');
    expect(log.startBody !== undefined && Buffer.from(log.startBody.audio.description_b64, 'base64').toString('hex') === '1210', '開始通知の音声の復号器設定（base64）が、往復で 0x12 0x10');

    const sentMedia = session.media;
    const receivedMedia = log.media;
    expect(sentMedia.length > 100 && receivedMedia.length === sentMedia.length && sentMedia.every((frame, index) => frame.hex === receivedMedia[index].hex), `映像・音声 ${sentMedia.length} 件が、順序もバイト列も、中継の代役の受信と完全に一致した`);
    expect(receivedMedia.filter((frame) => frame.type === 'video').length === 60 && receivedMedia.filter((frame) => frame.keyframe).length === 1, '映像は 60 フレーム（30 fps x 2 秒）で、キーフレームは先頭の 1 つ');
    const videoTimes = receivedMedia.filter((frame) => frame.type === 'video').map((frame) => frame.timestamp);
    expect(videoTimes[1] === '33333' && videoTimes[2] === '66667' && videoTimes[30] === '1000000', '映像の時刻が、フレーム番号から算出した値（33,333・66,667・1,000,000 マイクロ秒）');
    const increasing = (type) => receivedMedia.filter((frame) => frame.type === type).every((frame, index, all) => index === 0 || BigInt(frame.timestamp) >= BigInt(all[index - 1].timestamp));
    expect(increasing('video') && increasing('audio'), '同じ種別の時刻が、逆行しない（中継が破棄するものが無い）');

    const governor = session.governor;
    expect(governor.ack.video_us > 0 && governor.ack.audio_us > 0, '受領応答（ack）を、型付きで受けた（映像・音声の最新の時刻）');
    expect(governor.backlogMs !== undefined && governor.backlogMs >= 0 && governor.backlogMs < 200, `滞留時間を評価した：${governor.backlogMs} ms（送信済みの最新の時刻 - 受領済みの古い方）`);
    expect(governor.reconnect === false, '適応制御：再接続の指示は無い');
    expect(log.reports.length === 1 && log.reports[0].backlog_ms === Math.round(governor.backlogMs) && log.reports[0].state === 'live' && log.reports[0].dropped_video_frames === 0 && log.reports[0].target_kbps === governor.targetKbps, '状態報告（report）が、中継の代役に届き、本文が、組み立てた値と一致した');
    expect(JSON.stringify(log.reports[0].events.map((event) => event.kind)) === JSON.stringify(governor.events.map((event) => event.kind)), `状態報告の出来事が、適応制御の出来事と一致した（${log.reports[0].events.map((event) => event.kind).join(', ') || 'なし'}）`);

    expect(session.throttle.target_kbps === 3150, '抑制指示（throttle）を、型付きで受けた');
    expect(session.keyframeRequest.type === 'keyframe_request' && !('body' in session.keyframeRequest), 'キーフレーム要求（本文が空）を受けた');
    expect(session.fatal.code === 'stale_epoch', '致命通知（fatal）を、型付きで受けた');
    expect(session.received.includes('error:invalid_message:string'), 'テキストのメッセージは、復号されず、invalid_message として扱われた（接続は維持される）');
    expect(log.endBody !== undefined && log.endBody.reason === 'user_stop', '終了通知（end）が届いた');
    expect(log.protocolErrors.length === 0 && log.textFromBrowser === 0, 'ブラウザが送ったメッセージは、すべてバイナリで、参照実装の検証（4 章の 7 種）を通った', log.protocolErrors.join(', '));
  }

  lines.forEach((line) => console.log(line));
  if (problems.length > 0) {
    console.log(`FAIL ${problems.length} 件の食い違いがあります`);
    return EXIT_FINDINGS;
  }
  return EXIT_OK;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.log(`FAIL 実行中の例外: ${String((error && error.stack) || error).slice(0, 600)}`);
    process.exit(EXIT_FINDINGS);
  },
);
