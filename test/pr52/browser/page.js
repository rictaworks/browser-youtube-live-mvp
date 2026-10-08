// 実ブラウザの確認用のページ（issue #27）。製品のコード（lib/pipeline の PipelineClient・lib/audio の AudioMixer・workers/pipeline の本体）を、
// そのまま import して、実際のブラウザ（Playwright の Chromium）で動かす。シナリオは、window.__issue27 の関数。結果は、JSON にできる値。
// 確認する内容の判定は、Node 側（probe_pipeline.cjs）。このファイルは、測って返すだけ。
//
// 偽のデバイス: カメラ・マイクは --use-fake-device-for-media-stream。映像ソースの多くは、キャンバス（captureStream）から作る合成のトラックで、
// 画素が決まっている（赤の画面共有・青のカメラ）ので、合成の位置・色を、画素で確かめられる。
import { PipelineClient } from '/app/lib/pipeline/index.js';
import { AudioMixer, createBrowserAudioEnvironment } from '/app/lib/audio/index.js';
import { audioTimeUs, videoTimeUs } from '/app/core/clock/index.js';
import { evaluateCapabilities, readBrowserCapabilities } from '/app/core/capability/index.js';
import { wipeRect } from '/app/core/layout/index.js';

const pageParameters = new URL(location.href).searchParams;
const audioMode = pageParameters.get('audio') === 'real' ? 'real' : 'fake';
// ?debug=1 のときだけ、診断の出力（クライアントの diagnostic・段階の印）をコンソールへ出す。通常は静か
const debug = pageParameters.get('debug') === '1' ? (message) => console.debug(message) : () => undefined;
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

// 調べるとき（?debug=1）だけ: メインスレッドの遅れ（周期の処理が、予定より大きく遅れた時間）を表示する
if (pageParameters.get('debug') === '1') {
  let lastBeat = performance.now();
  setInterval(() => {
    const now = performance.now();
    const late = now - lastBeat - 500;
    if (late > 250) {
      debug(`main-thread-late ${Math.round(late)} ms (at ${Math.round(now)} ms)`);
    }
    lastBeat = now;
  }, 500);
}

async function waitFor(condition, timeoutMilliseconds = 8000) {
  const deadline = performance.now() + timeoutMilliseconds;
  while (!condition() && performance.now() < deadline) {
    await sleep(20);
  }
  return condition();
}

function newState() {
  return { layouts: [], chunks: [], faults: [], ended: [], configChanges: [] };
}

/** ワーカーを作り、計測用のポートを渡す。 */
function createProbeWorker(handle) {
  const worker = new Worker(`/probe/probe_worker.js?audio=${audioMode}&debug=${pageParameters.get('debug') === '1' ? 1 : 0}&slowCompose=${Number(pageParameters.get('slowCompose') || 0)}`, { type: 'module' });
  const channel = new MessageChannel();
  worker.postMessage({ probe: 'port', port: channel.port2 }, [channel.port2]);
  const pending = new Map();
  let nextId = 1;
  channel.port1.onmessage = (event) => {
    const resolve = pending.get(event.data.id);
    pending.delete(event.data.id);
    if (resolve) {
      resolve(event.data.result);
    }
  };
  handle.worker = worker;
  handle.ask = (message) =>
    new Promise((resolve) => {
      const id = nextId++;
      pending.set(id, resolve);
      channel.port1.postMessage({ ...message, id });
    });
  return worker;
}

async function startClient(state, options = {}) {
  const handle = { worker: null, ask: null };
  const client = new PipelineClient({
    createWorker: options.createWorker || (() => createProbeWorker(handle)),
    diagnostic: (event, fields) => debug(`client: ${event} ${JSON.stringify(fields)}`),
    onChunk: (chunk) => state.chunks.push(chunk),
    onFault: (fault) => {
      state.faults.push(fault);
      debug(`page: fault ${JSON.stringify(fault)}`);
    },
    onLayoutChanged: (layout) => state.layouts.push(layout),
    onSourceEnded: (kind) => state.ended.push(kind),
    onDecoderConfigChanged: (config) => state.configChanges.push({ kind: config.kind, length: config.description.length }),
  });
  const startedAt = performance.now();
  await client.start();
  return { client, ask: handle.ask, worker: handle.worker, startMilliseconds: performance.now() - startedAt };
}

