'use strict';
// ワイヤの 2 つの規則を、Jest を使わず、仕様から別に書いた参照実装（reference_frame.cjs）と、Node 標準の URL 解析で、独立に確かめる（読み取りのみ）。
// PR #44 のレビュー S1・S2 の再発防止。
//
//   A. 映像・音声は、時刻が必須（S1）。省くと、黙って 0 にせず、FrameError（invalid_message）。制御メッセージ 12 種は、省くと 0。
//      中継の TimeGuard は、同じ種別で時刻が逆行するフレームを破棄する。0 で補うと、2 枚目以降が破棄され、ブラウザには何も見えないまま配信が止まるため。
//      符号化の結果は、参照実装の符号化（Buffer）と、バイト列まで一致すること。
//   B. 状態通知（status）の視聴 URL（watch_url）は、https の YouTube のホスト（www.youtube.com・youtube.com・youtu.be）だけ（S2）。
//      受け入れた文字列は、ブラウザ（WHATWG の URL 解析）が、https の YouTube のホストへのリンクとして扱うものであること（資格情報・ポートを持たない）。
//      攻撃の形（別のスキーム・別のホスト・ユーザー情報・バックスラッシュ・制御文字・ホストの偽装）を、決定的な乱数で作った約 10 万通りで、この性質を確かめる。
//      TypeScript の実装は、URL 解析を使わない（core は URL を参照できない）。この検査の URL 解析は、実装とは別の、独立した判定。
//
// 使い方: node check_wire_rules.cjs <リポジトリのルート>
// 終了コード: 0 = 問題なし / 1 = 食い違い / 3 = 確認できなかった（TypeScript が無い）

const path = require('path');
const createCoreLoader = require('./ts_loader.cjs');
const { REFERENCE_TYPES, referenceControl, referenceEncode } = require('./reference_frame.cjs');

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_UNAVAILABLE = 3;

if (!process.argv[2]) {
  console.error('使い方: node check_wire_rules.cjs <リポジトリのルート>');
  process.exit(EXIT_FINDINGS);
}
const repo = path.resolve(process.argv[2]);
const requireCore = createCoreLoader(repo);
if (requireCore === null) {
  console.log('SKIP 確認できなかった: TypeScript（src/frontend/node_modules/typescript）が見つかりません。frontend の依存を導入してください');
  process.exit(EXIT_UNAVAILABLE);
}
const transport = requireCore('transport');
const codec = new transport.FrameCodec();

const problems = [];
const report = (message) => {
  if (problems.length < 30) problems.push(message);
};

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

/** 関数を実行して、{ value } または { error } にする。 */
function attempt(action) {
  try {
    return { value: action() };
  } catch (error) {
    return { error };
  }
}

const isFrameError = (error, code) => error !== undefined && error !== null && error.name === 'FrameError' && error.code === code;

// ---------------------------------------------------------------------------
// A. 映像・音声は、時刻が必須（S1）
// ---------------------------------------------------------------------------

