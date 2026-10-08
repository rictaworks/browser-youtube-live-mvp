// 配信パイプライン（映像の合成と H.264／AAC のエンコード。requirements.md 11.3〜11.7・12。issue #27）の設定値。
// 名前と数値は、ここへ集める（実装へ直書きしない）。契約の値（解像度・フレームレート・キーフレーム間隔・入力待ちの上限）は、
// core/contract の LIMITS から導く（実行時に src/contracts は読まない）。

import { LIMITS, PROFILE_VALUES } from "@/core/contract";
import type { Profile } from "@/core/contract";

function deriveFrameRate(): number {
  const rates = Array.from(new Set(PROFILE_VALUES.map((profile) => LIMITS.profiles[profile].framerate)));
  if (rates.length !== 1) {
    // プロファイルごとにフレームレートが違うと、音声 1,470 サンプル = 映像 1 フレームの対応（11.6）が成り立たない。契約の食い違いなので、推測せず失敗にする
    throw new RangeError(`contract profiles disagree on the frame rate: ${rates.join(", ")}`);
  }
  return rates[0];
}

/** フレームレート（30 fps。11.7）。 */
export const FRAME_RATE: number = deriveFrameRate();

/** キーフレーム間隔（フレーム数）。2 秒 × 30 fps = 60 フレームごとに keyFrame: true（11.7）。 */
export const KEYFRAME_INTERVAL_FRAMES: number = LIMITS.video.keyframe_interval_seconds * FRAME_RATE;

/**
 * キーフレーム間隔（メディア時刻のマイクロ秒。2 秒）。キーフレームの要否は、前のキーフレームからの経過したメディア時刻で判定する
 * （フレームを符号化の前に捨てても、間隔が 2 秒を超えない。映像 60 フレームはちょうど 2 秒なので、通常は 60 フレームごとと一致する）。
 */
export const KEYFRAME_INTERVAL_US: number = LIMITS.video.keyframe_interval_seconds * 1_000_000;

/** エンコーダの入力待ち（encodeQueueSize）が、これを超えたら、当該フレームを符号化せず捨てる（11.7。実時間性を優先する）。 */
export const ENCODER_QUEUE_MAX_FRAMES: number = LIMITS.adaptive.encoder_queue_max_frames;

/**
 * AAC-LC の 1 フレームのサンプル数。音声の出力チャンクの時刻は、入力の累積サンプル数から、この単位で算出する
 * （エンコーダが返す時刻・実時計に頼らない。11.6）。
 */
export const AAC_SAMPLES_PER_FRAME = 1024;

/** 配信前のプレビューの合成の解像度（標準 720p）。配信の開始で確定したプロファイルの解像度へ切り替わる。 */
export const PREVIEW_PROFILE: Profile = "720p";

/**
 * プレビューだけの間（配信前。音声のクロックが無い間）の、ワーカーのタイマの周期（ミリ秒）。30 fps の 1 周期。
 * このタイマは、プレビューの描画にだけ使う。配信の送出（合成・エンコード・時刻の採番）には使わない（11.6。配信中は音声の処理周期が駆動源）。
 */
export const PREVIEW_INTERVAL_MS: number = 1000 / FRAME_RATE;

/** トラックの処理器（MediaStreamTrackProcessor）が溜めるフレームの数。最新の 1 枚だけ（古いフレームを溜めない。11.4）。 */
export const TRACK_PROCESSOR_MAX_BUFFER_SIZE = 1;

/** ワーカーを起動して、準備完了（ready）の通知を待つ上限（ミリ秒）。超えたら worker_start_timeout。 */
export const PIPELINE_START_TIMEOUT_MS = 10_000;

/** ワーカーへの要求（応答のあるもの）の応答を待つ上限（ミリ秒）。超えたら request_timeout。 */
export const PIPELINE_REQUEST_TIMEOUT_MS = 10_000;

/**
 * エンコーダの最初の出力（復号器設定 decoderConfig を含む）を待つ上限（ミリ秒）。超えたら priming_timeout。
 * 最初の出力は、配信用のフレームと音声のブロックが届いて初めて得られる（音声のクロックが動いていない場合は、得られない）。
 */
export const DECODER_CONFIG_TIMEOUT_MS = 5_000;

/** 合成の余白（主映像の内接で生じる余白）の単色（11.4）。映像の色の見えを妨げない中立の黒。 */
export const COMPOSITION_LETTERBOX_COLOR = "#000000";

/**
 * 代替スレート（映像ソースが皆無のときの、内部生成の静止の映像。11.2）。文字を描かない（利用者の文言を含めない）。
 * 単色の背景と、簡素な図形（中央の角丸の枠と、円）だけ。色はデザインシステムのトークン（--bg2・--silver・--teal）の値。
 * 割合は、出力幅に対する千分率（整数）。
 */
export const SLATE = Object.freeze({
  backgroundColor: "#0a0e1a",
  frameColor: "rgba(192, 192, 192, 0.08)",
  markColor: "rgba(0, 251, 255, 0.35)",
  frameWidthPermille: 300,
  frameAspectWidth: 16,
  frameAspectHeight: 9,
  frameCornerRadiusPermille: 60,
  markRadiusPermille: 40,
});

/**
 * 遅れの検知（LagGuard）の基準。ワーカーの音声のブロックの処理待ちの深さ（ミリ秒）を推定し、
 *   BACKLOG_ENTER_MS         これを超えたら、遅れている（合成を飛ばす）。映像 3 フレーム分
 *   BACKLOG_EXIT_MS          遅れている状態からは、これを下回ったら戻る（ヒステリシス）。映像 1 フレーム分
 *   BACKLOG_DRIFT_ALLOWANCE  音声のクロックと実時間の進みの差（割合）の許容。基準が、この割合までの速さで追従する（500 ppm）
 *   BACKLOG_MAX_BEHIND_MS    遅れの状態が、これを超えて続いたら、基準がずれたとみなして、基準をやり直す
 *                            （音声の停止・再開の通知が無いまま、実時間だけが進んだ場合の安全装置。合成が止まり続けないようにする）
 */
export const BACKLOG_ENTER_MS = 100;
export const BACKLOG_EXIT_MS = 30;
export const BACKLOG_DRIFT_ALLOWANCE = 0.0005;
export const BACKLOG_MAX_BEHIND_MS = 3000;
