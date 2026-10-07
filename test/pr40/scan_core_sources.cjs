'use strict';
// issue #24（ブラウザ Domain Core）のソースを走査する（読み取りのみ）。Jest の走査（core/domain-core-rules.test.ts）とは別に、独立して実装した検査。
//   テキスト（src/frontend/core の全ファイルと、このテストのディレクトリの全ファイル）
//     - 絵文字が無い（CI の hygiene と同じ範囲）
//     - 削除系の語の実行形が無い（CI の hygiene と同じ規則。語は、このファイルにも素のまま書かず、部品から組み立てる）
//   構文木（src/frontend/core の、テスト以外の .ts）
//     - Date・performance・setTimeout・setInterval・requestAnimationFrame（実時計・タイマ）と Math.random を参照しない
//     - window・document・navigator・WebSocket・localStorage・sessionStorage・fetch・React を、大域として参照しない（プロパティの名前は許す）
//     - import は相対パスだけ（next・react・node の組み込みなどへ依存しない）
//     - 日本語（ひらがな・カタカナ・漢字）が、文字列・テンプレート・正規表現・識別子にない（コメントは許す）
//     - core/clock が BigInt を使わない
//   範囲
//     - core/contract（#3 の契約）が、変更されていない（git status）
// 走査器は、最初に、自己検査（違反の見本を見つけ、違反でない見本を通す）を行う。
//
// 使い方: node scan_core_sources.cjs <リポジトリのルート>
// 終了コード: 0 = 問題なし / 1 = 違反または自己検査の失敗 / 3 = 確認できなかった（TypeScript が無い）

const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');

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
  'Date', 'performance', 'setTimeout', 'setInterval', 'requestAnimationFrame', // 実時計・タイマ
  'window', 'document', 'navigator', 'WebSocket', 'localStorage', 'sessionStorage', 'fetch', 'React', // DOM・入出力・UI
]);
const JAPANESE = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u;

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

