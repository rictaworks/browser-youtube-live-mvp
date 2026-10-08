// LagGuard（requirements.md 11.6・12・27。issue #27）。ワーカーが音声のブロックの処理に遅れていること（処理待ちが積み上がっていること）を検知する。
//
//   背景  音声のブロック（128 サンプル = 約 2.9 ミリ秒）は、音声のスレッドから、一定の間隔で、ワーカーへ直接届く。ワーカーが 1 フレームの合成に時間を取られる
//         （GPU が無い環境・負荷の高い端末）と、その間に届いたブロックがポートの待ちに積み上がり、あとでまとめて（続けて）処理される。
//         合成を毎回行うと、遅れを取り戻せず、待ちが増え続ける（停止などの制御メッセージも、待ちの後ろに回る）。
//         そこで、遅れている間は、合成を飛ばす。映像のフレーム番号は、音声の累積サンプル数から決まるので、飛ばしても時刻は正しい。
//         符号化の前に飛ばすので、参照の連鎖を壊さない（入力待ちが 2 フレームを超えたときに捨てるのと同じ性質）。
//         音声のブロックは、常に処理する（音声は途切れさせない。ブロックの処理は、1 つ 1 ミリ秒未満で、合成より桁違いに軽い）
//   検知  待ちの深さを推定する。
//           ブロックのイベントの timeStamp = ワーカーが処理を始めた時刻（待ちの間に積み上がったイベントは、処理が始まった時刻の値を持つ。実測で確認）
//           音声の累積サンプル数 = ブロックが作られた時刻（実時間と同じ速さで進む）
//         2 つの進みの差（offset）が増えた分が、待ちの深さの増え。offset の最小値を基準（待ちが無いときの値）とし、基準からの超過を、待ちの深さとする。
//         待ちが ENTER を超えたら遅れ、EXIT を下回ったら戻る（ヒステリシス）。
//         旧方式（timeStamp の間隔が小さい塊が 1 フレーム分続いたら遅れ）は、遅れの原因である合成そのものが、塊の連続を断ち切る（合成の直後の
//         ブロックは、間隔が大きい）ため、合成が 12 ブロックより短い周期で行われる限り、検知できなかった（実測で確認。待ちが 10 秒まで積み上がった）。
//         実時計の API を、こちらからは呼ばない（イベントが持つ値を読むだけ。メディアの時刻の採番には、関わらない）。
//   基準  音声のクロックと実時間は、わずかにずれる（ppm の単位）。基準は、BACKLOG_DRIFT_ALLOWANCE の速さまで、上へ追従する（誤検知を防ぐ）。
//         音声の停止・再開は、呼び出し側が reset する。通知が無いまま基準がずれた（スリープなど）場合に備えて、遅れの状態が
//         BACKLOG_MAX_BEHIND_MS を超えて続いたら、基準をやり直す（合成が止まり続けない）
//   不明  timeStamp が無い・有限の数でない・逆行した場合は、基準をやり直し、遅れとしない（継続側。合成を止めない）

import { LIMITS } from "@/core/contract";
import { BACKLOG_DRIFT_ALLOWANCE, BACKLOG_ENTER_MS, BACKLOG_EXIT_MS, BACKLOG_MAX_BEHIND_MS } from "@/lib/pipeline/config";

const MILLISECONDS_PER_SECOND = 1000;

export class LagGuard {
  /** 最初に観測したブロックの timeStamp。null = 基準が無い（次のブロックが、新しい基準になる） */
  private baseStampMs: number | null = null;
  /** 直前のブロックの、基準からの経過（ミリ秒）。逆行の検知に使う */
  private previousWallMs = 0;
  /** これまでに観測したブロックのサンプル数の合計（今のブロックを含まない） */
  private elapsedFrames = 0;
  /** offset の基準（待ちが無いときの値） */
  private floorMs = 0;
  private behind = false;
  /** 遅れに入った時点の、基準からの経過（ミリ秒） */
  private behindSinceWallMs = 0;
  private backlog = 0;

  /**
   * ブロックを受けたときに呼ぶ。timeStampMs はイベントの timeStamp（ミリ秒）、blockFrames はブロックのサンプル数（チャンネルあたり）。
   * 遅れている（処理待ちが積み上がっている）なら真。
   */
  observe(timeStampMs: unknown, blockFrames: number): boolean {
    if (typeof timeStampMs !== "number" || !Number.isFinite(timeStampMs) || !Number.isInteger(blockFrames) || blockFrames < 1) {
      this.reset();
      return false;
    }
    if (this.baseStampMs === null) {
      this.start(timeStampMs, blockFrames);
      return false;
    }
    const wallMs = timeStampMs - this.baseStampMs;
    if (wallMs < this.previousWallMs) {
      // 時刻が逆行した（異なるポートなど）。基準をやり直す
      this.reset();
      this.start(timeStampMs, blockFrames);
      return false;
    }
    this.previousWallMs = wallMs;
    const mediaMs = (this.elapsedFrames * MILLISECONDS_PER_SECOND) / LIMITS.audio.sample_rate_hz;
    const offsetMs = wallMs - mediaMs;
    const blockMs = (blockFrames * MILLISECONDS_PER_SECOND) / LIMITS.audio.sample_rate_hz;
    if (offsetMs < this.floorMs) {
      this.floorMs = offsetMs;
    } else {
      this.floorMs += Math.min(offsetMs - this.floorMs, blockMs * BACKLOG_DRIFT_ALLOWANCE);
    }
    this.backlog = Math.max(0, offsetMs - this.floorMs);
    this.updateBehind(wallMs, offsetMs);
    this.elapsedFrames += blockFrames;
    return this.behind;
  }

  /** 推定した、処理待ちの深さ（ミリ秒。0 以上）。直近のブロックの時点。 */
  get backlogMs(): number {
    return this.backlog;
  }

  /** 基準と待ちの状態を忘れる（新しい配信・新しいポートの最初から・音声の停止と再開）。次のブロックが、新しい基準になる。 */
  reset(): void {
    this.baseStampMs = null;
    this.previousWallMs = 0;
    this.elapsedFrames = 0;
    this.floorMs = 0;
    this.behind = false;
    this.behindSinceWallMs = 0;
    this.backlog = 0;
  }

  private start(timeStampMs: number, blockFrames: number): void {
    this.baseStampMs = timeStampMs;
    this.previousWallMs = 0;
    this.elapsedFrames = blockFrames;
    this.floorMs = 0;
    this.behind = false;
    this.backlog = 0;
  }

  private updateBehind(wallMs: number, offsetMs: number): void {
    if (!this.behind) {
      if (this.backlog > BACKLOG_ENTER_MS) {
        this.behind = true;
        this.behindSinceWallMs = wallMs;
      }
      return;
    }
    if (this.backlog < BACKLOG_EXIT_MS) {
      this.behind = false;
      return;
    }
    if (wallMs - this.behindSinceWallMs > BACKLOG_MAX_BEHIND_MS) {
      // 待ちが解けないまま長く続いた: 基準がずれたとみなして、今の offset を新しい基準にする
      this.floorMs = offsetMs;
      this.backlog = 0;
      this.behind = false;
    }
  }
}
