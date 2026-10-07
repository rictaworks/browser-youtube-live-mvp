// Domain Core のテストが共有する道具（本番のコードからは使わない）。実時計・Math.random を使わず、結果は毎回同じになる。

/** 決定的な疑似乱数（mulberry32）。0 以上 1 未満の値を返す。同じ種からは、いつも同じ列。 */
export function seededRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  };
}

/**
 * 食い違いの説明を集める入れ物。
 * 大量の点を検査するループは、点ごとに expect を呼ばず（Jest の実行環境では数十倍遅い）、食い違いをここへ集めて、最後に 1 回だけ検査する。
 * 最初の数件だけを残す（失敗の表示を読みやすく保つ）。
 */
export class Problems {
  private static readonly MAX_REPORTED = 5;

  private readonly found: string[] = [];

  report(description: string): void {
    if (this.found.length < Problems.MAX_REPORTED) {
      this.found.push(description);
    }
  }

  list(): readonly string[] {
    return this.found;
  }
}
