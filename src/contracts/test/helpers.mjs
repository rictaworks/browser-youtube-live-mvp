// 契約のテストの共通部品。Node 22 の標準ライブラリだけを使う（依存パッケージなし）。
//
// 契約のディレクトリの探し方、厳密な JSON の読み込み（キーの重複を許さない）、JSON のキーの扱いを置く。
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));

/** 契約のディレクトリの目印のファイル。このファイルがあるディレクトリを、契約のディレクトリとみなす。 */
export const MARKER_FILE = "enums.json";

/** 契約のディレクトリが見つからないときのエラー。黙ってスキップせず、探した場所を並べて失敗する。 */
export class ContractsNotFoundError extends Error {
  constructor(checked) {
    const lines = checked.map(({ dir, reason }) => `  - ${dir}（${reason}）`);
    super(
      [
        "契約のディレクトリ（src/contracts）が見つかりません。黙ってスキップせず、失敗します。",
        "探した場所（この順）:",
        ...lines,
        `目印のファイル: ${MARKER_FILE}`,
        "対処: docker compose の環境では scripts/test_contracts.sh を使ってください（/contracts へ読み取り専用でマウントされます）。",
        "CI では、リポジトリをチェックアウトしたうえで、src/<層> を作業ディレクトリにして実行してください（../contracts が src/contracts になります）。",
      ].join("\n"),
    );
    this.name = "ContractsNotFoundError";
    this.checked = checked;
  }
}

/**
 * 契約のディレクトリの候補を、探す順に返す。
 *   1. /contracts          docker compose のマウント（読み取り専用）
 *   2. <cwd>/../contracts  CI のチェックアウト（作業ディレクトリが src/<層>）
 *   3. <cwd>/../../contracts
 *   4. このテストの隣       src/contracts/test の 1 つ上（作業ディレクトリに依らない）
 * 同じ場所を指す候補は、最初の 1 つだけを残す（失敗のメッセージに同じ場所を並べないため）。
 */
export function candidateDirs({ cwd = process.cwd(), testDir = TEST_DIR } = {}) {
  const candidates = ["/contracts", path.resolve(cwd, "../contracts"), path.resolve(cwd, "../../contracts"), path.resolve(testDir, "..")];
  return [...new Set(candidates)];
}

function hasMarker(dir) {
  return fs.existsSync(path.join(dir, MARKER_FILE));
}

/**
 * 候補を順に探し、最初に見つかったディレクトリを返す。1 つも無ければ ContractsNotFoundError。
 * hasMarkerFile は、ファイルシステムを使わずにテストするための差し替え口。
 */
export function locateContractsDir({ candidates = candidateDirs(), hasMarkerFile = hasMarker } = {}) {
  const checked = [];
  for (const dir of candidates) {
    if (hasMarkerFile(dir)) {
      return dir;
    }
    checked.push({ dir, reason: `${MARKER_FILE} が無い` });
  }
  throw new ContractsNotFoundError(checked);
}

/**
 * 厳密な JSON の読み込み。JSON.parse と違い、オブジェクトのキーの重複（後の値が黙って勝つ）を許さない。
 * 構文は JSON の文法どおり（末尾のカンマ・コメント・先頭の BOM を許さない）。
 */
