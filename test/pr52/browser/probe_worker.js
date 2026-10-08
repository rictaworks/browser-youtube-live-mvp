// 実ブラウザの確認用の、配信パイプラインのワーカーの入り口（issue #27）。製品のワーカー（workers/pipeline/pipeline.worker.ts）と同じ入り口の関数
// （startPipelineWorker）を使い、ワーカーの大域（self）の代わりに、次の差し替えと計測を足した「扉」を渡す。製品のコードは、変えない。
//
//   - AudioEncoder: 既定（?audio=fake）は、疑似の AAC エンコーダ。Linux の Chromium では、AAC のエンコードを使えない（AudioEncoder.isConfigSupported が偽。
//                  AAC は Windows・macOS・Android の Chrome だけ）ので、AAC の実エンコードは、この環境では確認できない。疑似は、1,024 サンプルごとに 1 チャンクを出し、
//                  最初の出力に AudioSpecificConfig（0x12 0x10）を付ける。?audio=real は、実際の AudioEncoder（Windows・macOS の Chrome で、AAC を確認するため）
//   - VideoEncoder: 実際の H.264 のエンコーダを包んで、出力（種類・時刻・復号器設定の有無）と、設定の呼び出しを記録する
//   - VideoFrame:   合成から作った VideoFrame の、作成と close を数える（解放漏れの検査）
//   - OffscreenCanvas: 作ったキャンバスを覚える（合成の結果の画素を読むため）
//   - プレビュー用の canvas: attach_preview のメッセージから覚える（プレビューの画素を読むため）
// 計測の窓口は、ページが渡す専用の MessagePort（{ probe: "port", port }）。製品のメッセージの経路（PipelineClient の onmessage）には、何も流さない。
// 実時計（performance）は、この計測の用具にだけ使う（製品のコードは使わない）。

import { startPipelineWorker } from '/app/workers/pipeline/startWorker.js';

const workerParameters = new URL(self.location.href).searchParams;
const audioMode = workerParameters.get('audio') === 'real' ? 'real' : 'fake';
// ?debug=1 のときだけ、診断の出力をコンソールへ出す。通常は静か
const debug = workerParameters.get('debug') === '1' ? (message) => self.console.debug(message) : () => undefined;
const OUTPUT_LOG_LIMIT = 20000;

const debugEnabled = workerParameters.get('debug') === '1';
// 合成の drawImage 1 回ごとに、この時間だけ、ワーカーのスレッドを塞ぐ（GPU の無い環境・負荷の高い端末で、合成が遅い状態の再現。場面 F）
const slowComposeMs = Number(workerParameters.get('slowCompose') || 0);

function busyWait(milliseconds) {
  const end = self.performance.now() + milliseconds;
  while (self.performance.now() < end) {
    // スレッドを塞ぐ
  }
}

/** drawImage の呼び出しのあとに、slowComposeMs だけスレッドを塞ぐ包み。 */
function slowedContext(context) {
  if (slowComposeMs <= 0) {
    return context;
  }
  return new Proxy(context, {
    get(target, property) {
      const value = Reflect.get(target, property, target);
      if (property === 'drawImage' && typeof value === 'function') {
        return (...args) => {
          const result = value.apply(target, args);
          busyWait(slowComposeMs);
          return result;
        };
      }
      return typeof value === 'function' ? value.bind(target) : value;
    },
    set(target, property, value) {
      return Reflect.set(target, property, value, target);
    },
  });
}
const SLOW_CALL_MS = 250;

/** 調べるとき（?debug=1）だけ: 同期の呼び出しの時間を測り、遅いものを表示する（ワーカーのスレッドを塞ぐ呼び出しを見つけるため）。 */
function timed(label, action) {
  if (!debugEnabled) {
    return action();
  }
  const started = self.performance.now();
  try {
    return action();
  } finally {
    const elapsed = self.performance.now() - started;
    if (elapsed > SLOW_CALL_MS) {
      debug(`slow-call ${label} ${Math.round(elapsed)} ms (at ${Math.round(started)} ms)`);
    }
  }
}

