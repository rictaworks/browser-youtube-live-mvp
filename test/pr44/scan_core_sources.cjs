'use strict';
// issue #25（ブラウザ Domain Core（2）: 転送フレームの符号化・送信待ち・適応制御・回線計測）のソースを走査する（読み取りのみ）。
// Jest の走査（core/domain-core-rules.test.ts と、各ディレクトリの定数の検査）とは別に、独立して実装した検査。
//   対象：src/frontend/core/transport・queue・governor・probe・report
//   テキスト（上の 5 ディレクトリの全ファイルと、このテストのディレクトリの全ファイル）
//     - 絵文字が無い（CI の hygiene と同じ範囲）
//     - 削除系の語の実行形が無い（CI の hygiene と同じ規則。語は、このファイルにも素のまま書かず、部品から組み立てる）
//   構文木（上の 5 ディレクトリの、テスト以外の .ts）
//     - Date・performance・setTimeout・setInterval・setImmediate・requestAnimationFrame（実時計・タイマ）と Math.random を参照しない
//     - window・document・navigator・WebSocket・localStorage・sessionStorage・fetch・console・process・crypto・React などを、大域として参照しない
//       （プロパティの名前は許す。TextEncoder・TextDecoder・DataView・BigInt は、環境に依存しない標準の道具なので許す）
//     - import は、core の中の相対パスだけ（next・react・node の組み込み・lib・app・components へ依存しない）
//     - 日本語（ひらがな・カタカナ・漢字）が、文字列・テンプレート・正規表現・識別子にない（コメントは許す）
//     - BigInt のリテラル（1n）を使わない（tsconfig の target が ES2017 のため、型検査に失敗する）
//     - モジュール直下の let・var（グローバルな可変の状態）が無い
//     - 適応制御の数値を、直書きしない：core/governor/BitrateGovernor.ts の数値リテラルは、単位の換算（0・1・100・1,000・1,000,000）だけ
//       （12 章の閾値・継続時間・割合は、契約（core/contract の LIMITS）から取る）
//     - フレームの構造の数値を、直書きしない：core/transport/frameLayout.ts の数値リテラルは、小さい道具の定数（0・1・16・32・64）だけ
//       （ヘッダの大きさ・識別子・種別の符号・上限は、契約から取る）
//   範囲
//     - 5 ディレクトリの主なモジュールがある（走査の空振りでない）。各ディレクトリに index.ts がある
// 走査器は、最初に、自己検査（違反の見本を見つけ、違反でない見本を通す）を行う。
//
// 使い方: node scan_core_sources.cjs <リポジトリのルート>
// 終了コード: 0 = 問題なし / 1 = 違反または自己検査の失敗 / 3 = 確認できなかった（TypeScript が無い）

const fs = require('fs');
const path = require('path');

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_UNAVAILABLE = 3;

const repo = path.resolve(process.argv[2] || '');
if (!process.argv[2] || !fs.existsSync(path.join(repo, 'src', 'frontend', 'core'))) {
  console.error('使い方: node scan_core_sources.cjs <リポジトリのルート>');
  process.exit(EXIT_FINDINGS);
}

let ts;
try {
  ts = require(path.join(repo, 'src', 'frontend', 'node_modules', 'typescript'));
} catch (error) {
  console.log('SKIP 確認できなかった: TypeScript（src/frontend/node_modules/typescript）が見つかりません。frontend の依存を導入してください');
  process.exit(EXIT_UNAVAILABLE);
}

const TARGET_DIRECTORIES = ['transport', 'queue', 'governor', 'probe', 'report'];

// ---------------------------------------------------------------------------
// 検知器
// ---------------------------------------------------------------------------

