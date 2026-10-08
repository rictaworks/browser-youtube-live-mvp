'use strict';
// プレビューの方式を、実ブラウザで実測して比べる（issue #27）。製品は、<canvas> を transferControlToOffscreen してワーカーへ渡し、ワーカーが直接描く方式（offscreen）。
// 代案は、ワーカーが描いた結果を ImageBitmap にして、フレームごとにメインスレッドへ送り、メインスレッドが画面へ描く方式（bitmap）。
// 同じ「合成」（1280x720）を 30 fps で描かせ、メインスレッドを 1.5 秒止めて（重い画面の更新・ガベージコレクションの疑似）、次を比べる。
//   - ワーカーの合成は、停止の間も続くか（ワーカーの周期の処理が、停止の間に何回走ったか。30 fps なら約 45 回）
//   - メインスレッドが、フレームごとに行う作業（bitmap だけ）と、その時間
//   - 停止の直後に、メインスレッドへ押し寄せる ImageBitmap の数と、その大きさ（bitmap だけ）
// 実測（Chromium 153）: bitmap では、メインスレッドの停止の間、ワーカーの周期の処理が止まった（ImageBitmap の受け渡しが、受け手の停止に、送り手を巻き込む）。
// offscreen では、ワーカーは止まらず、メインスレッドは何もしない。配信中、ワーカーは音声のブロックで駆動され、停止すると音声が溜まり、映像が遅れる（11.6）ので、
// メインスレッドの停止に巻き込まれない offscreen を採用する。
// 製品のコードは使わない（方式の比較のための、単純なページ browser/preview_method.js）。結果は数値で出し、方式の採用の根拠にする。
//
// 使い方: node probe_preview_method.cjs --repo <リポジトリのルート> [--playwright-dir <Playwright を導入したディレクトリ>] [--channel <chrome|msedge>] [--json]
// 終了コード: 0 = すべて確認できた / 1 = 食い違い / 3 = 確認できなかった

const path = require('path');
const support = require('./browser_support.cjs');

const { check } = support;
const STALL_AT_MS = 1500;
const STALL_MS = 1500;
const TOTAL_MS = 5000;
const FRAME_BYTES = 1280 * 720 * 4;

const PAGE_HTML = ['<!doctype html><meta charset="utf-8"><title>issue27 preview method</title>', '<div id="host"></div>', '<script type="module" src="/probe/preview_method.js"></script>'].join('\n');

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

/** 1 つの方式を動かし、停止の間にスクリーンショットを 2 枚撮る。 */
async function measure(playwright, launchOptions, base, mode) {
  const browser = await playwright.chromium.launch(launchOptions);
  try {
    const page = await browser.newPage({ viewport: { width: 800, height: 500 } });
    await page.goto(base);
    await page.waitForFunction(() => window.__previewReady === true, null, { timeout: 30000 });
    const running = page.evaluate((options) => window.__preview.run(options), { mode, totalMs: TOTAL_MS, stallAtMs: STALL_AT_MS, stallMs: STALL_MS });
    await sleep(STALL_AT_MS + 300);
    const shots = [];
    const started = Date.now();
    try {
      await page.screenshot({ clip: { x: 0, y: 0, width: 640, height: 360 }, timeout: 4000 });
      shots.push({ ok: true, seconds: (Date.now() - started) / 1000 });
    } catch (error) {
      shots.push({ ok: false, seconds: (Date.now() - started) / 1000, reason: String(error && error.message).split('\n')[0] });
    }
    const result = await running;
    return { result, shots };
  } finally {
    await browser.close();
  }
}

function analyze({ result, shots }) {
  const [stallStart, stallEnd] = result.stallWindow;
  const ticksInStall = result.workerTicks.filter(([time]) => time >= stallStart && time <= stallEnd).length;
  const tickTimeOfFrame = new Map(result.workerTicks.map(([time, frame]) => [frame, time]));
  const afterStall = result.arrivals.filter(([time]) => time >= stallEnd && time < stallEnd + 200);
  const backlogFrames = afterStall.filter(([, frame]) => tickTimeOfFrame.get(frame) <= stallEnd).length;
  const firstAfter = result.arrivals.find(([time]) => time >= stallEnd);
  const costs = result.handleCosts;
  return {
    mode: result.mode,
    stallMilliseconds: stallEnd - stallStart,
    workerFrames: result.workerFrames,
    ticksInStall,
    backlogFrames,
    backlogBytes: backlogFrames * FRAME_BYTES,
    firstFrameAgeMilliseconds: firstAfter ? stallEnd - tickTimeOfFrame.get(firstAfter[1]) : null,
    handled: costs.length,
    meanCostMilliseconds: costs.length > 0 ? costs.reduce((sum, cost) => sum + cost, 0) / costs.length : 0,
    maxCostMilliseconds: costs.length > 0 ? Math.max(...costs) : 0,
    shots,
  };
}

