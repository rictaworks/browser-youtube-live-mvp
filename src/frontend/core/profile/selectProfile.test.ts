/**
 * @jest-environment node
 */
// プロファイル選定（requirements.md 11.8）。実効スループットから、プロファイルと映像ビットレートの開始値を決める。
//   実効 4,100 kbps 以上 = 720p、1,200 以上 4,100 未満 = 480p、1,200 未満 = 回線不足（YouTube 資源を作らない）
//   開始値 = min(プロファイルの初期値, 実効スループット × 0.75)。プロファイルの下限を下回らない
import { LIMITS, PROFILE_VALUES } from "../contract";
import type { Profile } from "../contract";
import { selectProfile, startBitrateKbps } from "./selectProfile";
import type { ProfileDecision } from "./selectProfile";

describe("閾値の導出（11.8：（映像ビットレート下限 + 音声 128 kbps）の 1.3 倍を 100 kbps 単位に丸めた値）", () => {
  test.each<[Profile, number, number]>([
    ["720p", 3_000, 4_100],
    ["480p", 800, 1_200],
  ])("%s：（下限 %i + 音声 128）× 1.3 を 100 kbps 単位に丸めると %i（契約の line_threshold_kbps と一致）", (profile, videoMinimum, expectedThreshold) => {
    const audioKbps = LIMITS.audio.bitrate_kbps;
    expect(audioKbps).toBe(128);
    expect(LIMITS.profiles[profile].video_bitrate_min_kbps).toBe(videoMinimum);

    const raw = (videoMinimum + audioKbps) * 1.3; // 4,066.4 と 1,206.4
    const roundedTo100 = Math.round(raw / 100) * 100;
    expect(roundedTo100).toBe(expectedThreshold);
    expect(LIMITS.profiles[profile].line_threshold_kbps).toBe(expectedThreshold);
  });

  test("プロファイルは大きい順（720p、480p）で、閾値も大きい順（選定は、閾値を満たす最も大きいプロファイルを選ぶ）", () => {
    expect([...PROFILE_VALUES]).toEqual(["720p", "480p"]);
    expect(LIMITS.profiles["720p"].line_threshold_kbps).toBeGreaterThan(LIMITS.profiles["480p"].line_threshold_kbps);
    expect(LIMITS.profiles["720p"].width).toBeGreaterThan(LIMITS.profiles["480p"].width);
  });
});

describe("selectProfile: 境界", () => {
  test.each<[number, ProfileDecision]>([
    [6_000, { kind: "selected", profile: "720p", startBitrateKbps: 4_500 }],
    [100_000, { kind: "selected", profile: "720p", startBitrateKbps: 4_500 }],
    [6_000.5, { kind: "selected", profile: "720p", startBitrateKbps: 4_500 }],
    [4_101, { kind: "selected", profile: "720p", startBitrateKbps: 3_075 }],
    [4_100, { kind: "selected", profile: "720p", startBitrateKbps: 3_075 }],
    [4_099.9, { kind: "selected", profile: "480p", startBitrateKbps: 1_500 }],
    [4_099, { kind: "selected", profile: "480p", startBitrateKbps: 1_500 }],
    [2_000, { kind: "selected", profile: "480p", startBitrateKbps: 1_500 }],
    [1_999, { kind: "selected", profile: "480p", startBitrateKbps: 1_499 }],
    [1_201, { kind: "selected", profile: "480p", startBitrateKbps: 900 }],
    [1_200, { kind: "selected", profile: "480p", startBitrateKbps: 900 }],
    [1_199.9, { kind: "insufficient_bandwidth" }],
    [1_199, { kind: "insufficient_bandwidth" }],
    [800, { kind: "insufficient_bandwidth" }],
    [1, { kind: "insufficient_bandwidth" }],
    [0, { kind: "insufficient_bandwidth" }],
  ])("実効スループット %f kbps -> %j", (throughputKbps, expected) => {
    expect(selectProfile(throughputKbps)).toEqual(expected);
  });

  test("11.8 の表の境界 4 点（4,099・4,100・1,199・1,200）", () => {
    expect(selectProfile(4_099)).toMatchObject({ kind: "selected", profile: "480p" });
    expect(selectProfile(4_100)).toMatchObject({ kind: "selected", profile: "720p" });
    expect(selectProfile(1_199)).toEqual({ kind: "insufficient_bandwidth" });
    expect(selectProfile(1_200)).toMatchObject({ kind: "selected", profile: "480p" });
  });

  test("回線不足の判定は、プロファイルを返さない（YouTube 資源を作らない側）", () => {
    const decision = selectProfile(1_000);
    expect(decision.kind).toBe("insufficient_bandwidth");
    expect("profile" in decision).toBe(false);
    expect("startBitrateKbps" in decision).toBe(false);
  });

  test("結果は変更できない（凍結されている）。同じ入力に、いつも同じ出力", () => {
    expect(Object.isFrozen(selectProfile(5_000))).toBe(true);
    expect(Object.isFrozen(selectProfile(500))).toBe(true);
    expect(selectProfile(3_000)).toEqual(selectProfile(3_000));
  });
});

