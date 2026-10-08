/**
 * @jest-environment node
 */
// 配信パイプラインの設定値（issue #27）。名前と数値は config.ts へ集め、契約（core/contract）の値から導く。
import { videoTimeUs } from "@/core/clock";
import { LIMITS, PROFILE_VALUES } from "@/core/contract";
import {
  AAC_SAMPLES_PER_FRAME,
  DECODER_CONFIG_TIMEOUT_MS,
  ENCODER_QUEUE_MAX_FRAMES,
  FRAME_RATE,
  KEYFRAME_INTERVAL_FRAMES,
  KEYFRAME_INTERVAL_US,
  PIPELINE_REQUEST_TIMEOUT_MS,
  PIPELINE_START_TIMEOUT_MS,
  PREVIEW_INTERVAL_MS,
  PREVIEW_PROFILE,
  TRACK_PROCESSOR_MAX_BUFFER_SIZE,
} from "./config";

describe("契約から導く値", () => {
  it("フレームレートは 30 fps。両方のプロファイルで同じ（違えば、設定の取り違えなので、導出が失敗する）", () => {
    expect(FRAME_RATE).toBe(30);
    for (const profile of PROFILE_VALUES) {
      expect(LIMITS.profiles[profile].framerate).toBe(FRAME_RATE);
    }
  });

  it("キーフレーム間隔は 2 秒 = 60 フレーム = 2,000,000 マイクロ秒（60 フレームの映像の時刻の差と一致する）", () => {
    expect(KEYFRAME_INTERVAL_FRAMES).toBe(60);
    expect(KEYFRAME_INTERVAL_FRAMES).toBe(LIMITS.video.keyframe_interval_seconds * FRAME_RATE);
    expect(KEYFRAME_INTERVAL_US).toBe(2_000_000);
    expect(videoTimeUs(60) - videoTimeUs(0)).toBe(KEYFRAME_INTERVAL_US);
    expect(videoTimeUs(1_000_061) - videoTimeUs(1_000_001)).toBe(KEYFRAME_INTERVAL_US);
  });

  it("エンコーダの入力待ちの上限は 2 フレーム（契約の adaptive.encoder_queue_max_frames）", () => {
    expect(ENCODER_QUEUE_MAX_FRAMES).toBe(2);
    expect(ENCODER_QUEUE_MAX_FRAMES).toBe(LIMITS.adaptive.encoder_queue_max_frames);
  });

  it("AAC-LC の 1 フレームは 1,024 サンプル（音声の出力の時刻を、累積サンプル数から付ける単位）", () => {
    expect(AAC_SAMPLES_PER_FRAME).toBe(1024);
  });

  it("プレビューだけの間のタイマの周期は、30 fps の 1 周期（約 33.3 ミリ秒）", () => {
    expect(PREVIEW_INTERVAL_MS).toBeCloseTo(1000 / 30, 10);
  });

  it("配信前のプレビューの合成は、標準（720p）の解像度", () => {
    expect(PREVIEW_PROFILE).toBe("720p");
  });
});

describe("期限と上限", () => {
  it("すべて正の整数（ミリ秒）で、期限が無限にならない（有限時間で終端へ進む）", () => {
    for (const value of [PIPELINE_START_TIMEOUT_MS, PIPELINE_REQUEST_TIMEOUT_MS, DECODER_CONFIG_TIMEOUT_MS]) {
      expect(Number.isSafeInteger(value)).toBe(true);
      expect(value).toBeGreaterThan(0);
    }
  });

  it("トラックの処理器の入力待ちは、最新の 1 枚だけ（古いフレームを溜めない）", () => {
    expect(TRACK_PROCESSOR_MAX_BUFFER_SIZE).toBe(1);
  });
});
