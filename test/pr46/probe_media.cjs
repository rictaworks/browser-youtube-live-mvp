'use strict';
// 実ブラウザ（Playwright の Chromium）で、ソースの取得（lib/sources）と音声の混合（lib/audio・public/worklets）を実測する（issue #26）。
//
// Jest（疑似の AudioContext・MediaDevices）では確かめられない、次のことを、本物のブラウザで確かめる。
//   A. AudioContext（44,100 Hz）上の AudioWorklet が、ソースの有無にかかわらず止まらず、128 サンプルのブロックを途切れなく送る（累積サンプル数が連続し、
//      実時間と合う）。マイク・共有音声の追加・解除・音量の変更・過大な入力が、混合の数値（共有音声は 0.6 倍・上限 1）として、実ブラウザで合う
//   B. 転送した MessagePort で、メインスレッドを経由せず、配信パイプラインのワーカーへ直接送れる。メインスレッドを 1.5 秒占有しても、ブロックは途切れない
//      （タブが非表示で、メインスレッドのタイマが間引かれても、混合が続く前提の確認。非表示のタブそのものは、この環境では再現できない）
//   C. メディアクロック（core の MediaClock）を、ブロックで駆動する。AudioContext の suspend・resume で、停止と再開が通知され、累積サンプル数は連続する
//   D. SourceManager が、本物の MediaDevices（偽のデバイス）で、カメラ・マイク・画面共有・共有音声を取得する。マイクはエコー除去・雑音抑制が適用される。
//      存在しないデバイスの識別子は未取得（device_not_found）。トラックの終了で喪失。混合へ反映される。破棄でトラックが止まる
//   E. 画面共有の選択画面が使えない環境（偽の UI なし）で、attach("screen") が要求中のまま止まらず、状態が未取得へ戻る
//
// できないこと（この環境では確認できない。実機は、画面ができる #29 のユーザーテストで行う）:
//   - 実機のカメラ・マイク・画面共有（利用者の許可・選択画面）。偽のデバイス（--use-fake-device-for-media-stream・--use-fake-ui-for-media-stream）で代える
//   - 一時的なアクティベーション（クリック）が無いときの InvalidStateError（偽の UI では、検査が省かれる）。疑似の getDisplayMedia（Jest）で保証する
//   - 5 分以上、タブを非表示にしたときの継続（公式の保証の記述が無い。実機で、30 fps と音声の周期の維持を確かめる）
//   - 配信者自身への折り返し再生が起きないこと（耳で確かめる）。ソースの静的な検査と、グラフの接続の検査（Jest）で保証する
// lib/ の TypeScript は、リポジトリの TypeScript で、その場で JavaScript にして、ローカルの HTTP サーバー（127.0.0.1）から、ページへ配る（成果物を作らない）。
// Worklet（public/worklets）は、Next.js が配信するのと同じ URL（/worklets/...）で、そのまま配る。
//
// 使い方: node probe_media.cjs --repo <リポジトリのルート> [--playwright-dir <Playwright を導入したディレクトリ>] [--channel <chrome|msedge>] [--json]
//   Playwright の場所：--playwright-dir、または環境変数 ISSUE26_PLAYWRIGHT_DIR（その下の node_modules/playwright）、または src/frontend/node_modules/playwright
//   ブラウザの場所：Playwright の既定（~/.cache/ms-playwright）、または環境変数 PLAYWRIGHT_BROWSERS_PATH
// 終了コード: 0 = すべて確認できた / 1 = 食い違いがある / 3 = 確認できなかった（Playwright・Chromium・TypeScript が無い）。3 は成功ではない

const fs = require('fs');
const http = require('http');
const path = require('path');

const EXIT_OK = 0;
const EXIT_MISMATCH = 1;
const EXIT_UNAVAILABLE = 3;

