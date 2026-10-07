// プロファイル選定（requirements.md 11.8・15 章）。上り回線の実効スループット（kbps）から、プロファイルと映像ビットレートの開始値を決める。
//
//   実効スループット             | 結果
//   4,100 kbps 以上               | 標準（720p）
//   1,200 kbps 以上 4,100 未満    | 軽量（480p）
//   1,200 kbps 未満               | 回線不足（配信を開始しない。YouTube 資源は作成しない）
//
// 閾値は、契約（limits.json の profiles.<プロファイル>.line_threshold_kbps）の値で、「（映像ビットレート下限 + 音声 128 kbps）の 1.3 倍を
// 100 kbps 単位に丸めた値」（720p は 4,066.4 -> 4,100、480p は 1,206.4 -> 1,200）。導出はテストで再現する。
// 映像ビットレートの開始値は、min(プロファイルの初期値, 実効スループット × 0.75) で、プロファイルの下限を下回らない。

import { LIMITS, PROFILE_VALUES } from "../contract";
import type { Profile } from "../contract";

/** プロファイルを選定できた。 */
export interface SelectedProfile {
  readonly kind: "selected";
  readonly profile: Profile;
  /** 映像ビットレートの開始値（kbps。整数） */
  readonly startBitrateKbps: number;
}

/** 回線不足。終了理由 insufficient_bandwidth に対応する。YouTube 資源は作成しない。 */
export interface InsufficientBandwidth {
  readonly kind: "insufficient_bandwidth";
}

export type ProfileDecision = SelectedProfile | InsufficientBandwidth;

const INSUFFICIENT_BANDWIDTH: InsufficientBandwidth = Object.freeze({ kind: "insufficient_bandwidth" });

function assertThroughput(throughputKbps: number): void {
  if (typeof throughputKbps !== "number" || !Number.isFinite(throughputKbps) || throughputKbps < 0) {
    throw new RangeError(`throughputKbps must be a non-negative finite number: ${String(throughputKbps)}`);
  }
}

function assertProfile(profile: string): asserts profile is Profile {
  if (!(PROFILE_VALUES as readonly string[]).includes(profile)) {
    throw new RangeError(`unknown profile: ${String(profile)}`);
  }
}

/**
 * 映像ビットレートの開始値（kbps。整数）= max(下限, min(初期値, floor(実効スループット × 0.75)))。
 * 比率 0.75 は契約の line_probe.start_bitrate_throughput_ratio。0.75 は 2 進数で厳密に表せるため、積と切り捨ては厳密。
 */
export function startBitrateKbps(profile: Profile, throughputKbps: number): number {
  assertProfile(profile);
  assertThroughput(throughputKbps);
  const limits = LIMITS.profiles[profile];
  const byThroughput = Math.floor(throughputKbps * LIMITS.line_probe.start_bitrate_throughput_ratio);
  return Math.max(limits.video_bitrate_min_kbps, Math.min(limits.video_bitrate_initial_kbps, byThroughput));
}

/**
 * 実効スループット（kbps）から、プロファイルと開始ビットレートを選ぶ。閾値を満たす最も大きいプロファイル（PROFILE_VALUES は大きい順）。
 * どの閾値も満たさなければ回線不足。負・NaN・無限大・数値でない入力は、回線の値として扱わず RangeError。
 */
export function selectProfile(throughputKbps: number): ProfileDecision {
  assertThroughput(throughputKbps);
  for (const profile of PROFILE_VALUES) {
    if (throughputKbps >= LIMITS.profiles[profile].line_threshold_kbps) {
      return Object.freeze({ kind: "selected", profile, startBitrateKbps: startBitrateKbps(profile, throughputKbps) });
    }
  }
  return INSUFFICIENT_BANDWIDTH;
}
