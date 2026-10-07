'use strict';
// 独立の走査（issue #26）。Jest の走査（lib/audio/media-rules.test.ts。TypeScript の構文木）とは別に、字句の走査で、次を確かめる。
//   1. lib/audio・public/worklets: 音声の時刻の採番に、実時計・タイマを使わない（Date・performance・setInterval・requestAnimationFrame・Math.random・
//      setTimeout の呼び出し。setTimeout は、注入された環境のプロパティ（env.setTimeout）としてだけ使う）
//   2. lib/audio・lib/sources: 配信者自身への音声の折り返し再生をしない（出力先 destination への接続・<audio>・play・srcObject を使わない）。
//      lib/sources は、音声のグラフ（AudioContext・createMediaStreamSource）を作らない
//   3. public/worklets: 自己完結（import・export・fetch・動的評価が無い）。数値処理の定数が、MixerCore.ts と同じ
//   4. 絵文字・ネイティブのダイアログ（alert・confirm・prompt の呼び出し）が、#26 のファイル（lib/audio・lib/sources・public/worklets・このディレクトリ）に無い。
//      削除系の語の直書きが、このディレクトリのファイルに無い（語は分割して組み立てる規則）
// コメントと文字列の中身は、走査の対象外（コメントに、禁止の語を説明として書けるように）。走査器の自己検査（違反の例を検知すること）つき。
//
// 使い方: node scan_media_sources.cjs <リポジトリのルート>
// 終了コード: 0 = 違反なし / 1 = 違反あり

const fs = require('fs');
const path = require('path');

const repo = process.argv[2];
if (!repo) {
  console.error('usage: node scan_media_sources.cjs <repository root>');
  process.exit(1);
}
const frontend = path.join(repo, 'src', 'frontend');
const here = __dirname;

// ---------------------------------------------------------------------------
// 字句の走査: コメントと、文字列・テンプレートの中身を、空白にする（行数は保つ）
// ---------------------------------------------------------------------------

function maskCommentsAndStrings(source) {
  let output = '';
  const stack = []; // テンプレートの ${ ... } の中のコードの、波括弧の深さ
  let index = 0;
  let mode = 'code';
  let quote = '';
  let depth = 0;
  const blank = (character) => (character === '\n' ? '\n' : ' ');
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
        output += ' ' + blank(next || ' ');
        index += 2;
      } else if (character === quote) {
        mode = 'code';
        output += character;
        index += 1;
      } else {
        output += blank(character);
        index += 1;
      }
    } else if (mode === 'template') {
      if (character === '\\') {
        output += ' ' + blank(next || ' ');
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
        output += blank(character);
        index += 1;
      }
    }
  }
  return output;
}

