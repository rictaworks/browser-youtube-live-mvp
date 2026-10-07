'use strict';
// issue #25 の受け入れ条件に対応するテストが、すべて実行され、成功したことを確かめる（読み取りのみ）。
//
// 使い方: node check_acceptance_tests.cjs <リポジトリのルート> <jest --json の出力ファイル>
//
// Jest の JSON の結果（assertionResults）を、受け入れ条件ごとに、テストのファイルと、最上位の describe の題で絞り、成功したテストの数が、下限以上あることを確かめる。
// 失敗・スキップ（pending）・todo があれば失敗にする。ディスクにある 5 ディレクトリのテストのファイルが、すべて結果にあることも確かめる。
// テストの題の変更・削除・スキップで、受け入れ条件が黙って検査されなくなることを防ぐ。
// 下限は、実装担当のテストの件数（ベクタの件数など）の、現在の値。テストを足すのは自由（下限は超える）。減らす・題を変えるときは、この表も直す。

const fs = require('fs');
const path = require('path');

const repo = path.resolve(process.argv[2] || '');
const resultFile = process.argv[3];
if (!process.argv[2] || !resultFile || !fs.existsSync(resultFile)) {
  console.error('使い方: node check_acceptance_tests.cjs <リポジトリのルート> <jest --json の出力ファイル>');
  process.exit(1);
}

const TARGET_DIRECTORIES = ['transport', 'queue', 'governor', 'probe', 'report'];

