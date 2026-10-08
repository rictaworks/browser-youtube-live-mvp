'use strict';
// 実ブラウザ（Playwright の Chromium）で、配信パイプライン（issue #27）の全経路を実測する。製品のコード（PipelineClient・AudioMixer・ワーカーの本体）を、
// そのまま実際のブラウザで動かす。ソースは、キャンバスから作る合成のトラック（画素が決まっている）と、偽のカメラ（--use-fake-device-for-media-stream）。
//
//   A. レイアウトの画素: 4 つのレイアウト（代替スレート・カメラのみ・画面共有 + ワイプ・ソースの喪失で戻る）の、位置・色・ワイプの角の丸め。
//      プレビューが、合成と同一の画素（差が 0）であること。動きの無いソースでも描き続けること。プレビューだけの間は符号化しないこと
//   B. 全経路: 偽のカメラ + 合成の画面共有 -> メインの MediaStreamTrackProcessor -> readable をワーカーへ転送 -> 合成 -> 実際の H.264 のエンコード
//      キーフレーム間隔（2 秒）・復号器設定（description）・時刻の単調性（videoTime のグリッド）・AVCC の形式・復号できること・フレームの解放
//   C. 音声の停止（AudioContext の suspend）で合成が止まり、再開でキーフレームから再開する
//   D. 配信中のビットレートの変更（再設定）で、実際のエンコーダが何を出すか（キーフレーム・復号器設定・ビットレートの追従）
//   E. ワーカーの異常終了（未処理の例外）の検知と、ワーカーのスクリプトの読み込みの失敗
//   F. 合成が遅い環境（ワーカーの合成を 1 回 300 ミリ秒遅くして再現）でも、制御の応答・音声・メディアクロックが保たれる（遅れの検知で、合成を飛ばす）
//
// AAC: Linux の Chromium では、AAC の AudioEncoder を使えない（isConfigSupported が偽）。既定（--audio fake）は、疑似の AAC エンコーダで音声の経路
// （実際の AudioData の作成・時刻の算出・復号器設定の受け渡し）を確かめる。AAC の実エンコードは、確認できなかったこととして扱う。
// --audio real は、実際の AudioEncoder（Windows・macOS の Chrome）。probe_aac.cjs が、その確認を行う。
//
// 使い方: node probe_pipeline.cjs --repo <リポジトリのルート> [--playwright-dir <Playwright を導入したディレクトリ>] [--channel <chrome|msedge>] [--seconds 6] [--audio fake|real] [--only all|layouts|stream720|stream480|stall|bitrate|crash|overload] [--json]
// 終了コード: 0 = すべて確認できた / 1 = 食い違いがある / 3 = 確認できなかった（Playwright・Chromium・TypeScript が無い）。3 は成功ではない

const path = require('path');
const support = require('./browser_support.cjs');

const { check } = support;
const near = (actual, expected, tolerance) => Number.isFinite(actual) && Math.abs(actual - expected) <= tolerance;
/** [r, g, b, a] が、期待する [r, g, b] に近い（キャンバスのキャプチャは、色空間の変換で、数ずれることがある） */
const colorNear = (pixel, expected, tolerance = 14) => Array.isArray(pixel) && expected.every((value, index) => near(pixel[index], value, tolerance));

const PAGE_HTML = [
  '<!doctype html><meta charset="utf-8"><title>issue27 pipeline probe</title>',
  '<canvas id="preview" width="1280" height="720" style="width:640px;height:360px"></canvas>',
  '<script type="module" src="/probe/page.js"></script>',
].join('\n');

const BLACK = [0, 0, 0];
const RED = [255, 0, 0];
const BLUE = [0, 0, 255];
const SLATE_BACKGROUND = [10, 14, 26];
// 中央の印: 背景の上に、銀 8% の枠、その上に、シアン 35% の円（色は lib/pipeline/config.ts の SLATE）
const SLATE_CENTER = [Math.round(SLATE_BACKGROUND[0] * 0.92 * 0.65 + 192 * 0.08 * 0.65), Math.round((SLATE_BACKGROUND[1] * 0.92 + 192 * 0.08) * 0.65 + 251 * 0.35), Math.round((SLATE_BACKGROUND[2] * 0.92 + 192 * 0.08) * 0.65 + 255 * 0.35)];