function findMatches(maskedSource, pattern) {
  const found = [];
  const lines = maskedSource.split('\n');
  lines.forEach((line, lineIndex) => {
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
  ['performance（実時計）', /\bperformance\b/],
  ['setInterval（タイマ）', /\bsetInterval\s*\(/],
  ['requestAnimationFrame（描画の周期）', /\brequestAnimationFrame\b/],
  ['Math.random（乱数）', /\bMath\.random\b/],
  ['setTimeout の呼び出し（注入された環境のプロパティ env.setTimeout としてだけ使う。型の宣言（引数に型がある）は対象外）', /(?<![.\w])setTimeout\s*\((?!\s*\w+\s*:)/],
];

const LOOPBACK = [
  ['出力先（destination）への接続・参照', /\.destination\b/],
  ['srcObject（要素への接続）', /\bsrcObject\b/],
  ['play（再生）', /\.play\s*\(/],
  ['new Audio（音声の要素）', /\bnew\s+Audio\b/],
  ['HTMLAudioElement・HTMLMediaElement', /\bHTML(?:Audio|Media)Element\b/],
  ['createMediaElementSource', /\bcreateMediaElementSource\b/],
  ['createElement（要素の生成）', /\bcreateElement\b/],
];

const NO_AUDIO_GRAPH = [
  ['AudioContext', /\b(?:Offline)?AudioContext\b/],
  ['AudioWorkletNode', /\bAudioWorkletNode\b/],
  ['createMediaStreamSource', /\bcreateMediaStreamSource\b/],
  ['createMediaStreamDestination', /\bcreateMediaStreamDestination\b/],
];

const SELF_CONTAINED = [
  ['import・export の宣言', /^\s*(?:import|export)\b/],
  ['動的 import', /\bimport\s*\(/],
  ['fetch・XMLHttpRequest', /\b(?:fetch|XMLHttpRequest)\b/],
  ['eval・new Function', /\beval\s*\(|\bnew\s+Function\b/],
];

const NATIVE_DIALOG = [['ネイティブのダイアログ', /(?<![.\w])(?:alert|confirm|prompt)\s*\(/]];

function runtimeFiles(directory) {
  return fs
    .readdirSync(directory)
    .filter((name) => /\.ts$/.test(name) && !/\.test\.ts$/.test(name) && name !== 'test-support.ts' && name !== 'worklet-harness.ts')
    .sort()
    .map((name) => path.join(directory, name));
}

function scanFiles(files, rules) {
  const violations = [];
  for (const file of files) {
    const masked = maskCommentsAndStrings(fs.readFileSync(file, 'utf8'));
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
    'setTimeout(() => 1, 1); env.setTimeout(f, 1);',
    'context.destination; el.srcObject = s; new Audio();',
  ].join('\n');
  const masked = maskCommentsAndStrings(sample);
  const clock = scanFiles([], WALL_CLOCK);
  if (clock.length !== 0) {
    problems.push('empty scan must be empty');
  }
  const findings = (rules) => rules.flatMap(([label, pattern]) => findMatches(masked, pattern).map((hit) => `${label}@${hit.line}`));
  const wall = findings(WALL_CLOCK);
  if (!wall.some((entry) => entry.startsWith('Date') && entry.endsWith('@1')) || !wall.some((entry) => entry.startsWith('performance') && entry.endsWith('@2'))) {
    problems.push(`wall clock not detected: ${wall.join(', ')}`);
  }
  if (wall.some((entry) => entry.endsWith('@1') && !entry.startsWith('Date'))) {
    problems.push(`comment was scanned: ${wall.join(', ')}`);
  }
  if (!wall.some((entry) => entry.startsWith('setTimeout') && entry.endsWith('@3'))) {
    problems.push(`setTimeout call not detected: ${wall.join(', ')}`);
  }
  if (wall.filter((entry) => entry.startsWith('setTimeout')).length !== 1) {
    problems.push(`env.setTimeout must be allowed: ${wall.join(', ')}`);
  }
  if (wall.filter((entry) => entry.startsWith('Date') && entry.endsWith('@2')).length !== 0) {
    problems.push(`string literal was scanned: ${wall.join(', ')}`);
  }
  const loop = findings(LOOPBACK);
  for (const expected of ['出力先', 'srcObject', 'new Audio']) {
    if (!loop.some((entry) => entry.startsWith(expected))) {
      problems.push(`loopback not detected: ${expected}`);
    }
  }
  return problems;
}

// ---------------------------------------------------------------------------
// 実行
// ---------------------------------------------------------------------------

const audioFiles = runtimeFiles(path.join(frontend, 'lib', 'audio'));
const sourceFiles = runtimeFiles(path.join(frontend, 'lib', 'sources'));
const workletFiles = fs
  .readdirSync(path.join(frontend, 'public', 'worklets'))
  .filter((name) => name.endsWith('.js'))
  .sort()
  .map((name) => path.join(frontend, 'public', 'worklets', name));

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
console.log(`${selfProblems.length === 0 ? 'ok  ' : 'FAIL'} 走査器の自己検査（違反の例の検知・コメントと文字列の除外・env.setTimeout の許容）`);
for (const problem of selfProblems) {
  console.log(`       ${problem}`);
  failures.push(`self test: ${problem}`);
}

section('lib/audio: 実時計・タイマ・乱数を使わない', scanFiles(audioFiles, WALL_CLOCK), 8, audioFiles);
section('lib/audio: 出力先へつながない・音声の要素・再生を使わない（折り返し再生をしない）', scanFiles(audioFiles, LOOPBACK), 8, audioFiles);
section('lib/sources: 出力先へつながない・音声の要素・再生を使わない', scanFiles(sourceFiles, LOOPBACK), 7, sourceFiles);
section('lib/sources: 音声のグラフ（AudioContext・createMediaStreamSource など）を作らない', scanFiles(sourceFiles, NO_AUDIO_GRAPH), 7, sourceFiles);
section('public/worklets: 実時計・タイマ・乱数を使わない', scanFiles(workletFiles, WALL_CLOCK), 1, workletFiles);
section('public/worklets: 自己完結（import・export・fetch・動的評価が無い）', scanFiles(workletFiles, SELF_CONTAINED), 1, workletFiles);

// Worklet と MixerCore の、数値処理の定数
function constantOf(file, pattern) {
  const match = pattern.exec(fs.readFileSync(file, 'utf8'));
  return match ? Number(match[1]) : null;
}
const workletEpsilon = constantOf(workletFiles[0], /const GAIN_SNAP_EPSILON = ([0-9.e-]+);/);
const coreEpsilon = constantOf(path.join(frontend, 'lib', 'audio', 'MixerCore.ts'), /export const GAIN_SNAP_EPSILON = ([0-9.e-]+);/);
const constantsOk = workletEpsilon !== null && workletEpsilon === coreEpsilon;
console.log(`${constantsOk ? 'ok  ' : 'FAIL'} Worklet と MixerCore の、数値処理の定数（GAIN_SNAP_EPSILON）が同じ（Worklet ${workletEpsilon}・MixerCore ${coreEpsilon}）`);
if (!constantsOk) {
  failures.push('GAIN_SNAP_EPSILON differs');
}

// 絵文字・ネイティブのダイアログ
const EMOJI = /\p{Extended_Pictographic}|\p{Regional_Indicator}|[0-9#*]\u{FE0F}?\u{20E3}|\u{FE0F}/gu;
const TYPOGRAPHIC = new Set([String.fromCodePoint(0xa9), String.fromCodePoint(0xae), String.fromCodePoint(0x2122)]);
function filesUnder(directory) {
  const found = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      found.push(...filesUnder(full));
    } else if (entry.isFile()) {
      found.push(full);
    }
  }
  return found.sort();
}
const ownedFiles = [
  ...filesUnder(path.join(frontend, 'lib', 'audio')),
  ...filesUnder(path.join(frontend, 'lib', 'sources')),
  ...filesUnder(path.join(frontend, 'public', 'worklets')),
  ...filesUnder(here),
].filter((file) => /\.(?:ts|tsx|js|cjs|mjs|md|json|sh|py)$/.test(file));
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
section('絵文字を使わない（#26 のファイルすべて）', emojiViolations, 20, ownedFiles);

const codeFiles = ownedFiles.filter((file) => /\.(?:ts|tsx|js|cjs|mjs)$/.test(file) && !file.startsWith(here));
section('ネイティブの alert・confirm・prompt を使わない', scanFiles(codeFiles, NATIVE_DIALOG), 20, codeFiles);

// 削除系の語の直書き（このディレクトリのファイル。語は、分割して組み立てる）
const part = (...pieces) => pieces.join('');
const DELETION_WORDS = [
  new RegExp(`(?<![A-Za-z0-9_.-])(?:${part('r', 'm')}(?:dir|i)?|${part('un', 'link')}|${part('sh', 'red')})(?![A-Za-z0-9_./-])`),
  new RegExp(`--?${part('de', 'lete')}\\b`),
  new RegExp(`git\\s+(?:${part('cl', 'ean')}|worktree\\s+${part('re', 'move')}|branch\\s+-[A-Za-z]*[dD])`),
  new RegExp(`docker[^#\\n]*\\s${part('do', 'wn')}\\b|--${part('r', 'm')}\\b`),
  new RegExp(`\\b${part('pr', 'une')}\\b`),
  new RegExp(`\\b(?:fs|os|shutil|File|FileUtils|Dir|Pathname)\\.(?:${part('r', 'm')}\\w*|${part('re', 'move')}\\w*|${part('de', 'lete')}\\w*|${part('un', 'link')}\\w*)`),
];
const testDirectoryFiles = filesUnder(here).filter((file) => /\.(?:sh|cjs|py|md|json)$/.test(file));
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
section('削除系の語を、このディレクトリのファイルに直書きしない', deletionViolations, 3, testDirectoryFiles);

console.log('');
if (failures.length > 0) {
  console.log(`FAIL 違反 ${failures.length} 件`);
  process.exit(1);
}
console.log('PASS 違反はありません');
process.exit(0);
