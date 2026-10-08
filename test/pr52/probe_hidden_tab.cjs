'use strict';
// 配信中にタブが非表示になっても、合成・符号化が止まらないことを、実ブラウザで測る（issue #27。requirements.md 11.6・13.1・27）。
//
// Playwright は、ページを常に表示中として扱う（可視状態を模擬する）ため、タブを本当には非表示にできない。そこで、このスクリプトは、ブラウザを自分で起動し
// （有頭。Linux では仮想ディスプレイ Xvfb の中）、生の CDP（Chrome DevTools Protocol）でタブを操作する。別のタブを前面にすると、配信中のタブの
// document.visibilityState が hidden になる（実測で確認）。ブラウザの既定の動作（タイマの間引き・背景のレンダラーの優先度の引き下げ）をそのまま受ける
// （Playwright の既定の起動引数にある --disable-background-timer-throttling などは付けない）。
//
//   1. 配信を始める（偽のカメラ + 合成の画面共有 -> 合成 -> 実際の H.264。音声は疑似の AAC）。タブは表示中。表示中の基準を測る
//   2. 別のタブを前面にして、配信中のタブを非表示にする。--hidden-seconds の間、窓（--sample-seconds）ごとに、チャンクの数・到着の間隔・
//      ワーカーの統計・メディアクロックを記録する
//   3. 配信中のタブを前面に戻して、続けて測る
//   判定: 非表示の間も、映像が約 30 fps・音声が約 43.07 チャンク/秒で届き、メディアクロックが実時間に追従し、故障・停止・時刻の逆行が無いこと
//
// 計測の用具: 画面共有の代わりの合成のトラックは、メインスレッドのタイマで描く。非表示のタブでは、タイマが間引かれて（約 1 秒に 1 回）更新が減る。
// 製品の経路（音声のブロック -> ワーカー -> 合成 -> 符号化 -> チャンク）は、メインスレッドのタイマに依存しない。カメラ（偽のデバイス）は毎秒 30 フレーム届く。
//
// 使い方: node probe_hidden_tab.cjs --repo <リポジトリのルート> [--playwright-dir <Playwright を導入したディレクトリ>] [--hidden-seconds 30] [--visible-seconds 8]
//         [--after-seconds 8] [--sample-seconds 5] [--profile 480p|720p] [--with-screen 1|0] [--browser-path <ブラウザの実行ファイル>] [--display auto|xvfb|current] [--fake-audio-output 1|0] [--work-dir <作業用>]
// 5 分以上の測定: --hidden-seconds 330（約 6 分かかる。run_all.sh は、環境変数 ISSUE27_HIDDEN_SECONDS で渡せる）
// 終了コード: 0 = すべて確認できた / 1 = 食い違い / 3 = 確認できなかった（ブラウザ・仮想ディスプレイ・Node の WebSocket が無い）。3 は成功ではない

const fs = require('fs');
const http = require('http');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const support = require('./browser_support.cjs');

const { check } = support;
const AUDIO_CHUNKS_PER_SECOND = 44100 / 1024;
const PAGE_HTML = [
  '<!doctype html><meta charset="utf-8"><title>issue27 hidden tab probe</title>',
  '<canvas id="preview" width="1280" height="720" style="width:640px;height:360px"></canvas>',
  '<script type="module" src="/probe/page.js"></script>',
].join('\n');

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

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

function httpRequest(method, url) {
  return new Promise((resolve, reject) => {
    const request = http.request(url, { method }, (response) => {
      let body = '';
      response.on('data', (chunk) => (body += chunk));
      response.on('end', () => resolve(body));
    });
    request.on('error', reject);
    request.end();
  });
}

async function waitForDebugger(port) {
  for (let attempt = 0; attempt < 150; attempt += 1) {
    try {
      return JSON.parse(await httpRequest('GET', `http://127.0.0.1:${port}/json/version`));
    } catch (error) {
      await sleep(100);
    }
  }
  throw new Error('the browser did not open its debugging port');
}

/** 生の CDP のクライアント（Node の WebSocket）。 */
async function connect(webSocketUrl) {
  const socket = new WebSocket(webSocketUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve);
    socket.addEventListener('error', () => reject(new Error('cannot connect to the debugging socket')));
  });
  let nextId = 1;
  const pending = new Map();
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) {
        reject(new Error(JSON.stringify(message.error)));
      } else {
        resolve(message.result);
      }
    }
  });
  return {
    send: (method, params = {}) =>
      new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        socket.send(JSON.stringify({ id, method, params }));
      }),
    close: () => socket.close(),
  };
}