// 絵文字の範囲（コードポイントの 16 進数。A-B は範囲）。CI の hygiene（.github/workflows/ci.yml の emoji）と同じ。このファイルに、絵文字そのものを書かない
const EMOJI_TABLE = `
  231A-231B 2328 23CF 23E9-23F3 23F8-23FA 25FD-25FE
  2600-2604 260E 2611 2614-2615 2618 261D 2620 2622-2623 2626 262A 262E-262F 2638-263A 2640 2642
  2648-2653 265F-2660 2663 2665-2666 2668 267B 267E-267F 2692-2697 2699 269B-269C 26A0-26A1 26A7
  26AA-26AB 26B0-26B1 26BD-26BE 26C4-26C5 26C8 26CE-26CF 26D1 26D3-26D4 26E9-26EA 26F0-26F5 26F7-26FA 26FD
  2702 2705 2708-270D 270F 2712 2714 2716 271D 2721 2728 2733-2734 2744 2747 274C 274E 2753-2755 2757
  2763-2764 2795-2797 27A1 27B0 27BF 2934-2935 2B05-2B07 2B1B-2B1C 2B50 2B55
  1F000-1FAFF
  FE0F 20E3 E0020-E007F
`;
const EMOJI_PATTERN = new RegExp(
  '[' +
    EMOJI_TABLE.split(/\s+/)
      .filter(Boolean)
      .map((token) => {
        const [low, high] = token.split('-');
        return `\\u{${low}}-\\u{${high || low}}`;
      })
      .join('') +
    ']',
  'u',
);

function joined(...parts) {
  return parts.join('');
}

// 削除系の語（CI の hygiene と同じ規則）。語は、部品から組み立てる
const DELETION_RULES = [
  ['ファイル・ディレクトリを消すコマンド', new RegExp(`(?<![A-Za-z0-9_.-])(?:${joined('r', 'm')}(?:dir|i)?|${joined('un', 'link')}|${joined('sh', 'red')})(?![A-Za-z0-9_./-])`)],
  ['削除のオプション', new RegExp(`(?<![A-Za-z0-9_-])--?${joined('del', 'ete')}(?:-[a-z]+)?(?![A-Za-z0-9_-])`)],
  ['git の削除系', new RegExp(`(?<![A-Za-z0-9_-])git\\s+(?:${joined('cle', 'an')}|worktree\\s+${joined('rem', 'ove')}|branch\\s+-[A-Za-z]*[dD][A-Za-z]*)(?![A-Za-z0-9_-])`)],
  ['docker の削除系', new RegExp(`(?<![A-Za-z0-9_-])docker[^#\\n]*\\s${joined('do', 'wn')}(?![A-Za-z0-9_-])`)],
  ['不要な資源の一括削除', new RegExp(`(?<![A-Za-z0-9_-])${joined('pru', 'ne')}(?![A-Za-z0-9_-])`)],
  ['ファイル削除の呼び出し', new RegExp(`(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\\.(?:${joined('r', 'm')}\\w*|[Rr]emove\\w*|${joined('del', 'ete')}\\w*|${joined('un', 'link')}\\w*)`)],
];

function findEmoji(text) {
  const found = [];
  text.split('\n').forEach((line, index) => {
    const match = EMOJI_PATTERN.exec(line);
    if (match) {
      found.push({ line: index + 1, rule: '絵文字', text: `U+${match[0].codePointAt(0).toString(16).toUpperCase()}` });
    }
  });
  return found;
}

function findDeletionWords(text) {
  const found = [];
  text.split('\n').forEach((line, index) => {
    for (const [label, pattern] of DELETION_RULES) {
      if (pattern.test(line)) {
        found.push({ line: index + 1, rule: `削除系: ${label}`, text: line.trim().slice(0, 60) });
      }
    }
  });
  return found;
}

const FORBIDDEN_GLOBALS = new Set([
  'Date', 'performance', 'setTimeout', 'setInterval', 'setImmediate', 'clearTimeout', 'clearInterval', 'queueMicrotask', 'requestAnimationFrame', 'requestIdleCallback', // 実時計・タイマ
  'window', 'document', 'navigator', 'self', 'globalThis', 'WebSocket', 'localStorage', 'sessionStorage', 'indexedDB', 'location', 'history', 'fetch', 'XMLHttpRequest', // DOM・入出力
  'console', 'process', 'crypto', 'React', 'Worker', 'Blob', 'URL', 'structuredClone', 'eval', // ほか
  'alert', 'confirm', 'prompt', // ネイティブのダイアログ
]);
const JAPANESE = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u;

// 数値リテラルの許す集合（ファイル名 -> 許す値）。値は、数値リテラルの text（数値区切りの _ を除く）を、数に直したもの
const NUMERIC_ALLOW_LIST = {
  'governor/BitrateGovernor.ts': new Set([0, 1, 100, 1000, 1000000]),
  'transport/frameLayout.ts': new Set([0, 1, 16, 32, 64]),
};