function compareLayouts(measured) {
  const results = [];
  console.log('--- A. レイアウトの画素（合成の位置・色・角の丸め）と、プレビュー = 合成');
  check(results, 'ワーカーを起動して、準備完了（ready）まで 10 秒以内', measured.startMilliseconds < 10000, `${Math.round(measured.startMilliseconds)} ms`);
  check(results, '代替スレート: 背景は単色、中央に図形（文字は無い）。四隅は背景色', measured.reachedSlate && colorNear(measured.slate[0], SLATE_BACKGROUND, 3) && colorNear(measured.slate[1], SLATE_BACKGROUND, 3), JSON.stringify(measured.slate));
  check(results, '代替スレート: 中央の図形の色が、背景の上の枠と円の重なり（約 16, 106, 115）', colorNear(measured.slate[2], SLATE_CENTER, 8), `actual=${JSON.stringify(measured.slate[2])} expected≈${JSON.stringify(SLATE_CENTER)}`);
  check(results, 'プレビューは、合成と同一の画素（代替スレート。差のある画素が 0）', measured.slateCompare.sameSize === true && measured.slateCompare.differing === 0, JSON.stringify(measured.slateCompare));
  check(
    results,
    'カメラのみ（640x480）: 縦横比を保って内接（960x720。左右 160 画素の余白）。余白は黒の単色、映像は青',
    measured.reachedCameraOnly &&
      colorNear(measured.cameraOnly[0], BLACK, 3) &&
      colorNear(measured.cameraOnly[2], BLACK, 3) &&
      colorNear(measured.cameraOnly[1], BLUE) &&
      colorNear(measured.cameraOnly[3], BLUE) &&
      colorNear(measured.cameraOnly[4], BLUE),
    JSON.stringify(measured.cameraOnly),
  );
  const [main, wipeCenter, cornerOuter, cornerOuter2, cornerBottomRight, cornerInner, cornerInnerBottomRight, leftOfWipe, edge] = measured.withWipe;
  check(results, '画面共有 + カメラ: 画面共有が主映像（赤）。右下にカメラのワイプ（青）', measured.reachedWipe && colorNear(main, RED) && colorNear(wipeCenter, BLUE), JSON.stringify({ main, wipeCenter }));
  check(results, 'ワイプは出力の右下: 幅は出力幅の約 22%（282）、右・下の外側の余白は等しい（32）', measured.wipe.width === 282 && 1280 - (measured.wipe.x + measured.wipe.width) === 32 && 720 - (measured.wipe.y + measured.wipe.height) === 32, JSON.stringify(measured.wipe));
  check(results, 'ワイプの角は、丸く切り取られる（角の画素は、下の画面共有の赤）。丸めの内側は、カメラの青', colorNear(cornerOuter, RED) && colorNear(cornerOuter2, RED) && colorNear(cornerBottomRight, RED) && colorNear(cornerInner, BLUE) && colorNear(cornerInnerBottomRight, BLUE), JSON.stringify({ cornerOuter, cornerOuter2, cornerBottomRight, cornerInner, cornerInnerBottomRight }));
  check(results, 'ワイプの左隣・出力の右下の端は、画面共有の赤', colorNear(leftOfWipe, RED) && colorNear(edge, RED), JSON.stringify({ leftOfWipe, edge }));
  check(results, 'プレビューは、合成と同一の画素（画面共有 + ワイプ。差のある画素が 0）', measured.compareWithWipe.sameSize === true && measured.compareWithWipe.differing === 0 && measured.compareWithWipe.width === 1280, JSON.stringify(measured.compareWithWipe));
  check(results, '同じ位置の画素が、プレビューと合成で一致する', JSON.stringify(measured.previewPixels) === JSON.stringify(measured.withWipe), '');
  check(results, '動きの無い画面共有・カメラ（新しいフレームが 1.5 秒届かない）でも、最後のフレームを描き続ける', colorNear(measured.staticPixels[0], RED) && colorNear(measured.staticPixels[1], BLUE) && measured.staticStats.composedFrames > 0, JSON.stringify(measured.staticPixels));
  check(results, '画面共有の喪失 -> カメラのみ（中断せず）。余白は黒・映像は青', measured.reachedCameraOnlyAgain && colorNear(measured.afterScreenLost[0], BLACK, 3) && colorNear(measured.afterScreenLost[1], BLUE), JSON.stringify(measured.afterScreenLost));
  check(results, 'カメラの喪失 -> 代替スレート（映像ソースが皆無）。背景と中央の図形', measured.reachedSlateAgain && colorNear(measured.afterCameraLost[0], SLATE_BACKGROUND, 3) && colorNear(measured.afterCameraLost[1], SLATE_CENTER, 8), JSON.stringify(measured.afterCameraLost));
  check(results, 'レイアウトの変化が順に通知される: スレート -> カメラのみ -> 画面共有 + ワイプ -> カメラのみ -> スレート', JSON.stringify(measured.layoutEvents) === JSON.stringify(['slate', 'camera_only', 'screen_with_wipe', 'camera_only', 'slate']), JSON.stringify(measured.layoutEvents));
  check(results, 'トラックの終了が、ソースの終了として通知される（画面共有、カメラの順）', JSON.stringify(measured.endedEvents) === JSON.stringify(['screen', 'camera']), JSON.stringify(measured.endedEvents));
  check(results, '最後のプレビューも、合成と同一の画素', measured.finalCompare.differing === 0, JSON.stringify(measured.finalCompare));
  check(results, '合成の失敗・故障が 0 件', measured.faults.length === 0 && measured.stats.composeFailures === 0, JSON.stringify({ faults: measured.faults, composeFailures: measured.stats.composeFailures }));
  check(results, 'フレームの解放漏れが無い（受け取った数 = 閉じた数 + 保持している数）。ソースが皆無になったので、保持は 0', measured.stats.framesReceived === measured.stats.framesClosed + measured.stats.framesRetained && measured.stats.framesRetained === 0 && measured.stats.framesReceived >= 4, JSON.stringify({ received: measured.stats.framesReceived, closed: measured.stats.framesClosed, retained: measured.stats.framesRetained }));
  check(results, 'プレビューだけの間は、符号化しない（VideoFrame を作らない・エンコーダを動かさない）', measured.counters.snapshotsCreated === 0 && measured.counters.videoEncodeCalls === 0 && measured.stats.mode === 'preview', JSON.stringify({ snapshots: measured.counters.snapshotsCreated, encodeCalls: measured.counters.videoEncodeCalls, mode: measured.stats.mode }));
  check(results, 'プレビューだけの間は、ワーカーのタイマ（30 fps の周期）が駆動した', measured.counters.previewIntervalTicks.length > 60, `ticks=${measured.counters.previewIntervalTicks.length}`);
  return results;
}