function findSyntaxViolations(fileName, source) {
  const sourceFile = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const found = [];
  const add = (node, rule, text) => {
    found.push({ line: sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1, rule, text: String(text).slice(0, 40) });
  };
  const isClock = /(^|\/)clock\//.test(fileName);
  walk(sourceFile, (node) => {
    if (ts.isIdentifier(node)) {
      if (!isPropertyNamePosition(node) && FORBIDDEN_GLOBALS.has(node.text)) add(node, '実時計・タイマ・DOM・入出力の大域の参照', node.text);
      if (isClock && node.text === 'BigInt') add(node, 'メディアクロックの BigInt', node.text);
      if (JAPANESE.test(node.text)) add(node, '日本語の識別子', node.text);
    }
    if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'Math' && node.name.text === 'random') add(node, '乱数', 'Math.random');
    if (isClock && ts.isBigIntLiteral(node)) add(node, 'メディアクロックの BigInt', node.text);
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier) && !node.moduleSpecifier.text.startsWith('.')) {
      add(node, '相対パスでない import', node.moduleSpecifier.text);
    }
    const literal =
      ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node) || ts.isTemplateHead(node) || ts.isTemplateMiddle(node) || ts.isTemplateTail(node) || ts.isRegularExpressionLiteral(node)
        ? node.text
        : undefined;
    if (literal !== undefined && JAPANESE.test(literal)) add(node, '日本語の文字列リテラル', literal);
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

  expectRules('Date.now', findSyntaxViolations('x.ts', 'export const f = () => Date.now();'), ['実時計']);
  expectRules('new Date', findSyntaxViolations('x.ts', 'export const f = () => new Date();'), ['実時計']);
  expectRules('performance.now', findSyntaxViolations('x.ts', 'export const f = () => performance.now();'), ['実時計']);
  expectRules('setTimeout', findSyntaxViolations('x.ts', 'export const f = () => setTimeout(() => 1, 1);'), ['実時計']);
  expectRules('Math.random', findSyntaxViolations('x.ts', 'export const f = () => Math.random();'), ['乱数']);
  expectRules('window', findSyntaxViolations('x.ts', 'export const f = () => window.x;'), ['大域の参照']);
  expectRules('navigator', findSyntaxViolations('x.ts', 'export const f = () => navigator.userAgent;'), ['大域の参照']);
  expectRules('react', findSyntaxViolations('x.ts', "import React from 'react';\nexport const f = React;"), ['相対パスでない import']);
  expectRules('日本語リテラル', findSyntaxViolations('x.ts', `export const f = '${String.fromCodePoint(0x65e5, 0x672c)}';`), ['日本語の文字列リテラル']);
  expectRules('clock の BigInt', findSyntaxViolations('clock/x.ts', 'export const f = (n: number) => BigInt(n);'), ['BigInt']);
  expectRules('違反でない（プロパティ名・コメント・文字列の語）', findSyntaxViolations('x.ts', "// Date.now() window\nexport const f = (env: { navigator?: unknown }) => [env.navigator, 'Date.now'];"), []);
  expectRules('違反でない（clock 以外の BigInt）', findSyntaxViolations('transport/x.ts', 'export const f = (n: number) => BigInt(n);'), []);
  expectRules('違反でない（日本語はコメントだけ）', findSyntaxViolations('x.ts', `// ${String.fromCodePoint(0x65e5, 0x672c)}\nexport const f = 1;`), []);

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
  const coreFiles = listFiles(coreRoot);
  const textFiles = [...coreFiles, ...listFiles(testRoot)];
  const sourceFiles = coreFiles.filter((file) => file.endsWith('.ts') && !file.endsWith('.test.ts'));
  const reported = [];

  for (const file of textFiles) {
    const buffer = fs.readFileSync(file);
    if (isBinary(buffer)) continue;
    const text = buffer.toString('utf8');
    for (const finding of [...findEmoji(text), ...findDeletionWords(text)]) {
      reported.push(`${path.relative(repo, file)}:${finding.line} [${finding.rule}] ${finding.text}`);
    }
  }
  console.log(`${reported.length === 0 ? 'ok  ' : 'FAIL'} 絵文字・削除系の語：${textFiles.length} ファイルを走査（core 全体と、このテストのディレクトリ）`);

  const syntaxReported = [];
  for (const file of sourceFiles) {
    const relative = path.relative(coreRoot, file).split(path.sep).join('/');
    for (const finding of findSyntaxViolations(relative, fs.readFileSync(file, 'utf8'))) {
      syntaxReported.push(`${path.relative(repo, file)}:${finding.line} [${finding.rule}] ${finding.text}`);
    }
  }
  console.log(`${syntaxReported.length === 0 ? 'ok  ' : 'FAIL'} 構文木の走査：${sourceFiles.length} ファイル（テスト以外の core/**/*.ts。実時計・タイマ・乱数・DOM・相対でない import・日本語のリテラル・clock の BigInt）`);

  const required = ['clock/MediaClock.ts', 'layout/resolveLayout.ts', 'layout/containRect.ts', 'layout/wipeRect.ts', 'capability/readBrowserCapabilities.ts', 'profile/selectProfile.ts', 'reconnect/ReconnectPolicy.ts', 'tablock/TabLockGuard.ts', 'start/validateStartInput.ts', 'state/transitionStudio.ts', 'state/transitionSource.ts'];
  const missing = required.filter((name) => !fs.existsSync(path.join(coreRoot, name)));
  console.log(`${missing.length === 0 ? 'ok  ' : 'FAIL'} 走査の対象に、issue #24 の主なモジュールがある（走査の空振りでない）${missing.length ? `：無いもの ${missing.join(', ')}` : ''}`);

  let contractUntouched = true;
  try {
    const status = childProcess.execFileSync('git', ['status', '--porcelain', '--', 'src/frontend/core/contract'], { cwd: repo, encoding: 'utf8' });
    contractUntouched = status.trim() === '';
    console.log(`${contractUntouched ? 'ok  ' : 'FAIL'} core/contract（#3 の契約）が変更されていない（git status）${contractUntouched ? '' : `\n${status}`}`);
  } catch (error) {
    console.log('SKIP 確認できなかった: git status を実行できません（core/contract が変更されていないことの確認）');
  }

  const all = [...reported, ...syntaxReported];
  if (all.length > 0) {
    console.log('違反:');
    all.forEach((item) => console.log(`  - ${item}`));
  }
  return all.length === 0 && missing.length === 0 && contractUntouched ? EXIT_OK : EXIT_FINDINGS;
}

process.exit(main());