/** キャンバスから作る合成の映像トラック。色が決まっているので、合成の画素を確かめられる。animate: 動く白い四角を足す（エンコーダに動きを与える）。 */
function syntheticSource(color, width, height, { animate = false, noise = false, refreshMilliseconds = 100 } = {}) {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d');
  let phase = 0;
  const draw = () => {
    context.fillStyle = color;
    context.fillRect(0, 0, width, height);
    if (animate) {
      phase = (phase + 23) % (width - 80);
      context.fillStyle = '#ffffff';
      context.fillRect(phase, 20, 80, 80);
    }
    if (noise) {
      // 情報量の多い映像（符号化の目標のビットレートに、実績が届くようにする）。画面の下半分に、乱数の色のブロックを敷き詰める
      for (let y = Math.floor(height / 2); y < height; y += 8) {
        for (let x = 0; x < width; x += 8) {
          context.fillStyle = `rgb(${Math.floor(Math.random() * 256)},${Math.floor(Math.random() * 256)},${Math.floor(Math.random() * 256)})`;
          context.fillRect(x, y, 8, 8);
        }
      }
    }
  };
  draw();
  const track = canvas.captureStream(30).getVideoTracks()[0];
  let timer = setInterval(draw, refreshMilliseconds);
  return {
    track,
    pause() {
      clearInterval(timer);
      timer = null;
    },
    stop() {
      clearInterval(timer);
      timer = null;
      track.stop();
    },
  };
}

function mixerEnvironment(contexts) {
  const base = createBrowserAudioEnvironment(window);
  return {
    ...base,
    createContext: (options) => {
      const context = base.createContext(options);
      contexts.push(context);
      return context;
    },
  };
}