const MAIN_720P = { label: '標準 720p・H.264 Main', codec: 'avc1.4D401F', profileIdc: 0x4d, width: 1280, height: 720, bitrate: 4500000 };
const BASELINE_480P = { label: '軽量 480p・Constrained Baseline（Main が使えない環境）', codec: 'avc1.42E01F', profileIdc: 0x42, width: 854, height: 480, bitrate: 1500000 };

function compareStream(measured, options, expectation = MAIN_720P) {
  const results = [];
  const seconds = expectation === MAIN_720P ? options.seconds : Math.min(options.seconds, 5);
  console.log(`--- B. 全経路（偽のカメラ + 合成の画面共有 -> ワーカー -> 合成 -> H.264）: ${expectation.label}。音声: ${measured.audioMode === 'real' ? '実際の AudioEncoder' : '疑似の AAC エンコーダ（Linux の Chromium は AAC を使えない）'}`);
  const video = measured.video;
  const audio = measured.audio;
  check(results, `映像の復号器設定（AVCDecoderConfigurationRecord）を得た: 先頭が版 1・プロファイル 0x${expectation.profileIdc.toString(16).toUpperCase()}、7 バイト以上`, measured.configured.videoDescriptionHead[0] === 1 && measured.configured.videoDescriptionHead[1] === expectation.profileIdc && measured.configured.videoDescriptionLength >= 7 && measured.configured.videoCodec === expectation.codec, JSON.stringify(measured.configured));
  if (measured.audioMode === 'fake') {
    check(results, '音声の復号器設定（AudioSpecificConfig）は 0x12 0x10（疑似の AAC。AAC-LC・44.1 kHz・2 ch）', JSON.stringify(measured.configured.audioDescription) === JSON.stringify([0x12, 0x10]), JSON.stringify(measured.configured.audioDescription));
  } else {
    check(results, '音声の復号器設定（AudioSpecificConfig）は 2 バイト以上で、先頭の 5 ビットが 2（AAC-LC）', measured.configured.audioDescription.length >= 2 && measured.configured.audioDescription[0] >> 3 === 2, JSON.stringify(measured.configured.audioDescription));
  }
  check(results, `設定（エンコーダの最初の出力の取得まで）が 5 秒以内`, measured.configureMilliseconds < 5000, `${Math.round(measured.configureMilliseconds)} ms`);
  check(results, `映像: ${seconds} 秒で、${Math.floor(seconds * 30 * 0.8)} チャンク以上（30 fps。CPU の負荷で、間引かれることがあるので 8 割以上）`, video.count >= Math.floor(seconds * 30 * 0.8), `count=${video.count}`);
  check(results, '映像: 最初のチャンクはキーフレーム（送出は、キーフレームから）', video.firstIsKey, '');
  // 入力待ちで落としたフレーム・遅れで合成を飛ばしたフレームが 1 つも無ければ、60 フレームごと（2,000,000 マイクロ秒）ちょうど。
  // 飛ばしたフレームがキーフレームの番になると、次に符号化するフレームがキーフレームになるので、間隔は 2 秒より少し長くなる（YouTube の要件は 4 秒以内）
  const lossless = measured.statsDuring.droppedBeforeEncode === 0 && measured.statsDuring.skippedForLag === 0;
  const keyIntervalsOk = lossless ? video.keyIntervals.every((interval) => interval === 2_000_000) : video.keyIntervals.every((interval) => interval >= 2_000_000 && interval <= 2_300_000);
  check(results, `映像: キーフレームの間隔は 2 秒（60 フレームごと）。${lossless ? '落とした・飛ばしたフレームが無いので、2,000,000 マイクロ秒ちょうど' : '落とした・飛ばしたフレームがあるので、2.0 から 2.3 秒（4 秒以内）'}`, video.keyTimestamps.length >= 3 && keyIntervalsOk, JSON.stringify({ keys: video.keyTimestamps.length, intervals: video.keyIntervals, dropped: measured.statsDuring.droppedBeforeEncode, skippedForLag: measured.statsDuring.skippedForLag }));
  check(results, '映像: 時刻は videoTime(フレーム番号) のグリッド上（実時計で採番していない）で、単調増加', video.onGrid && video.strictlyIncreasing, '');
  // 映像のメディア時刻は、音声の累積サンプル数から決まる（フレーム番号 = 累積サンプル数 ÷ 1,470）ので、最後の映像と音声のチャンクの時刻は揃う（実時計で採番すると、ずれていく）。
  // 入力待ちの破棄・エンコーダの内部の間引きでチャンクが欠けても、時刻の進みは変わらない（フレームの欠けは、別に数える）
  // 映像のチャンクは、エンコーダの出力の遅れ（ソフトウェアの H.264 で、負荷が高いと数フレーム）の分だけ、音声のチャンクより遅れて届く。許容は 0.75 秒
  const endGapSeconds = Math.abs(video.lastTimestampUs - audio.lastTimestampUs) / 1_000_000;
  check(results, '映像: メディア時刻の進みが、音声と揃っている（最後の映像と音声のチャンクの時刻の差が 0.75 秒以内。エンコーダの出力の遅れを見込む）', Number.isFinite(endGapSeconds) && endGapSeconds < 0.75, `gap=${endGapSeconds.toFixed(3)} s`);
  check(results, '映像: すべて AVCC 形式（各 NAL の前に 4 バイトの長さ）。キーフレームは IDR（NAL 5）を含み、フレームに SPS・PPS（NAL 7・8）を含まない', video.avccOk && video.keyHasIdr && video.noParameterSetsInFrames, '');
  check(results, '映像: 復号器設定で、すべてのチャンクが復号できる（復号したフレーム数 = チャンク数。エラー 0）', measured.decode.decoded === measured.decode.expected && measured.decode.errors.length === 0, JSON.stringify(measured.decode));
  check(results, `映像: 復号したフレームの大きさは出力解像度（${expectation.width}x${expectation.height}）で、画面共有の赤が写っている`, JSON.stringify(measured.decode.sizes) === JSON.stringify([`${expectation.width}x${expectation.height}`]) && measured.decode.lastPixel && measured.decode.lastPixel[0] > 180 && measured.decode.lastPixel[1] < 80 && measured.decode.lastPixel[2] < 80, JSON.stringify({ sizes: measured.decode.sizes, pixel: measured.decode.lastPixel }));
  check(results, `音声: ${seconds} 秒で、${Math.floor(seconds * 43 * 0.8)} チャンク以上（AAC-LC は 1,024 サンプル = 約 23 ミリ秒ごと）`, audio.count >= Math.floor(seconds * 43 * 0.8), `count=${audio.count}`);
  check(results, '音声: 時刻は audioTime(起点 + n × 1,024) と、すべて一致する（累積サンプル数から算出。実時計・エンコーダの時刻に頼らない）', audio.firstMatches && audio.allMatch && audio.strictlyIncreasing, JSON.stringify({ start: audio.startSample, firstMatches: audio.firstMatches, allMatch: audio.allMatch }));
  check(results, '音声: チャンクの間隔は 23,219 から 23,221 マイクロ秒（1,024 ÷ 44,100 秒の丸め）。キーフレームの属性は付けない', audio.minDelta >= 23219 && audio.maxDelta <= 23221 && audio.allNotKeyframe, JSON.stringify({ min: audio.minDelta, max: audio.maxDelta }));
  if (measured.audioMode === 'fake') {
    // 疑似の AAC エンコーダが、実際の AudioData を受け取り、中身（インターリーブの f32）を読めることを数える。実際の AudioEncoder では、受け取った数を数えない（上の音声のチャンク数が、その確認）
    check(results, '実際の AudioData（インターリーブの f32）を作って、エンコーダが中身を読める', measured.countersAfter.audioDataSeen > 100 && measured.countersAfter.audioDataReadable === true, JSON.stringify({ seen: measured.countersAfter.audioDataSeen, readable: measured.countersAfter.audioDataReadable }));
  }
  check(results, 'プレビューは、符号化へ渡すキャンバスと同一の画素（配信中。差のある画素が 0）', measured.previewVersusComposite.sameSize === true && measured.previewVersusComposite.differing === 0, JSON.stringify(measured.previewVersusComposite));
  check(results, '配信中は、ワーカーのタイマ（プレビューの 30 fps の周期）を使わない。配信の開始後、タイマの周期の処理が 0 回で、音声の処理周期だけが駆動する（モードは clock）', measured.previewTicksDuringStream === 0 && measured.statsDuring.mode === 'clock', `ticksDuringStream=${measured.previewTicksDuringStream}, mode=${measured.statsDuring.mode}`);
  check(results, 'メディアクロック: フレーム番号 = 累積サンプル数 ÷ 1,470 の切り捨て（取りこぼしも重複も無い）', measured.statsDuring.clock && measured.statsDuring.clock.frameIndex === Math.floor(measured.statsDuring.clock.sampleCount / 1470), JSON.stringify(measured.statsDuring.clock));
  check(results, '合成の失敗・エンコーダの故障・ワーカーの故障が 0 件', measured.faults.length === 0 && measured.statsDuring.composeFailures === 0 && !measured.statsDuring.videoFaulted && !measured.statsDuring.audioFaulted, JSON.stringify({ faults: measured.faults, stats: measured.statsDuring }));
  check(results, 'ソースのフレームの解放漏れが無い（受け取った数 = 閉じた数 + 保持している数）。保持は 2 枚以下（画面共有とカメラ）', measured.statsDuring.framesReceived === measured.statsDuring.framesClosed + measured.statsDuring.framesRetained && measured.statsDuring.framesRetained <= 2 && measured.statsDuring.framesReceived > 50, JSON.stringify({ received: measured.statsDuring.framesReceived, closed: measured.statsDuring.framesClosed, retained: measured.statsDuring.framesRetained }));
  check(results, '合成から作った VideoFrame は、すべて閉じられた（作成数 = 閉じた数）。配信の終了後', measured.countersAfter.snapshotsCreated === measured.countersAfter.snapshotsClosed && measured.countersAfter.snapshotsCreated > 100, JSON.stringify({ created: measured.countersAfter.snapshotsCreated, closed: measured.countersAfter.snapshotsClosed }));
  check(results, '破棄フレーム数（入力待ち 2 フレーム超で、符号化せず捨てた）が、合成したフレームの 2 割未満', measured.statsDuring.droppedBeforeEncode < measured.statsDuring.composedFrames * 0.2, `dropped=${measured.statsDuring.droppedBeforeEncode} / composed=${measured.statsDuring.composedFrames}, 最大の入力待ち=${measured.countersDuring.maxEncodeQueueSize}`);
  check(results, `設定の内容: 実際のエンコーダへ、${expectation.codec}・${expectation.width}x${expectation.height}・固定ビットレート ${expectation.bitrate / 1000} kbps・低遅延・AVCC・30 fps で configure した`, JSON.stringify(measured.countersDuring.videoConfigures[0]) === JSON.stringify({ codec: expectation.codec, width: expectation.width, height: expectation.height, bitrate: expectation.bitrate, framerate: 30, bitrateMode: 'constant', latencyMode: 'realtime', avcFormat: 'avc' }), JSON.stringify(measured.countersDuring.videoConfigures[0]));
  check(results, '配信の終了後の統計: プロファイルは戻り、プレビューだけの状態（配信中の状態を残さない）', measured.statsAfter.mode === 'preview' && measured.statsAfter.profile === null && measured.statsAfter.gateOpen === false, JSON.stringify({ mode: measured.statsAfter.mode, profile: measured.statsAfter.profile }));
  console.log(`info 実測: グリッド上で欠けたフレーム ${video.missingOnGrid} 個（計上した破棄 ${measured.statsDuring.droppedBeforeEncode} 個・遅れで飛ばした ${measured.statsDuring.skippedForLag} 個。差は、エンコーダの内部の間引き）、チャンクの速さ ${video.fps.toFixed(2)} fps`);
  console.log(`info 実測: 映像 ${video.count} チャンク・${video.durationSeconds.toFixed(2)} 秒・平均 ${Math.round((video.totalBytes * 8) / Math.max(video.durationSeconds, 0.001) / 1000)} kbps・最大のチャンク ${video.maxBytes} バイト、音声 ${audio.count} チャンク、設定に ${Math.round(measured.configureMilliseconds)} ms`);
  return results;
}