function checkMediaTimestamps() {
  const before = problems.length;
  let checks = 0;
  const MEDIA = ['video', 'audio'];
  const names = Object.values(REFERENCE_TYPES).map(([name]) => name);
  const controlNames = names.filter((name) => !MEDIA.includes(name));
  const body = Uint8Array.from([1, 2, 3, 4, 5]);
  const two64 = (BigInt(1) << BigInt(64));
  const two53 = BigInt(Number.MAX_SAFE_INTEGER) + BigInt(1);

  // 1. 映像・音声：時刻を省く（欠落・undefined・null）-> invalid_message
  for (const type of MEDIA) {
    const omitted = [
      ['省く', { type, body }],
      ['undefined', { type, timestampUs: undefined, body }],
      ['null', { type, timestampUs: null, body }],
    ];
    for (const [label, input] of omitted) {
      checks += 1;
      const result = attempt(() => transport.encodeRawFrame(input));
      if (!isFrameError(result.error, 'invalid_message')) report(`${type} の時刻（${label}）が、invalid_message になりません（${result.error ? `${result.error.name}:${result.error.code}` : 'フレームを作りました'}）`);
    }
  }
  // 型付きの入口（FrameCodec.encode）も同じ
  const payload = Uint8Array.from([0, 0, 0, 4, 0x65, 0xaa]);
  for (const [label, message] of [
    ['video（時刻なし）', { type: 'video', keyframe: true, payload }],
    ['video（keyframe もなし）', { type: 'video', payload }],
    ['audio（時刻なし）', { type: 'audio', payload }],
    ['video（time: null）', { type: 'video', timestampUs: null, keyframe: false, payload }],
    ['audio（time: undefined）', { type: 'audio', timestampUs: undefined, payload }],
  ]) {
    checks += 1;
    const result = attempt(() => codec.encode(message));
    if (!isFrameError(result.error, 'invalid_message')) report(`FrameCodec.encode: ${label} が invalid_message になりません（${result.error ? `${result.error.name}:${result.error.code}` : 'フレームを作りました'}）`);
  }

  // 2. 明示した 0 は、受け付ける（「省く」と「0」を区別する）。参照実装とバイト列まで一致
  for (const type of MEDIA) {
    for (const timestampUs of [0, BigInt(0)]) {
      checks += 1;
      const encoded = attempt(() => Buffer.from(transport.encodeRawFrame({ type, timestampUs, body })));
      const expected = referenceEncode({ type, keyframe: false, timestamp: 0, body: Buffer.from(body) });
      if (encoded.error || !encoded.value.equals(expected)) report(`${type} の明示した時刻 0（${typeof timestampUs}）が、参照実装の符号化と一致しません`);
    }
  }

  // 3. 制御メッセージ 12 種：時刻を省くと 0（参照実装とバイト列まで一致）
  if (controlNames.length !== 12) report(`制御メッセージの種別が 12 種ではありません: ${controlNames.length}`);
  for (const type of controlNames) {
    checks += 1;
    const encoded = attempt(() => Buffer.from(transport.encodeRawFrame({ type, body })));
    const expected = referenceEncode({ type, keyframe: false, timestamp: 0, body: Buffer.from(body) });
    if (encoded.error || !encoded.value.equals(expected)) report(`制御メッセージ ${type} の、時刻を省いた符号化が、参照実装（時刻 0）と一致しません`);
  }

  // 4. 14 種 × 時刻の値の表：正しい時刻は、参照実装と一致するバイト列。誤った時刻と、媒体の省略は、invalid_message（黙って丸めたり、0 にしたりしない）
  const timestamps = [
    [undefined, '省く'],
    [null, 'null'],
    [0, '0'],
    [33333, '33333'],
    [Number.MAX_SAFE_INTEGER, '2^53 - 1（Number）'],
    [BigInt(0), 'BigInt 0'],
    [two53, '2^53（BigInt）'],
    [two53 + BigInt(1), '2^53 + 1（BigInt）'],
    [two64 - BigInt(1), '2^64 - 1（BigInt）'],
    [two64, '2^64（BigInt）'],
    [-1, '-1'],
    [-BigInt(1), 'BigInt -1'],
    [1.5, '1.5'],
    [Number.NaN, 'NaN'],
    [Number.POSITIVE_INFINITY, 'Infinity'],
    [Number.MAX_SAFE_INTEGER + 1, '2^53（Number）'],
    ['5', '文字列'],
    [{}, 'オブジェクト'],
    [true, '真偽値'],
  ];
  for (const type of names) {
    for (const [timestampUs, label] of timestamps) {
      checks += 1;
      const isMedia = MEDIA.includes(type);
      let valid;
      let wanted;
      if (timestampUs === undefined) {
        valid = !isMedia;
        wanted = BigInt(0);
      } else if (typeof timestampUs === 'bigint') {
        valid = timestampUs >= BigInt(0) && timestampUs < two64;
        wanted = timestampUs;
      } else if (typeof timestampUs === 'number') {
        valid = Number.isSafeInteger(timestampUs) && timestampUs >= 0;
        wanted = valid ? BigInt(timestampUs) : undefined;
      } else {
        valid = false;
      }
      const result = attempt(() => Buffer.from(transport.encodeRawFrame({ type, timestampUs, body })));
      if (valid) {
        const expected = referenceEncode({ type, keyframe: false, timestamp: wanted, body: Buffer.from(body) });
        if (result.error || !result.value.equals(expected)) report(`${type} の時刻（${label}）: 参照実装の符号化と一致しません（${result.error ? result.error.message : 'バイト列の違い'}）`);
      } else if (!isFrameError(result.error, 'invalid_message')) {
        report(`${type} の時刻（${label}）: invalid_message になりません（${result.error ? `${result.error.name}:${result.error.code}` : 'フレームを作りました'}）`);
      }
    }
  }
  console.log(`${problems.length === before ? 'ok  ' : 'FAIL'} A. 映像・音声は時刻が必須。制御メッセージ 12 種は省くと 0（${checks} 回の検査。参照実装のバイト列と一致）`);
}

