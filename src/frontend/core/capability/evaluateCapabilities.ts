// 能力検出の評価（requirements.md 30.1・15 章「能力検出」・16.6）。検出の結果（CapabilityReport）から、開始の可否などを決める純粋な関数。
//
//   能力                                   | 欠ける場合
//   H.264 の映像エンコード                  | 配信の開始を提供しない
//   AAC-LC の音声エンコード                 | 配信の開始を提供しない
//   ワーカー上でのフレーム取得と描画         | 配信の開始を提供しない
//   音声の処理周期での信号取得               | 配信の開始を提供しない
//   WebSocket                              | 配信の開始を提供しない
//   画面共有 API                            | 画面共有の操作のみを提供しない
//   タブ間の排他                            | サーバー側の排他のみで運用する
//
// ブラウザの名称・版では判断しない（入力に持たない）。真偽は、真偽値の true のときだけ「ある」とし、それ以外（undefined など）は「無い」（拒否側）。

import type { CapabilityEvaluation, CapabilityReport, RequiredCapabilityId } from "./types";

/** 検出の結果から、開始の可否・画面共有の可否・タブ間の排他の有無・使うコーデック文字列・開始に必須で不足している能力を返す。 */
export function evaluateCapabilities(report: CapabilityReport): CapabilityEvaluation {
  const videoCodec = typeof report.videoCodec === "string" && report.videoCodec.length > 0 ? report.videoCodec : null;
  const capture = report.frameCapture;
  const hasFrameCapture =
    capture.trackProcessorInWindow === true &&
    capture.readableStreamTransfer === true &&
    capture.offscreenCanvasInWorker === true &&
    capture.videoFrameInWorker === true;

  // 30.1 の表の順
  const missingRequired: RequiredCapabilityId[] = [];
  if (videoCodec === null) {
    missingRequired.push("h264_encode");
  }
  if (report.aacEncode !== true) {
    missingRequired.push("aac_encode");
  }
  if (!hasFrameCapture) {
    missingRequired.push("worker_frame_capture");
  }
  if (report.audioWorklet !== true) {
    missingRequired.push("audio_processing");
  }
  if (report.webSocket !== true) {
    missingRequired.push("websocket");
  }

  return Object.freeze({
    canStart: missingRequired.length === 0,
    canShareScreen: report.screenCapture === true,
    tabLock: report.tabLock === true,
    videoCodec,
    missingRequired: Object.freeze(missingRequired),
  });
}