function compareStall(measured) {
  const results = [];
  console.log('--- C. 音声の停止（AudioContext の suspend）と再開');
  check(results, '停止中は合成しない（合成したフレーム数が増えない）。メディアクロックの累積サンプル数も進まない', measured.duringSuspend.composed === measured.atSuspend.composed && measured.duringSuspend.clock.sampleCount === measured.atSuspend.clock.sampleCount && measured.atSuspend.clock.stalled === true, JSON.stringify({ atSuspend: measured.atSuspend, duringSuspend: measured.duringSuspend }));
  check(results, '停止の前は合成が進んでいた（1.5 秒で 30 フレーム以上）', measured.before.composed >= 30, `composed=${measured.before.composed}`);
  check(results, '再開すると、合成が再び進み、停止の状態が解ける', measured.after.composed > measured.duringSuspend.composed + 15 && measured.after.clock.stalled === false && measured.after.clock.sampleCount > measured.duringSuspend.clock.sampleCount, JSON.stringify(measured.after));
  check(results, '再開後の最初の映像のチャンクは、キーフレーム（空白を埋めず、キーフレームから再開する）', measured.firstVideoAfterResumeIsKey === true && measured.videoAfterResume > 15, `afterResume=${measured.videoAfterResume}`);
  check(results, '停止をまたいでも、メディア時刻は、音声の累積サンプル数から決まる（停止中は音声が進まないので、時刻の飛びが無い: 1 フレームの間隔の 3 倍未満）', measured.timestampStepAcrossResumeUs !== null && measured.timestampStepAcrossResumeUs > 0 && measured.timestampStepAcrossResumeUs < 100000, `step=${measured.timestampStepAcrossResumeUs} us`);
  check(results, '故障が 0 件', measured.faults.length === 0, JSON.stringify(measured.faults));
  return results;
}