// [受け入れ条件, テストのファイル（core からの相対パス）, 最上位の describe の題の先頭, 成功したテストの下限, （省略できる）テストの題に含まれる語]
const REQUIRED = [
  // フレームの符号化（core/transport/FrameCodec）
  ['ヘッダ 17 バイト・識別子・版・種別・属性・時刻 8 バイト・本文長 4 バイト', 'transport/frameLayout.test.ts', 'encodeRawFrame: ヘッダの構造', 32],
  ['64 ビットの時刻（0・2^32-1・2^32・2^53-1・2^53・2^53+1・2^63・2^64-1）の符号化（BigInt。8 つの境界）', 'transport/frameLayout.test.ts', 'encodeRawFrame: ヘッダの構造', 8, '時刻の境界'],
  ['64 ビットの時刻の復号（BigInt。丸めない。8 つの境界）', 'transport/frameLayout.test.ts', 'decodeRawFrame: 正しいフレーム', 8, '時刻の境界'],
  ['正しいフレームの復号（14 種の種別・方向・属性・空の本文・上限ちょうど）', 'transport/frameLayout.test.ts', 'decodeRawFrame: 正しいフレーム', 41],
  ['検証の順（7 種のエラーと優先順位）', 'transport/frameLayout.test.ts', 'decodeRawFrame: 検証の順', 37],
  ['拒否（時刻・2 MB 超・未知の種別・本文の型）が型付きのエラー', 'transport/frameLayout.test.ts', 'encodeRawFrame: 拒否', 21],
  ['符号化と復号の往復', 'transport/frameLayout.test.ts', 'encodeRawFrame と decodeRawFrame の往復', 1],
  ['型付きのエラー（FrameError）', 'transport/errors.test.ts', 'FrameError', 3],
  ['base64（description_b64）の符号化・復号・往復・不正な入力', 'transport/base64.test.ts', 'decodeBase64: 不正な入力は', 19],
  ['base64 の独立した実装との突き合わせ', 'transport/base64.test.ts', '独立した実装（Node の Buffer）との突き合わせ', 3],
  ['ブラウザが送る 7 種の encode（hello）', 'transport/FrameCodec.test.ts', 'encode: hello', 4],
  ['ブラウザが送る 7 種の encode（probe）', 'transport/FrameCodec.test.ts', 'encode: probe', 3],
  ['ブラウザが送る 7 種の encode（start）', 'transport/FrameCodec.test.ts', 'encode: start', 4],
  ['ブラウザが送る 7 種の encode（video）', 'transport/FrameCodec.test.ts', 'encode: video', 8],
  ['ブラウザが送る 7 種の encode（audio）', 'transport/FrameCodec.test.ts', 'encode: audio', 1],
  ['ブラウザが送る 7 種の encode（report・end）', 'transport/FrameCodec.test.ts', 'encode: report', 3],
  ['encode の呼び出しの誤り（方向違い・未知の種別）', 'transport/FrameCodec.test.ts', 'encode: 呼び出しの誤り', 3],
  ['ブラウザが受ける 7 種の decode（JSON 本文の型付き）', 'transport/FrameCodec.test.ts', 'decode: 中継 → ブラウザの 7 種', 10],
  ['decode の入力の形（ArrayBuffer・ビュー・Buffer。テキストは拒否）', 'transport/FrameCodec.test.ts', 'decode: 入力の形', 8],
  ['decode のヘッダの検証が FrameError の符号で返る', 'transport/FrameCodec.test.ts', 'decode: ヘッダの検証', 8],
  ['decode の本文（JSON）の不備は invalid_body', 'transport/FrameCodec.test.ts', 'decode: 本文（JSON）の不備は', 12],
  ['本文の JSON は UTF-8（バイト数で数える）', 'transport/FrameCodec.test.ts', 'decode: 日本語を含む本文は', 1],
  ['JSON 本文の型付き（start）の検証', 'transport/bodies.test.ts', 'parseStartBody', 33],
  ['JSON 本文の型付き（report と detail は符号と数値のみ）の検証', 'transport/bodies.test.ts', 'parseReportBody', 61],
  ['JSON 本文の型付き（accepted・probe_result・ack・throttle・status・fatal・end）の検証', 'transport/bodies.test.ts', 'parseAcceptedBody', 17],
  ['開始通知の本文の組み立て（base64 の往復を含む）', 'transport/startBody.test.ts', 'buildStartBody', 7],
  ['共有ベクタ：契約のディレクトリが無ければ失敗する（黙ってスキップしない）', 'transport/FrameCodec.vectors.test.ts', '契約のディレクトリの探し方', 4],
  ['共有ベクタ：契約を網羅している（14 種の種別・7 種のエラー・64 ビットの境界）', 'transport/FrameCodec.vectors.test.ts', '共有ベクタが、契約を網羅している', 5],
  ['共有ベクタ（有効）の復号：両方の受信側（42 件）', 'transport/FrameCodec.vectors.test.ts', 'valid：復号', 42],
  ['共有ベクタ（有効）の符号化：hex と一致（42 件）', 'transport/FrameCodec.vectors.test.ts', 'valid：符号化', 42],
  ['共有ベクタ：ブラウザが送る 7 種の型付きの encode', 'transport/FrameCodec.vectors.test.ts', 'valid：ブラウザが送る 7 種は', 28],
  ['共有ベクタ：ブラウザが受ける 7 種の型付きの decode', 'transport/FrameCodec.vectors.test.ts', 'valid：ブラウザが受ける 7 種は', 14],
  ['共有ベクタ（無効）の拒否（43 件）', 'transport/FrameCodec.vectors.test.ts', 'invalid：receivers', 43],
  ['受信の堅牢性（どんなバイト列でも、型付きのメッセージか FrameError）', 'transport/FrameCodec.robustness.test.ts', 'decode は、型付きのメッセージか FrameError', 7],
  ['結合：メディアクロック -> SendQueue -> FrameCodec -> 中継側の復号', 'transport/FrameCodec.pipeline.test.ts', '送信の経路', 2],
  ['結合：BitrateGovernor -> ReportBuilder -> FrameCodec -> 中継側の復号', 'transport/FrameCodec.pipeline.test.ts', '状態報告の経路', 1],
  ['フレームの構造の数値を直書きしない', 'transport/frameLayout.constants.test.ts', 'frameLayout.ts は、フレームの構造の数値を直書きしない', 3],

  // 送信待ち（core/queue/SendQueue）
  ['既定の安全弁の値を契約から導く', 'queue/SendQueue.test.ts', '契約との対応', 1],
  ['enqueue・dequeue は到着順（映像と音声が交互）', 'queue/SendQueue.test.ts', 'enqueue と dequeue：到着順', 4],
  ['不正なチャンクは RangeError・時刻の逆行を検知', 'queue/SendQueue.test.ts', 'enqueue：入力の検査', 17],
  ['dropVideoUntilNextKey：映像を 1 枚でも破棄したら次のキーフレームまで破棄・破棄中の状態', 'queue/SendQueue.test.ts', 'dropVideoUntilNextKey', 14],
  ['discardAllVideo：全破棄（キーフレームの発行は呼び出し側）', 'queue/SendQueue.test.ts', 'discardAllVideo', 7],
  ['音声は、どんな破棄の操作でも破棄しない', 'queue/SendQueue.test.ts', '音声は、どんな破棄の操作でも', 3],
  ['再接続中は符号化結果を捨てる（送信待ちに積まない）', 'queue/SendQueue.test.ts', '再接続中は、符号化結果を捨てる', 4],
  ['滞留時間 backlogMs と、受領応答が来る前の初期値の扱い', 'queue/SendQueue.test.ts', '滞留時間 backlogMs', 26],
  ['メモリの上限（件数・バイト）と、超過時は映像から破棄', 'queue/SendQueue.test.ts', 'メモリの上限（安全弁）', 13],
  ['破棄フレーム数・破棄の履歴', 'queue/SendQueue.test.ts', '破棄の履歴', 5],
  ['性質の検査（音声を失わない・破棄のあとはキーフレームから・上限・順序）', 'queue/SendQueue.test.ts', '性質の検査', 1],

  // 適応制御（core/governor/BitrateGovernor）
  ['契約（12 章の数値）との対応', 'governor/BitrateGovernor.test.ts', '契約との対応', 2],
  ['条件 1：滞留 1.5 秒超が 2 回連続で 30% 引き下げ（下限まで）', 'governor/BitrateGovernor.test.ts', '条件 1（backlog_high_twice）', 13],
  ['条件 2：滞留 0.3 秒未満かつ直近 10 秒に破棄なしで 10% 引き上げ（上限まで）', 'governor/BitrateGovernor.test.ts', '条件 2（backlog_low_no_drop）', 16],
  ['条件 3：滞留 4 秒超で全破棄と即時のキーフレーム', 'governor/BitrateGovernor.test.ts', '条件 3（backlog_critical）', 8],
  ['条件 4：映像の受領済み時刻が 10 秒進まなければ再接続', 'governor/BitrateGovernor.test.ts', '条件 4（video_ack_stalled）', 8],
  ['条件 5：滞留 8 秒超が 10 秒継続で再接続', 'governor/BitrateGovernor.test.ts', '条件 5（backlog_severe_sustained）', 5],
  ['条件 6：下限で逼迫が 20 秒継続で劣化', 'governor/BitrateGovernor.test.ts', '条件 6（degraded_enter）', 7],
  ['条件 7：劣化中に滞留 1.5 秒以下が 10 秒継続で解除', 'governor/BitrateGovernor.test.ts', '条件 7（degraded_exit）', 6],
  ['7 条件が契約の列挙 adaptive_condition と 1 対 1', 'governor/BitrateGovernor.test.ts', '7 条件が、契約の列挙', 9],
  ['中継の抑制指示を優先（min(現在の目標, 指示)・解除のメッセージは無い）', 'governor/BitrateGovernor.test.ts', '中継の抑制指示は、ブラウザ側の判定より優先する', 14],
  ['目標の変更は 1 秒あたり 1 回まで', 'governor/BitrateGovernor.test.ts', '目標の変更は、1 秒あたり 1 回まで', 4],
  ['入力の時刻が逆行しても壊れない', 'governor/BitrateGovernor.test.ts', '入力の時刻が、同じ・逆行しても壊れない', 4],
  ['滞留時間を評価できないとき（その接続の最初の ack の前）', 'governor/BitrateGovernor.test.ts', '滞留時間を評価できないとき', 1],
  ['状態の初期化（reset）', 'governor/BitrateGovernor.test.ts', '状態の初期化（reset）', 2],
  ['入力の検査', 'governor/BitrateGovernor.test.ts', '入力の検査', 30],
  ['決定的・変更できない結果', 'governor/BitrateGovernor.test.ts', '結果は変更できない', 2],
  ['性質の検査（目標の範囲・1 秒 1 回・出来事と変化の一致）', 'governor/BitrateGovernor.test.ts', '性質の検査', 1],
  ['シミュレーション A：健全な回線', 'governor/BitrateGovernor.simulation.test.ts', 'シナリオ A', 3],
  ['シミュレーション B：悪化と回復', 'governor/BitrateGovernor.simulation.test.ts', 'シナリオ B', 7],
  ['シミュレーション C：劣化と解除', 'governor/BitrateGovernor.simulation.test.ts', 'シナリオ C', 5],
  ['シミュレーション D：回線の不通で再接続', 'governor/BitrateGovernor.simulation.test.ts', 'シナリオ D', 2],
  ['シミュレーション E：受領応答が来ない接続', 'governor/BitrateGovernor.simulation.test.ts', 'シナリオ E', 2],
  ['シミュレーションは決定的', 'governor/BitrateGovernor.simulation.test.ts', '決定的', 1],
  ['12 章の数値を直書きしない', 'governor/BitrateGovernor.constants.test.ts', 'BitrateGovernor.ts は、12 章の数値を直書きしない', 4],

  // 回線計測（core/probe/UplinkProbe）
  ['送信ペースの計算（純粋）：3 秒・6,000 kbps・32 KB', 'probe/probePlan.test.ts', 'planProbeSends: 既定の契約の値', 5],
  ['送信ペースの数の表（境界・端数）', 'probe/probePlan.test.ts', 'planProbeSends: 数の表', 7],
  ['送信ペースの不正な入力', 'probe/probePlan.test.ts', 'planProbeSends: 不正な入力は', 12],
  ['計測データの中身（決定的な擬似乱数。圧縮されにくい）', 'probe/probePayload.test.ts', 'ProbePayloadGenerator', 13],
  ['measure：正常（結果を受け取って返す）', 'probe/UplinkProbe.test.ts', 'UplinkProbe.measure：正常', 11],
  ['measure：結果が来ない場合のタイムアウト', 'probe/UplinkProbe.test.ts', 'UplinkProbe.measure：結果が来ない', 4],
  ['measure：送信の失敗', 'probe/UplinkProbe.test.ts', 'UplinkProbe.measure：送信の失敗', 3],
  ['measure：不正な結果', 'probe/UplinkProbe.test.ts', 'UplinkProbe.measure：不正な結果', 7],
  ['計測データと設定', 'probe/UplinkProbe.test.ts', 'UplinkProbe：計測データと設定', 11],
  ['回線計測の数値を直書きしない', 'probe/UplinkProbe.constants.test.ts', '回線計測のソースは、契約の数値を直書きしない', 5],

  // 状態報告（core/report/ReportBuilder）
  ['契約の共有ベクタの report と同じ本文', 'report/ReportBuilder.test.ts', '契約の共有テストベクタ', 4],
  ['出来事 8 種の detail は符号と数値のみ', 'report/ReportBuilder.test.ts', '出来事 8 種の', 11],
  ['自由記述・不正な値は RangeError（デバイス名・ラベルを載せない）', 'report/ReportBuilder.test.ts', '出来事の検査', 22],
  ['出来事は欠落なく 1 回ずつ送る（prepare・commit）', 'report/ReportBuilder.test.ts', '出来事は、欠落なく 1 回ずつ送る', 8],
  ['滞留時間・破棄フレーム数・目標ビットレート・状態', 'report/ReportBuilder.test.ts', '滞留時間・破棄フレーム数・目標ビットレート・状態', 16],
  ['適応制御の出来事を、そのまま積める', 'report/ReportBuilder.test.ts', '適応制御（BitrateGovernor）の出来事', 1],
  ['性質の検査（欠落なく・重複なく・順序どおり）', 'report/ReportBuilder.test.ts', '性質の検査', 1],
];

