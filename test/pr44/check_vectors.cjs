'use strict';
// 共有テストベクタ（src/contracts/ws-frame-vectors.json）を、TypeScript の実装（src/frontend/core/transport）へ、Jest を使わず、独立に通す（読み取りのみ）。
// 中継（Go。src/relay/core/frame）も、同じベクタを通す（run_all.sh の別の手順）。これで、ブラウザと中継のコーデックの互換を、両側から確かめる。
//
//   1. TypeScript を、リポジトリの typescript で、その場で CommonJS にして読み込む（ファイルは作らない）
//   2. ベクタの JSON を、直接読む。契約のディレクトリは、/contracts・../contracts・../../contracts・リポジトリの src/contracts の順に探し、
//      見つからなければ、探した場所を並べて失敗する（黙ってスキップしない）
//   3. valid：両方の受信側の復号（方向の違う側は wrong_direction）・decoded の欄からの符号化が hex と一致（decode_only を除く）
//      ブラウザが受ける 7 種は、型付きの復号が本文の JSON と一致。ブラウザが送る 7 種は、型付きの符号化が hex と一致（x_ の拡張のキーを持つものを除く）
//      invalid：receivers に挙げた受信側が、error の符号で拒否（ブラウザの入口 FrameCodec.decode も）
//   4. 差分テスト：このファイルの中の、参照実装（ws-protocol.md の 2 章・4 章から書き下した。Node の Buffer で、TypeScript の実装とは別に書いた）と、
//      TypeScript の復号を、ベクタを土台にした、決定的な乱数の 20 万通りの入力（1 バイトの書き換え・切り詰め・延長・本文長の端の値・
//      種別の全 256 値・属性の全 256 値）で突き合わせる。復号の結果（種別・キーフレーム・時刻・本文）と、エラーの符号が、完全に一致すること
//
// 使い方: node check_vectors.cjs <リポジトリのルート>
// 終了コード: 0 = 問題なし / 1 = 食い違いまたは自己検査の失敗 / 3 = 確認できなかった（TypeScript が無い）

const fs = require('fs');
const path = require('path');

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_UNAVAILABLE = 3;

const repo = path.resolve(process.argv[2] || '');
const coreRoot = path.join(repo, 'src', 'frontend', 'core');
if (!process.argv[2] || !fs.existsSync(coreRoot)) {
  console.error('使い方: node check_vectors.cjs <リポジトリのルート>');
  process.exit(EXIT_FINDINGS);
}

let ts;
try {
  ts = require(path.join(repo, 'src', 'frontend', 'node_modules', 'typescript'));
} catch (error) {
  console.log('SKIP 確認できなかった: TypeScript（src/frontend/node_modules/typescript）が見つかりません。frontend の依存を導入してください');
  process.exit(EXIT_UNAVAILABLE);
}

// ---------------------------------------------------------------------------
// TypeScript の読み込み（その場で CommonJS にする。ファイルは作らない）
// ---------------------------------------------------------------------------

function createLoader() {
  const cache = new Map();
  function resolveFile(base) {
    for (const candidate of [`${base}.ts`, path.join(base, 'index.ts')]) {
      if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
    }
    throw new Error(`module not found: ${path.relative(repo, base)}`);
  }
  function load(file) {
    if (cache.has(file)) return cache.get(file).exports;
    const source = fs.readFileSync(file, 'utf8');
    const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, esModuleInterop: true }, fileName: file }).outputText;
    const moduleObject = { exports: {} };
    cache.set(file, moduleObject);
    const localRequire = (specifier) => {
      if (!specifier.startsWith('.')) throw new Error(`a non-relative import in ${path.relative(repo, file)}: ${specifier}`);
      return load(resolveFile(path.resolve(path.dirname(file), specifier)));
    };
    new Function('exports', 'require', 'module', '__filename', '__dirname', output)(moduleObject.exports, localRequire, moduleObject, file, path.dirname(file));
    return moduleObject.exports;
  }
  return (relative) => load(resolveFile(path.join(coreRoot, relative)));
}