export function parseStrictJson(text, label = "JSON") {
  if (text.charCodeAt(0) === 0xfeff) {
    throw new SyntaxError(`${label}: 先頭に BOM があります`);
  }
  let pos = 0;

  const fail = (message) => {
    throw new SyntaxError(`${label}: ${message}（文字位置 ${pos}）`);
  };
  const skipWhitespace = () => {
    while (pos < text.length && " \t\n\r".includes(text[pos])) {
      pos += 1;
    }
  };
  const matchToken = (pattern) => {
    pattern.lastIndex = pos;
    const found = pattern.exec(text);
    if (found === null) {
      return null;
    }
    pos += found[0].length;
    return found[0];
  };
  const STRING = /"(?:[^"\\\u0000-\u001f]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"/y;
  const NUMBER = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y;

  const parseString = () => {
    const token = matchToken(STRING);
    if (token === null) {
      fail("文字列が不正です");
    }
    return JSON.parse(token);
  };
  const parseObject = () => {
    pos += 1;
    const result = {};
    skipWhitespace();
    if (text[pos] === "}") {
      pos += 1;
      return result;
    }
    for (;;) {
      skipWhitespace();
      if (text[pos] !== '"') {
        fail("オブジェクトのキーが文字列ではありません");
      }
      const key = parseString();
      if (Object.hasOwn(result, key)) {
        fail(`オブジェクトのキーが重複しています: ${JSON.stringify(key)}`);
      }
      skipWhitespace();
      if (text[pos] !== ":") {
        fail("キーのあとに : がありません");
      }
      pos += 1;
      // __proto__ のキーでも、プロトタイプを書き換えず、普通のプロパティとして持つ
      Object.defineProperty(result, key, { value: parseValue(), enumerable: true, writable: true, configurable: true });
      skipWhitespace();
      if (text[pos] === ",") {
        pos += 1;
      } else if (text[pos] === "}") {
        pos += 1;
        return result;
      } else {
        fail("オブジェクトの , または } がありません");
      }
    }
  };
  const parseArray = () => {
    pos += 1;
    const result = [];
    skipWhitespace();
    if (text[pos] === "]") {
      pos += 1;
      return result;
    }
    for (;;) {
      result.push(parseValue());
      skipWhitespace();
      if (text[pos] === ",") {
        pos += 1;
      } else if (text[pos] === "]") {
        pos += 1;
        return result;
      } else {
        fail("配列の , または ] がありません");
      }
    }
  };
  function parseValue() {
    skipWhitespace();
    const head = text[pos];
    if (head === "{") return parseObject();
    if (head === "[") return parseArray();
    if (head === '"') return parseString();
    for (const [literal, value] of [
      ["true", true],
      ["false", false],
      ["null", null],
    ]) {
      if (text.startsWith(literal, pos)) {
        pos += literal.length;
        return value;
      }
    }
    const number = matchToken(NUMBER);
    if (number === null) {
      fail("値が不正です");
    }
    return Number(number);
  }

  const value = parseValue();
  skipWhitespace();
  if (pos !== text.length) {
    fail("JSON のあとに余分な文字があります");
  }
  return value;
}

/** 契約のディレクトリのファイル（UTF-8）を読む。 */
export function readContractFile(dir, name) {
  return fs.readFileSync(path.join(dir, name), "utf8");
}

/** 契約の JSON を、厳密に読む。 */
export function readContractJson(dir, name) {
  return parseStrictJson(readContractFile(dir, name), name);
}

/**
 * 契約のテストが使う、契約のディレクトリと、読み込んだ JSON。
 * 契約のディレクトリが見つからなければ、ここで例外になる（テストファイルの読み込みが失敗する）。
 */
export function loadContracts() {
  const dir = locateContractsDir();
  return {
    dir,
    enums: readContractJson(dir, "enums.json"),
    limits: readContractJson(dir, "limits.json"),
    rejections: readContractJson(dir, "http-rejections.json"),
    vectors: readContractJson(dir, "ws-frame-vectors.json"),
  };
}

/** 文書用のキー（$comment・note・*_note）。定数モジュールへは複製しない。 */
export function isDocumentKey(key) {
  return key === "$comment" || key === "note" || key.endsWith("_note");
}

/** 文書用のキーを、再帰的に取り除いた複製を返す（定数モジュールが持つべき内容）。 */
export function withoutDocumentKeys(value) {
  if (Array.isArray(value)) {
    return value.map(withoutDocumentKeys);
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !isDocumentKey(key))
        .map(([key, child]) => [key, withoutDocumentKeys(child)]),
    );
  }
  return value;
}

/** 16 進文字列（空文字列を含む）を、バイト列へ。奇数桁・16 進以外は例外。 */
export function hexToBytes(hex) {
  if (!/^(?:[0-9a-f]{2})*$/.test(hex)) {
    throw new Error(`16 進文字列（小文字・偶数桁）ではありません: ${hex.slice(0, 40)}`);
  }
  return Uint8Array.from(hex.match(/../g) ?? [], (pair) => parseInt(pair, 16));
}

/** バイト列を、小文字の 16 進文字列へ。 */
export function bytesToHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