async function evaluate(cdp, expression, timeoutMilliseconds = 60000) {
  const call = cdp.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  const timeout = new Promise((_resolve, reject) => setTimeout(() => reject(new Error(`evaluate timed out after ${timeoutMilliseconds} ms: ${expression.slice(0, 60)}`)), timeoutMilliseconds));
  const result = await Promise.race([call, timeout]);
  if (result.exceptionDetails) {
    const description = result.exceptionDetails.exception && result.exceptionDetails.exception.description ? result.exceptionDetails.exception.description : JSON.stringify(result.exceptionDetails.text);
    throw new Error(`page exception: ${String(description).split('\n')[0]}`);
  }
  return result.result.value;
}

/** X の抽象ソケット（@/tmp/.X11-unix/X<番号>）が、待ち受け中か。/tmp/.X11-unix が読み取り専用の環境（WSLg など）では、Xvfb は、ファイルのソケットを作れず、抽象ソケットだけで動く。 */
function abstractSocketListening(number) {
  try {
    return fs.readFileSync('/proc/net/unix', 'utf8').includes(`@/tmp/.X11-unix/X${number}`);
  } catch (error) {
    return false;
  }
}

/** 空いているディスプレイ番号を探す（既存の X サーバー・WSLg のソケットとロックを避けるため、90 番台から）。 */
function findFreeDisplayNumber() {
  for (let number = 90; number < 190; number += 1) {
    if (!fs.existsSync(`/tmp/.X11-unix/X${number}`) && !fs.existsSync(`/tmp/.X${number}-lock`) && !abstractSocketListening(number)) {
      return number;
    }
  }
  throw new Error('no free X display number between 90 and 189');
}

/** 仮想ディスプレイ（Xvfb）を起動し、待ち受けが始まるまで待つ。 */
async function startXvfb() {
  const number = findFreeDisplayNumber();
  const child = spawn('Xvfb', [`:${number}`, '-screen', '0', '1280x800x24', '-nolisten', 'tcp'], { stdio: 'ignore' });
  let exited = false;
  child.on('exit', () => {
    exited = true;
  });
  child.on('error', () => {
    exited = true;
  });
  const listening = () => fs.existsSync(`/tmp/.X11-unix/X${number}`) || abstractSocketListening(number);
  for (let attempt = 0; attempt < 100 && !exited && !listening(); attempt += 1) {
    await sleep(50);
  }
  if (exited || !listening()) {
    child.kill('SIGTERM');
    throw new Error('Xvfb did not start');
  }
  return { display: `:${number}`, stop: () => child.kill('SIGTERM') };
}

function summarizeWindows(samples) {
  const windows = [];
  for (let index = 1; index < samples.length; index += 1) {
    const previous = samples[index - 1];
    const current = samples[index];
    const seconds = (current.wallMs - previous.wallMs) / 1000;
    const mediaSeconds = (current.stats.clock.sampleCount - previous.stats.clock.sampleCount) / 44100;
    windows.push({
      seconds,
      visibility: current.visibility,
      videoRate: (current.video.count - previous.video.count) / seconds,
      audioRate: (current.audio.count - previous.audio.count) / seconds,
      mediaSeconds,
      drift: mediaSeconds - seconds,
      composed: current.stats.composedFrames - previous.stats.composedFrames,
      dropped: current.stats.droppedBeforeEncode - previous.stats.droppedBeforeEncode,
      skippedForLag: current.stats.skippedForLag - previous.stats.skippedForLag,
      videoMaxGapMs: current.video.maxGapMs,
      audioMaxGapMs: current.audio.maxGapMs,
      stalled: current.stats.clock.stalled,
    });
  }
  return windows;
}

function aggregate(samples) {
  const windows = summarizeWindows(samples);
  const first = samples[0];
  const last = samples[samples.length - 1];
  const seconds = (last.wallMs - first.wallMs) / 1000;
  return {
    windows,
    seconds,
    videoRate: (last.video.count - first.video.count) / seconds,
    audioRate: (last.audio.count - first.audio.count) / seconds,
    mediaSeconds: (last.stats.clock.sampleCount - first.stats.clock.sampleCount) / 44100,
    minWindowVideoRate: Math.min(...windows.map((window) => window.videoRate)),
    minWindowAudioRate: Math.min(...windows.map((window) => window.audioRate)),
    maxVideoGapMs: Math.max(...windows.map((window) => window.videoMaxGapMs)),
    maxAudioGapMs: Math.max(...windows.map((window) => window.audioMaxGapMs)),
    dropped: last.stats.droppedBeforeEncode - first.stats.droppedBeforeEncode,
    skippedForLag: last.stats.skippedForLag - first.stats.skippedForLag,
    composed: last.stats.composedFrames - first.stats.composedFrames,
    anyStalled: windows.some((window) => window.stalled),
    visibilities: Array.from(new Set(samples.map((sample) => sample.visibility))),
  };
}