const results = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
const problems = [];
const lines = [];

/** Jest の結果のファイル名（コンテナの /app/core/... など）を、core からの相対パスにする。 */
function relativeToCore(name) {
  const normalized = name.split(path.sep).join('/');
  const index = normalized.lastIndexOf('/core/');
  return index >= 0 ? normalized.slice(index + '/core/'.length) : normalized;
}

const byFile = new Map();
for (const suite of results.testResults) {
  byFile.set(relativeToCore(suite.name), suite);
}

// 1. 全体：失敗・スキップ・todo が無い
if (results.numFailedTests !== 0 || results.numFailedTestSuites !== 0) problems.push(`失敗があります（テスト ${results.numFailedTests} 件・スイート ${results.numFailedTestSuites} 件）`);
if (results.numPendingTests !== 0) problems.push(`スキップ（pending）されたテストが ${results.numPendingTests} 件あります`);
if (results.numTodoTests !== 0) problems.push(`todo のテストが ${results.numTodoTests} 件あります`);
lines.push(`${problems.length === 0 ? 'ok  ' : 'FAIL'} 全体：スイート ${results.numTotalTestSuites} 件・テスト ${results.numTotalTests} 件（成功 ${results.numPassedTests}・失敗 ${results.numFailedTests}・スキップ ${results.numPendingTests}・todo ${results.numTodoTests}）`);