function isPropertyNamePosition(identifier) {
  const parent = identifier.parent;
  if (ts.isPropertyAccessExpression(parent) && parent.name === identifier) return true;
  if (ts.isQualifiedName(parent) && parent.right === identifier) return true;
  if (
    (ts.isPropertyAssignment(parent) || ts.isPropertySignature(parent) || ts.isMethodSignature(parent) || ts.isPropertyDeclaration(parent) ||
      ts.isMethodDeclaration(parent) || ts.isGetAccessorDeclaration(parent) || ts.isSetAccessorDeclaration(parent) || ts.isEnumMember(parent)) &&
    parent.name === identifier
  ) {
    return true;
  }
  return ts.isBindingElement(parent) && parent.propertyName === identifier;
}

function walk(node, visit) {
  visit(node);
  ts.forEachChild(node, (child) => walk(child, visit));
}

/** fileName は、src/frontend/core からの相対パス（/ 区切り）。 */
function findSyntaxViolations(fileName, source) {
  const sourceFile = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const found = [];
  const add = (node, rule, text) => {
    found.push({ line: sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1, rule, text: String(text).slice(0, 40) });
  };
  const allowedNumbers = NUMERIC_ALLOW_LIST[fileName];
  walk(sourceFile, (node) => {
    if (ts.isIdentifier(node)) {
      if (!isPropertyNamePosition(node) && FORBIDDEN_GLOBALS.has(node.text)) add(node, '実時計・タイマ・DOM・入出力の大域の参照', node.text);
      if (JAPANESE.test(node.text)) add(node, '日本語の識別子', node.text);
    }
    if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'Math' && node.name.text === 'random') add(node, '乱数', 'Math.random');
    if (ts.isBigIntLiteral(node)) add(node, 'BigInt のリテラル（target ES2017 では型検査に失敗する）', node.text);
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
      const specifier = node.moduleSpecifier.text;
      if (!specifier.startsWith('.')) {
        add(node, '相対パスでない import', specifier);
      } else {
        const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(fileName), specifier));
        if (resolved.startsWith('..')) add(node, 'core の外への import', specifier);
      }
    }
    if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword || (ts.isIdentifier(node.expression) && node.expression.text === 'require'))) {
      add(node, '動的 import・require', node.getText(sourceFile));
    }
    if (ts.isVariableDeclarationList(node)) {
      const isConst = (node.flags & ts.NodeFlags.Const) !== 0;
      const isLet = (node.flags & ts.NodeFlags.Let) !== 0;
      const isModuleLevel = ts.isVariableStatement(node.parent) && node.parent.parent === sourceFile;
      if (!isConst && !isLet) add(node, 'var', 'var');
      else if (isLet && isModuleLevel) add(node, 'モジュール直下の let（グローバルな可変の状態）', 'let');
    }
    const literal =
      ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node) || ts.isTemplateHead(node) || ts.isTemplateMiddle(node) || ts.isTemplateTail(node) || ts.isRegularExpressionLiteral(node)
        ? node.text
        : undefined;
    if (literal !== undefined && JAPANESE.test(literal)) add(node, '日本語の文字列リテラル', literal);
    if (allowedNumbers !== undefined && ts.isNumericLiteral(node)) {
      const value = Number(node.text.replace(/_/g, ''));
      if (!allowedNumbers.has(value)) add(node, '契約の値の直書き（数値リテラル）', node.text);
    }
  });
  return found;
}

// ---------------------------------------------------------------------------
// 自己検査（走査器が、違反を見つけ、違反でないものを通すこと）
// ---------------------------------------------------------------------------

