// AudioClockDriver（requirements.md 11.6。issue #26）。音声の処理周期（Worklet のブロック）で、メディアクロックを駆動する。
//
//   - 音声の累積サンプル数が、マスタークロック。ブロックのたびに、MediaClock.onAudioTick(サンプル数) を呼び、期限が来た映像フレームの番号の区間
//     （FrameRange）を、合成（onTick の呼び出し先。#27）へ渡す。音声の処理周期が、合成の駆動源になる
//   - ブロックの累積サンプル数（firstSample）が、クロックの累積と食い違ったら、続けず AudioContinuityError（ブロックの欠落・重複・順序の入れ替わり。
//     メッセージポートでは起きないはずで、起きたら、時刻の基準が崩れたことになる）。クロックは変えない
//   - AudioContext の停止（端末の休止・音声出力の中断）は onAudioStall、再開は onAudioResume。停止中も、実際に生成された音声のサンプルは数える。
//     再開では、空白を埋めず、再開後の最初に合成するフレームをキーフレームにする（#24）。Worklet の累積サンプル数は、AudioContext が止まっている間は
//     進まないので、停止・再開をまたいでも、連続している
//   - 時刻の採番に、実時計（Date・performance）を使わない。時刻は、累積サンプル数から、MediaClock が算出する
//
// AudioMixerListener を実装する。メインスレッドでは、mixer.subscribe(driver) で使う。配信パイプラインのワーカーでは、MessagePort で受けたブロックを
// onBlock へ渡し、AudioContext の状態の変化の通知（メインスレッドから転送）を onStall・onResume へ渡す。

import type { FrameRange, MediaClock } from "@/core/clock";
import type { AudioMixerListener } from "./AudioMixer";
import { AudioContinuityError } from "./errors";
import type { MixedAudioBlock } from "./workletProtocol";

/** 合成へ渡すもの。ブロック（PCM。エンコーダへ）と、このブロックで期限が来た映像フレームの区間（合成へ）。 */
export interface AudioTick {
  readonly block: MixedAudioBlock;
  readonly range: FrameRange;
}

export type AudioTickHandler = (tick: AudioTick) => void;

export class AudioClockDriver implements AudioMixerListener {
  private readonly clock: MediaClock;
  private readonly handleTick: AudioTickHandler;

  constructor(clock: MediaClock, handleTick: AudioTickHandler) {
    this.clock = clock;
    this.handleTick = handleTick;
  }

  /**
   * ブロックで、クロックを進める。ブロックの累積サンプル数が、クロックの累積と一致しなければ、AudioContinuityError（クロックも、通知も、変えない）。
   * handleTick の例外は、そのまま呼び出し元へ伝わる（クロックは、すでに進んでいる）。
   */
  onBlock(block: MixedAudioBlock): void {
    const expected = this.clock.sampleCount;
    if (block.firstSample !== expected) {
      throw new AudioContinuityError(expected, block.firstSample);
    }
    const range = this.clock.onAudioTick(block.frames);
    this.handleTick({ block, range });
  }

  /** AudioContext の停止（端末の休止・音声出力の中断）。合成を止める。 */
  onStall(): void {
    this.clock.onAudioStall();
  }

  /** AudioContext の再開。空白を埋めずに、キーフレームから再開する（停止していなければ、何も起きない）。 */
  onResume(): void {
    this.clock.onAudioResume();
  }
}