// 2. ディスクにある、5 ディレクトリのテストのファイルが、すべて結果にある
const coreRoot = path.join(repo, 'src', 'frontend', 'core');
const onDisk = [];
for (const directory of TARGET_DIRECTORIES) {
  const full = path.join(coreRoot, directory);
  if (!fs.existsSync(full)) {
    problems.push(`ディレクトリがありません: core/${directory}`);
    continue;
  }
  for (const name of fs.readdirSync(full)) {
    if (name.endsWith('.test.ts')) onDisk.push(`${directory}/${name}`);
  }
}
const absent = onDisk.filter((name) => !byFile.has(name));
if (absent.length > 0) problems.push(`テストのファイルが結果にありません（実行されていない）: ${absent.join(', ')}`);
lines.push(`${absent.length === 0 && onDisk.length > 0 ? 'ok  ' : 'FAIL'} ディスクにあるテストのファイル ${onDisk.length} 件が、すべて実行されている`);

// 3. 受け入れ条件ごとの、成功したテストの数
let missingCount = 0;
for (const [criterion, file, describePrefix, minimum, titleIncludes] of REQUIRED) {
  const suite = byFile.get(file);
  const matched = suite
    ? suite.assertionResults.filter((item) => (item.ancestorTitles[0] || '').startsWith(describePrefix) && (titleIncludes === undefined || item.title.includes(titleIncludes)))
    : [];
  const passed = matched.filter((item) => item.status === 'passed').length;
  const notPassed = matched.filter((item) => item.status !== 'passed').length;
  if (!suite) {
    problems.push(`受け入れ条件「${criterion}」: テストのファイルが結果にありません（${file}）`);
    missingCount += 1;
  } else if (notPassed > 0) {
    problems.push(`受け入れ条件「${criterion}」: 成功していないテストが ${notPassed} 件あります（${file} の「${describePrefix}」）`);
    missingCount += 1;
  } else if (passed < minimum) {
    problems.push(`受け入れ条件「${criterion}」: 成功したテストが ${passed} 件で、下限 ${minimum} 件に足りません（${file} の「${describePrefix}」。題の変更・削除の疑い）`);
    missingCount += 1;
  }
}
lines.push(`${missingCount === 0 ? 'ok  ' : 'FAIL'} 受け入れ条件 ${REQUIRED.length} 項目に対応するテストが、下限以上、成功している`);

lines.forEach((line) => console.log(line));
if (problems.length > 0) {
  console.log('問題:');
  problems.forEach((item) => console.log(`  - ${item}`));
  process.exit(1);
}
process.exit(0);
