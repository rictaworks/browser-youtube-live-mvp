// 適応制御（requirements.md 12 章）の、入力と出力の型。

import type { AdaptiveCondition } from "../contract";
import type { BrowserEvent } from "../report";

/** 評価（毎秒）の入力。時刻・設定値・現況は、すべて、引数で受け取る（Domain Core）。 */
export interface GovernorInput {
  /** 現在時刻（メディアクロック由来の秒。0 以上）。実時計を使わない。1 秒ごとの評価では、前回より 1 秒以上あとの値 */
  readonly nowSec: number;
  /**
   * 滞留時間（ミリ秒。SendQueue.backlogMs の値）。評価できないとき（接続・再接続の直後で、その接続の最初の受領応答を、まだ受けていない）は undefined。
   * undefined の評価では、滞留時間による条件（1・2・3・5・6・7）は評価せず、それらの状態も変えない（条件 4 は評価する）
   */
  readonly backlogMs: number | undefined;
  /** 直近の破棄の履歴：映像を破棄した時刻のリスト（メディアクロック由来の秒。SendQueue.dropHistorySec の値）。順不同でよい */
  readonly dropTimesSec: readonly number[];
  /** 現在の目標ビットレート（映像。kbps）。minKbps 以上 maxKbps 以下の整数 */
  readonly targetKbps: number;
  /** プロファイルの映像ビットレートの下限（kbps）。1 以上の整数 */
  readonly minKbps: number;
  /** プロファイルの映像ビットレートの上限（kbps）。minKbps 以上の整数 */
  readonly maxKbps: number;
  /** 中継の抑制指示（目標ビットレート。kbps）。無ければ省く。受けた評価で 1 回だけ渡す（解除を伝えるメッセージは無い） */
  readonly throttleKbps?: number;
  /** 中継が受領済みと応答した、映像の最新のメディア時刻（マイクロ秒）。まだ 1 つも受けていなければ undefined */
  readonly ackedVideoUs: number | undefined;
  /** 現在の状態が「劣化」か */
  readonly degraded: boolean;
}

/** 劣化の有無の変化：劣化に入った（started）・解除した（cleared）・変化なし（none）。 */
export type DegradedChange = "started" | "cleared" | "none";

/** 再接続の原因。12 章の条件のうち、再接続へ移る 2 つ。 */
export type ReconnectCause = Extract<AdaptiveCondition, "video_ack_stalled" | "backlog_severe_sustained">;

/** 評価の結果。 */
export interface GovernorDecision {
  /**
   * 時刻が進まない評価（直前の評価と同じか、それより前）で、無視した。状態を変えていない。
   * このとき、目標・劣化は入力のままで、ほかの指示・出来事は無い
   */
  readonly ignored: boolean;
  /** 新しい目標ビットレート（kbps）。変更が無ければ、入力の値。常に、下限から上限の範囲 */
  readonly targetKbps: number;
  /** 送信待ちの映像を、すべて破棄する指示（条件 3）。SendQueue.discardAllVideo を呼ぶ */
  readonly discardAllVideo: boolean;
  /** 直ちにキーフレームを発行する指示（条件 3。discardAllVideo と同時） */
  readonly requestKeyframe: boolean;
  /** 接続不良として、再接続へ移る指示（条件 4・5） */
  readonly reconnect: boolean;
  /** 再接続の原因（reconnect が真のときだけ。条件 4 を先に挙げる） */
  readonly reconnectCause: ReconnectCause | undefined;
  /** 新しい「劣化」の有無 */
  readonly degraded: boolean;
  /** 劣化の有無の変化（degraded が、入力から変わったか）。変わったとき、対応する出来事（degraded_started・degraded_cleared）も出る */
  readonly degradedChange: DegradedChange;
  /**
   * 発生させる出来事（状態報告に載せる）。順は、目標の変更（bitrate_down・bitrate_up）、映像の全破棄（video_dropped。破棄したフレーム数は無い）、
   * 劣化の変化（degraded_started・degraded_cleared）
   */
  readonly events: readonly BrowserEvent[];
  /** 成立した条件（契約の列挙 adaptive_condition の順）。目標が、すでに下限・上限にあって、変化が無かったときも、条件は成立している */
  readonly triggered: readonly AdaptiveCondition[];
}

/** 内部の状態の写し（診断用。時刻は秒）。 */
export interface GovernorDiagnostics {
  readonly lastEvaluatedSec: number | undefined;
  /** 滞留時間が 1.5 秒を超えた評価の、連続の数（条件 1） */
  readonly highStreak: number;
  /** 滞留時間が 8 秒を超える状態が始まった時刻（条件 5） */
  readonly severeSinceSec: number | undefined;
  /** 下限で逼迫（滞留時間 1.5 秒超）が始まった時刻（条件 6） */
  readonly squeezedSinceSec: number | undefined;
  /** 劣化中に、滞留時間が 1.5 秒以下になった時刻（条件 7） */
  readonly relaxedSinceSec: number | undefined;
  /** 受領済みの映像の時刻が、最後に進んだ時刻（未受信の間は、最初の評価の時刻。条件 4） */
  readonly ackAdvancedAtSec: number | undefined;
  /** 目標を最後に変えた時刻 */
  readonly lastChangeSec: number | undefined;
}