function selfTest() {
  const problems = [];
  const expectRules = (label, found, rules) => {
    const names = found.map((item) => item.rule);
    for (const rule of rules) {
      if (!names.some((name) => name.includes(rule))) problems.push(`${label}: 「${rule}」を見つけられません`);
    }
    if (rules.length === 0 && names.length > 0) problems.push(`${label}: 違反でないものを、違反と判定しました（${names.join(', ')}）`);
  };

  expectRules('Date.now', findSyntaxViolations('queue/x.ts', 'export const f = () => Date.now();'), ['実時計']);
  expectRules('new Date', findSyntaxViolations('queue/x.ts', 'export const f = () => new Date();'), ['実時計']);
  expectRules('performance.now', findSyntaxViolations('probe/x.ts', 'export const f = () => performance.now();'), ['実時計']);
  expectRules('setTimeout', findSyntaxViolations('probe/x.ts', 'export const f = () => setTimeout(() => 1, 1);'), ['実時計']);
  expectRules('Math.random', findSyntaxViolations('probe/x.ts', 'export const f = () => Math.random();'), ['乱数']);
  expectRules('WebSocket', findSyntaxViolations('transport/x.ts', "export const f = () => new WebSocket('wss://example.invalid');"), ['大域の参照']);
  expectRules('console', findSyntaxViolations('report/x.ts', "export function f(): void { console.log('x'); }"), ['大域の参照']);
  expectRules('react', findSyntaxViolations('report/x.ts', "import React from 'react';\nexport const f = React;"), ['相対パスでない import']);
  expectRules('core の外への import', findSyntaxViolations('report/x.ts', "import { x } from '../../lib/x';\nexport const f = x;"), ['core の外への import']);
  expectRules('動的 import', findSyntaxViolations('report/x.ts', "export const f = () => import('./x');"), ['動的 import']);
  expectRules('日本語リテラル', findSyntaxViolations('report/x.ts', `export const f = '${String.fromCodePoint(0x65e5, 0x672c)}';`), ['日本語の文字列リテラル']);
  expectRules('日本語の識別子', findSyntaxViolations('report/x.ts', `export const ${String.fromCodePoint(0x65e5)} = 1;`), ['日本語の識別子']);
  expectRules('BigInt のリテラル', findSyntaxViolations('transport/x.ts', 'export const one = 1n;'), ['BigInt のリテラル']);
  expectRules('モジュール直下の let', findSyntaxViolations('queue/x.ts', 'let counter = 0;\nexport const next = () => counter + 1;'), ['モジュール直下の let']);
  expectRules('var', findSyntaxViolations('queue/x.ts', 'export function f(): number { var x = 1; return x; }'), ['var']);
  expectRules('閾値の直書き（governor）', findSyntaxViolations('governor/BitrateGovernor.ts', 'export const overloaded = (b: number) => b > 1500;'), ['契約の値の直書き']);
  expectRules('ヘッダの大きさの直書き（frameLayout）', findSyntaxViolations('transport/frameLayout.ts', 'export const header = 17;'), ['契約の値の直書き']);
  expectRules('違反でない（単位の換算の数値）', findSyntaxViolations('governor/BitrateGovernor.ts', 'export const toMicro = (s: number) => s * 1_000_000 + 100 / 1000 + 0 + 1;'), []);
  expectRules('違反でない（プロパティ名・コメント・文字列の語）', findSyntaxViolations('queue/x.ts', "// Date.now() window\nexport const f = (env: { navigator?: unknown }) => [env.navigator, 'Date.now'];"), []);
  expectRules('違反でない（BigInt の呼び出し・TextEncoder）', findSyntaxViolations('transport/x.ts', 'export const f = (n: number) => [BigInt(n), new TextEncoder().encode("a")];'), []);
  expectRules('違反でない（日本語はコメントだけ）', findSyntaxViolations('queue/x.ts', `// ${String.fromCodePoint(0x65e5, 0x672c)}\nexport const f = 1;`), []);
  expectRules('違反でない（core の中の相対 import）', findSyntaxViolations('governor/x.ts', "import { LIMITS } from '../contract';\nimport type { T } from '../report/types';\nexport const f = LIMITS;"), []);
  expectRules('違反でない（関数の中の let）', findSyntaxViolations('queue/x.ts', 'export function f(): number { let total = 0; for (let i = 0; i < 3; i += 1) { total += i; } return total; }'), []);

  expectRules('絵文字', findEmoji(`a ${String.fromCodePoint(0x1f600)} b`), ['絵文字']);
  expectRules('絵文字（記号）', findEmoji(`a ${String.fromCodePoint(0x2714)} b`), ['絵文字']);
  expectRules('絵文字でない（矢印・乗算・全角の記号）', findEmoji(`a ${String.fromCodePoint(0x2192)} ${String.fromCodePoint(0xd7)} ${String.fromCodePoint(0x203b)} ${String.fromCodePoint(0x3042)}`), []);

  expectRules('削除系（コマンドの実行形）', findDeletionWords(`${joined('r', 'm')} -f x`), ['削除系']);
  expectRules('削除系（呼び出し）', findDeletionWords(`fs.${joined('r', 'mSync')}(x)`), ['削除系']);
  expectRules('削除系（git）', findDeletionWords(`git ${joined('cle', 'an')} -fd`), ['削除系']);
  expectRules('削除系ではない（別の語の一部・通常の文）', findDeletionWords('const form = perform(); // transform the format'), []);
  return problems;
}