/** 2D コンテキストの各メソッドの呼び出しの時間を測る包み。 */
function timedContext(context, label) {
  if (!debugEnabled) {
    return context;
  }
  return new Proxy(context, {
    get(target, property) {
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? (...args) => timed(`${label}.${String(property)}`, () => value.apply(target, args)) : value;
    },
    set(target, property, value) {
      return Reflect.set(target, property, value, target);
    },
  });
}

/** OffscreenCanvas の包み。getContext が、時間を測る包みの 2D コンテキストを返す。 */
function timedCanvas(canvas, label) {
  if (!debugEnabled) {
    return canvas;
  }
  return new Proxy(canvas, {
    get(target, property) {
      if (property === 'getContext') {
        return (...args) => {
          const context = target.getContext(...args);
          return context === null ? null : timedContext(context, label);
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
    set(target, property, value) {
      return Reflect.set(target, property, value, target);
    },
  });
}

const counters = {
  snapshotsCreated: 0,
  snapshotsClosed: 0,
  videoOutputs: [],
  videoConfigures: [],
  videoEncodeCalls: 0,
  maxEncodeQueueSize: 0,
  previewIntervalTicks: [],
  audioDataSeen: 0,
  audioDataReadable: true,
};
const canvases = [];
let previewCanvas = null;
let probePort = null;

class CountingVideoFrame extends VideoFrame {
  constructor(...args) {
    const started = debugEnabled ? self.performance.now() : 0;
    super(...args);
    if (debugEnabled) {
      const elapsed = self.performance.now() - started;
      if (elapsed > SLOW_CALL_MS) {
        debug(`slow-call new VideoFrame(canvas) ${Math.round(elapsed)} ms (at ${Math.round(started)} ms)`);
      }
    }
    this.closedByPipeline = false;
    counters.snapshotsCreated += 1;
  }

  close() {
    if (!this.closedByPipeline) {
      this.closedByPipeline = true;
      counters.snapshotsClosed += 1;
    }
    super.close();
  }
}

class CapturingOffscreenCanvas extends OffscreenCanvas {
  constructor(width, height) {
    super(width, height);
    canvases.push(this);
  }

  getContext(...args) {
    const context = super.getContext(...args);
    return context === null ? null : timedContext(slowedContext(context), 'composite');
  }
}

class RecordingVideoEncoder {
  constructor(init) {
    this.inner = new VideoEncoder({
      output: (chunk, metadata) => {
        if (counters.videoOutputs.length < OUTPUT_LOG_LIMIT) {
          const decoderConfig = metadata && metadata.decoderConfig;
          counters.videoOutputs.push({
            type: chunk.type,
            timestamp: chunk.timestamp,
            byteLength: chunk.byteLength,
            hasDecoderConfig: Boolean(decoderConfig),
            descriptionLength: decoderConfig && decoderConfig.description ? decoderConfig.description.byteLength : 0,
          });
        }
        init.output(chunk, metadata);
      },
      error: init.error,
    });
  }

  static isConfigSupported(config) {
    return VideoEncoder.isConfigSupported(config);
  }

  get state() {
    return this.inner.state;
  }

  get encodeQueueSize() {
    const size = this.inner.encodeQueueSize;
    if (size > counters.maxEncodeQueueSize) {
      counters.maxEncodeQueueSize = size;
    }
    return size;
  }

  configure(config) {
    counters.videoConfigures.push({
      codec: config.codec,
      width: config.width,
      height: config.height,
      bitrate: config.bitrate,
      framerate: config.framerate,
      bitrateMode: config.bitrateMode,
      latencyMode: config.latencyMode,
      avcFormat: config.avc && config.avc.format,
    });
    this.inner.configure(config);
  }

  encode(frame, options) {
    counters.videoEncodeCalls += 1;
    timed('VideoEncoder.encode', () => this.inner.encode(frame, options));
  }

  flush() {
    return this.inner.flush();
  }

  close() {
    this.inner.close();
  }
}

/** 疑似の AAC エンコーダ。実際の AudioData を受け取り、中身を読めることを確かめ、1,024 サンプルごとに 1 チャンクを出す。 */
class FakeAacEncoder {
  constructor(init) {
    this.init = init;
    this.state = 'unconfigured';
    this.buffered = 0;
    this.firstOutput = true;
  }

  static isConfigSupported(config) {
    return Promise.resolve({ supported: config.codec === 'mp4a.40.2' && config.aac && config.aac.format === 'aac', config });
  }

  configure() {
    this.state = 'configured';
    this.firstOutput = true;
  }

  encode(data) {
    counters.audioDataSeen += 1;
    try {
      const samples = new Float32Array(data.numberOfFrames * data.numberOfChannels);
      data.copyTo(samples, { planeIndex: 0, format: 'f32' });
    } catch (error) {
      counters.audioDataReadable = false;
    }
    this.buffered += data.numberOfFrames;
    while (this.buffered >= 1024) {
      this.buffered -= 1024;
      const bytes = new Uint8Array([0x21, 0x10, 0x04]);
      const chunk = { type: 'key', timestamp: data.timestamp + 1, byteLength: bytes.length, copyTo: (destination) => destination.set(bytes) };
      const metadata = this.firstOutput ? { decoderConfig: { codec: 'mp4a.40.2', description: new Uint8Array([0x12, 0x10]) } } : undefined;
      this.firstOutput = false;
      this.init.output(chunk, metadata);
    }
  }

  flush() {
    return Promise.resolve();
  }

  close() {
    this.state = 'closed';
  }
}

/**
 * 画素を読むときは、読み出し用の別のキャンバスへ写してから読む。合成・プレビューのキャンバス自体に getImageData を呼ぶと、そのキャンバスが
 * GPU から CPU の描画へ切り替わり、以後の描画が極端に遅くなる（実測）ので、計測が配信の経路を乱さないようにする。
 */
function snapshotPixels(canvas) {
  const scratch = new OffscreenCanvas(canvas.width, canvas.height);
  const context = scratch.getContext('2d', { willReadFrequently: true });
  context.drawImage(canvas, 0, 0);
  return context;
}

function readPixels(canvas, points) {
  const context = snapshotPixels(canvas);
  return points.map(([x, y]) => Array.from(context.getImageData(x, y, 1, 1).data));
}

function compareCanvases(a, b) {
  if (a.width !== b.width || a.height !== b.height) {
    return { sameSize: false, widthA: a.width, widthB: b.width, heightA: a.height, heightB: b.height, differing: -1 };
  }
  const dataA = snapshotPixels(a).getImageData(0, 0, a.width, a.height).data;
  const dataB = snapshotPixels(b).getImageData(0, 0, b.width, b.height).data;
  let differing = 0;
  for (let index = 0; index < dataA.length; index += 4) {
    if (dataA[index] !== dataB[index] || dataA[index + 1] !== dataB[index + 1] || dataA[index + 2] !== dataB[index + 2]) {
      differing += 1;
    }
  }
  return { sameSize: true, width: a.width, height: a.height, differing };
}

function handleProbe(request) {
  const composite = canvases[canvases.length - 1];
  let result;
  switch (request.probe) {
    case 'counters':
      result = { ...counters, canvasCount: canvases.length, compositeSize: composite ? [composite.width, composite.height] : null, previewSize: previewCanvas ? [previewCanvas.width, previewCanvas.height] : null, audioMode };
      break;
    case 'pixels':
      result = readPixels(request.target === 'preview' ? previewCanvas : composite, request.points);
      break;
    case 'compare':
      result = previewCanvas && composite ? compareCanvases(composite, previewCanvas) : { error: 'no preview or composite' };
      break;
    case 'throw':
      self.setTimeout(() => {
        throw new Error('probe: uncaught error in the worker');
      }, 0);
      result = { scheduled: true };
      break;
    case 'clock':
      result = { epochMs: self.performance.timeOrigin + self.performance.now() };
      break;
    default:
      result = { error: `unknown probe request ${String(request.probe)}` };
  }
  probePort.postMessage({ id: request.id, result });
}

/** 音声のポートの onmessage の呼び出しの時間を、1 秒ごとに集計する包み（?debug=1 のときだけ使う）。 */
function instrumentAudioPort(port) {
  const window = { count: 0, totalMs: 0, maxMs: 0, maxQueueMs: 0, since: self.performance.now() };
  const flush = () => {
    const now = self.performance.now();
    if (window.count > 0 && now - window.since >= 1000) {
      debug(`audio-port count=${window.count} mean=${(window.totalMs / window.count).toFixed(3)}ms max=${window.maxMs.toFixed(1)}ms (at ${Math.round(now)} ms)`);
      window.count = 0;
      window.totalMs = 0;
      window.maxMs = 0;
      window.since = now;
    }
  };
  return new Proxy(port, {
    get(target, property) {
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
    set(target, property, value) {
      if (property === 'onmessage' && typeof value === 'function') {
        target.onmessage = (event) => {
          const started = self.performance.now();
          try {
            value(event);
          } finally {
            const elapsed = self.performance.now() - started;
            window.count += 1;
            window.totalMs += elapsed;
            window.maxMs = Math.max(window.maxMs, elapsed);
            flush();
          }
        };
        return true;
      }
      return Reflect.set(target, property, value, target);
    },
  });
}

let hostHandler = null;
const scope = {
  VideoEncoder: RecordingVideoEncoder,
  AudioEncoder: audioMode === 'real' ? self.AudioEncoder : FakeAacEncoder,
  VideoFrame: CountingVideoFrame,
  AudioData: self.AudioData,
  OffscreenCanvas: CapturingOffscreenCanvas,
  setInterval: (callback, intervalMs) =>
    self.setInterval(() => {
      counters.previewIntervalTicks.push(self.performance.timeOrigin + self.performance.now());
      callback();
    }, intervalMs),
  clearInterval: (handle) => self.clearInterval(handle),
  setTimeout: (callback, delayMs) => self.setTimeout(callback, delayMs),
  clearTimeout: (handle) => self.clearTimeout(handle),
  postMessage: (message, transfer) => timed(`postMessage(${message && message.type})`, () => self.postMessage(message, transfer)),
  close: () => self.close(),
  get onmessage() {
    return hostHandler;
  },
  set onmessage(next) {
    hostHandler = next;
    self.onmessage = (event) => {
      const data = event.data;
      if (data && typeof data === 'object' && data.probe === 'port') {
        probePort = data.port;
        probePort.onmessage = (message) => handleProbe(message.data);
        return;
      }
      if (debugEnabled && data && typeof data === 'object' && data.type === 'connect_audio') {
        // 音声のポートのメッセージの処理時間を、1 秒ごとに集計して表示する（遅れの原因が、ブロックの処理か、合成かを見分けるため）
        next({ data: { ...data, port: instrumentAudioPort(data.port) } });
        return;
      }
      if (data && typeof data === 'object' && data.type === 'attach_preview') {
        previewCanvas = data.canvas;
        if (debugEnabled) {
          // 製品には、時間を測る包みの canvas を渡す（画素の読み出しには、元の canvas を使う）
          next({ data: { ...data, canvas: timedCanvas(data.canvas, 'preview') } });
          return;
        }
      }
      if (data && data.type && data.type !== 'audio_stalled') {
        debug(`probe-worker: recv ${data.type}`);
      }
      if (next) {
        next(event);
      }
    };
  },
};

// 調べるとき（?debug=1）だけ: ワーカーのスレッドの遅れ（周期の処理が、予定より大きく遅れた時間）を表示する
if (workerParameters.get('debug') === '1') {
  let lastBeat = self.performance.now();
  self.setInterval(() => {
    const now = self.performance.now();
    const late = now - lastBeat - 500;
    if (late > 250) {
      debug(`worker-thread-late ${Math.round(late)} ms (at ${Math.round(now)} ms)`);
    }
    lastBeat = now;
  }, 500);
}

startPipelineWorker(scope, { diagnostic: (event, fields) => debug(`pipeline-worker: ${event} ${JSON.stringify(fields)}`) });
