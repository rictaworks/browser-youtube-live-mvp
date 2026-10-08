/**
 * @jest-environment node
 */
// ChunkGate（requirements.md 11.9・12。issue #27）。符号化結果を、メインスレッド（送信待ち）へ渡してよいかの門。
//   - 閉じている間（配信の開始前・再接続中）は、映像も音声も渡さず、捨てる（送信待ちに積まない）。エンコーダは動かし続ける
//   - 開いたあと、映像は最初のキーフレームから渡す（差分フレームは、直前までの全フレームに依存するため。復帰時はキーフレームから再開する）。
//     音声は、すぐ渡す（音声は破棄対象としない。AAC の全フレームが独立）
//   - 開いたまま、もう一度開いても、状態は変わらない（重複した通知で、映像の流れを途切れさせない）
import { createEncodedChunk } from "@/lib/pipeline/chunks";
import type { EncodedChunk } from "@/lib/pipeline/chunks";
import { ChunkGate } from "./ChunkGate";

function video(keyframe: boolean, timestampUs = 0): EncodedChunk {
  return createEncodedChunk({ kind: "video", timestampUs, keyframe, data: new Uint8Array(4) });
}

function audio(timestampUs = 0): EncodedChunk {
  return createEncodedChunk({ kind: "audio", timestampUs, keyframe: false, data: new Uint8Array(3) });
}

describe("閉じている間", () => {
  it("初期状態は閉じていて、映像も音声も渡さない（捨てた数を数える）", () => {
    const gate = new ChunkGate();

    expect(gate.isOpen).toBe(false);
    expect(gate.admit(video(true))).toBe(false);
    expect(gate.admit(video(false))).toBe(false);
    expect(gate.admit(audio())).toBe(false);
    expect(gate.counters).toEqual({ closedDiscardedVideo: 2, closedDiscardedAudio: 1, skippedBeforeKeyframe: 0 });
  });
});

describe("開いたあと", () => {
  it("音声は、すぐ渡す。映像は、最初のキーフレームから渡す（それまでの差分フレームは捨てる）", () => {
    const gate = new ChunkGate();
    gate.open();

    expect(gate.isOpen).toBe(true);
    expect(gate.waitingForKeyframe).toBe(true);
    expect(gate.admit(audio())).toBe(true);
    expect(gate.admit(video(false))).toBe(false);
    expect(gate.admit(video(false))).toBe(false);
    expect(gate.admit(video(true))).toBe(true);
    expect(gate.waitingForKeyframe).toBe(false);
    expect(gate.admit(video(false))).toBe(true);
    expect(gate.admit(audio())).toBe(true);
    expect(gate.counters.skippedBeforeKeyframe).toBe(2);
  });

  it("開いたまま、もう一度開いても、映像の流れは変わらない（重複した通知）", () => {
    const gate = new ChunkGate();
    gate.open();
    gate.admit(video(true));

    gate.open();

    expect(gate.waitingForKeyframe).toBe(false);
    expect(gate.admit(video(false))).toBe(true);
  });
});

describe("閉じて、開き直す（再接続からの復帰）", () => {
  it("閉じている間は渡さず、開き直したら、映像はまた最初のキーフレームから", () => {
    const gate = new ChunkGate();
    gate.open();
    gate.admit(video(true));
    gate.admit(video(false));

    gate.close();
    expect(gate.isOpen).toBe(false);
    expect(gate.admit(video(true))).toBe(false);
    expect(gate.admit(audio())).toBe(false);

    gate.open();
    expect(gate.admit(video(false))).toBe(false);
    expect(gate.admit(video(true))).toBe(true);
    expect(gate.admit(video(false))).toBe(true);
  });

  it("閉じるのは何度でもよい", () => {
    const gate = new ChunkGate();

    expect(() => {
      gate.close();
      gate.close();
    }).not.toThrow();
    expect(gate.isOpen).toBe(false);
  });
});

describe("不変条件: 開いたあとに最初に渡す映像は、必ずキーフレーム", () => {
  it("開閉と映像の並びを 2,000 通り試しても、開き直したあとの最初の映像は、いつもキーフレーム", () => {
    let seed = 20_261_008;
    const random = (): number => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };
    const gate = new ChunkGate();
    let firstVideoAfterOpen = true;

    for (let step = 0; step < 2000; step += 1) {
      const roll = random();
      if (roll < 0.1) {
        gate.open();
        // 開いたまま開き直しても状態が変わらないので、閉じていたときだけ、「開いたあとの最初」になる
        if (!gate.isOpen) {
          throw new Error("the gate must be open after open()");
        }
      } else if (roll < 0.2) {
        gate.close();
        firstVideoAfterOpen = true;
      } else {
        const chunk = video(random() < 0.2, step);
        const admitted = gate.admit(chunk);
        if (admitted && firstVideoAfterOpen) {
          expect(chunk.keyframe).toBe(true);
          firstVideoAfterOpen = false;
        }
      }
    }
  });
});