// ---------------------------------------------------------------------------
// 走査
// ---------------------------------------------------------------------------

function listFiles(directory) {
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...listFiles(full));
    } else if (entry.isFile()) {
      files.push(full);
    }
  }
  return files.sort();
}

function isBinary(buffer) {
  return buffer.subarray(0, 8000).includes(0);
}

function main() {
  const selfProblems = selfTest();
  if (selfProblems.length > 0) {
    console.log('FAIL 走査器の自己検査に失敗しました:');
    selfProblems.forEach((problem) => console.log(`  - ${problem}`));
    return EXIT_FINDINGS;
  }
  console.log('ok   走査器の自己検査（違反の見本を見つけ、違反でない見本を通す）');

  const coreRoot = path.join(repo, 'src', 'frontend', 'core');
  const testRoot = __dirname;
  const missingDirectories = TARGET_DIRECTORIES.filter((name) => !fs.existsSync(path.join(coreRoot, name)));
  if (missingDirectories.length > 0) {
    console.log(`FAIL 対象のディレクトリがありません: ${missingDirectories.join(', ')}`);
    return EXIT_FINDINGS;
  }
  const targetFiles = TARGET_DIRECTORIES.flatMap((name) => listFiles(path.join(coreRoot, name)));
  const textFiles = [...targetFiles, ...listFiles(testRoot)];
  const sourceFiles = targetFiles.filter((file) => file.endsWith('.ts') && !file.endsWith('.test.ts'));
  const reported = [];

  for (const file of textFiles) {
    const buffer = fs.readFileSync(file);
    if (isBinary(buffer)) continue;
    const text = buffer.toString('utf8');
    for (const finding of [...findEmoji(text), ...findDeletionWords(text)]) {
      reported.push(`${path.relative(repo, file)}:${finding.line} [${finding.rule}] ${finding.text}`);
    }
  }
  console.log(`${reported.length === 0 ? 'ok  ' : 'FAIL'} 絵文字・削除系の語：${textFiles.length} ファイルを走査（5 ディレクトリと、このテストのディレクトリ）`);

  const syntaxReported = [];
  for (const file of sourceFiles) {
    const relative = path.relative(coreRoot, file).split(path.sep).join('/');
    for (const finding of findSyntaxViolations(relative, fs.readFileSync(file, 'utf8'))) {
      syntaxReported.push(`${path.relative(repo, file)}:${finding.line} [${finding.rule}] ${finding.text}`);
    }
  }
  console.log(`${syntaxReported.length === 0 ? 'ok  ' : 'FAIL'} 構文木の走査：${sourceFiles.length} ファイル（テスト以外の .ts。実時計・タイマ・乱数・DOM・入出力・相対でない import・日本語のリテラル・BigInt のリテラル・モジュール直下の let・契約の値の直書き）`);

  const required = ['transport/FrameCodec.ts', 'transport/frameLayout.ts', 'transport/bodies.ts', 'transport/base64.ts', 'queue/SendQueue.ts', 'governor/BitrateGovernor.ts', 'probe/UplinkProbe.ts', 'probe/probePlan.ts', 'report/ReportBuilder.ts'];
  const missing = required.filter((name) => !fs.existsSync(path.join(coreRoot, name)));
  const missingIndexes = TARGET_DIRECTORIES.filter((name) => !fs.existsSync(path.join(coreRoot, name, 'index.ts')));
  console.log(`${missing.length === 0 && missingIndexes.length === 0 ? 'ok  ' : 'FAIL'} 走査の対象に、issue #25 の主なモジュールと、各ディレクトリの index.ts がある（走査の空振りでない）${missing.length ? `：無いもの ${missing.join(', ')}` : ''}${missingIndexes.length ? `：index.ts が無いディレクトリ ${missingIndexes.join(', ')}` : ''}`);

  const all = [...reported, ...syntaxReported];
  if (all.length > 0) {
    console.log('違反:');
    all.forEach((item) => console.log(`  - ${item}`));
  }
  return all.length === 0 && missing.length === 0 && missingIndexes.length === 0 ? EXIT_OK : EXIT_FINDINGS;
}

process.exit(main());
