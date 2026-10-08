// 配信パイプライン（合成とエンコード。issue #27）の型付きのエラーと、故障の通知（ワーカー -> メインスレッド）。
// メッセージは、符号と、元のエラーの名前だけ（元のエラーの文面は、デバイス名・URL などを含み得るので、メッセージにも故障の通知にも入れない。cause に残す）。
// 利用者へ表示する文言は、画面（#29）が、符号から、文言カタログの文言を選ぶ（ここに文言を持たない）。

import { nameOf } from "@/lib/sources/error-name";

/**
 *   invalid_message              ワーカーとの間のメッセージが、決められた形でない
 *   invalid_state                状態に合わない呼び出し（終了したクライアントへの呼び出しなど）
 *   profile_locked               プロファイルは配信の開始時に確定し、配信中に変更しない（11.7）
 *   not_configured               エンコーダの設定の前に、設定を要する呼び出しをした
 *   bitrate_out_of_range         映像ビットレートが、プロファイルの下限から上限の範囲に無い
 *   video_config_unsupported     H.264 の設定を、エンコーダが使えない（isConfigSupported が偽）
 *   audio_config_unsupported     AAC-LC の設定を、エンコーダが使えない（Linux・ChromeOS の Chrome など。30.1）
 *   video_encoder_error          映像エンコーダの error コールバック
 *   audio_encoder_error          音声エンコーダの error コールバック
 *   decoder_config_missing       エンコーダが返した復号器設定（description）が無い・形が正しくない
 *   decoder_config_unavailable   復号器設定を、まだ得ていない（エンコーダの最初の出力の前）
 *   priming_timeout              エンコーダの最初の出力を、期限内に得られなかった（音声のクロックが動いていない、など）
 *   compose_failed               映像の合成に失敗した（このフレームは符号化しない）
 *   source_stream_failed         映像ソースのフレームのストリームが、失敗した
 *   audio_continuity_lost        音声のブロックの累積サンプル数が連続しない（メディアクロックの基準が崩れた）
 *   worker_crashed               ワーカーが異常終了した（error イベント）
 *   worker_start_timeout         ワーカーが、期限内に準備完了を通知しなかった
 *   request_timeout              ワーカーが、期限内に応答しなかった
 *   terminated                   クライアントが終了した（terminate）ため、待っていた要求を打ち切った
 *   preview_already_transferred  この canvas は、すでにワーカーへ渡した（transferControlToOffscreen は 1 回だけ）
 *   preview_unavailable          プレビューの canvas を使えない（2D コンテキストを得られない・描画に失敗した）
 *   environment_unsupported      ワーカーの実行環境に、必要な機能（WebCodecs・OffscreenCanvas・タイマ）が無い
 *   unexpected                   想定していない失敗
 */
export const PIPELINE_ERROR_CODES = [
  "invalid_message",
  "invalid_state",
  "profile_locked",
  "not_configured",
  "bitrate_out_of_range",
  "video_config_unsupported",
  "audio_config_unsupported",
  "video_encoder_error",
  "audio_encoder_error",
  "decoder_config_missing",
  "decoder_config_unavailable",
  "priming_timeout",
  "compose_failed",
  "source_stream_failed",
  "audio_continuity_lost",
  "worker_crashed",
  "worker_start_timeout",
  "request_timeout",
  "terminated",
  "preview_already_transferred",
  "preview_unavailable",
  "environment_unsupported",
  "unexpected",
] as const;
export type PipelineErrorCode = (typeof PIPELINE_ERROR_CODES)[number];

export function isPipelineErrorCode(value: unknown): value is PipelineErrorCode {
  return typeof value === "string" && (PIPELINE_ERROR_CODES as readonly string[]).includes(value);
}

export class PipelineError extends Error {
  readonly code: PipelineErrorCode;
  /** 元のエラーの名前（DOMException の EncodingError など）。無ければ null。文面は持たない */
  readonly detail: string | null;

  constructor(code: PipelineErrorCode, cause?: unknown) {
    const detail = nameOf(cause);
    super(`pipeline error: ${code}${detail === null ? "" : ` (${detail})`}`, cause === undefined ? undefined : { cause });
    this.name = "PipelineError";
    this.code = code;
    this.detail = detail;
  }
}

/** 故障の通知（ワーカー -> メインスレッド）。構造化複製で送れる単純な値で、符号と、元のエラーの名前だけ。 */
export interface PipelineFault {
  readonly code: PipelineErrorCode;
  readonly detail: string | null;
}

/** 投げられた値を、故障の通知にする。PipelineError はそのまま、それ以外は unexpected（名前だけを残す）。 */
export function faultOf(error: unknown): PipelineFault {
  if (error instanceof PipelineError) {
    return { code: error.code, detail: error.detail };
  }
  return { code: "unexpected", detail: nameOf(error) };
}

/**
 * ワーカーから届いた故障の通知を、PipelineError にする（応答のある要求を拒否するときに使う）。
 * 元のエラーの名前（detail）は、通知のものを引き継ぐ（文面は、通知に無い）。
 */
export function errorFromFault(fault: PipelineFault): PipelineError {
  return new PipelineError(fault.code, fault.detail === null ? undefined : { name: fault.detail });
}