function compareBitrate(measured) {
  const results = [];
  console.log('--- D. 配信中のビットレートの変更（再設定）で、実際のエンコーダが何を出すか');
  check(results, '再設定は、同じコーデック・解像度・固定ビットレート・低遅延・AVCC のまま、ビットレートだけを変える（4.5 Mbps -> 3 Mbps -> 6 Mbps）', JSON.stringify(measured.configures) === JSON.stringify([4500000, 3000000, 6000000]) && measured.configuresKeepOtherSettings, JSON.stringify(measured.configures));
  check(results, 'キーフレームの間隔は、再設定があっても 2 秒を超えない（エンコーダが再設定でキーフレームを出しても、出さなくても）', measured.maxKeyInterval <= 2_000_000, `max=${measured.maxKeyInterval}`);
  console.log(`info 実測（再設定の扱いの根拠）: 再設定の直後 300 ミリ秒以内のキーフレーム ${measured.keyframesWithin300msAfterReconfigure} 件、定期（2 秒）でないキーフレーム ${measured.irregularKeyframes} 件、再設定の最初の出力に付いた復号器設定 ${measured.decoderConfigOutputsAfterReconfigure} 件、復号器設定の内容の変化の通知 ${measured.configChanges.length} 件`);
  console.log(`info 実測: 映像ビットレートの実績 変更前 ${measured.kbpsBefore} kbps（目標 4,500）-> 3,000 kbps へ変更後 ${measured.kbpsAfterLowering} kbps`);
  check(results, '再設定で、復号器設定の内容は変わらない（変われば、中継へ設定の再送が要る。通知は 0 件）', measured.configChanges.length === 0, JSON.stringify(measured.configChanges));
  check(results, '再設定で、故障が起きない', measured.faults.length === 0, JSON.stringify(measured.faults));
  if (measured.kbpsBefore >= 1500) {
    check(results, '目標を 3 Mbps に下げたあとの実績が、変更前より小さい（ビットレートの変更が効く）', measured.kbpsAfterLowering < measured.kbpsBefore, `${measured.kbpsBefore} -> ${measured.kbpsAfterLowering} kbps`);
  } else {
    // 映像の情報量が少なく、固定ビットレートの目標に届かない環境では、目標の変更の効果を、実績から判定できない。判定できなかったことを、成功に数えない
    check(results, `目標を 3 Mbps に下げたあとの実績の比較は、判定できなかった（変更前の実績 ${measured.kbpsBefore} kbps が、目標に届いていない。確認できなかった）`, false, `${measured.kbpsBefore} -> ${measured.kbpsAfterLowering} kbps`);
  }
  return results;
}