const requireCore = createLoader();
const transport = requireCore('transport');

// ---------------------------------------------------------------------------
// ベクタの読み込み
// ---------------------------------------------------------------------------

function locateContractsDir() {
  const candidates = [...new Set(['/contracts', path.resolve(process.cwd(), '../contracts'), path.resolve(process.cwd(), '../../contracts'), path.join(repo, 'src', 'contracts')])];
  const found = candidates.find((dir) => fs.existsSync(path.join(dir, 'enums.json')));
  if (found === undefined) {
    throw new Error(['契約のディレクトリが見つかりません。黙ってスキップせず、失敗します。探した場所:', ...candidates.map((dir) => `  - ${dir}`)].join('\n'));
  }
  return found;
}

function hexToBuffer(hex) {
  if (!/^([0-9a-f]{2})*$/.test(hex)) throw new Error(`invalid hex: ${hex.slice(0, 40)}`);
  return Buffer.from(hex, 'hex');
}

// ---------------------------------------------------------------------------
// 参照実装（ws-protocol.md の 2 章・4 章から書き下したもの。TypeScript の実装とは独立。reference_frame.cjs）
// ---------------------------------------------------------------------------

const { MAX_MESSAGE, REFERENCE_TYPES, referenceDecode: decodeWithReference, referenceEncode } = require('./reference_frame.cjs');

/** 参照実装の復号の結果を、比較できる値（本文は 16 進数の文字列だけ）にする。 */
function referenceDecode(bytes, accepts) {
  const decoded = decodeWithReference(bytes, accepts);
  if (decoded.error !== undefined) return { error: decoded.error };
  return { type: decoded.type, keyframe: decoded.keyframe, timestamp: decoded.timestamp, body: decoded.body };
}

/** TypeScript の復号の結果を、参照実装と同じ形（比較できる値）にする。 */
function tsDecode(bytes, accepts) {
  try {
    const frame = transport.decodeRawFrame(new Uint8Array(bytes), accepts);
    return { type: frame.type, keyframe: frame.keyframe, timestamp: frame.timestampUs.toString(), body: Buffer.from(frame.body).toString('hex') };
  } catch (error) {
    if (error && error.name === 'FrameError') return { error: error.code };
    return { error: `unexpected: ${String(error)}` };
  }
}

// ---------------------------------------------------------------------------
// 検査
// ---------------------------------------------------------------------------