function parseArguments(argv) {
  const options = { repo: null, playwrightDir: process.env.ISSUE26_PLAYWRIGHT_DIR || null, channel: process.env.ISSUE26_BROWSER_CHANNEL || null, json: false };
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
// lib・core の TypeScript を、その場で JavaScript にして配るサーバー
// ---------------------------------------------------------------------------

const SERVED_ROOTS = ['lib', 'core'];

function createServer(ts, frontendRoot) {
  function resolveSpecifier(specifier, directory) {
    const base = specifier.startsWith('@/') ? path.resolve(frontendRoot, specifier.slice(2)) : path.resolve(directory, specifier);
    const relative = path.relative(frontendRoot, base).split(path.sep).join('/');
    if (fs.existsSync(`${base}.ts`)) {
      return `/app/${relative}.js`;
    }
    if (fs.existsSync(path.join(base, 'index.ts'))) {
      return `/app/${relative}/index.js`;
    }
    throw new Error(`unresolved import ${specifier} in ${directory}`);
  }

  function transpile(file) {
    const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      fileName: file,
      compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2020, isolatedModules: true },
    });
    const directory = path.dirname(file);
    return output.outputText.replace(/(\bfrom\s+["'])((?:@\/|\.{1,2}\/)[^"']*)(["'])/g, (_match, head, specifier, tail) => `${head}${resolveSpecifier(specifier, directory)}${tail}`);
  }

  const page = [
    '<!doctype html><meta charset="utf-8"><title>issue26 media probe</title>',
    '<script type="module">',
    '  import * as audio from "/app/lib/audio/index.js";',
    '  import * as sources from "/app/lib/sources/index.js";',
    '  import { MediaClock } from "/app/core/clock/index.js";',
    '  window.__issue26 = { audio, sources, MediaClock };',
    '  window.__issue26Ready = true;',
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
      if (url.pathname === '/worklets/stream-mixer-processor.js') {
        response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'public, max-age=0' });
        response.end(fs.readFileSync(path.join(frontendRoot, 'public', 'worklets', 'stream-mixer-processor.js')));
        return;
      }
      const match = /^\/app\/(.+)\.js$/.exec(url.pathname);
      const source = match ? path.resolve(frontendRoot, `${match[1]}.ts`) : null;
      const allowed = source !== null && SERVED_ROOTS.some((root) => source.startsWith(path.join(frontendRoot, root) + path.sep));
      if (!allowed || !fs.existsSync(source)) {
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
// ページの中で実行するシナリオ（ページの中の window.__issue26 を使う。自己完結の関数）
// ---------------------------------------------------------------------------

/** A. AudioWorklet の混合: 止まらず、途切れず、数値が合う（疑似でなく、本物の AudioContext・Worklet・MediaStream） */
async function scenarioMixer() {
  const { audio } = window.__issue26;
  const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

  const contexts = [];
  const base = audio.createBrowserAudioEnvironment(window);
  const environment = {
    ...base,
    createContext: (options) => {
      const context = base.createContext(options);
      contexts.push(context);
      return context;
    },
  };

  // 一定の値（直流）の音声トラック。別の AudioContext から作る（混合器の入力として、サンプリング周波数が違っても、変換される）
  const helpers = [];
  const constantTrack = (level) => {
    const context = new AudioContext();
    const source = context.createConstantSource();
    source.offset.value = level;
    source.start();
    const destination = context.createMediaStreamDestination();
    source.connect(destination);
    helpers.push(context);
    return destination.stream.getAudioTracks()[0];
  };

  const blocks = [];
  const faults = [];
  const events = [];
  const mixer = new audio.AudioMixer({ environment, onListenerError: (error) => faults.push(`listener:${error && error.message}`) });
  mixer.subscribe({
    onBlock: (block) => blocks.push({ firstSample: block.firstSample, frames: block.frames, length: block.pcm.length, left: block.pcm[0], right: block.pcm[1], max: maxAbs(block.pcm), arrival: performance.timeOrigin + performance.now() }),
    onStall: () => events.push('stall'),
    onResume: () => events.push('resume'),
    onFault: (fault) => faults.push(`${fault.code}:${fault.detail}`),
  });

  function maxAbs(pcm) {
    let max = 0;
    for (let index = 0; index < pcm.length; index += 1) {
      const value = Math.abs(pcm[index]);
      if (value > max) {
        max = value;
      }
    }
    return max;
  }

  /** 最近の count ブロックの、左右の平均と、左右の差の最大。 */
  const level = (count) => {
    const recent = blocks.slice(-count);
    let sumLeft = 0;
    let sumRight = 0;
    let maxDifference = 0;
    for (const block of recent) {
      sumLeft += block.left;
      sumRight += block.right;
      maxDifference = Math.max(maxDifference, Math.abs(block.left - block.right));
    }
    return { left: sumLeft / recent.length, right: sumRight / recent.length, maxDifference, max: Math.max(...recent.map((block) => block.max)) };
  };

  /** 条件が成り立つまで、上限の時間まで待つ（負荷が高い環境で、固定の待ち時間が足りないことを避ける） */
  const waitFor = async (condition, timeoutMilliseconds = 6000) => {
    const deadline = performance.now() + timeoutMilliseconds;
    while (!condition() && performance.now() < deadline) {
      await sleep(25);
    }
    return condition();
  };

  /** 期待する水準（左右とも）に、続けて 2 回収まるまで待つ。上限の時間を過ぎたら、そのときの値を返す（reached = 収まったか）。 */
  const settle = async (expected, tolerance, timeoutMilliseconds = 6000) => {
    const deadline = performance.now() + timeoutMilliseconds;
    let consecutive = 0;
    for (;;) {
      const current = level(30);
      const inRange = Math.abs(current.left - expected) <= tolerance && Math.abs(current.right - expected) <= tolerance;
      consecutive = inRange ? consecutive + 1 : 0;
      if (consecutive >= 2 || performance.now() >= deadline) {
        return { ...current, reached: consecutive >= 2 };
      }
      await sleep(50);
    }
  };

  /** 直近の 30 ブロックが、すべて 0 になるまで待つ（ソースを外したあと、無音を出し続ける） */
  const settleSilence = async (timeoutMilliseconds = 6000) => {
    const reached = await waitFor(() => blocks.length >= 30 && level(30).max === 0, timeoutMilliseconds);
    return { ...level(30), reached };
  };

  await mixer.start();
  const statusAfterStart = mixer.status;
  const result = { statusAfterStart, sampleRate: contexts[0].sampleRate, contextCount: contexts.length };

  // ソースが 1 つも無い間も、止まらずに、無音のブロックが来る
  await waitFor(() => blocks.length >= 60);
  result.silence = { ...level(60), blocks: blocks.length };

  const mic = constantTrack(0.5);
  const shared = constantTrack(0.25);
  mixer.addSource('microphone', mic);
  result.micOnly = await settle(0.5, 0.01);
  mixer.addSource('shared_audio', shared);
  result.micAndShared = await settle(0.65, 0.01);
  mixer.setGain('shared_audio', 1);
  result.sharedFullGain = await settle(0.75, 0.01);
  mixer.removeSource('microphone');
  result.sharedOnly = await settle(0.25, 0.01);
  mixer.removeSource('shared_audio');
  result.afterRemoval = await settleSilence();

  // 過大な入力: マイク 1.0 と共有音声 1.0（音量 0.6）= 1.6。リミッタが、全体を縮めて、上限（1）に収める
  mixer.setGain('shared_audio', 0.6);
  mixer.addSource('microphone', constantTrack(1));
  mixer.addSource('shared_audio', constantTrack(1));
  result.overload = await settle(1, 0.02);

  mixer.removeSource('microphone');
  mixer.removeSource('shared_audio');
  await settleSilence();

  await mixer.stop();
  const total = blocks.length;
  result.statusAfterStop = mixer.status;
  result.contextState = contexts[0].state;
  result.totalBlocks = total;
  // 最初のブロックの到着から最後のブロックの到着までの、音声の長さ（累積サンプル数）と、実時間（開始の処理・タイマの遅れを含めない）
  const first = blocks[0];
  const last = blocks[blocks.length - 1];
  result.audioSeconds = (last.firstSample + last.frames - first.firstSample) / 44100;
  result.wallSeconds = (last.arrival - first.arrival) / 1000;
  result.lastEndSample = last.firstSample + last.frames;
  result.allFrames128 = blocks.every((block) => block.frames === 128 && block.length === 256);
  let gaps = 0;
  for (let index = 1; index < blocks.length; index += 1) {
    if (blocks[index].firstSample !== blocks[index - 1].firstSample + blocks[index - 1].frames) {
      gaps += 1;
    }
  }
  result.firstBlockStart = blocks[0] ? blocks[0].firstSample : null;
  result.gaps = gaps;
  result.maxAbsEver = Math.max(...blocks.map((block) => block.max));
  result.faults = faults;
  result.events = events;
  const countAfterStop = blocks.length;
  await sleep(300);
  result.blocksAfterStop = blocks.length - countAfterStop;
  for (const context of helpers) {
    await context.close();
  }
  return result;
}

/** B. 転送した MessagePort で、ワーカーへ直接送る。メインスレッドを占有しても、途切れない */
async function scenarioWorkerPath() {
  const { audio } = window.__issue26;
  const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
  const workerSource = [
    'let expected = 0, blocks = 0, gaps = 0, maxAbs = 0, firstSeen = null, frames = 0, wrongLength = 0; const arrivals = [];',
    'self.onmessage = (event) => {',
    '  if (event.data && event.data.type === "port") {',
    '    event.data.port.onmessage = (message) => {',
    '      const data = message.data;',
    '      if (data.type !== "block") return;',
    '      if (firstSeen === null) firstSeen = data.firstSample;',
    '      if (data.firstSample !== expected) gaps += 1;',
    '      if (data.pcm.length !== data.frames * 2) wrongLength += 1;',
    '      expected = data.firstSample + data.frames;',
    '      blocks += 1; frames += data.frames; arrivals.push(performance.timeOrigin + performance.now());',
    '      for (let i = 0; i < data.pcm.length; i += 1) { const a = Math.abs(data.pcm[i]); if (a > maxAbs) maxAbs = a; }',
    '    };',
    '    self.postMessage({ type: "ready" });',
    '  } else if (event.data && event.data.type === "report") {',
    '    self.postMessage({ type: "report", blocks, gaps, maxAbs, firstSeen, frames, expected, wrongLength, arrivals });',
    '  }',
    '};',
  ].join('\n');
  const worker = new Worker(URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' })));
  const ask = (message, transfer) =>
    new Promise((resolve) => {
      worker.onmessage = (event) => resolve(event.data);
      worker.postMessage(message, transfer || []);
    });

  const channel = new MessageChannel();
  await ask({ type: 'port', port: channel.port2 }, [channel.port2]);
  const base = audio.createBrowserAudioEnvironment(window);
  const mixer = new audio.AudioMixer({ environment: base });
  let mainThreadBlocks = 0;
  mixer.subscribe({ onBlock: () => { mainThreadBlocks += 1; } });

  await mixer.start({ sink: channel.port1 });
  await sleep(500);
  // メインスレッドを 1.5 秒占有する（タブが非表示で、メインスレッドのタイマが間引かれた状態の代わり）。この間、メインスレッドは、何も受け取れない。
  // 占有の時間帯（エポックからの時刻）を記録し、その間にワーカーへ届いたブロックの数を、あとで数える
  const busyStart = performance.timeOrigin + performance.now();
  while (performance.timeOrigin + performance.now() - busyStart < 1500) {
    // busy wait
  }
  const busyEnd = performance.timeOrigin + performance.now();
  await sleep(500);
  const after = await ask({ type: 'report' });
  await mixer.stop();
  const arrivalsDuringBusy = after.arrivals.filter((time) => time >= busyStart && time <= busyEnd).length;
  const audioSeconds = after.expected / 44100;
  const wallSeconds = (after.arrivals[after.arrivals.length - 1] - after.arrivals[0]) / 1000;
  return { after: { ...after, arrivals: undefined }, arrivalsDuringBusy, busySeconds: (busyEnd - busyStart) / 1000, mainThreadBlocks, audioSeconds, wallSeconds, status: mixer.status };
}

/** C. メディアクロックの駆動と、AudioContext の suspend・resume */
async function scenarioStallResume() {
  const { audio, MediaClock } = window.__issue26;
  const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
  const contexts = [];
  const base = audio.createBrowserAudioEnvironment(window);
  const environment = {
    ...base,
    createContext: (options) => {
      const context = base.createContext(options);
      contexts.push(context);
      return context;
    },
  };
  const errors = [];
  const events = [];
  const ticks = [];
  const clock = new MediaClock();
  const driver = new audio.AudioClockDriver(clock, (tick) => ticks.push({ frameCount: tick.range.frameCount, skipped: tick.range.skippedFrameCount, keyframe: tick.range.keyframeRequired, first: tick.range.firstFrameIndex }));
  const mixer = new audio.AudioMixer({ environment, onListenerError: (error) => errors.push(`${error && error.name}:${error && error.message}`) });
  mixer.subscribe(driver);
  mixer.subscribe({ onStall: () => events.push('stall'), onResume: () => events.push('resume') });

  await mixer.start();
  await sleep(1500);
  const running = { sampleCount: clock.sampleCount, frameIndex: clock.frameIndex };

  await contexts[0].suspend();
  await sleep(300);
  const atSuspend = clock.sampleCount;
  const stalledFlag = clock.isStalled;
  await sleep(500);
  const duringSuspend = clock.sampleCount;
  await contexts[0].resume();
  await sleep(100);
  const resumedFlag = clock.isStalled;
  await sleep(900);
  const after = { sampleCount: clock.sampleCount, frameIndex: clock.frameIndex, needsKeyframe: clock.needsKeyframe };
  const keyframeTicks = ticks.filter((tick) => tick.keyframe).length;
  const frameSum = ticks.reduce((sum, tick) => sum + tick.frameCount, 0);
  const skippedSum = ticks.reduce((sum, tick) => sum + tick.skipped, 0);
  await mixer.stop();
  return { running, atSuspend, duringSuspend, stalledFlag, resumedFlag, after, keyframeTicks, frameSum, skippedSum, events, errors, contextStatesAfterStop: contexts[0].state, audioTimeOfSampleCount: clock.audioTime(clock.sampleCount) };
}

/** D. SourceManager（本物の MediaDevices。偽のデバイス）と、混合への反映 */
async function scenarioSources() {
  const { audio, sources } = window.__issue26;
  const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
  const errors = [];
  const diagnostics = [];
  const manager = new sources.SourceManager({
    mediaDevices: navigator.mediaDevices,
    onError: (error) => errors.push(`${error && error.name}:${error && error.message}`),
    onDiagnostic: (event, fields) => diagnostics.push({ event, fields }),
  });
  const changes = [];
  manager.subscribe((change) => changes.push(`${change.kind}:${change.current.state}:${change.layout}`));
  const result = { canShareScreen: manager.canShareScreen, initialLayout: manager.layout };

  await manager.devices.refresh();
  result.deviceCounts = { cameras: manager.devices.snapshot.cameras.length, microphones: manager.devices.snapshot.microphones.length };

  const camera = await manager.attach('camera');
  result.camera = { state: camera.state, trackKind: camera.track && camera.track.kind, hasDeviceId: Boolean(camera.deviceId), hasLabel: Boolean(camera.label), layout: manager.layout, ended: camera.track && camera.track.readyState };
  const cameraTrack = camera.track;

  const microphone = await manager.attach('microphone');
  const settings = microphone.track.getSettings();
  result.microphone = { state: microphone.state, trackKind: microphone.track.kind, echoCancellation: settings.echoCancellation, noiseSuppression: settings.noiseSuppression };
  const microphoneTrack = microphone.track;

  // 存在しないデバイスの識別子（exact）は、別のデバイスへ黙って切り替えず、未取得（device_not_found）になる
  const missing = await manager.attach('camera', 'does-not-exist');
  result.missingDevice = { state: missing.state, reason: missing.reason, cameraTrackStopped: cameraTrack.readyState === 'ended', layout: manager.layout };
  const cameraAgain = await manager.attach('camera');
  result.cameraAgain = { state: cameraAgain.state, layout: manager.layout };

  // 混合へ反映する（本物の偽マイクの音声）
  const environment = audio.createBrowserAudioEnvironment(window);
  const mixer = new audio.AudioMixer({ environment, onListenerError: (error) => errors.push(`mixer:${error && error.message}`) });
  const blocks = [];
  mixer.subscribe({ onBlock: (block) => blocks.push({ firstSample: block.firstSample, frames: block.frames, max: block.pcm.reduce((max, value) => Math.max(max, Math.abs(value)), 0) }) });
  const unbind = audio.bindSourcesToMixer(manager, mixer);
  await mixer.start();
  await sleep(3000);
  result.mixerWithMic = { hasMic: mixer.hasSource('microphone'), maxAbs: Math.max(...blocks.map((block) => block.max)), blocks: blocks.length };

  const screen = await manager.attach('screen');
  result.screen = { state: screen.state, trackKind: screen.track && screen.track.kind, sharedAudio: manager.getHandle('shared_audio').state, layout: manager.layout, mixerHasShared: mixer.hasSource('shared_audio') };
  const screenTrack = screen.track;
  const sharedTrack = manager.getHandle('shared_audio').track;

  // トラックの終了（本物のトラックに ended を起こす）。マイクの喪失は、混合から外して継続する
  const blocksBeforeLoss = blocks.length;
  microphoneTrack.dispatchEvent(new Event('ended'));
  await sleep(600);
  result.afterMicLoss = { state: manager.getHandle('microphone').state, mixerHasMic: mixer.hasSource('microphone'), mixerStatus: mixer.status, newBlocks: blocks.length - blocksBeforeLoss, latestMax: Math.max(...blocks.slice(-50).map((block) => block.max)) };

  // 画面共有の終了は、共有音声も喪失
  screenTrack.dispatchEvent(new Event('ended'));
  result.afterScreenLoss = { screen: manager.getHandle('screen').state, shared: manager.getHandle('shared_audio').state, mixerHasShared: mixer.hasSource('shared_audio'), layout: manager.layout };

  let gaps = 0;
  for (let index = 1; index < blocks.length; index += 1) {
    if (blocks[index].firstSample !== blocks[index - 1].firstSample + blocks[index - 1].frames) {
      gaps += 1;
    }
  }
  result.blockGaps = gaps;

  const cameraTrackBeforeDispose = manager.getHandle('camera').track;
  const cameraStateBeforeDispose = cameraTrackBeforeDispose ? cameraTrackBeforeDispose.readyState : null;
  unbind();
  await mixer.stop();
  manager.dispose();
  result.afterDispose = {
    camera: manager.getHandle('camera').state,
    cameraTrackBefore: cameraStateBeforeDispose,
    cameraTrackAfter: cameraTrackBeforeDispose ? cameraTrackBeforeDispose.readyState : null,
    sharedTrackEnded: sharedTrack ? sharedTrack.readyState : null,
  };
  result.mediaElements = document.querySelectorAll('audio, video').length;
  result.changes = changes;
  result.errors = errors;
  result.diagnosticsText = JSON.stringify(diagnostics);
  return result;
}

/** E. 画面共有の選択画面が使えない環境（偽の UI なし）。要求中のまま止まらない */
async function scenarioScreenWithoutFakeUi() {
  const { sources } = window.__issue26;
  const manager = new sources.SourceManager({ mediaDevices: navigator.mediaDevices, onError: () => undefined });
  const outcome = { settled: false };
  const race = await Promise.race([
    manager
      .attach('screen')
      .then((handle) => ({ kind: 'resolved', state: handle.state, reason: handle.reason }))
      .catch((error) => ({ kind: 'rejected', name: error && error.name, code: error && error.code, errorName: error && error.errorName })),
    new Promise((resolve) => setTimeout(() => resolve({ kind: 'timeout' }), 10000)),
  ]);
  outcome.race = race;
  outcome.screenState = manager.getHandle('screen').state;
  outcome.sharedState = manager.getHandle('shared_audio').state;
  outcome.reason = manager.getHandle('screen').reason;
  manager.dispose();
  return outcome;
}

// ---------------------------------------------------------------------------
// 突き合わせ
// ---------------------------------------------------------------------------

function check(results, label, condition, detail) {
  results.push({ label, ok: Boolean(condition), detail });
  console.log(`${condition ? 'ok  ' : 'FAIL'} ${label}${detail === undefined ? '' : `（${detail}）`}`);
}

const near = (value, expected, tolerance) => Number.isFinite(value) && Math.abs(value - expected) <= tolerance;

function compareMixer(measured) {
  const results = [];
  console.log('--- A. AudioWorklet の混合（本物の AudioContext・Worklet）');
  check(results, 'AudioContext は 44,100 Hz で作られ、混合器は running になる', measured.sampleRate === 44100 && measured.statusAfterStart === 'running' && measured.contextCount === 1, `sampleRate=${measured.sampleRate}, status=${measured.statusAfterStart}`);
  check(results, 'ソースが 1 つも無い間も、止まらず、無音のブロックを出し続ける（開始から、上限 6 秒の間に、60 ブロック以上が届き、すべて 0）', measured.silence.blocks >= 60 && measured.silence.max === 0, `blocks=${measured.silence.blocks}, max=${measured.silence.max}`);
  check(results, 'マイクだけ（直流 0.5）: 出力は 0.5（左右同じ。モノラルの入力が、左右へ）', measured.micOnly.reached && near(measured.micOnly.left, 0.5, 0.01) && measured.micOnly.maxDifference < 1e-6, `left=${measured.micOnly.left}, diff=${measured.micOnly.maxDifference}`);
  check(results, 'マイクと共有音声（直流 0.25）: 0.5 + 0.25 × 0.6 = 0.65（共有音声は、マイクの 0.6 倍）', measured.micAndShared.reached && near(measured.micAndShared.left, 0.65, 0.01), `left=${measured.micAndShared.left}`);
  check(results, '共有音声の音量を 1 にすると、0.5 + 0.25 = 0.75（音量の変更が、Worklet に届く）', measured.sharedFullGain.reached && near(measured.sharedFullGain.left, 0.75, 0.01), `left=${measured.sharedFullGain.left}`);
  check(results, 'マイクを外す（配信中の解除）: 共有音声だけで 0.25。止まらない', measured.sharedOnly.reached && near(measured.sharedOnly.left, 0.25, 0.01), `left=${measured.sharedOnly.left}`);
  check(results, '共有音声も外す（皆無）: 無音を生成し続ける（出力は 0）', measured.afterRemoval.reached && measured.afterRemoval.max === 0, `max=${measured.afterRemoval.max}`);
  check(results, '過大な入力（1.0 + 1.0 × 0.6 = 1.6）: リミッタが全体を縮め、上限（1）を超えない。出力は 1 付近', measured.overload.reached && measured.overload.max <= 1 && near(measured.overload.left, 1, 0.02), `max=${measured.overload.max}, left=${measured.overload.left}`);
  check(results, '全期間で、出力は、上限（1）を超えない', measured.maxAbsEver <= 1, `maxAbsEver=${measured.maxAbsEver}`);
  check(results, 'すべてのブロックが 128 サンプル（PCM は 256 要素）', measured.allFrames128);
  check(results, '累積サンプル数は、0 から始まり、途切れない（ブロックの欠落・重複・順序の入れ替わりが 0 件。ソースの追加・解除・音量の変更の最中も）', measured.firstBlockStart === 0 && measured.gaps === 0, `first=${measured.firstBlockStart}, gaps=${measured.gaps}`);
  check(results, '累積サンプル数の進みが、実時間と同じ速さ（最初のブロックの到着から最後のブロックの到着までで、実時間の 0.6 倍から 1.4 倍。CPU の負荷で到着が遅れても、成り立つ緩い範囲。実際の比は、括弧の中）', measured.audioSeconds / measured.wallSeconds >= 0.6 && measured.audioSeconds / measured.wallSeconds <= 1.4, `音声 ${measured.audioSeconds.toFixed(2)} 秒 / 実時間 ${measured.wallSeconds.toFixed(2)} 秒 = ${(measured.audioSeconds / measured.wallSeconds).toFixed(3)}`);
  check(results, '停止（stop）で、AudioContext が閉じ、ブロックは来なくなる', measured.statusAfterStop === 'stopped' && measured.contextState === 'closed' && measured.blocksAfterStop === 0, `status=${measured.statusAfterStop}, context=${measured.contextState}, after=${measured.blocksAfterStop}`);
  check(results, '障害（不正なメッセージ・拒否・例外）が 0 件。停止・再開の通知も、無い（停止していない）', measured.faults.length === 0 && measured.events.length === 0, JSON.stringify({ faults: measured.faults, events: measured.events }));
  return results;
}

function compareWorkerPath(measured) {
  const results = [];
  console.log('--- B. 転送した MessagePort で、ワーカーへ直接送る（メインスレッドを 1.5 秒占有）');
  check(results, 'ブロックは、ワーカーだけへ届き、メインスレッドの購読者へは届かない', measured.after.blocks > 0 && measured.mainThreadBlocks === 0, `worker=${measured.after.blocks}, main=${measured.mainThreadBlocks}`);
  check(results, 'メインスレッドを占有している間（1.5 秒）も、ワーカーは、ブロックを受け取り続ける（占有の時間帯に届いた数が、1.5 秒分 = 約 516 ブロックの 6 割以上）', measured.arrivalsDuringBusy >= 300, `占有 ${measured.busySeconds.toFixed(2)} 秒の間に、${measured.arrivalsDuringBusy} ブロック`);
  check(results, 'ワーカーが受け取った累積サンプル数は、0 から始まり、途切れない。PCM の長さは、すべてサンプル数 × 2', measured.after.firstSeen === 0 && measured.after.gaps === 0 && measured.after.wrongLength === 0, `first=${measured.after.firstSeen}, gaps=${measured.after.gaps}`);
  check(results, 'ワーカーが受け取った累積の進みが、実時間と同じ速さ（最初のブロックの到着から最後のブロックの到着までで、0.6 倍から 1.4 倍）', measured.audioSeconds / measured.wallSeconds >= 0.6 && measured.audioSeconds / measured.wallSeconds <= 1.4, `音声 ${measured.audioSeconds.toFixed(2)} 秒 / 実時間 ${measured.wallSeconds.toFixed(2)} 秒 = ${(measured.audioSeconds / measured.wallSeconds).toFixed(3)}`);
  return results;
}

function compareStallResume(measured) {
  const results = [];
  console.log('--- C. メディアクロックの駆動と、AudioContext の suspend・resume');
  check(results, 'ブロックで、メディアクロックが進む（1.5 秒待って、音声が 0.8 秒以上。映像フレーム = 累積 ÷ 1,470 の切り捨て）', measured.running.sampleCount / 44100 >= 0.8 && measured.running.frameIndex === Math.floor(measured.running.sampleCount / 1470), `音声 ${(measured.running.sampleCount / 44100).toFixed(2)} 秒, frames=${measured.running.frameIndex}`);
  check(results, 'suspend で、停止が通知され（onStall）、クロックが止まる。停止中は、サンプルが増えない（飛行中の数ブロックを除く）', measured.stalledFlag === true && measured.duringSuspend - measured.atSuspend <= 128 * 4, `停止中の増分=${measured.duringSuspend - measured.atSuspend}`);
  check(results, 'resume で、再開が通知され（onResume）、クロックの停止が解ける。再開後、クロックが進む', measured.resumedFlag === false && measured.after.sampleCount > measured.duringSuspend + 44100 * 0.3, `再開後の増分=${measured.after.sampleCount - measured.duringSuspend}`);
  check(results, '再開後の最初の合成が、キーフレーム（1 回だけ）。空白を埋めない', measured.keyframeTicks === 1 && measured.after.needsKeyframe === false, `keyframeTicks=${measured.keyframeTicks}`);
  check(results, '停止・再開の通知は、順に 1 回ずつ（stall -> resume）。連続性の例外（AudioContinuityError）は、起きない（停止をまたいでも、Worklet の累積サンプル数は連続）', JSON.stringify(measured.events) === JSON.stringify(['stall', 'resume']) && measured.errors.length === 0, JSON.stringify({ events: measured.events, errors: measured.errors }));
  check(results, 'フレームの数（合成した + 停止中に期限が来て合成しなかった）= 累積 ÷ 1,470。取りこぼし・重複が無い', measured.frameSum + measured.skippedSum === measured.after.frameIndex, `合成=${measured.frameSum}, 停止中=${measured.skippedSum}, クロック=${measured.after.frameIndex}`);
  check(results, '音声の時刻は、累積サンプル数から導く（audioTime）。実時計に依らない', Number.isInteger(measured.audioTimeOfSampleCount) && measured.audioTimeOfSampleCount > 0, String(measured.audioTimeOfSampleCount));
  return results;
}

function compareSources(measured) {
  const results = [];
  console.log('--- D. SourceManager（本物の MediaDevices。偽のデバイス）と、混合への反映');
  check(results, '画面共有 API があり（canShareScreen）、初期のレイアウトは代替スレート', measured.canShareScreen === true && measured.initialLayout === 'slate', JSON.stringify({ canShareScreen: measured.canShareScreen, layout: measured.initialLayout }));
  check(results, 'デバイスの一覧に、カメラとマイクがある', measured.deviceCounts.cameras >= 1 && measured.deviceCounts.microphones >= 1, JSON.stringify(measured.deviceCounts));
  check(results, 'カメラを取得: 取得済み・映像のトラック・デバイスの識別子・ラベルがある。レイアウトはカメラのみ', measured.camera.state === 'active' && measured.camera.trackKind === 'video' && measured.camera.hasDeviceId && measured.camera.hasLabel && measured.camera.layout === 'camera_only', JSON.stringify(measured.camera));
  check(results, 'マイクを取得: エコー除去・雑音抑制が適用されている（トラックの設定が、どちらも true）', measured.microphone.state === 'active' && measured.microphone.trackKind === 'audio' && measured.microphone.echoCancellation === true && measured.microphone.noiseSuppression === true, JSON.stringify(measured.microphone));
  check(results, '存在しないデバイスの識別子: 別のデバイスへ黙って切り替えず、未取得（device_not_found）。古いカメラのトラックは止まり、レイアウトは代替スレート', measured.missingDevice.state === 'detached' && measured.missingDevice.reason === 'device_not_found' && measured.missingDevice.cameraTrackStopped && measured.missingDevice.layout === 'slate', JSON.stringify(measured.missingDevice));
  check(results, '失敗のあと、カメラを取得し直せる', measured.cameraAgain.state === 'active' && measured.cameraAgain.layout === 'camera_only', JSON.stringify(measured.cameraAgain));
  check(results, '混合にマイクが反映され、偽のマイクの音声（ビープ）が、混合の出力に現れる（最大の振幅 > 0.001）', measured.mixerWithMic.hasMic && measured.mixerWithMic.maxAbs > 0.001 && measured.mixerWithMic.blocks > 500, JSON.stringify(measured.mixerWithMic));
  check(results, '画面共有を取得: 取得済み・共有音声も取得済み（偽の UI の画面は、音声を持つ）・混合へ反映。レイアウトは、カメラと画面共有で、ワイプ', measured.screen.state === 'active' && measured.screen.trackKind === 'video' && measured.screen.sharedAudio === 'active' && measured.screen.mixerHasShared && measured.screen.layout === 'screen_with_wipe', JSON.stringify(measured.screen));
  check(results, 'マイクのトラックの終了: 喪失になり、混合から外れる。混合は、止まらず、継続する（ブロックが来続ける）', measured.afterMicLoss.state === 'lost' && !measured.afterMicLoss.mixerHasMic && measured.afterMicLoss.mixerStatus === 'running' && measured.afterMicLoss.newBlocks > 30, JSON.stringify(measured.afterMicLoss));
  check(results, '画面共有のトラックの終了: 画面共有も共有音声も喪失。共有音声は混合から外れ、レイアウトはカメラのみ', measured.afterScreenLoss.screen === 'lost' && measured.afterScreenLoss.shared === 'lost' && !measured.afterScreenLoss.mixerHasShared && measured.afterScreenLoss.layout === 'camera_only', JSON.stringify(measured.afterScreenLoss));
  check(results, 'ソースの追加・喪失の間も、ブロックの累積サンプル数は、途切れない', measured.blockGaps === 0, `gaps=${measured.blockGaps}`);
  check(results, '破棄（dispose）で、取得済みのトラックを止める（カメラのトラックは、破棄の前は live、破棄のあとは ended）。未取得へ戻る', measured.afterDispose.cameraTrackBefore === 'live' && measured.afterDispose.cameraTrackAfter === 'ended' && measured.afterDispose.camera === 'detached' && measured.afterDispose.sharedTrackEnded === 'ended', JSON.stringify(measured.afterDispose));
  check(results, '音声・映像の要素（<audio>・<video>）を作らない（取得した音声を、再生へ接続しない。折り返し再生をしない）', measured.mediaElements === 0, `elements=${measured.mediaElements}`);
  check(results, '例外の処理へ渡った購読者の例外・混合器の例外が 0 件', measured.errors.length === 0, JSON.stringify(measured.errors));
  check(results, '診断（ログ）に、デバイス名・ラベル・デバイスの識別子を含めない', !/fake_device|Fake|does-not-exist/i.test(measured.diagnosticsText), measured.diagnosticsText.slice(0, 200));
  return results;
}

function compareScreenWithoutFakeUi(measured) {
  const results = [];
  console.log('--- E. 画面共有の選択画面が使えない環境（偽の UI なし）');
  check(results, 'attach("screen") は、10 秒以内に決着する（要求中のまま止まらない）', measured.race.kind !== 'timeout', JSON.stringify(measured.race));
  check(results, '状態は、要求中のままではなく、未取得（detached）へ戻る。共有音声も', measured.screenState === 'detached' && measured.sharedState === 'detached', JSON.stringify({ screen: measured.screenState, shared: measured.sharedState, reason: measured.reason }));
  console.log(`info 実測の結果: ${JSON.stringify(measured.race)}（Chromium の headless では NotSupportedError -> 型付きのエラー unsupported のはず）`);
  return results;
}

// ---------------------------------------------------------------------------
// 実行
// ---------------------------------------------------------------------------

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const frontendRoot = path.join(options.repo, 'src', 'frontend');
  const playwrightCandidates = [
    options.playwrightDir && path.join(options.playwrightDir, 'node_modules', 'playwright'),
    path.join(frontendRoot, 'node_modules', 'playwright'),
  ].filter(Boolean);
  const playwright = loadModule('Playwright', playwrightCandidates);
  const ts = loadModule('TypeScript', [path.join(frontendRoot, 'node_modules', 'typescript')]);
  for (const required of ['lib/audio/index.ts', 'lib/sources/index.ts', 'public/worklets/stream-mixer-processor.js']) {
    if (!fs.existsSync(path.join(frontendRoot, required))) {
      console.log(`FAIL 必要なファイルがありません: ${required}`);
      process.exit(EXIT_MISMATCH);
    }
  }

  const server = createServer(ts, frontendRoot);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}/`;

  const launchOptions = options.channel ? { channel: options.channel } : {};
  const fakeDeviceArguments = ['--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required'];
  let browser;
  try {
    browser = await playwright.chromium.launch({ ...launchOptions, args: [...fakeDeviceArguments, '--use-fake-ui-for-media-stream'] });
  } catch (error) {
    server.close();
    return unavailable(`Chromium を起動できません（${String(error && error.message).split('\n')[0]}）`);
  }

  const results = [];
  const pageErrors = [];
  try {
    const open = async (activeBrowser) => {
      const page = await activeBrowser.newPage();
      page.on('pageerror', (error) => pageErrors.push(String(error && error.message)));
      await page.goto(base);
      await page.waitForFunction(() => window.__issue26Ready === true, null, { timeout: 30000 });
      return page;
    };

    const userAgent = await (await open(browser)).evaluate(() => navigator.userAgent);
    console.log(`info ブラウザ: ${userAgent}`);

    const page = await open(browser);
    results.push(...compareMixer(await page.evaluate(scenarioMixer)));
    results.push(...compareWorkerPath(await (await open(browser)).evaluate(scenarioWorkerPath)));
    results.push(...compareStallResume(await (await open(browser)).evaluate(scenarioStallResume)));
    results.push(...compareSources(await (await open(browser)).evaluate(scenarioSources)));

    // E は、偽の UI なしのブラウザで
    const plain = await playwright.chromium.launch({ ...launchOptions, args: fakeDeviceArguments });
    try {
      results.push(...compareScreenWithoutFakeUi(await (await open(plain)).evaluate(scenarioScreenWithoutFakeUi)));
    } finally {
      await plain.close();
    }

    console.log('--- ページの未処理の例外');
    check(results, 'ページの未処理の例外（pageerror）が 0 件', pageErrors.length === 0, JSON.stringify(pageErrors));
  } finally {
    await browser.close();
    server.close();
  }

  const failed = results.filter((result) => !result.ok);
  if (options.json) {
    console.log(JSON.stringify({ results }, null, 2));
  }
  console.log(`\n実機（Chromium）の確認: ${results.length - failed.length} 件 ok / ${failed.length} 件 FAIL`);
  process.exit(failed.length === 0 ? EXIT_OK : EXIT_MISMATCH);
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(EXIT_MISMATCH);
});
