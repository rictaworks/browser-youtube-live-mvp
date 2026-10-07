export interface Wordmark {
  /** 最後の語より前の部分（1 語なら、その語） */
  readonly lead: string;
  /** 強調して表示する最後の語（1 語なら、空文字） */
  readonly accent: string;
}

/**
 * 製品名を、ワードマークの「前の語」と「強調する最後の語」に分ける（モックの「Browser <b>Live</b>」）。
 * 語は空白で区切る。前後と語の間の余分な空白は 1 つにそろえる。空の製品名は RangeError。
 */
export function splitWordmark(name: string): Wordmark {
  const words = name.trim().split(/\s+/).filter((word) => word !== "");
  if (words.length === 0) {
    throw new RangeError("splitWordmark: the brand name must not be empty");
  }
  if (words.length === 1) {
    return { lead: words[0], accent: "" };
  }
  return { lead: words.slice(0, -1).join(" "), accent: words[words.length - 1] };
}