function compareOverload(measured) {
  const results = [];
  console.log('--- F. 合成が遅い環境（合成の drawImage を 1 回 150 ミリ秒遅くして再現。合成 1 回で約 300 ミリ秒）');
  check(results, '制御の要求（get_stats・end_session）が、期限内に応答される（期限切れ request_timeout が起きない）', measured.failure === null, String(measured.failure));
  const samples = measured.samples;
  if (samples.length === 0) {
    return results;
  }
  const first = samples[0];
  const last = samples[samples.length - 1];
  const lagSeconds = (sample) => sample.wallSeconds - sample.mediaSeconds - (first.wallSeconds - first.mediaSeconds);
  const maxRoundTrip = Math.max(...samples.map((sample) => sample.roundTripMs));
  const maxBacklog = Math.max(...samples.map((sample) => sample.backlogMs));
  const maxLag = Math.max(...samples.map(lagSeconds));
  console.log(`info 実測: get_stats の往復の最大 ${Math.round(maxRoundTrip)} ms・処理待ちの深さの最大 ${maxBacklog} ms・メディアクロックの遅れの最大 ${maxLag.toFixed(2)} 秒・合成 ${last.composed} 枚・遅れで飛ばした ${last.skippedForLag} 枚・入力待ちで破棄 ${last.dropped} 枚・終了に ${Math.round(measured.finishMs)} ms`);
  check(results, '制御の応答が保たれる: get_stats の往復が、すべて 2 秒未満（遅れの検知が働かないと、待ちが積み上がって、応答が返らなくなる）', samples.length >= 5 && maxRoundTrip < 2000, `max=${Math.round(maxRoundTrip)} ms, samples=${samples.length}`);
  check(results, '処理待ちの深さが、増え続けない（最大 1.5 秒未満）。統計の audioBacklogMs で見える', maxBacklog < 1500, `max=${maxBacklog} ms`);
  check(results, 'メディアクロック（音声の処理）が、実時間に追いついている（遅れの増加が 2 秒未満）', maxLag < 2, `max lag growth=${maxLag.toFixed(2)} s`);
  check(results, '遅れている間は、合成を飛ばす（飛ばした数が 1 以上）。合成は止まらない（5 枚以上）', last.skippedForLag > 0 && last.composed >= 5, `composed=${last.composed}, skipped=${last.skippedForLag}`);
  const expectedAudio = Math.floor((last.mediaSeconds ?? 0) * 43.07 * 0.95);
  check(results, '音声は途切れない: 処理したメディア時間の分の音声のチャンクが、すべて出る（95% 以上）', measured.audioChunks >= expectedAudio && measured.audioSummary.allMatch === true && measured.audioSummary.strictlyIncreasing === true, `audio=${measured.audioChunks} (expected >= ${expectedAudio}), allMatch=${measured.audioSummary.allMatch}`);
  check(results, '配信の終了が、2 秒未満で完了する（end_session の応答）。終了後はプレビューだけの状態', measured.finishMs < 2000 && measured.finalMode === 'preview', `finish=${Math.round(measured.finishMs)} ms, mode=${measured.finalMode}`);
  check(results, '故障が 0 件（遅れは故障ではない）', measured.faults.length === 0, JSON.stringify(measured.faults));
  return results;
}