/** H.264 の AVCC 形式（各 NAL の前に 4 バイトの長さ）として正しく読めるか。NAL の種類（下位 5 ビット）を返す。 */
function walkAvcc(data) {
  const nalTypes = [];
  let offset = 0;
  while (offset + 4 <= data.length) {
    const length = ((data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
    if (length === 0 || offset + 4 + length > data.length) {
      return { ok: false, nalTypes };
    }
    nalTypes.push(data[offset + 4] & 0x1f);
    offset += 4 + length;
  }
  return { ok: offset === data.length, nalTypes };
}

/** A. 4 つのレイアウトの画素（合成の位置・色・角の丸め）と、プレビュー = 合成、動きの無い画面共有、ソースの喪失 */
async function layouts() {
  const state = newState();
  const { client, ask, startMilliseconds } = await startClient(state);
  client.attachPreview(document.getElementById('preview'));
  const pixels = (points, target = 'composite') => ask({ probe: 'pixels', target, points });
  const untilLayout = async (name) => {
    const reached = await waitFor(() => state.layouts[state.layouts.length - 1] === name, 10000);
    await sleep(250);
    return reached;
  };
  const result = { startMilliseconds };

  result.reachedSlate = await untilLayout('slate');
  result.slate = await pixels([[2, 2], [1277, 717], [640, 360]]);
  result.slateCompare = await ask({ probe: 'compare' });

  const camera = syntheticSource('#0000ff', 640, 480);
  client.addVideoSource('camera', camera.track);
  result.reachedCameraOnly = await untilLayout('camera_only');
  result.cameraOnly = await pixels([[80, 360], [640, 360], [1200, 360], [640, 5], [640, 715]]);

  const screen = syntheticSource('#ff0000', 1280, 720);
  client.addVideoSource('screen', screen.track);
  result.reachedWipe = await untilLayout('screen_with_wipe');
  const wipe = wipeRect(1280, 720, 640 / 480);
  result.wipe = { x: wipe.x, y: wipe.y, width: wipe.width, height: wipe.height, cornerRadius: wipe.cornerRadius };
  const inset = Math.round(wipe.cornerRadius / 2);
  const points = [
    [100, 100], // 主映像（画面共有）
    [wipe.x + Math.floor(wipe.width / 2), wipe.y + Math.floor(wipe.height / 2)], // ワイプの中心（カメラ）
    [wipe.x, wipe.y], // ワイプの左上の角: 角の丸めで切り取られ、下の画面共有が見える
    [wipe.x + 2, wipe.y + 2], // 同上（角の外側）
    [wipe.x + wipe.width - 1, wipe.y + wipe.height - 1], // ワイプの右下の角（切り取られる）
    [wipe.x + inset + 4, wipe.y + inset + 4], // 角の丸めの内側（カメラ）
    [wipe.x + wipe.width - inset - 5, wipe.y + wipe.height - inset - 5],
    [wipe.x - 6, wipe.y + Math.floor(wipe.height / 2)], // ワイプの左隣（画面共有）
    [1279, 719], // 外側の余白の右下の端（画面共有）
  ];
  result.withWipe = await pixels(points);
  result.withWipePoints = points;
  result.compareWithWipe = await ask({ probe: 'compare' });
  result.previewPixels = await pixels(points, 'preview');

  // 動きの無い画面共有・カメラ（新しいフレームが届かない）でも、最後のフレームを描き続ける
  screen.pause();
  camera.pause();
  await sleep(1500);
  result.staticPixels = await pixels([[100, 100], [wipe.x + Math.floor(wipe.width / 2), wipe.y + Math.floor(wipe.height / 2)]]);
  result.staticStats = await client.getStats();

  // 画面共有の喪失 -> カメラのみ -> カメラの喪失（代替スレート）
  screen.stop();
  result.reachedCameraOnlyAgain = await untilLayout('camera_only');
  result.afterScreenLost = await pixels([[80, 360], [640, 360]]);
  camera.stop();
  result.reachedSlateAgain = await untilLayout('slate');
  result.afterCameraLost = await pixels([[2, 2], [640, 360]]);
  result.finalCompare = await ask({ probe: 'compare' });
  result.layoutEvents = state.layouts;
  result.endedEvents = state.ended;
  result.faults = state.faults;
  result.stats = await client.getStats();
  result.counters = await ask({ probe: 'counters' });
  client.terminate();
  return result;
}

/** ストリームの準備: 映像ソース（動く画面共有 + 偽のカメラ）・プレビュー・音声のミキサーをつなぎ、設定して、送出を始める。 */
async function beginStreaming(state, { profile = '720p', videoBitrateKbps = 4500, withCamera = true, withScreen = true, videoCodec = null, noise = false } = {}) {
  const started = await startClient(state);
  const { client, ask } = started;
  client.attachPreview(document.getElementById('preview'));
  // 動く画面共有の代わり。この環境（GPU の無いヘッドレスの Chromium）では、動く 1280x720 以上の映像ソースを、カメラと同時に合成・符号化すると、CPU が足りず、
  // 入力待ちの破棄が増える（実測。1920x1080 では、ワーカーでの drawImage が数秒単位で止まる）ので、640x360 にする。合成で 1280x720 へ拡大される
  const screen = withScreen ? syntheticSource('#ff0000', 640, 360, { animate: true, noise, refreshMilliseconds: 100 }) : null;
  if (screen !== null) {
    client.addVideoSource('screen', screen.track);
  }
  let cameraStream = null;
  if (withCamera) {
    cameraStream = await navigator.mediaDevices.getUserMedia({ video: true });
    client.addVideoSource('camera', cameraStream.getVideoTracks()[0]);
  }
  if (pageParameters.get('debug') === '1') {
    // 1 秒ごとに get_stats の往復を測り、ワーカーのメディア時間が実時間からどれだけ遅れているか（音声の処理の遅れの深さ）を表示する
    const clockStart = performance.now();
    setInterval(async () => {
      const asked = performance.now();
      try {
        const stats = await client.getStats();
        const answered = performance.now();
        const media = stats.clock === null ? null : stats.clock.sampleCount / 44100;
        debug(`stats-probe round-trip=${Math.round(answered - asked)}ms wall=${((answered - clockStart) / 1000).toFixed(1)}s media=${media === null ? 'n/a' : media.toFixed(1)}s composed=${stats.composedFrames} skippedForLag=${stats.skippedForLag} dropped=${stats.droppedBeforeEncode}`);
      } catch (error) {
        debug(`stats-probe failed ${error && error.code}`);
      }
    }, 1000);
  }
  const expectedLayout = withScreen ? (withCamera ? 'screen_with_wipe' : 'screen_only') : 'camera_only';
  await waitFor(() => state.layouts.includes(expectedLayout), 10000);

  const contexts = [];
  const mixer = new AudioMixer({ environment: mixerEnvironment(contexts), onListenerError: (error) => state.faults.push({ code: `listener:${error && error.message}`, detail: null }) });
  mixer.subscribe(client.audioListener);
  await mixer.start({ sink: client.openAudioSink() });

  const capabilities = evaluateCapabilities(await readBrowserCapabilities(window));
  const configureStartedAt = performance.now();
  debug('page: configure sent');
  const configured = await client.configure({ profile, videoCodec: videoCodec || capabilities.videoCodec, videoBitrateKbps });
  debug('page: configured');
  const configureMilliseconds = performance.now() - configureStartedAt;
  client.beginDelivery();
  return {
    ...started,
    screen,
    cameraStream,
    mixer,
    contexts,
    capabilities,
    configured,
    configureMilliseconds,
    async finish() {
      debug('page: endSession');
      await client.endSession();
      debug('page: endSession ok');
      await mixer.stop();
      if (screen !== null) {
        screen.stop();
      }
      if (cameraStream) {
        cameraStream.getTracks().forEach((track) => track.stop());
      }
    },
  };
}

function summarizeVideo(chunks) {
  const video = chunks.filter((chunk) => chunk.kind === 'video');
  const keys = video.filter((chunk) => chunk.keyframe).map((chunk) => chunk.timestampUs);
  const grid = video.every((chunk) => {
    const index = Math.round((chunk.timestampUs * 30) / 1_000_000);
    return videoTimeUs(index) === chunk.timestampUs;
  });
  const walked = video.map((chunk) => walkAvcc(chunk.data));
  const duration = video.length > 1 ? (video[video.length - 1].timestampUs - video[0].timestampUs) / 1_000_000 : 0;
  const firstIndex = video.length > 0 ? Math.round((video[0].timestampUs * 30) / 1_000_000) : 0;
  const lastIndex = video.length > 0 ? Math.round((video[video.length - 1].timestampUs * 30) / 1_000_000) : 0;
  return {
    count: video.length,
    lastTimestampUs: video.length > 0 ? video[video.length - 1].timestampUs : null,
    missingOnGrid: video.length > 0 ? lastIndex - firstIndex + 1 - video.length : 0,
    firstIsKey: video.length > 0 && video[0].keyframe,
    keyTimestamps: keys,
    keyIntervals: keys.slice(1).map((time, index) => time - keys[index]),
    onGrid: grid,
    strictlyIncreasing: video.every((chunk, index) => index === 0 || chunk.timestampUs > video[index - 1].timestampUs),
    durationSeconds: duration,
    fps: duration > 0 ? (video.length - 1) / duration : 0,
    avccOk: walked.every((entry) => entry.ok),
    keyHasIdr: video.every((chunk, index) => !chunk.keyframe || walked[index].nalTypes.includes(5)),
    noParameterSetsInFrames: walked.every((entry) => !entry.nalTypes.includes(7) && !entry.nalTypes.includes(8)),
    maxBytes: video.reduce((max, chunk) => Math.max(max, chunk.byteLength), 0),
    totalBytes: video.reduce((sum, chunk) => sum + chunk.byteLength, 0),
  };
}

function summarizeAudio(chunks) {
  const audio = chunks.filter((chunk) => chunk.kind === 'audio');
  if (audio.length === 0) {
    return { count: 0 };
  }
  // 最初のチャンクの時刻から、起点の累積サンプル数（128 の倍数）を求め、以後は audioTime(起点 + n × 1,024) と一致するか
  const approx = Math.round((audio[0].timestampUs * 44100) / 1_000_000);
  const start = Math.round(approx / 128) * 128;
  const deltas = audio.slice(1).map((chunk, index) => chunk.timestampUs - audio[index].timestampUs);
  return {
    count: audio.length,
    lastTimestampUs: audio[audio.length - 1].timestampUs,
    startSample: start,
    firstMatches: audioTimeUs(start) === audio[0].timestampUs,
    allMatch: audio.every((chunk, index) => audioTimeUs(start + index * 1024) === chunk.timestampUs),
    minDelta: Math.min(...deltas),
    maxDelta: Math.max(...deltas),
    strictlyIncreasing: deltas.every((delta) => delta > 0),
    allNotKeyframe: audio.every((chunk) => chunk.keyframe === false),
  };
}

/** 映像の符号化結果を、復号して確かめる（AVCC のまま・復号器設定が正しいか）。復号した最後のフレームの色も読む。 */
async function decodeVideo(chunks, configured, expectedWidth, expectedHeight) {
  const video = chunks.filter((chunk) => chunk.kind === 'video');
  const firstKey = video.findIndex((chunk) => chunk.keyframe);
  const sizes = new Set();
  const errors = [];
  let decoded = 0;
  let lastPixel = null;
  const canvas = new OffscreenCanvas(expectedWidth, expectedHeight);
  const context = canvas.getContext('2d', { willReadFrequently: true });
  const decoder = new VideoDecoder({
    output: (frame) => {
      decoded += 1;
      sizes.add(`${frame.displayWidth}x${frame.displayHeight}`);
      context.drawImage(frame, 0, 0);
      lastPixel = Array.from(context.getImageData(100, 100, 1, 1).data);
      frame.close();
    },
    error: (error) => errors.push(`${error.name}`),
  });
  decoder.configure({ codec: configured.video.codec, description: configured.video.description, codedWidth: expectedWidth, codedHeight: expectedHeight });
  for (const chunk of video.slice(firstKey)) {
    decoder.decode(new EncodedVideoChunk({ type: chunk.keyframe ? 'key' : 'delta', timestamp: chunk.timestampUs, data: chunk.data }));
  }
  await decoder.flush();
  decoder.close();
  return { decoded, expected: video.length - firstKey, sizes: Array.from(sizes), errors, lastPixel };
}

/**
 * B. 全経路（偽のカメラ + 合成の画面共有 -> 合成 -> 実際の H.264 のエンコード、音声は疑似の AAC）を、数秒間流して、符号化結果を調べる。
 * 画素の読み出し（プレビュー = 合成の比較）は、開始の 1.5 秒後に 1 回だけ行う。GPU の無い環境（ヘッドレスの Chromium の SwiftShader）では、
 * 描画の待ちが数秒で溜まり、読み出しがその全部の完了を待つので、配信中の遅い時期に読み出すと、ワーカーが数秒止まる（実測）。
 */
async function stream({ seconds = 6, profile = '720p', videoBitrateKbps = 4500, videoCodec = null } = {}) {
  const state = newState();
  const run = await beginStreaming(state, { profile, videoBitrateKbps, videoCodec });
  const { client, ask } = run;
  const width = profile === '720p' ? 1280 : 854;
  const height = profile === '720p' ? 720 : 480;
  // 配信が始まった時点の、ワーカーのタイマの周期の処理の回数（以後、増えないこと = 配信中は音声の処理周期だけが駆動する）
  const previewTicksAtBegin = (await ask({ probe: 'counters' })).previewIntervalTicks.length;
  await sleep(1500);
  const compare = await ask({ probe: 'compare' });
  debug('page: compare ok');
  await sleep(Math.max(0, seconds * 1000 - 1500));
  debug(`page: chunks so far ${state.chunks.length}`);
  const statsDuring = await client.getStats();
  debug(`page: stats ${JSON.stringify(statsDuring)}`);
  const countersDuring = await ask({ probe: 'counters' });
  debug('page: counters ok');
  const chunks = state.chunks.slice();
  const result = {
    audioMode,
    capabilities: { canStart: run.capabilities.canStart, videoCodec: run.capabilities.videoCodec, missingRequired: run.capabilities.missingRequired },
    configureMilliseconds: run.configureMilliseconds,
    configured: {
      videoCodec: run.configured.video.codec,
      videoDescriptionLength: run.configured.video.description.length,
      videoDescriptionHead: Array.from(run.configured.video.description.slice(0, 4)),
      audioDescription: Array.from(run.configured.audio.description),
    },
    video: summarizeVideo(chunks),
    audio: summarizeAudio(chunks),
    decode: await decodeVideo(chunks, run.configured, width, height),
    statsDuring,
    countersDuring: { ...countersDuring, videoOutputs: undefined, previewIntervalTicks: countersDuring.previewIntervalTicks.length },
    previewVersusComposite: compare,
    previewTicksDuringStream: countersDuring.previewIntervalTicks.length - previewTicksAtBegin,
    faults: state.faults,
    layouts: state.layouts,
    configChanges: state.configChanges,
  };
  debug('page: decode ok');
  await run.finish();
  debug('page: finished');
  result.countersAfter = await ask({ probe: 'counters' }).then((counters) => ({ snapshotsCreated: counters.snapshotsCreated, snapshotsClosed: counters.snapshotsClosed, audioDataSeen: counters.audioDataSeen, audioDataReadable: counters.audioDataReadable }));
  result.statsAfter = await client.getStats();
  client.terminate();
  return result;
}

/** C. 音声の停止（AudioContext の suspend）で合成が止まり、再開でキーフレームから再開する */
async function stall() {
  const state = newState();
  const run = await beginStreaming(state, { withCamera: false });
  const { client, contexts } = run;
  await sleep(1500);
  const before = await client.getStats();
  const chunksBefore = state.chunks.length;

  await contexts[0].suspend();
  await sleep(500);
  const atSuspend = await client.getStats();
  await sleep(1500);
  const duringSuspend = await client.getStats();
  const chunksDuringSuspendStart = state.chunks.length;
  await contexts[0].resume();
  await sleep(1500);
  const after = await client.getStats();
  const videoAfter = state.chunks.slice(chunksDuringSuspendStart).filter((chunk) => chunk.kind === 'video');
  const videoBefore = state.chunks.slice(0, chunksDuringSuspendStart).filter((chunk) => chunk.kind === 'video');
  const result = {
    before: { composed: before.composedFrames, clock: before.clock },
    atSuspend: { composed: atSuspend.composedFrames, clock: atSuspend.clock },
    duringSuspend: { composed: duringSuspend.composedFrames, clock: duringSuspend.clock },
    after: { composed: after.composedFrames, clock: after.clock },
    chunksBefore,
    firstVideoAfterResumeIsKey: videoAfter.length > 0 && videoAfter[0].keyframe,
    videoAfterResume: videoAfter.length,
    timestampStepAcrossResumeUs: videoAfter.length > 0 && videoBefore.length > 0 ? videoAfter[0].timestampUs - videoBefore[videoBefore.length - 1].timestampUs : null,
    faults: state.faults,
  };
  await run.finish();
  client.terminate();
  return result;
}

/** D. 配信中のビットレートの変更（再設定）で、実際のエンコーダが、キーフレーム・復号器設定を出すか（出力と設定の記録から） */
async function bitrate() {
  const state = newState();
  const run = await beginStreaming(state, { withCamera: false, noise: true });
  const { client, ask } = run;
  await sleep(3000);
  const bytesBetween = (from, to) => state.chunks.filter((chunk) => chunk.kind === 'video' && chunk.timestampUs >= from && chunk.timestampUs < to).reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const lastTimestamp = () => state.chunks.filter((chunk) => chunk.kind === 'video').slice(-1)[0].timestampUs;
  const keyIntervals = () => {
    const keys = state.chunks.filter((chunk) => chunk.kind === 'video' && chunk.keyframe).map((chunk) => chunk.timestampUs);
    return keys.slice(1).map((time, index) => time - keys[index]);
  };
  const t0 = lastTimestamp();
  const before = await ask({ probe: 'counters' });
  client.setBitrate(3000);
  await sleep(300);
  const keyframeAfterReconfigure = state.chunks.filter((chunk) => chunk.kind === 'video' && chunk.keyframe && chunk.timestampUs > t0);
  await sleep(3000);
  const t1 = lastTimestamp();
  const after = await ask({ probe: 'counters' });
  client.setBitrate(6000);
  await sleep(3000);
  const afterRaise = await ask({ probe: 'counters' });
  const reconfigured = after.videoOutputs.slice(before.videoOutputs.length);
  const result = {
    configures: afterRaise.videoConfigures.map((entry) => entry.bitrate),
    configuresKeepOtherSettings: afterRaise.videoConfigures.every((entry) => entry.bitrateMode === 'constant' && entry.latencyMode === 'realtime' && entry.avcFormat === 'avc' && entry.width === 1280 && entry.height === 720),
    keyframesWithin300msAfterReconfigure: keyframeAfterReconfigure.length,
    irregularKeyframes: keyIntervals().filter((interval) => interval < 2_000_000).length,
    maxKeyInterval: Math.max(...keyIntervals()),
    decoderConfigOutputsAfterReconfigure: reconfigured.filter((entry) => entry.hasDecoderConfig).length,
    keyOutputsAfterReconfigure: reconfigured.filter((entry) => entry.type === 'key').map((entry) => entry.timestamp),
    configChanges: state.configChanges,
    kbpsBefore: Math.round((bytesBetween(t0 - 3_000_000, t0) * 8) / 3000),
    kbpsAfterLowering: Math.round((bytesBetween(t1 - 2_000_000, t1) * 8) / 2000),
    faults: state.faults,
  };
  await run.finish();
  client.terminate();
  return result;
}

/** E. ワーカーの異常終了（未処理の例外）を検知して通知する。ワーカーのスクリプトの読み込みの失敗も、start の拒否になる */
async function crash() {
  const state = newState();
  const { client, ask } = await startClient(state);
  const before = await client.getStats();
  await ask({ probe: 'throw' });
  await waitFor(() => state.faults.some((fault) => fault.code === 'worker_crashed'), 5000);
  const afterCrash = await client.getStats().then(
    () => 'resolved',
    (error) => error.code,
  );
  const sendAfterCrash = (() => {
    try {
      client.requestKeyframe();
      return 'no error';
    } catch (error) {
      return error.code;
    }
  })();
  const loadFailure = await (async () => {
    const failed = new PipelineClient({ createWorker: () => new Worker('/probe/no_such_worker.js', { type: 'module' }), onChunk: () => undefined, onFault: () => undefined });
    return failed.start().then(
      () => 'resolved',
      (error) => error.code,
    );
  })();
  return { modeBefore: before.mode, faults: state.faults, afterCrash, sendAfterCrash, loadFailure };
}

/**
 * F. 合成が遅い環境（?slowCompose=ミリ秒 でワーカーの合成を遅くした状態）での配信。ワーカーが遅れても、制御の応答・音声・メディアクロックが保たれるか。
 * 1 秒ごとに get_stats の往復を測り、ワーカーのメディアクロックが実時間から遅れていく様子（処理待ちの深さ）を記録する。
 * 合成のたびに待ちが積み上がる環境で、遅れの検知（LagGuard）が働かないと、待ちが増え続け、get_stats・end_session の応答が返らなくなる（実測）。
 */
async function overload({ seconds = 8 } = {}) {
  const state = newState();
  let run;
  try {
    run = await beginStreaming(state, { profile: '720p', videoBitrateKbps: 4500 });
  } catch (error) {
    // 設定（configure）の要求が期限切れになるなど: 失敗として返す（判定は Node 側）
    return { samples: [], failure: `start: ${(error && error.code) || String(error)}`, finishMs: 0, audioChunks: 0, videoChunks: 0, audioSummary: { count: 0 }, finalMode: null, faults: state.faults };
  }
  const { client } = run;
  const started = performance.now();
  const samples = [];
  // 要求の期限切れ（request_timeout）などは、例外で打ち切らず、失敗として記録して返す（判定は Node 側）
  let failure = null;
  try {
    while (performance.now() - started < seconds * 1000) {
      const asked = performance.now();
      const stats = await client.getStats();
      const answered = performance.now();
      samples.push({
        wallSeconds: (answered - started) / 1000,
        roundTripMs: answered - asked,
        mediaSeconds: stats.clock === null ? null : stats.clock.sampleCount / 44100,
        composed: stats.composedFrames,
        skippedForLag: stats.skippedForLag,
        dropped: stats.droppedBeforeEncode,
        backlogMs: stats.audioBacklogMs,
      });
      await sleep(1000);
    }
  } catch (error) {
    failure = `getStats: ${(error && error.code) || String(error)}`;
  }
  const chunks = state.chunks.slice();
  const finishAsked = performance.now();
  let finalMode = null;
  try {
    await run.finish();
    finalMode = (await client.getStats()).mode;
  } catch (error) {
    failure = failure || `finish: ${(error && error.code) || String(error)}`;
  }
  const finishMs = performance.now() - finishAsked;
  client.terminate();
  const audio = chunks.filter((chunk) => chunk.kind === 'audio');
  const video = chunks.filter((chunk) => chunk.kind === 'video');
  return {
    samples,
    failure,
    finishMs,
    audioChunks: audio.length,
    videoChunks: video.length,
    audioSummary: summarizeAudio(chunks),
    finalMode,
    faults: state.faults,
  };
}

/**
 * F. 非表示のタブでの長時間の計測（probe_hidden_tab.cjs が、生の CDP でタブを本当に非表示にして使う）。
 * 配信を始めたあと、符号化結果のチャンクは、中身を残さず、数・到着の間隔・時刻だけを記録する（長時間でもメモリが増えない）。
 * hiddenSnapshot を呼ぶたびに、前回からの数・最大の到着間隔・ワーカーの統計・タブの可視状態を返す。
 */
let hiddenRun = null;

function newMeter() {
  return { count: 0, bytes: 0, lastArrival: null, maxGapMs: 0, lastTimestampUs: null, nonMonotonic: 0, firstTimestampUs: null };
}

function recordChunk(meter, chunk) {
  const now = performance.now();
  meter.count += 1;
  meter.bytes += chunk.byteLength;
  if (meter.lastArrival !== null) {
    meter.maxGapMs = Math.max(meter.maxGapMs, now - meter.lastArrival);
  }
  meter.lastArrival = now;
  if (meter.firstTimestampUs === null) {
    meter.firstTimestampUs = chunk.timestampUs;
  }
  if (meter.lastTimestampUs !== null && chunk.timestampUs <= meter.lastTimestampUs) {
    meter.nonMonotonic += 1;
  }
  meter.lastTimestampUs = chunk.timestampUs;
}

async function hiddenStart({ profile = '480p', videoBitrateKbps = 1500, videoCodec = 'avc1.42E01F', withScreen = true } = {}) {
  const state = newState();
  const meters = { video: newMeter(), audio: newMeter() };
  state.chunks = { push: (chunk) => recordChunk(meters[chunk.kind], chunk) };
  const visibilityChanges = [];
  document.addEventListener('visibilitychange', () => visibilityChanges.push([Math.round(performance.now()), document.visibilityState]));
  const run = await beginStreaming(state, { profile, videoBitrateKbps, videoCodec, withScreen });
  hiddenRun = { state, meters, run, visibilityChanges, startedAt: performance.now(), lastSnapshotCounts: { video: 0, audio: 0 } };
  return { visibility: document.visibilityState, configureMilliseconds: run.configureMilliseconds, layouts: state.layouts.slice() };
}

async function hiddenSnapshot() {
  const { state, meters, run } = hiddenRun;
  const stats = await run.client.getStats();
  const now = performance.now();
  const snapshot = {
    wallMs: now - hiddenRun.startedAt,
    visibility: document.visibilityState,
    hidden: document.hidden,
    video: { count: meters.video.count, bytes: meters.video.bytes, maxGapMs: meters.video.maxGapMs, nonMonotonic: meters.video.nonMonotonic, lastTimestampUs: meters.video.lastTimestampUs },
    audio: { count: meters.audio.count, bytes: meters.audio.bytes, maxGapMs: meters.audio.maxGapMs, nonMonotonic: meters.audio.nonMonotonic, lastTimestampUs: meters.audio.lastTimestampUs },
    stats: {
      composedFrames: stats.composedFrames,
      encodedVideoFrames: stats.encodedVideoFrames,
      droppedBeforeEncode: stats.droppedBeforeEncode,
      skippedForLag: stats.skippedForLag,
      composeFailures: stats.composeFailures,
      deliveredVideoChunks: stats.deliveredVideoChunks,
      deliveredAudioChunks: stats.deliveredAudioChunks,
      framesReceived: stats.framesReceived,
      framesClosed: stats.framesClosed,
      framesRetained: stats.framesRetained,
      videoFaulted: stats.videoFaulted,
      audioFaulted: stats.audioFaulted,
      clock: stats.clock,
    },
    faults: state.faults.slice(),
  };
  // 次の窓のために、最大の到着間隔を戻す
  meters.video.maxGapMs = 0;
  meters.audio.maxGapMs = 0;
  return snapshot;
}

async function hiddenFinish() {
  const { state, run, visibilityChanges } = hiddenRun;
  await run.finish();
  const statsAfter = await run.client.getStats();
  run.client.terminate();
  return { faults: state.faults, visibilityChanges, modeAfter: statsAfter.mode, framesReceived: statsAfter.framesReceived, framesClosed: statsAfter.framesClosed, framesRetained: statsAfter.framesRetained };
}

window.__issue27 = { layouts, stream, stall, bitrate, crash, overload, hiddenStart, hiddenSnapshot, hiddenFinish, audioMode };
window.__issue27Ready = true;
