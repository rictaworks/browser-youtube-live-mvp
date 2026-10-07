// ソースの取得・解除・喪失の監視（requirements.md 11.2・13.1・16.2・25.5）の型。
// 状態（SourceState）と、状態を動かす規則（transitionSource）は、core/ が持つ（ここで重複して持たない）。

import type { Layout, SourceKind, SourceState } from "@/core/contract";

/** SourceManager が扱うソースの種別（4 種）。代替スレートは、内部生成で、取得・解除の対象ではない。 */
export const MANAGED_SOURCE_KINDS = ["camera", "screen", "microphone", "shared_audio"] as const satisfies readonly SourceKind[];
export type ManagedSourceKind = (typeof MANAGED_SOURCE_KINDS)[number];

export function isManagedSourceKind(value: unknown): value is ManagedSourceKind {
  return typeof value === "string" && (MANAGED_SOURCE_KINDS as readonly string[]).includes(value);
}

/**
 * attach の対象にできる種別。共有音声は、画面共有と同じ取得（getDisplayMedia の音声トラック）で得るため、単独では取得できない
 * （attach("screen") で、共有音声も得られる）。
 */
export const ATTACHABLE_SOURCE_KINDS = ["camera", "screen", "microphone"] as const satisfies readonly ManagedSourceKind[];
export type AttachableSourceKind = (typeof ATTACHABLE_SOURCE_KINDS)[number];

/**
 * 今の状態になった理由（符号）。画面に出す文言は、画面（#29）が、この符号から、文言カタログの文言を選ぶ（ここに文言を持たない）。
 *   released             解除した（利用者の操作）
 *   permission_denied    権限を拒否された（getUserMedia の NotAllowedError。カメラ・マイクだけ）
 *   selection_cancelled  選択の取り消し。画面共有は、ブラウザが、拒否と取り消しを区別できない（どちらも NotAllowedError）ため、
 *                        拒否ではなく取り消しとして、未取得へ戻す
 *   device_not_found     デバイスが無い（NotFoundError・指定したデバイスの識別子が無い）
 *   no_audio_track       画面共有の取得に、音声のトラックが含まれていなかった（共有音声だけが、未取得。共有音声が得られるのは、
 *                        Chrome・Edge の「タブの共有」と、Windows・ChromeOS の「画面全体の共有」だけ）
 *   track_ended          トラックが終了した（デバイスの取り外し・共有の停止）
 *   request_failed       取得に失敗した（型付きのエラー SourceError も、呼び出し元へ投げる）
 */
export const SOURCE_REASON_VALUES = [
  "released",
  "permission_denied",
  "selection_cancelled",
  "device_not_found",
  "no_audio_track",
  "track_ended",
  "request_failed",
] as const;
export type SourceReason = (typeof SOURCE_REASON_VALUES)[number];

/**
 * ソースの 1 つの状態（凍結した、変わらない記録。状態が変わるたびに、新しい記録に置き換わる）。
 * label・deviceId は、画面の表示のためで、ログ・測定イベント・中継へ送らない。
 */
export interface SourceHandle {
  readonly kind: ManagedSourceKind;
  readonly state: SourceState;
  /** 取得済み（active）のときだけ、トラック。それ以外は null（終了したトラックを持たない） */
  readonly track: MediaStreamTrack | null;
  /** 取得したデバイスの識別子（トラックの設定から。画面共有・共有音声は無いので null）。喪失（lost）のときも、最後の値を残す */
  readonly deviceId: string | null;
  /** トラックのラベル（デバイス名）。喪失（lost）のときも、最後の値を残す */
  readonly label: string | null;
  /** 今の状態になった理由。要求中・取得済み・初期の未取得は null */
  readonly reason: SourceReason | null;
}

/** 4 種別すべての現在の状態。 */
export type SourceHandles = Readonly<Record<ManagedSourceKind, SourceHandle>>;

/** ソースの状態の変化（購読者へ通知する）。レイアウトは、変化のあとの映像ソースの組から、resolveLayout で解決し直した結果。 */
export interface SourceChange {
  readonly kind: ManagedSourceKind;
  readonly previous: SourceHandle;
  readonly current: SourceHandle;
  /** 変化のあとのレイアウト（11.3） */
  readonly layout: Layout;
  /** この変化で、レイアウトが変わった */
  readonly layoutChanged: boolean;
}

export type SourceChangeListener = (change: SourceChange) => void;

/**
 * 注入できるメディアデバイス（navigator.mediaDevices に当たる物。テストで差し替える）。
 * getDisplayMedia は、画面共有 API が無い環境には無い（その環境では、画面共有の操作のみ提供しない。30.1）。
 */
export type MediaDevicesLike = Pick<MediaDevices, "getUserMedia" | "enumerateDevices" | "addEventListener" | "removeEventListener"> & {
  readonly getDisplayMedia?: MediaDevices["getDisplayMedia"];
};