function report(label, summary) {
  console.log(
    `info ${label}: ${summary.seconds.toFixed(1)} 秒 / 映像 ${summary.videoRate.toFixed(2)} チャンク/秒（窓の最小 ${summary.minWindowVideoRate.toFixed(1)}）` +
      ` / 音声 ${summary.audioRate.toFixed(2)} チャンク/秒（窓の最小 ${summary.minWindowAudioRate.toFixed(1)}。理論値 ${AUDIO_CHUNKS_PER_SECOND.toFixed(2)}）` +
      ` / メディア時間 ${summary.mediaSeconds.toFixed(2)} 秒（実時間との差 ${(summary.mediaSeconds - summary.seconds).toFixed(2)} 秒）` +
      ` / 最大の到着間隔 映像 ${Math.round(summary.maxVideoGapMs)} ms・音声 ${Math.round(summary.maxAudioGapMs)} ms` +
      ` / 合成 ${summary.composed}・入力待ちで破棄 ${summary.dropped}・遅れで飛ばした ${summary.skippedForLag}`,
  );
}

/**
 * タブ tabId を前面にして、配信中のタブの document.visibilityState が expected になるまで待つ。前面にする操作は、最大 10 回繰り返す。
 * 戻り値: 何回目の操作で expected になったか。ならなければ 0。
 */
async function switchTab(debugPort, cdp, tabId, expected) {
  for (let attempt = 1; attempt <= 10; attempt += 1) {
    await httpRequest('GET', `http://127.0.0.1:${debugPort}/json/activate/${tabId}`);
    for (let wait = 0; wait < 10; wait += 1) {
      await sleep(300);
      if ((await evaluate(cdp, 'document.visibilityState', 10000)) === expected) {
        return attempt;
      }
    }
  }
  return 0;
}

/** ブラウザの環境変数。Linux では、指定のディスプレイ（X11）だけを使わせる（Wayland の画面を使わせない）。 */
function browserEnvironment(display) {
  const environment = { ...process.env };
  if (process.platform === 'linux') {
    environment.DISPLAY = display;
    delete environment.WAYLAND_DISPLAY;
  }
  return environment;
}