const problems = [];
const report = (message) => {
  if (problems.length < 20) problems.push(message);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function seeded(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function main() {
  let dir;
  try {
    dir = locateContractsDir();
  } catch (error) {
    console.log(`FAIL ${error.message}`);
    return EXIT_FINDINGS;
  }
  const vectors = JSON.parse(fs.readFileSync(path.join(dir, 'ws-frame-vectors.json'), 'utf8'));
  if (!(vectors.valid.length > 0 && vectors.invalid.length > 0)) {
    console.log('FAIL ベクタが空です');
    return EXIT_FINDINGS;
  }
  console.log(`ok   ベクタを読みました（${dir}。valid ${vectors.valid.length} 件・invalid ${vectors.invalid.length} 件）`);

  const codec = new transport.FrameCodec();
  const receivers = { relay: 'browser_to_relay', browser: 'relay_to_browser' };

  // --- valid ---
  let validChecks = 0;
  for (const vector of vectors.valid) {
    const bytes = hexToBuffer(vector.hex);
    const expected = { type: vector.decoded.type, keyframe: vector.decoded.keyframe, timestamp: vector.decoded.timestamp_us, body: vector.decoded.body_hex };
    for (const accepts of Object.values(receivers)) {
      const ts = tsDecode(bytes, accepts);
      const reference = referenceDecode(bytes, accepts);
      const want = accepts === vector.direction ? expected : { error: 'wrong_direction' };
      validChecks += 1;
      if (!same(ts, want)) report(`valid ${vector.name} (${accepts}): TypeScript ${JSON.stringify(ts)} != ${JSON.stringify(want)}`);
      if (!same(reference, want)) report(`valid ${vector.name} (${accepts}): 参照実装 ${JSON.stringify(reference)} != ${JSON.stringify(want)}`);
    }
    // 符号化
    const frame = { type: vector.decoded.type, keyframe: vector.decoded.keyframe, timestamp: vector.decoded.timestamp_us, body: hexToBuffer(vector.decoded.body_hex) };
    const encoded = Buffer.from(transport.encodeRawFrame({ type: frame.type, keyframe: frame.keyframe, timestampUs: BigInt(frame.timestamp), body: new Uint8Array(frame.body) }));
    validChecks += 1;
    if (vector.decode_only === true) {
      if (encoded.equals(bytes) || encoded[4] !== (bytes[4] & 1)) report(`valid ${vector.name}: decode_only のベクタで、予約ビットが 0 になっていません`);
    } else {
      if (encoded.toString('hex') !== vector.hex) report(`valid ${vector.name}: 符号化が hex と一致しません`);
      if (referenceEncode(frame).toString('hex') !== vector.hex) report(`valid ${vector.name}: 参照実装の符号化が hex と一致しません（ベクタの誤り）`);
    }
    // 型付きの復号（ブラウザが受ける種別）
    if (vector.direction === 'relay_to_browser') {
      validChecks += 1;
      let message;
      try {
        message = codec.decode(new Uint8Array(bytes));
      } catch (error) {
        report(`valid ${vector.name}: 型付きの復号が失敗しました: ${error.message}`);
        continue;
      }
      if (vector.decoded.type === 'keyframe_request') {
        if (!same(message, { type: 'keyframe_request' })) report(`valid ${vector.name}: keyframe_request の復号が不正です`);
      } else if (!same(message, { type: vector.decoded.type, body: JSON.parse(hexToBuffer(vector.decoded.body_hex).toString('utf8')) })) {
        report(`valid ${vector.name}: 型付きの復号が、本文の JSON と一致しません: ${JSON.stringify(message)}`);
      }
    }
  }
  console.log(`${problems.length === 0 ? 'ok  ' : 'FAIL'} valid ${vectors.valid.length} 件：両方の受信側の復号・符号化・型付きの復号（${validChecks} 回の検査）`);

  // --- valid（型付きの符号化：ブラウザが送る 7 種）---
  const beforeTyped = problems.length;
  let typedChecks = 0;
  const skipped = [];
  for (const vector of vectors.valid.filter((item) => item.direction === 'browser_to_relay' && item.decode_only !== true)) {
    const body = hexToBuffer(vector.decoded.body_hex);
    const type = vector.decoded.type;
    const text = () => body.toString('utf8');
    let message;
    if (type === 'hello') message = { type, ticket: text() };
    else if (type === 'probe') message = { type, payload: new Uint8Array(body) };
    else if (type === 'start' || type === 'report' || type === 'end') message = { type, body: JSON.parse(text()) };
    else if (type === 'video') message = { type, timestampUs: BigInt(vector.decoded.timestamp_us), keyframe: vector.decoded.keyframe, payload: new Uint8Array(body) };
    else message = { type, timestampUs: BigInt(vector.decoded.timestamp_us), payload: new Uint8Array(body) };
    typedChecks += 1;
    const encoded = Buffer.from(codec.encode(message)).toString('hex');
    if (encoded !== vector.hex) {
      // 本文に x_ の拡張のキーを持つ（型付きの符号化は、未知のキーを送らない）ものだけ、例外
      const keys = type === 'report' || type === 'start' || type === 'end' ? Object.keys(JSON.parse(text())) : [];
      if (keys.some((key) => key.startsWith('x_'))) skipped.push(vector.name);
      else report(`valid ${vector.name}: 型付きの符号化が hex と一致しません`);
    }
  }
  if (new Set(vectors.valid.filter((item) => item.direction === 'browser_to_relay').map((item) => item.decoded.type)).size !== 7) report('valid: ブラウザが送る種別の例が、7 種そろっていません');
  console.log(`${problems.length === beforeTyped ? 'ok  ' : 'FAIL'} valid（ブラウザが送る 7 種）の型付きの符号化：${typedChecks} 件。型付きでは再現しない（x_ の拡張のキー）：${skipped.length} 件${skipped.length ? `（${skipped.join(', ')}）` : ''}`);

  // --- invalid ---
  const beforeInvalid = problems.length;
  let invalidChecks = 0;
  for (const vector of vectors.invalid) {
    const bytes = hexToBuffer(vector.hex);
    for (const receiver of vector.receivers) {
      const accepts = receivers[receiver];
      invalidChecks += 1;
      const ts = tsDecode(bytes, accepts);
      const reference = referenceDecode(bytes, accepts);
      if (!same(ts, { error: vector.error })) report(`invalid ${vector.name} (${receiver}): TypeScript ${JSON.stringify(ts)} != ${vector.error}`);
      if (!same(reference, { error: vector.error })) report(`invalid ${vector.name} (${receiver}): 参照実装 ${JSON.stringify(reference)} != ${vector.error}`);
      if (receiver === 'browser') {
        try {
          codec.decode(new Uint8Array(bytes));
          report(`invalid ${vector.name}: ブラウザの入口（FrameCodec.decode）が拒否しませんでした`);
        } catch (error) {
          if (!(error && error.name === 'FrameError' && error.code === vector.error)) report(`invalid ${vector.name}: ブラウザの入口の符号が違います: ${error && error.code}`);
        }
      }
    }
  }
  const codes = new Set(vectors.invalid.flatMap((item) => item.receivers.map((receiver) => `${receiver}:${item.error}`)));
  for (const receiver of Object.keys(receivers)) {
    for (const code of ['truncated_header', 'invalid_magic', 'unsupported_version', 'unknown_type', 'wrong_direction', 'too_large', 'length_mismatch']) {
      if (!codes.has(`${receiver}:${code}`)) report(`invalid: ${receiver} を受信側とする ${code} の例がありません（ベクタが、検証の順を網羅していない）`);
    }
  }
  console.log(`${problems.length === beforeInvalid ? 'ok  ' : 'FAIL'} invalid ${vectors.invalid.length} 件：receivers の受信側が、error の符号で拒否（${invalidChecks} 回の検査。7 種のエラーを、両方の受信側で網羅）`);

  // --- 差分テスト ---
  const beforeDifferential = problems.length;
  const random = seeded(2025);
  const bases = vectors.valid.map((vector) => hexToBuffer(vector.hex));
  const typeCodes = Object.keys(REFERENCE_TYPES).map(Number);
  let compared = 0;
  const compare = (bytes, label) => {
    for (const accepts of Object.values(receivers)) {
      compared += 1;
      const ts = tsDecode(bytes, accepts);
      const reference = referenceDecode(bytes, accepts);
      if (!same(ts, reference)) report(`差分 ${label} (${accepts}): TypeScript ${JSON.stringify(ts).slice(0, 120)} / 参照実装 ${JSON.stringify(reference).slice(0, 120)}`);
    }
  };
  // 1. ベクタの 1 バイトの書き換え（ヘッダ全体と、本文の先頭）× 代表的な値
  const interesting = [0x00, 0x01, 0x02, 0x41, 0x42, 0x4b, 0x4c, 0x7f, 0x80, 0xfe, 0xff];
  for (const base of bases) {
    for (let position = 0; position < Math.min(base.length, 24); position += 1) {
      for (const value of interesting) {
        const mutated = Buffer.from(base);
        mutated[position] = value;
        compare(mutated, `byte ${position}=${value}`);
      }
    }
    // 2. すべての長さへの切り詰め（ヘッダの付近）
    for (let length = 0; length <= Math.min(base.length, 40); length += 1) compare(base.subarray(0, length), `truncated ${length}`);
    // 3. 末尾の延長
    for (const extra of [1, 2, 5, 100]) compare(Buffer.concat([base, Buffer.alloc(extra, 0xab)]), `extended ${extra}`);
  }
  // 4. 種別の全 256 値 × 属性の全 256 値（本文は空・本文長は 0）
  for (let type = 0; type < 256; type += 1) {
    for (let attributes = 0; attributes < 256; attributes += 8) {
      const header = Buffer.alloc(17);
      header.set([0x42, 0x4c, 1, type, attributes]);
      compare(header, `type ${type} attr ${attributes}`);
    }
  }
  // 5. 本文長の端の値（宣言と実際の食い違い・2 MB の境界・符号なし 32 ビットの最大）
  const lengthFields = [0, 1, 2, 255, 256, 65535, 65536, MAX_MESSAGE - 18, MAX_MESSAGE - 17, MAX_MESSAGE - 16, MAX_MESSAGE, 0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff];
  for (const code of typeCodes) {
    for (const declared of lengthFields) {
      for (const actual of [0, 1, 2, 17, 300]) {
        const header = Buffer.alloc(17);
        header.set([0x42, 0x4c, 1, code, 0]);
        header.writeUInt32BE(declared, 13);
        compare(Buffer.concat([header, Buffer.alloc(actual, 7)]), `declared ${declared} actual ${actual} type ${code}`);
      }
    }
  }
  // 6. 全体がちょうど上限・上限を 1 バイト超える（実際に確保する）
  for (const code of [0x04, 0x81]) {
    for (const total of [MAX_MESSAGE - 1, MAX_MESSAGE, MAX_MESSAGE + 1]) {
      const message = Buffer.alloc(total);
      message.set([0x42, 0x4c, 1, code, 0]);
      message.writeUInt32BE(total - 17, 13);
      compare(message, `total ${total} type ${code}`);
    }
  }
  // 7. 時刻の欄（64 ビット）のランダムな値と、本文のランダムな長さ（正しいフレームを、乱数で作る）
  for (let round = 0; round < 40000; round += 1) {
    const code = typeCodes[Math.floor(random() * typeCodes.length)];
    const bodyLength = Math.floor(random() * 300);
    const body = Buffer.alloc(bodyLength);
    for (let index = 0; index < bodyLength; index += 1) body[index] = Math.floor(random() * 256);
    const header = Buffer.alloc(17);
    header.set([0x42, 0x4c, 1, code, Math.floor(random() * 256)]);
    for (let index = 5; index < 13; index += 1) header[index] = Math.floor(random() * 256);
    header.writeUInt32BE(bodyLength, 13);
    compare(Buffer.concat([header, body]), `random ${round}`);
  }
  // 8. 完全にランダムなバイト列（先頭の数バイトだけ、識別子・版を正しくする場合を含む）
  for (let round = 0; round < 40000; round += 1) {
    const length = Math.floor(random() * 60);
    const bytes = Buffer.alloc(length);
    for (let index = 0; index < length; index += 1) bytes[index] = Math.floor(random() * 256);
    if (length >= 3 && random() < 0.5) bytes.set([0x42, 0x4c, 1]);
    compare(bytes, `noise ${round}`);
  }
  console.log(`${problems.length === beforeDifferential ? 'ok  ' : 'FAIL'} 差分テスト：参照実装と TypeScript の復号が、${compared} 通り（2 つの受信側の合計）で、完全に一致`);

  if (problems.length > 0) {
    console.log('食い違い:');
    problems.forEach((item) => console.log(`  - ${item}`));
    return EXIT_FINDINGS;
  }
  return EXIT_OK;
}

process.exit(main());
