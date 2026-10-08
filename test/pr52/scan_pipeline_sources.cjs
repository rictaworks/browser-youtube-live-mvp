'use strict';
// 独立の走査（issue #27）。Jest の走査（lib/pipeline/pipeline-rules.test.ts。TypeScript の構文木）とは別に、字句の走査で、次を確かめる。
//   1. lib/pipeline・workers/pipeline（テストとテストの道具を除く）: 時刻の採番に、実時計・描画の周期・乱数を使わない（Date・performance・
//      requestAnimationFrame・Math.random）。大域のタイマ（setTimeout・setInterval の呼び出し）は、既定のタイマの定義（lib/pipeline/timers.ts）だけ
//      （ほかは、注入された環境のメソッド scheduler.setInterval などとしてだけ使う）
//   2. 文字を描かない（fillText・strokeText・measureText・font）。画面・DOM・ネットワークに触れない（document・window・fetch・WebSocket など）。
//      import.meta は、lib/pipeline/defaultWorker.ts だけ
//   3. 映像トラックを止めない（track.stop()・getTracks 系。止めるのは SourceManager。#26）
//   4. 日本語の文字列リテラルが無い（コメントは対象外）。絵文字・ネイティブのダイアログが、#27 のファイルに無い
//   5. メッセージの取り決めの一致: COMMAND_TYPES のすべてを PipelineHost が処理し、EVENT_TYPES のすべてを PipelineClient が処理する
//   6. 削除系の語の直書きが、このディレクトリのファイルに無い（語は分割して組み立てる規則）
// コメントと、（1〜3 では）文字列の中身は、走査の対象外（コメントに、禁止の語を説明として書けるように）。走査器の自己検査（違反の例を検知すること）つき。
//
// 使い方: node scan_pipeline_sources.cjs <リポジトリのルート>
// 終了コード: 0 = 違反なし / 1 = 違反あり

const fs = require('fs');
const path = require('path');

const repo = process.argv[2];
if (!repo) {
  console.error('usage: node scan_pipeline_sources.cjs <repository root>');
  process.exit(1);
}
const frontend = path.join(repo, 'src', 'frontend');
const here = __dirname;

// ---------------------------------------------------------------------------
// 字句の走査: コメント（と、必要なら文字列・テンプレートの中身）を、空白にする（行数は保つ）
// ---------------------------------------------------------------------------

function mask(source, { keepStrings }) {
  let output = '';
  const stack = []; // テンプレートの ${ ... } の中のコードの、波括弧の深さ
  let index = 0;
  let mode = 'code';
  let quote = '';
  let depth = 0;
  const blank = (character) => (character === '\n' ? '\n' : ' ');
  const text = (character) => (keepStrings ? character : blank(character));
  while (index < source.length) {
    const character = source[index];
    const next = source[index + 1];
    if (mode === 'code') {
      if (character === '/' && next === '/') {
        mode = 'line';
        output += '  ';
        index += 2;
      } else if (character === '/' && next === '*') {
        mode = 'block';
        output += '  ';
        index += 2;
      } else if (character === '"' || character === "'") {
        mode = 'string';
        quote = character;
        output += character;
        index += 1;
      } else if (character === '`') {
        mode = 'template';
        output += character;
        index += 1;
      } else if (character === '{') {
        depth += 1;
        output += character;
        index += 1;
      } else if (character === '}') {
        depth -= 1;
        if (stack.length > 0 && depth === stack[stack.length - 1]) {
          stack.pop();
          mode = 'template';
        }
        output += character;
        index += 1;
      } else {
        output += character;
        index += 1;
      }
    } else if (mode === 'line') {
      if (character === '\n') {
        mode = 'code';
        output += character;
      } else {
        output += ' ';
      }
      index += 1;
    } else if (mode === 'block') {
      if (character === '*' && next === '/') {
        mode = 'code';
        output += '  ';
        index += 2;
      } else {
        output += blank(character);
        index += 1;
      }
    } else if (mode === 'string') {
      if (character === '\\') {
        output += text(character) + text(next || ' ');
        index += 2;
      } else if (character === quote) {
        mode = 'code';
        output += character;
        index += 1;
      } else {
        output += text(character);
        index += 1;
      }
    } else if (mode === 'template') {
      if (character === '\\') {
        output += text(character) + text(next || ' ');
        index += 2;
      } else if (character === '`') {
        mode = 'code';
        output += character;
        index += 1;
      } else if (character === '$' && next === '{') {
        stack.push(depth);
        depth += 1;
        mode = 'code';
        output += '${';
        index += 2;
      } else {
        output += text(character);
        index += 1;
      }
    }
  }
  return output;
}

