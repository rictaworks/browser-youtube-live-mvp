// プレビューの方式の比較用のページ（issue #27）。製品のコードは使わない。同じ「合成」（1280x720 の塗りつぶし + 動く四角）を、ワーカーが 30 fps で描き、
// 結果を画面へ出す 2 つの方式を、同じ条件（メインスレッドの停止）で比べる。
//   offscreen  <canvas> を transferControlToOffscreen してワーカーへ渡し、ワーカーが直接描く（製品の方式）。メインスレッドは何もしない
//   bitmap     ワーカーが描いた結果を ImageBitmap にして、フレームごとにメインスレッドへ送り、メインスレッドが画面の <canvas> へ描く
// 計測は、メインスレッドを 1 回、一定時間止めて（重い画面の更新・ガベージコレクションの疑似）、その間と直後の様子を見る。
// 実時計（performance）は、この計測の用具にだけ使う（製品のコードは使わない）。

const WORKER_SOURCE = `
let canvas = null;
let context = null;
let mode = null;
let frame = 0;
let timer = null;
const ticks = [];
self.onmessage = (event) => {
  const message = event.data;
  if (message.type === 'init') {
    mode = message.mode;
    canvas = message.canvas || new OffscreenCanvas(1280, 720);
    context = canvas.getContext('2d', { alpha: false });
    timer = setInterval(tick, 1000 / 30);
  } else if (message.type === 'stop') {
    clearInterval(timer);
    self.postMessage({ type: 'ticks', ticks, frame });
  }
};
function tick() {
  frame += 1;
  ticks.push([performance.timeOrigin + performance.now(), frame]);
  context.fillStyle = 'hsl(' + ((frame * 7) % 360) + ',80%,40%)';
  context.fillRect(0, 0, 1280, 720);
  context.fillStyle = '#ffffff';
  context.fillRect((frame * 13) % 1100, 300, 160, 160);
  if (mode === 'bitmap') {
    const bitmap = canvas.transferToImageBitmap();
    self.postMessage({ type: 'frame', frame, bitmap }, [bitmap]);
  }
}
`;

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function busyWait(milliseconds) {
  const end = performance.now() + milliseconds;
  while (performance.now() < end) {
    // メインスレッドを塞ぐ
  }
}

/** 1 つの方式を、totalMs 動かし、stallAtMs の時点でメインスレッドを stallMs 止める。 */
async function run({ mode, totalMs = 5000, stallAtMs = 1500, stallMs = 1500 }) {
  const host = document.getElementById('host');
  const view = document.createElement('canvas');
  view.width = 1280;
  view.height = 720;
  view.style.cssText = 'width:640px;height:360px;display:block';
  host.replaceChildren(view);
  const worker = new Worker(URL.createObjectURL(new Blob([WORKER_SOURCE], { type: 'text/javascript' })));
  const arrivals = [];
  const handleCosts = [];
  if (mode === 'offscreen') {
    const offscreen = view.transferControlToOffscreen();
    worker.postMessage({ type: 'init', mode, canvas: offscreen }, [offscreen]);
  } else {
    const bitmapContext = view.getContext('bitmaprenderer');
    worker.onmessage = (event) => {
      if (event.data.type !== 'frame') {
        return;
      }
      const started = performance.now();
      bitmapContext.transferFromImageBitmap(event.data.bitmap);
      const finished = performance.now();
      arrivals.push([performance.timeOrigin + started, event.data.frame]);
      handleCosts.push(finished - started);
    };
    worker.postMessage({ type: 'init', mode });
  }
  const startedAt = performance.now();
  let stallWindow = null;
  setTimeout(() => {
    const begin = performance.timeOrigin + performance.now();
    busyWait(stallMs);
    stallWindow = [begin, performance.timeOrigin + performance.now()];
  }, stallAtMs);
  await sleep(totalMs);
  const ticksPromise = new Promise((resolve) => {
    const previous = worker.onmessage;
    worker.onmessage = (event) => {
      if (event.data.type === 'ticks') {
        resolve(event.data);
      } else if (previous) {
        previous(event);
      }
    };
  });
  worker.postMessage({ type: 'stop' });
  const ticks = await ticksPromise;
  worker.terminate();
  return { mode, startedAt, stallWindow, workerTicks: ticks.ticks, workerFrames: ticks.frame, arrivals, handleCosts };
}

/** 表示された画素を、スクリーンショット（PNG）から読む。ブラウザがデコードするので、ライブラリは要らない。 */
async function pixelOfPng(base64, x, y) {
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
  const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
  const scratch = new OffscreenCanvas(bitmap.width, bitmap.height);
  const context = scratch.getContext('2d', { willReadFrequently: true });
  context.drawImage(bitmap, 0, 0);
  return Array.from(context.getImageData(x, y, 1, 1).data);
}

window.__preview = { run, pixelOfPng };
window.__previewReady = true;
