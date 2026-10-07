/** 整数を、3 桁区切りの文字列にする（例: 1200 -> 1,200）。実行環境の言語に依らず、同じ結果にする */
export function formatInteger(value: number): string {
  return new Intl.NumberFormat("en-US").format(value);
}