function compareCrash(measured) {
  const results = [];
  console.log('--- E. ワーカーの異常終了の検知');
  check(results, 'ワーカーの未処理の例外を検知して、worker_crashed の故障を 1 回だけ通知する', measured.faults.filter((fault) => fault.code === 'worker_crashed').length === 1 && measured.faults.length === 1, JSON.stringify(measured.faults));
  check(results, '異常終了のあとの要求は invalid_state（死んだワーカーへ送り続けない）', measured.afterCrash === 'invalid_state' && measured.sendAfterCrash === 'invalid_state', JSON.stringify({ afterCrash: measured.afterCrash, sendAfterCrash: measured.sendAfterCrash }));
  check(results, 'ワーカーのスクリプトの読み込みに失敗（存在しない URL）したら、start は worker_crashed で拒否される', measured.loadFailure === 'worker_crashed', measured.loadFailure);
  return results;
}

async function main() {
  const options = support.parseArguments(process.argv.slice(2), { seconds: 6, audio: 'fake', only: 'all' });
  const { frontendRoot, playwright, ts } = support.loadTools(options);
  const server = support.createServer({ ts, frontendRoot, browserDirectory: path.join(__dirname, 'browser'), pageHtml: PAGE_HTML });
  const base = await support.listen(server);
  const launchOptions = options.channel ? { channel: options.channel } : {};
  const results = [];
  const pageErrors = [];

  // 場面ごとに、新しいブラウザ（GPU の処理・描画の待ちを引き継がない）と新しいページで動かし、終わったら閉じる。
  // 前の場面のページを開いたままにすると、その描画が次の場面の負荷になる（実測。GPU の無い環境で、ワーカーが数秒止まる原因になった）
  const inFreshBrowser = async (action, extraQuery = '') => {
    const browser = await playwright.chromium.launch({ ...launchOptions, args: support.FAKE_DEVICE_ARGUMENTS });
    try {
      const page = await browser.newPage();
      page.on('pageerror', (error) => pageErrors.push(String(error && error.message)));
      if (process.env.ISSUE27_DEBUG === '1') {
        // 調べるとき（ISSUE27_DEBUG=1）は、ページとワーカーの診断を、時刻つきで表示する
        const started = Date.now();
        const show = (origin) => (message) => console.log(`[${((Date.now() - started) / 1000).toFixed(2)}s ${origin}] ${message.text()}`);
        page.on('console', show('page'));
        page.on('worker', (worker) => worker.on('console', show('worker')));
      }
      await page.goto(`${base}?audio=${options.audio}${process.env.ISSUE27_DEBUG === '1' ? '&debug=1' : ''}${extraQuery}`);
      await page.waitForFunction(() => window.__issue27Ready === true, null, { timeout: 30000 });
      return await action(page);
    } finally {
      await browser.close();
    }
  };

  try {
    let probe;
    try {
      probe = await inFreshBrowser(async (page) => ({
        userAgent: await page.evaluate(() => navigator.userAgent),
        aacSupported: await page.evaluate(async () => {
          try {
            return (await AudioEncoder.isConfigSupported({ codec: 'mp4a.40.2', sampleRate: 44100, numberOfChannels: 2, bitrate: 128000, aac: { format: 'aac' } })).supported === true;
          } catch (error) {
            return false;
          }
        }),
      }));
    } catch (error) {
      server.close();
      return support.unavailable(`Chromium を起動できません（${String(error && error.message).split('\n')[0]}）`);
    }
    console.log(`info ブラウザ: ${probe.userAgent}`);
    console.log(`info このブラウザの AAC エンコード（AudioEncoder.isConfigSupported）: ${probe.aacSupported ? '使える' : '使えない（Linux の Chromium など）'}`);
    if (options.audio === 'real' && !probe.aacSupported) {
      server.close();
      return support.unavailable('このブラウザは AAC をエンコードできないため、--audio real は確認できません（Windows・macOS の Chrome で実行してください）');
    }

    const wants = (name) => options.only === 'all' || options.only === name;
    if (wants('layouts')) {
      results.push(...compareLayouts(await inFreshBrowser((page) => page.evaluate(() => window.__issue27.layouts()))));
    }
    if (wants('stream720')) {
      results.push(...compareStream(await inFreshBrowser((page) => page.evaluate((seconds) => window.__issue27.stream({ seconds }), options.seconds)), options));
    }
    if (wants('stream480') && options.audio === 'fake') {
      const measured = await inFreshBrowser((page) =>
        page.evaluate((seconds) => window.__issue27.stream({ seconds, profile: '480p', videoBitrateKbps: 1500, videoCodec: 'avc1.42E01F' }), Math.min(options.seconds, 5)),
      );
      results.push(...compareStream(measured, options, BASELINE_480P));
    }
    if (options.audio === 'fake') {
      if (wants('stall')) {
        results.push(...compareStall(await inFreshBrowser((page) => page.evaluate(() => window.__issue27.stall()))));
      }
      if (wants('bitrate')) {
        results.push(...compareBitrate(await inFreshBrowser((page) => page.evaluate(() => window.__issue27.bitrate()))));
      }
      if (wants('crash')) {
        results.push(...compareCrash(await inFreshBrowser((page) => page.evaluate(() => window.__issue27.crash()))));
      }
      if (wants('overload')) {
        results.push(...compareOverload(await inFreshBrowser((page) => page.evaluate(() => window.__issue27.overload({ seconds: 8 })), '&slowCompose=150')));
      }
    }
    console.log('--- ページの未処理の例外');
    check(results, 'ページの未処理の例外（pageerror）が 0 件', pageErrors.length === 0, JSON.stringify(pageErrors));
  } finally {
    server.close();
  }
  support.finish(results, options, '実機（Chromium）の確認');
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(support.EXIT_MISMATCH);
});