async function main() {
  const options = support.parseArguments(process.argv.slice(2), {
    'hidden-seconds': 30,
    'visible-seconds': 8,
    'after-seconds': 8,
    'sample-seconds': 5,
    profile: '480p',
    'with-screen': 1,
    'browser-path': '',
    display: 'auto',
    'fake-audio-output': 1,
  });
  const hiddenSeconds = options['hidden-seconds'];
  const sampleSeconds = options['sample-seconds'];
  if (typeof WebSocket !== 'function') {
    return support.unavailable('この Node には WebSocket がありません（Node 22 以上が必要です）');
  }
  const { frontendRoot, playwright, ts } = support.loadTools(options);
  const browserPath = options['browser-path'] || playwright.chromium.executablePath();
  if (!browserPath || !fs.existsSync(browserPath)) {
    return support.unavailable(`ブラウザの実行ファイルが見つかりません（${browserPath || '未指定'}）。--browser-path で指定してください`);
  }

  let xvfb = null;
  let display = process.env.DISPLAY || '';
  const wantXvfb = options.display === 'xvfb' || (options.display === 'auto' && process.platform === 'linux');
  if (wantXvfb) {
    try {
      xvfb = await startXvfb();
      display = xvfb.display;
    } catch (error) {
      // 黙って今のディスプレイ（利用者の画面）へ切り替えない。画面にウィンドウを開いてよいときは、--display current を明示する
      return support.unavailable(`仮想ディスプレイ（Xvfb）を起動できません（${String(error && error.message)}）。画面にウィンドウを開いてよければ --display current を指定してください`);
    }
  }
  if (process.platform === 'linux' && display === '') {
    return support.unavailable('ディスプレイがありません（Xvfb を導入するか、DISPLAY を設定してください）');
  }

  const server = support.createServer({ ts, frontendRoot, browserDirectory: path.join(__dirname, 'browser'), pageHtml: PAGE_HTML });
  const base = await support.listen(server);
  const debugPort = await freePort();
  const profileDirectory = path.join(options.workDir || os.tmpdir(), 'issue27-hidden-profile');
  fs.mkdirSync(profileDirectory, { recursive: true });
  const browser = spawn(
    browserPath,
    [
      `--remote-debugging-port=${debugPort}`,
      `--user-data-dir=${profileDirectory}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--no-sandbox',
      ...(process.platform === 'linux' ? ['--ozone-platform=x11'] : []),
      '--hide-crash-restore-bubble',
      '--use-fake-device-for-media-stream',
      '--use-fake-ui-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
      // 音声の出力デバイスが無い環境（仮想ディスプレイ）では、AudioContext が進まない。偽の音声出力（実時間で進む）を使う。実機では、本物の出力デバイスが駆動する
      ...(options['fake-audio-output'] === 1 ? ['--disable-audio-output'] : []),
      '--window-size=1280,800',
      'about:blank',
    ],
    { env: browserEnvironment(display), stdio: 'ignore' },
  );
  const results = [];
  let cdp = null;
  // timeout などで中断されたとき、起動したブラウザと仮想ディスプレイを残さない
  const abort = () => {
    browser.kill('SIGKILL');
    if (xvfb !== null) {
      xvfb.stop();
    }
    process.exit(support.EXIT_MISMATCH);
  };
  process.once('SIGTERM', abort);
  process.once('SIGINT', abort);
  try {
    const version = await waitForDebugger(debugPort);
    console.log(`info ブラウザ: ${version.Browser}（表示: ${display || '既定'}）`);
    const target = JSON.parse(await httpRequest('PUT', `http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(base)}`));
    cdp = await connect(target.webSocketDebuggerUrl);
    for (let attempt = 0; attempt < 200 && (await evaluate(cdp, 'window.__issue27Ready === true', 5000).catch(() => false)) !== true; attempt += 1) {
      await sleep(100);
    }
    const started = await evaluate(cdp, `window.__issue27.hiddenStart(${JSON.stringify({ profile: options.profile, videoBitrateKbps: options.profile === '720p' ? 4500 : 1500, videoCodec: options.profile === '720p' ? null : 'avc1.42E01F', withScreen: options['with-screen'] === 1 })})`);
    console.log(`info 配信を開始（${options.profile}・画面共有の合成 ${options['with-screen'] === 1 ? 'あり' : 'なし'}）。開始時のタブ: ${started.visibility}。設定に ${Math.round(started.configureMilliseconds)} ms`);

    const snapshot = () => evaluate(cdp, 'window.__issue27.hiddenSnapshot()', 30000);
    // 窓ごとの記録を、ページの時間（performance.now）で測った長さが seconds に届くまで続ける
    const collect = async (seconds) => {
      const samples = [await snapshot()];
      while (samples[samples.length - 1].wallMs - samples[0].wallMs < seconds * 1000) {
        await sleep(sampleSeconds * 1000);
        samples.push(await snapshot());
      }
      return samples;
    };

    await sleep(1500);
    const visibleSamples = await collect(options['visible-seconds']);

    // 別のタブを前面にして、配信中のタブを非表示にする。前面にする操作が、タブの準備より早いことがあるので、可視状態が変わるまで、操作を繰り返す
    const other = JSON.parse(await httpRequest('PUT', `http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent('about:blank')}`));
    const hiddenAfterAttempts = await switchTab(debugPort, cdp, other.id, 'hidden');
    if (hiddenAfterAttempts === 0) {
      throw new Error('could not make the streaming tab hidden by bringing another tab to the front (document.visibilityState stayed visible)');
    }
    console.log(`info 別のタブを前面にした（${hiddenAfterAttempts} 回目の操作で、配信中のタブが hidden）。${hiddenSeconds} 秒間、非表示のまま測る（${sampleSeconds} 秒ごとの窓）`);
    const hiddenSamples = await collect(hiddenSeconds);

    // 配信中のタブを前面に戻す
    if ((await switchTab(debugPort, cdp, target.id, 'visible')) === 0) {
      throw new Error('could not bring the streaming tab back to the front');
    }
    const afterSamples = await collect(options['after-seconds']);
    const finished = await evaluate(cdp, 'window.__issue27.hiddenFinish()', 30000);

    console.log('--- 非表示のタブでの配信（生の CDP + 仮想ディスプレイ）');
    const visible = aggregate(visibleSamples);
    const hidden = aggregate(hiddenSamples);
    const after = aggregate(afterSamples);
    report('表示中（基準）', visible);
    report('非表示', hidden);
    report('前面に戻した後', after);

    const hiddenWindows = hidden.windows;
    check(results, '非表示の間、タブの可視状態は、すべての窓で hidden（タブを本当に非表示にできている）', hidden.visibilities.length === 1 && hidden.visibilities[0] === 'hidden', JSON.stringify(hidden.visibilities));
    check(results, '表示中の基準・前面に戻した後は、visible', visible.visibilities.join() === 'visible' && after.visibilities.join() === 'visible', JSON.stringify({ visible: visible.visibilities, after: after.visibilities }));
    check(results, `非表示の間の長さが ${hiddenSeconds} 秒以上（測定の長さ）`, hidden.seconds >= hiddenSeconds * 0.98, `${hidden.seconds.toFixed(1)} 秒`);
    check(results, '非表示の間も、音声のチャンクが理論値（43.07/秒）の ±2% で届く（音声の処理が、タブの非表示で間引かれない）', Math.abs(hidden.audioRate - AUDIO_CHUNKS_PER_SECOND) <= AUDIO_CHUNKS_PER_SECOND * 0.02 && hidden.minWindowAudioRate >= AUDIO_CHUNKS_PER_SECOND * 0.9, `${hidden.audioRate.toFixed(2)}（窓の最小 ${hidden.minWindowAudioRate.toFixed(1)}）`);
    check(results, '非表示の間も、映像が 27 チャンク/秒以上（30 fps の 9 割）。表示中の基準の 9 割以上', hidden.videoRate >= 27 && hidden.videoRate >= visible.videoRate * 0.9, `${hidden.videoRate.toFixed(2)}（表示中 ${visible.videoRate.toFixed(2)}、窓の最小 ${hidden.minWindowVideoRate.toFixed(1)}）`);
    check(results, '非表示の間、メディアクロックが実時間に追従する（差が 1% または 0.5 秒のうち大きい方の内）', Math.abs(hidden.mediaSeconds - hidden.seconds) <= Math.max(0.5, hidden.seconds * 0.01), `差 ${(hidden.mediaSeconds - hidden.seconds).toFixed(3)} 秒`);
    check(results, '非表示の間、チャンクの到着の間隔が 500 ミリ秒を超えない（映像・音声。配信が途切れない）', hidden.maxVideoGapMs <= 500 && hidden.maxAudioGapMs <= 500, `映像 ${Math.round(hidden.maxVideoGapMs)} ms・音声 ${Math.round(hidden.maxAudioGapMs)} ms`);
    check(results, '非表示の間、メディアクロックの停止（stalled）が無い。映像・音声のエンコーダの故障も無い', !hidden.anyStalled && hiddenSamples.every((sample) => !sample.stats.videoFaulted && !sample.stats.audioFaulted) && hiddenSamples[hiddenSamples.length - 1].faults.length === 0, JSON.stringify(hiddenSamples[hiddenSamples.length - 1].faults));
    check(results, '非表示の間、遅れで合成を飛ばした割合が 2% 未満（ワーカーが遅れない）。入力待ちの破棄は 5% 未満', hidden.skippedForLag <= hidden.composed * 0.02 && hidden.dropped <= hidden.composed * 0.05, `skippedForLag=${hidden.skippedForLag}, dropped=${hidden.dropped}, composed=${hidden.composed}`);
    check(results, 'チャンクの時刻が逆行しない（映像・音声）', [...visibleSamples, ...hiddenSamples, ...afterSamples].every((sample) => sample.video.nonMonotonic === 0 && sample.audio.nonMonotonic === 0), '');
    check(results, '前面に戻した後も、配信が続く（映像 27 チャンク/秒以上・音声が理論値の ±2%）', after.videoRate >= 27 && Math.abs(after.audioRate - AUDIO_CHUNKS_PER_SECOND) <= AUDIO_CHUNKS_PER_SECOND * 0.02, `映像 ${after.videoRate.toFixed(2)}・音声 ${after.audioRate.toFixed(2)}`);
    check(results, '配信の終了後: プレビューだけの状態に戻り、フレームの解放漏れが無い（受け取った数 = 閉じた数 + 保持している数）', finished.modeAfter === 'preview' && finished.framesReceived === finished.framesClosed + finished.framesRetained && finished.faults.length === 0, JSON.stringify(finished));
    console.log(`info 窓ごとの映像チャンク/秒（非表示）: ${hiddenWindows.map((window) => window.videoRate.toFixed(0)).join(' ')}`);
  } finally {
    if (cdp !== null) {
      cdp.close();
    }
    browser.kill('SIGTERM');
    server.close();
    if (xvfb !== null) {
      xvfb.stop();
    }
  }
  support.finish(results, options, '非表示のタブでの配信の確認');
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(support.EXIT_MISMATCH);
});