// ---------------------------------------------------------------------------
// B. 視聴 URL は、https の YouTube のホストだけ（S2）
// ---------------------------------------------------------------------------

const ALLOWED_HOSTS = new Set(['www.youtube.com', 'youtube.com', 'youtu.be']);

/** 独立した判定：ブラウザ（WHATWG の URL 解析）が、この文字列を、https の YouTube のホストへのリンクとして扱うか（資格情報・ポートなし）。 */
function browserTreatsAsYouTube(text) {
  let url;
  try {
    url = new URL(text);
  } catch (error) {
    return false;
  }
  return url.protocol === 'https:' && ALLOWED_HOSTS.has(url.hostname) && url.username === '' && url.password === '' && url.port === '';
}

/** status のフレーム（参照実装で作る）を、ブラウザの入口（FrameCodec.decode）へ通す。 */
function decodeStatus(watchUrl) {
  const frame = referenceControl('status', { state: 'live', watch_url: watchUrl, warning: null, time_limit_notice_seconds: null, end_reason: null });
  return attempt(() => codec.decode(new Uint8Array(frame)));
}

function checkWatchUrl() {
  const before = problems.length;
  const BACKSLASH = String.fromCharCode(92);
  const TAB = String.fromCharCode(9);
  const LF = String.fromCharCode(10);
  const CR = String.fromCharCode(13);
  const NUL = String.fromCharCode(0);
  const fullwidth = (text) => Array.from(text).map((char) => (/[a-z]/.test(char) ? String.fromCodePoint(char.charCodeAt(0) - 0x61 + 0xff41) : char)).join('');
  const IDEOGRAPHIC_FULL_STOP = String.fromCodePoint(0x3002);
  const SOFT_HYPHEN = String.fromCodePoint(0xad);

  // 1. 独立した判定そのものの自己検査（正しく攻撃を見分けること）
  const oracleCases = [
    ['https://www.youtube.com/watch?v=x', true],
    ['https://youtu.be/x', true],
    ['https://www.youtube.com@evil.example/', false],
    [`https://evil.example${BACKSLASH}@www.youtube.com/`, false],
    ['https://evil.example@www.youtube.com/', false],
    ['https://www.youtube.com:8443/', false],
    ['javascript:alert(1)', false],
    ['http://www.youtube.com/', false],
    [`https://www.you${TAB}tube.com/`, true], // WHATWG は、タブを取り除く。実装は厳しく拒否してよい（受け入れてよいのは、安全なものだけ）
    [`https://youtube${IDEOGRAPHIC_FULL_STOP}com/`, true], // 全角の句点は、ドットとして扱われる
    [`https://you${SOFT_HYPHEN}tube.com/`, true],
    ['//www.youtube.com/', false],
    ['not a url', false],
  ];
  for (const [text, expected] of oracleCases) {
    if (browserTreatsAsYouTube(text) !== expected) report(`独立した判定の自己検査に失敗: ${JSON.stringify(text)} は ${expected} のはず`);
  }

  // 2. 受け入れるべきもの（契約の例と、YouTube の形）。受け入れた値は、そのまま返る
  const mustAccept = [
    'https://www.youtube.com/watch?v=dummyVideoId',
    'https://youtube.com/watch?v=dummyVideoId',
    'https://youtu.be/dummyVideoId',
    'https://www.youtube.com/live/dummyVideoId?feature=share&t=10#comments',
    'https://www.youtube.com/@channel/live',
    'https://www.youtube.com',
    'https://youtu.be?x=1',
  ];
  for (const text of mustAccept) {
    const result = decodeStatus(text);
    if (result.error || !result.value || result.value.body.watch_url !== text) report(`受け入れるべき視聴 URL を拒否しました、または書き換えました: ${text}（${result.error ? result.error.message : JSON.stringify(result.value)}）`);
    if (!browserTreatsAsYouTube(text)) report(`自己検査: 受け入れるべき視聴 URL を、独立した判定が YouTube とみなしません: ${text}`);
  }
  const nullResult = decodeStatus(null);
  if (nullResult.error || nullResult.value.body.watch_url !== null) report('watch_url の null が受け入れられません（準備の完了前の通知）');

  // 3. 拒否するべきもの：invalid_body
  const mustReject = [
    'http://www.youtube.com/watch?v=x',
    'javascript:alert(1)',
    'data:text/html,x',
    'file:///etc/passwd',
    '//www.youtube.com/watch?v=x',
    'www.youtube.com/watch?v=x',
    'HTTPS://www.youtube.com/watch?v=x',
    ` https://www.youtube.com/watch?v=x`,
    `https://www.youtube.com/watch?v=x${LF}`,
    '',
    'https://',
    'https://evil.example/watch?v=x',
    'https://www.youtube.com.evil.example/watch?v=x',
    'https://www.youtube.com@evil.example/',
    'https://evil.example@www.youtube.com/',
    `https://evil.example${BACKSLASH}@www.youtube.com/`,
    'https://www.youtube.com:443/watch?v=x',
    'https://m.youtube.com/watch?v=x',
    'https://www.youtube.com./watch?v=x',
    'https://WWW.YOUTUBE.COM/watch?v=x',
    `https://www.you${TAB}tube.com/watch?v=x`,
    `https://www.youtube.com/watch${BACKSLASH}evil`,
    `https://www.youtube.com/watch?v=x${NUL}`,
    `https://youtube${IDEOGRAPHIC_FULL_STOP}com/`,
    `https://${fullwidth('youtube')}.com/`,
  ];
  for (const text of mustReject) {
    const result = decodeStatus(text);
    if (!isFrameError(result.error, 'invalid_body')) report(`拒否するべき視聴 URL が invalid_body になりません: ${JSON.stringify(text)}（${result.error ? `${result.error.name}:${result.error.code}` : '受け入れました'}）`);
  }

  // 4. 性質の検査：受け入れた文字列は、ブラウザが YouTube への https のリンクとして扱うものだけ。決定的な乱数の約 10 万通り
  const random = seeded(2026);
  const pick = (list) => list[Math.floor(random() * list.length)];
  const SCHEMES = ['https', 'http', 'HTTPS', 'Https', 'javascript', 'data', 'blob', 'file', 'ftp', 'wss', '', ' https', 'https '];
  const SEPARATORS = ['://', ':/', ':', `:${BACKSLASH}${BACKSLASH}`, '//', `${BACKSLASH}${BACKSLASH}`, `/${BACKSLASH}`, ':///', `:${BACKSLASH}/`];
  const AUTHORITIES = ['', '', '', 'user@', 'user:pw@', 'www.youtube.com@', '@', ':@', 'evil.example@', 'evil.example:443@'];
  const HOSTS = [
    'www.youtube.com', 'www.youtube.com', 'youtube.com', 'youtu.be', 'WWW.YOUTUBE.COM', 'YouTu.be', 'www.youtube.com.', 'www.youtube.com..', '.www.youtube.com',
    'm.youtube.com', 'music.youtube.com', 'www.youtu.be', 'evil.example', 'www.youtube.com.evil.example', 'evil.example.www.youtube.com', 'wwwyoutube.com',
    'youtube.com.evil.example', 'xn--youtube-6o3b.com', '127.0.0.1', '2130706433', '0x7f.1', '[::1]', 'localhost', 'www.youtube.com%2eevil.example', 'www%2eyoutube.com',
    'www.youtube.com%00', 'www.youtube.com%40evil.example', fullwidth('youtube') + '.com', `youtube${IDEOGRAPHIC_FULL_STOP}com`, `you${SOFT_HYPHEN}tube.com`,
  ];
  const PORTS = ['', '', '', ':443', ':80', ':0', ':8443', ':', ':evil', ':65536'];
  const TAILS = [
    '', '/', '/watch?v=abc', '?x=1', '#frag', '/@chan', '/live/abc?feature=share#t=10', `${BACKSLASH}evil.example`, `/${BACKSLASH}evil.example`, '//evil.example',
    '/%2f%2fevil.example', '/..//evil.example', '?next=//evil.example', '#@evil.example', '/ ', `/${TAB}`, `/${LF}`, `/${CR}`, ' ', LF, TAB, '%0a', '%09', '/%00', '/..%2f',
  ];
  const INSERTIONS = [TAB, LF, CR, ' ', NUL, BACKSLASH, '@', ':', '/', '.', '%', '?', '#', '[', ']', String.fromCodePoint(0x7f), String.fromCodePoint(0x3000), String.fromCodePoint(0xff0f), String.fromCodePoint(0x65e5)];
  const mutate = (text) => {
    const position = Math.floor(random() * (text.length + 1));
    const kind = random();
    if (kind < 0.5) return text.slice(0, position) + pick(INSERTIONS) + text.slice(position);
    if (kind < 0.8 && position < text.length) return text.slice(0, position) + pick(INSERTIONS) + text.slice(position + 1);
    if (position < text.length) return text.slice(0, position) + text.slice(position + 1);
    return text;
  };

  const ROUNDS = 100000;
  let accepted = 0;
  let acceptedUnsafe = 0;
  let rejectedUnsafe = 0;
  let rejectedSafe = 0;
  let unexpected = 0;
  for (let round = 0; round < ROUNDS; round += 1) {
    let text;
    if (random() < 0.5) {
      text = `${pick(SCHEMES)}${pick(SEPARATORS)}${pick(AUTHORITIES)}${pick(HOSTS)}${pick(PORTS)}${pick(TAILS)}`;
      if (random() < 0.3) text = mutate(text);
    } else {
      text = `https://${pick(['www.youtube.com', 'youtube.com', 'youtu.be'])}${pick(['', '/', '/watch?v=dummyVideoId', '/live/abc', '?si=abc', '#t=1', '/@chan'])}`;
      for (let times = 1 + Math.floor(random() * 2); times > 0; times -= 1) text = mutate(text);
    }
    const safe = browserTreatsAsYouTube(text);
    const result = decodeStatus(text);
    if (result.error === undefined) {
      accepted += 1;
      if (result.value.body.watch_url !== text) report(`受け入れた値が書き換わりました: ${JSON.stringify(text)} -> ${JSON.stringify(result.value.body.watch_url)}`);
      if (!safe) {
        acceptedUnsafe += 1;
        report(`安全でない視聴 URL を受け入れました（ブラウザは YouTube 以外、または資格情報・ポートつきとして扱う）: ${JSON.stringify(text)}`);
      }
    } else if (isFrameError(result.error, 'invalid_body')) {
      if (safe) rejectedSafe += 1;
      else rejectedUnsafe += 1;
    } else {
      unexpected += 1;
      report(`想定外のエラー: ${JSON.stringify(text)}: ${result.error.name}:${result.error.code || ''}`);
    }
  }
  // 空振りの検知：受け入れた例・攻撃の形で拒否した例が、十分にあること
  if (accepted < 500) report(`受け入れた例が少なすぎます（${accepted} 件）。検査が、受け入れる側を通っていません`);
  if (rejectedUnsafe < 20000) report(`攻撃の形で拒否した例が少なすぎます（${rejectedUnsafe} 件）`);
  console.log(
    `${problems.length === before ? 'ok  ' : 'FAIL'} B. 視聴 URL は https の YouTube だけ（${ROUNDS} 通り。受け入れ ${accepted}・うち安全でない ${acceptedUnsafe}、拒否 ${rejectedUnsafe + rejectedSafe}（うち安全でない形 ${rejectedUnsafe}・厳しすぎて安全なものを拒否 ${rejectedSafe}）、想定外 ${unexpected}）`,
  );
}

function main() {
  checkMediaTimestamps();
  checkWatchUrl();
  if (problems.length > 0) {
    console.log('食い違い:');
    problems.forEach((item) => console.log(`  - ${item}`));
    return EXIT_FINDINGS;
  }
  return EXIT_OK;
}

process.exit(main());