async function main() {
  const options = support.parseArguments(process.argv.slice(2), {});
  const { frontendRoot, playwright, ts } = support.loadTools(options);
  const server = support.createServer({ ts, frontendRoot, browserDirectory: path.join(__dirname, 'browser'), pageHtml: PAGE_HTML });
  const base = await support.listen(server);
  const launchOptions = options.channel ? { channel: options.channel } : {};
  const results = [];
  try {
    let offscreen;
    let bitmap;
    try {
      offscreen = analyze(await measure(playwright, launchOptions, base, 'offscreen'));
      bitmap = analyze(await measure(playwright, launchOptions, base, 'bitmap'));
    } catch (error) {
      return support.unavailable(`Chromium で測れません（${String(error && error.message).split('\n')[0]}）`);
    }
    const expectedInStall = Math.floor((STALL_MS / 1000) * 30);
    console.log('--- プレビューの方式の比較: offscreen（製品。ワーカーが直接描く）と bitmap（ImageBitmap を毎フレーム送る）');
    for (const entry of [offscreen, bitmap]) {
      console.log(
        `info ${entry.mode}: メインスレッドの停止 ${Math.round(entry.stallMilliseconds)} ms の間に、ワーカーの周期の処理が走った回数 ${entry.ticksInStall}（30 fps なら約 ${expectedInStall}）` +
          ` / 停止の直後 200 ms に届いた、停止中に作られたフレーム ${entry.backlogFrames} 枚（${(entry.backlogBytes / 1048576).toFixed(0)} MiB 相当）` +
          ` / メインスレッドの処理 ${entry.handled} 回・平均 ${entry.meanCostMilliseconds.toFixed(2)} ms・最大 ${entry.maxCostMilliseconds.toFixed(2)} ms` +
          (entry.firstFrameAgeMilliseconds === null ? '' : ` / 停止の直後に最初に描いたフレームの古さ ${Math.round(entry.firstFrameAgeMilliseconds)} ms`),
      );
      const shot = entry.shots[0];
      console.log(
        `info ${entry.mode}: 停止の開始の 0.3 秒後に撮ったスクリーンショットは、${shot.ok ? `${shot.seconds.toFixed(2)} 秒かかった（停止の残りは約 1.2 秒。${shot.seconds >= 1.0 ? '停止が終わるまで待たされた' : '停止の最中に返った'}）` : `返らなかった（${shot.reason}）`}。` +
          (shot.ok && shot.seconds < 1.0 ? '' : '停止の最中の表示の更新は、この環境では、スクリーンショットで確かめられない（確認できなかった）'),
      );
    }
    check(results, 'offscreen: メインスレッドが停止している間も、ワーカーの合成は止まらない（30 fps の 8 割以上）', offscreen.ticksInStall >= expectedInStall * 0.8, `ticks=${offscreen.ticksInStall} / ${expectedInStall}`);
    check(results, 'offscreen: メインスレッドは、フレームごとの作業をしない（処理 0 回）。停止の直後に、押し寄せるフレームも無い', offscreen.handled === 0 && offscreen.backlogFrames === 0, `handled=${offscreen.handled}, backlog=${offscreen.backlogFrames}`);
    check(results, 'bitmap: メインスレッドが、フレームごとに ImageBitmap を処理する（常時の負荷が増える）', bitmap.handled > 60 && bitmap.meanCostMilliseconds > 0, `handled=${bitmap.handled}, mean=${bitmap.meanCostMilliseconds.toFixed(3)} ms`);
    check(
      results,
      'bitmap: メインスレッドの停止に、ワーカーが巻き込まれる（停止中にワーカーの処理が 8 割未満しか走らない）か、停止の直後に 5 枚以上が押し寄せる。どちらかが起きる',
      bitmap.ticksInStall < expectedInStall * 0.8 || bitmap.backlogFrames >= 5,
      `ticks=${bitmap.ticksInStall} / ${expectedInStall}, backlog=${bitmap.backlogFrames}`,
    );
  } finally {
    server.close();
  }
  support.finish(results, options, 'プレビューの方式の比較');
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(support.EXIT_MISMATCH);
});
