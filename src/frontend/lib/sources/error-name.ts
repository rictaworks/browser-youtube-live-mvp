// エラーの名前の読み取り。型付きのエラー（SourceError・AudioMixerError）と診断に、元のエラー（DOMException など）の名前だけを残すための部品。
// 元のエラーの文面（デバイス名・ラベルを含み得る）は、メッセージにも診断にも入れない。

/** 値が、名前（空でない文字列）を持つオブジェクト（Error・DOMException など）なら、その名前。そうでなければ null（推測しない）。 */
export function nameOf(value: unknown): string | null {
  if (typeof value === "object" && value !== null && "name" in value) {
    const name = (value as { name: unknown }).name;
    return typeof name === "string" && name !== "" ? name : null;
  }
  return null;
}