describe("開始ビットレート：min(初期値, 実効スループット × 0.75)。下限を下回らない", () => {
  test("契約の比率は 0.75", () => {
    expect(LIMITS.line_probe.start_bitrate_throughput_ratio).toBe(0.75);
  });

  test.each<[Profile, number, number]>([
    ["720p", 6_000, 4_500], // 初期値の方が小さい
    ["720p", 4_800, 3_600], // 実効 × 0.75 = 3,600
    ["720p", 4_100, 3_075],
    ["720p", 3_000, 3_000], // 実効 × 0.75 = 2,250 は下限 3,000 を下回るため、下限
    ["720p", 0, 3_000],
    ["480p", 5_000, 1_500],
    ["480p", 2_000, 1_500],
    ["480p", 1_999, 1_499], // 1,499.25 の切り捨て
    ["480p", 1_200, 900],
    ["480p", 1_000, 800], // 750 は下限 800 を下回るため、下限
    ["480p", 0, 800],
  ])("%s・実効 %f kbps -> 開始値 %i kbps", (profile, throughputKbps, expected) => {
    expect(startBitrateKbps(profile, throughputKbps)).toBe(expected);
  });

  test("選定された範囲（実効 1,200 kbps 以上）では、開始値は、いつもプロファイルの下限以上・初期値以下の整数", () => {
    const problems: string[] = [];
    for (let throughput = 1_200; throughput <= 9_000; throughput += 1) {
      const decision = selectProfile(throughput);
      if (decision.kind !== "selected") {
        problems.push(`${throughput}: not selected`);
        continue;
      }
      const limits = LIMITS.profiles[decision.profile];
      const start = decision.startBitrateKbps;
      if (!Number.isInteger(start) || start < limits.video_bitrate_min_kbps || start > limits.video_bitrate_initial_kbps || start > throughput * 0.75) {
        problems.push(`${throughput}: ${decision.profile} start ${start}`);
      }
    }
    expect(problems.slice(0, 5)).toEqual([]);
  });

  test("開始値は、スループットが上がっても、下がらない（単調。480p から 720p へ上がる 4,100 でも、1,500 から 3,075 へ上がる）", () => {
    let previous = 0;
    const problems: string[] = [];
    for (let throughput = 1_200; throughput <= 9_000; throughput += 1) {
      const decision = selectProfile(throughput);
      if (decision.kind !== "selected") {
        problems.push(`${throughput}: not selected`);
        continue;
      }
      if (decision.startBitrateKbps < previous) {
        problems.push(`${throughput}: ${decision.startBitrateKbps} < ${previous}`);
      }
      previous = decision.startBitrateKbps;
    }
    expect(problems.slice(0, 5)).toEqual([]);
  });
});

describe("不正な入力（測定の失敗を、回線の値として扱わず RangeError）", () => {
  test.each([
    ["負の数", -1],
    ["NaN", Number.NaN],
    ["無限大", Number.POSITIVE_INFINITY],
    ["負の無限大", Number.NEGATIVE_INFINITY],
  ])("%s", (_label, value) => {
    expect(() => selectProfile(value)).toThrow(RangeError);
    expect(() => startBitrateKbps("720p", value)).toThrow(RangeError);
  });

  test("数値でない入力", () => {
    expect(() => selectProfile("5000" as never)).toThrow(RangeError);
    expect(() => selectProfile(undefined as never)).toThrow(RangeError);
    expect(() => selectProfile(null as never)).toThrow(RangeError);
  });

  test("未知のプロファイルは、開始値を計算せず RangeError", () => {
    expect(() => startBitrateKbps("1080p" as never, 5_000)).toThrow(RangeError);
  });
});