const maskAll = (source) => mask(source, { keepStrings: false });
const maskCommentsOnly = (source) => mask(source, { keepStrings: true });

function findMatches(maskedSource, pattern) {
  const found = [];
  maskedSource.split('\n').forEach((line, lineIndex) => {
    const match = pattern.exec(line);
    if (match) {
      found.push({ line: lineIndex + 1, text: match[0] });
    }
  });
  return found;
}

// ---------------------------------------------------------------------------
// 規則
// ---------------------------------------------------------------------------

const WALL_CLOCK = [
  ['Date（実時計）', /\bDate\b/],
  ['performance（実時計）', /(?<![.\w])performance\b/],
  ['requestAnimationFrame（描画の周期）', /\brequestAnimationFrame\b/],
  ['Math.random（乱数）', /\bMath\.random\b/],
];
// 大域のタイマの呼び出し。メソッドの呼び出し（env.setTimeout(...)）と、型の宣言（setTimeout(callback: ...)）は、対象外
const GLOBAL_TIMER = [['大域のタイマの呼び出し（setTimeout・setInterval・clearTimeout・clearInterval）', /(?<![.\w])(?:setTimeout|setInterval|clearTimeout|clearInterval)\s*\((?!\s*\w+\s*:)/]];
const NO_TEXT = [['文字を描く API（fillText・strokeText・measureText・font）', /\b(?:fillText|strokeText|measureText)\b|\.font\b/]];
const NO_DOM = [['画面・DOM・ネットワーク（document・window・fetch・XMLHttpRequest・WebSocket・localStorage・sessionStorage）', /(?<![.\w])(?:document|window|fetch|XMLHttpRequest|WebSocket|localStorage|sessionStorage)\b/]];
const IMPORT_META = [['import.meta', /\bimport\.meta\b/]];
const NO_TRACK_STOP = [['映像トラックの停止（track.stop・getTracks 系）', /\w*[tT]rack\w*(?:\?)?\.stop\s*\(|\.(?:getTracks|getVideoTracks|getAudioTracks)\s*\(/]];
const NATIVE_DIALOG = [['ネイティブのダイアログ', /(?<![.\w])(?:alert|confirm|prompt)\s*\(/]];
// 日本語（ひらがな・カタカナ・漢字・全角記号）。コードポイントから組み立てる
const range = (from, to) => `${String.fromCodePoint(from)}-${String.fromCodePoint(to)}`;
const JAPANESE = [['日本語の文字列リテラル', new RegExp(`[${range(0x3040, 0x30ff)}${range(0x3400, 0x9fff)}${range(0xff00, 0xffef)}${range(0x3000, 0x303f)}]`)]];

function runtimeFiles(directory) {
  return fs
    .readdirSync(directory)
    .filter((name) => /\.ts$/.test(name) && !/\.test\.ts$/.test(name) && !/-support\.ts$/.test(name))
    .sort()
    .map((name) => path.join(directory, name));
}

function scanFiles(files, rules, masker = maskAll) {
  const violations = [];
  for (const file of files) {
    const masked = masker(fs.readFileSync(file, 'utf8'));
    for (const [label, pattern] of rules) {
      for (const hit of findMatches(masked, pattern)) {
        violations.push(`${path.relative(repo, file)}:${hit.line} ${label}: ${hit.text.trim()}`);
      }
    }
  }
  return violations;
}

// ---------------------------------------------------------------------------
// 走査器の自己検査
// ---------------------------------------------------------------------------

function selfTest() {
  const problems = [];
  const sample = [
    'const a = Date.now(); // Date.now() in a comment',
    'const text = "Date.now()"; const t = `${performance.now()} Date`;',
    'setTimeout(() => 1, 1); this.scheduler.setInterval(f, 1);',
    'track.stop(); this.cameraTrack.stop(); stream.getTracks(); pump.stop();',
    'ctx.fillText("a", 0, 0); document.title; const u = import.meta.url;',
    'const label = "日本語"; // コメントの日本語',
  ].join('\n');
  const masked = maskAll(sample);
  const hits = (rules, source = masked) => rules.flatMap(([label, pattern]) => findMatches(source, pattern).map((hit) => `${label}@${hit.line}`));
  const wall = hits(WALL_CLOCK);
  if (!wall.some((entry) => entry.startsWith('Date') && entry.endsWith('@1')) || !wall.some((entry) => entry.startsWith('performance') && entry.endsWith('@2'))) {
    problems.push(`wall clock not detected: ${wall.join(', ')}`);
  }
  if (wall.some((entry) => entry.startsWith('Date') && entry.endsWith('@2'))) {
    problems.push(`string literal was scanned: ${wall.join(', ')}`);
  }
  const timers = hits(GLOBAL_TIMER);
  if (timers.length !== 1 || !timers[0].endsWith('@3')) {
    problems.push(`global timer call: expected exactly the setTimeout at line 3, got ${timers.join(', ')}`);
  }
  const stops = hits(NO_TRACK_STOP);
  if (stops.length !== 1 || !stops[0].endsWith('@4')) {
    problems.push(`track stop: expected 1 hit at line 4 (pump.stop is allowed), got ${stops.join(', ')}`);
  }
  if (!findMatches('track.stop(); this.cameraTrack.stop(); stream.getTracks();', NO_TRACK_STOP[0][1]).length) {
    problems.push('track stop not detected');
  }
  if (hits(NO_TEXT).length !== 1 || hits(NO_DOM).length !== 1 || hits(IMPORT_META).length !== 1) {
    problems.push('text / dom / import.meta not detected');
  }
  const japanese = hits(JAPANESE, maskCommentsOnly(sample));
  if (japanese.length !== 1 || !japanese[0].endsWith('@6')) {
    problems.push(`japanese literal: expected exactly the string at line 6 (comments are allowed), got ${japanese.join(', ')}`);
  }
  return problems;
}

// ---------------------------------------------------------------------------
// 実行
// ---------------------------------------------------------------------------

const libFiles = runtimeFiles(path.join(frontend, 'lib', 'pipeline'));
const workerFiles = runtimeFiles(path.join(frontend, 'workers', 'pipeline'));
const runtime = [...libFiles, ...workerFiles];
const timersFile = path.join(frontend, 'lib', 'pipeline', 'timers.ts');
const defaultWorkerFile = path.join(frontend, 'lib', 'pipeline', 'defaultWorker.ts');

const failures = [];
function section(title, violations, minimumFiles, files) {
  const ok = violations.length === 0 && files.length >= minimumFiles;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${title}（走査したファイル ${files.length} 件）`);
  if (files.length < minimumFiles) {
    failures.push(`${title}: 走査したファイルが少なすぎます（${files.length} < ${minimumFiles}）`);
  }
  for (const violation of violations) {
    console.log(`       ${violation}`);
    failures.push(`${title}: ${violation}`);
  }
}

const selfProblems = selfTest();
console.log(`${selfProblems.length === 0 ? 'ok  ' : 'FAIL'} 走査器の自己検査（違反の例の検知・コメントと文字列の除外・メソッドとしての scheduler.setInterval の許容）`);
for (const problem of selfProblems) {
  console.log(`       ${problem}`);
  failures.push(`self test: ${problem}`);
}

section('実時計・描画の周期・乱数を使わない', scanFiles(runtime, WALL_CLOCK), 25, runtime);
section('大域のタイマは、既定のタイマの定義（timers.ts）だけ', scanFiles(runtime.filter((file) => file !== timersFile), GLOBAL_TIMER), 25, runtime);
section('文字を描かない（代替スレート・プレビュー）', scanFiles(runtime, NO_TEXT), 25, runtime);
section('画面・DOM・ネットワークに触れない', scanFiles(runtime, NO_DOM), 25, runtime);
section('import.meta は、既定のワーカーの作り方（defaultWorker.ts）だけ', scanFiles(runtime.filter((file) => file !== defaultWorkerFile), IMPORT_META), 25, runtime);
section('映像トラックを止めない（止めるのは SourceManager）', scanFiles(runtime, NO_TRACK_STOP), 25, runtime);
section('日本語の文字列リテラルを持たない（コメントは対象外）', scanFiles(runtime, JAPANESE, maskCommentsOnly), 25, runtime);

// メッセージの取り決めの一致
function listOf(file, name) {
  const source = fs.readFileSync(file, 'utf8');
  const match = new RegExp(`export const ${name} = \\[([^\\]]*)\\]`).exec(source);
  return match ? Array.from(match[1].matchAll(/"([a-z_]+)"/g)).map((entry) => entry[1]) : [];
}
function casesOf(file) {
  return new Set(Array.from(fs.readFileSync(file, 'utf8').matchAll(/case "([a-z_]+)":/g)).map((entry) => entry[1]));
}
const messagesFile = path.join(frontend, 'workers', 'pipeline', 'messages.ts');
const commandTypes = listOf(messagesFile, 'COMMAND_TYPES');
const eventTypes = listOf(messagesFile, 'EVENT_TYPES');
const hostCases = casesOf(path.join(frontend, 'workers', 'pipeline', 'PipelineHost.ts'));
const clientCases = casesOf(path.join(frontend, 'lib', 'pipeline', 'PipelineClient.ts'));
const missingCommands = commandTypes.filter((type) => !hostCases.has(type));
const missingEvents = eventTypes.filter((type) => !clientCases.has(type));
const contractOk = commandTypes.length >= 16 && eventTypes.length >= 7 && missingCommands.length === 0 && missingEvents.length === 0;
console.log(`${contractOk ? 'ok  ' : 'FAIL'} メッセージの取り決め: コマンド ${commandTypes.length} 種のすべてを PipelineHost が処理し、イベント ${eventTypes.length} 種のすべてを PipelineClient が処理する`);
if (!contractOk) {
  failures.push(`message contract: missing commands ${JSON.stringify(missingCommands)}, missing events ${JSON.stringify(missingEvents)}`);
}

// 絵文字・ネイティブのダイアログ
const EMOJI = /\p{Extended_Pictographic}|\p{Regional_Indicator}|[0-9#*]\u{FE0F}?\u{20E3}|\u{FE0F}/gu;
const TYPOGRAPHIC = new Set([String.fromCodePoint(0xa9), String.fromCodePoint(0xae), String.fromCodePoint(0x2122)]);
function filesUnder(directory) {
  const found = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.next') {
      continue;
    }
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      found.push(...filesUnder(full));
    } else if (entry.isFile()) {
      found.push(full);
    }
  }
  return found.sort();
}
const ownedFiles = [...filesUnder(path.join(frontend, 'lib', 'pipeline')), ...filesUnder(path.join(frontend, 'workers', 'pipeline')), ...filesUnder(here)].filter((file) =>
  /\.(?:ts|tsx|js|cjs|mjs|md|json|sh|py)$/.test(file),
);
const emojiViolations = [];
for (const file of ownedFiles) {
  const text = fs.readFileSync(file, 'utf8');
  for (const match of text.matchAll(EMOJI)) {
    if (!TYPOGRAPHIC.has(match[0])) {
      const line = text.slice(0, match.index).split('\n').length;
      emojiViolations.push(`${path.relative(repo, file)}:${line} U+${match[0].codePointAt(0).toString(16)}`);
    }
  }
}
section('絵文字を使わない（#27 のファイルすべて）', emojiViolations, 40, ownedFiles);

const codeFiles = ownedFiles.filter((file) => /\.(?:ts|tsx|js|cjs|mjs)$/.test(file));
section('ネイティブの alert・confirm・prompt を使わない', scanFiles(codeFiles, NATIVE_DIALOG), 40, codeFiles);

// 削除系の語の直書き（このディレクトリのファイル。語は、分割して組み立てる）
const part = (...pieces) => pieces.join('');
const DELETION_WORDS = [
  new RegExp(`(?<![A-Za-z0-9_.-])(?:${part('r', 'm')}(?:dir|i)?|${part('un', 'link')}|${part('sh', 'red')})(?![A-Za-z0-9_./-])`),
  new RegExp(`(?<![A-Za-z0-9_-])--?${part('de', 'lete')}(?:-[a-z]+)?(?![A-Za-z0-9_-])`),
  new RegExp(`git\\s+(?:${part('cl', 'ean')}|worktree\\s+${part('re', 'move')}|branch\\s+-[A-Za-z]*[dD])`),
  new RegExp(`docker[^#\\n]*\\s${part('do', 'wn')}\\b|--${part('r', 'm')}\\b`),
  new RegExp(`\\b${part('pr', 'une')}\\b`),
  new RegExp(`(?<![A-Za-z0-9_])(?:fs|os|shutil|File|FileUtils|Dir|Pathname)\\.(?:${part('r', 'm')}\\w*|[Rr]${part('em', 'ove')}\\w*|${part('de', 'lete')}\\w*|${part('un', 'link')}\\w*)`),
];
const testDirectoryFiles = filesUnder(here).filter((file) => /\.(?:sh|cjs|js|tsx|ts|py|md|json)$/.test(file));
const deletionViolations = [];
for (const file of testDirectoryFiles) {
  fs.readFileSync(file, 'utf8')
    .split('\n')
    .forEach((line, index) => {
      if (/^\s*#/.test(line)) {
        return;
      }
      for (const pattern of DELETION_WORDS) {
        if (pattern.test(line)) {
          deletionViolations.push(`${path.relative(repo, file)}:${index + 1} ${line.trim().slice(0, 100)}`);
        }
      }
    });
}
section('削除系の語を、このディレクトリのファイルに直書きしない', deletionViolations, 8, testDirectoryFiles);

console.log('');
if (failures.length > 0) {
  console.log(`FAIL 違反 ${failures.length} 件`);
  process.exit(1);
}
console.log('PASS 違反はありません');
process.exit(0);
