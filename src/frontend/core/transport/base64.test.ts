/**
 * @jest-environment node
 */
// base64（標準の文字集合・パディングあり）の符号化・復号（ws-protocol.md の 5.3：description_b64）。
//   - 復号は厳密：長さ・文字・パディングの位置・末尾の余りのビット（正規形）を検査する。往復で、同じ文字列・同じバイト列に戻る
//   - 独立した実装（Node の Buffer）と、RFC 4648 の例・契約のベクタの値で突き合わせる
import { Problems, seededRandom } from "../testing/helpers";
import { decodeBase64, encodeBase64 } from "./base64";

function bytesOf(...values: number[]): Uint8Array {
  return Uint8Array.from(values);
}

function asciiBytes(text: string): Uint8Array {
  return Uint8Array.from(Array.from(text, (character) => character.charCodeAt(0)));
}

describe("encodeBase64: RFC 4648 の例と、契約の例", () => {
  test.each([
    ["", ""],
    ["f", "Zg=="],
    ["fo", "Zm8="],
    ["foo", "Zm9v"],
    ["foob", "Zm9vYg=="],
    ["fooba", "Zm9vYmE="],
    ["foobar", "Zm9vYmFy"],
  ])("%j -> %j", (text, expected) => {
    expect(encodeBase64(asciiBytes(text))).toBe(expected);
  });

  test("音声の復号器設定（AAC-LC・44.1 kHz・2 ch は 0x12 0x10）は EhA=（契約 ws-protocol.md の 5.3）", () => {
    expect(encodeBase64(bytesOf(0x12, 0x10))).toBe("EhA=");
  });

  test("契約のベクタの映像の復号器設定（AVCDecoderConfigurationRecord）の base64 を、復号して再び符号化すると、同じ文字列に戻る", () => {
    const text = "AU1AH//hAA9nTUAfllQFAe2AoEA8IhEBAARo7jyA";
    const bytes = decodeBase64(text);
    expect(bytes[0]).toBe(1);
    expect(encodeBase64(bytes)).toBe(text);
  });

  test("0 から 255 までの全バイト値が、往復で同じになる", () => {
    const all = Uint8Array.from({ length: 256 }, (_, value) => value);
    expect(decodeBase64(encodeBase64(all))).toEqual(all);
  });
});

describe("decodeBase64: 正しい入力", () => {
  test.each([
    ["Zg==", "f"],
    ["Zm8=", "fo"],
    ["Zm9v", "foo"],
    ["Zm9vYg==", "foob"],
    ["", ""],
  ])("%j -> %j", (text, expected) => {
    expect(decodeBase64(text)).toEqual(asciiBytes(expected));
  });

  test("標準の文字集合の + と / を扱う（URL 安全な - と _ ではない）", () => {
    expect(decodeBase64("+/8=")).toEqual(bytesOf(0xfb, 0xff));
    expect(encodeBase64(bytesOf(0xfb, 0xff))).toBe("+/8=");
  });
});

describe("decodeBase64: 不正な入力は、推測して復号せず RangeError", () => {
  test.each([
    ["長さが 4 の倍数でない（パディングの不足）", "Zg="],
    ["長さが 4 の倍数でない（1 文字）", "Z"],
    ["長さが 4 の倍数でない（5 文字）", "Zm9vY"],
    ["範囲外の文字", "Zm9v!A=="],
    ["URL 安全な文字（-）", "-_8="],
    ["空白", "Zm9v Zg=="],
    ["改行", "Zm9v\n"],
    ["先頭の空白", " Zm9v"],
    ["パディングが途中にある", "Zg==Zm9v"],
    ["パディングが 3 個", "Z==="],
    ["パディングだけの組", "===="],
    ["パディングの前に、データが無い組", "=Zg="],
    ["末尾の余りのビットが 0 でない（1 バイトの組）", "Zh=="],
    ["末尾の余りのビットが 0 でない（2 バイトの組）", "Zm9="],
    ["パディングの後ろに文字", "Zg=a"],
  ])("%s: %j", (_label, text) => {
    expect(() => decodeBase64(text)).toThrow(RangeError);
  });

  test.each([
    ["数値", 12],
    ["null", null],
    ["undefined", undefined],
    ["配列", ["Zm9v"]],
  ])("文字列でない入力（%s）は RangeError", (_label, value) => {
    expect(() => decodeBase64(value as unknown as string)).toThrow(RangeError);
  });
});

describe("独立した実装（Node の Buffer）との突き合わせ", () => {
  test("長さ 0 から 300 のバイト列（決定的な乱数）の符号化が、Buffer と一致し、往復で戻る", () => {
    const random = seededRandom(25);
    const problems = new Problems();
    for (let length = 0; length <= 300; length += 1) {
      const bytes = Uint8Array.from({ length }, () => Math.floor(random() * 256));
      const expected = Buffer.from(bytes).toString("base64");
      const encoded = encodeBase64(bytes);
      if (encoded !== expected) {
        problems.report(`length ${length}: ${encoded} != ${expected}`);
        continue;
      }
      const decoded = decodeBase64(encoded);
      if (decoded.length !== bytes.length || !decoded.every((value, index) => value === bytes[index])) {
        problems.report(`length ${length}: round trip differs`);
      }
    }
    expect(problems.list()).toEqual([]);
  });

  test("符号化は、入力を変更しない。復号の結果は、新しいバイト列", () => {
    const input = bytesOf(1, 2, 3, 4);
    const before = Array.from(input);
    encodeBase64(input);
    expect(Array.from(input)).toEqual(before);
    const first = decodeBase64("AQIDBA==");
    const second = decodeBase64("AQIDBA==");
    first[0] = 99;
    expect(second[0]).toBe(1);
  });

  test("部分ビュー（byteOffset のある Uint8Array）も、ビューの範囲だけを符号化する", () => {
    const backing = bytesOf(9, 9, 0x12, 0x10, 9);
    expect(encodeBase64(backing.subarray(2, 4))).toBe("EhA=");
  });
});
