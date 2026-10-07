'use strict';
// このテストの対象（同一オリジン中継・API クライアント・bot 判定・ランディング・アカウント画面）のソースを走査する（読み取りのみ）。
// Jest の走査（src/frontend/lib/source-policy）とは別に、TypeScript の構文木で独立に実装した検査。
//
//   テキスト（対象のソースと、このテストのディレクトリの全ファイル）
//     - 絵文字が無い（CI の hygiene と同じ範囲）
//     - 削除系の語の実行形が無い（CI の hygiene と同じ規則。語は、このファイルにも素のまま書かず、部品から組み立てる）
//     - 不可視の制御文字（ゼロ幅・双方向の制御・制御文字）が無い
//     - 秘密らしい文字列（秘密鍵・各種のトークンの形）が無い
//   構文木（対象のソースのうち、テストではない .ts・.tsx）
//     - ネイティブのダイアログ（alert・confirm・prompt。window・globalThis・self 経由を含む）を呼ばない
//     - 日本語（ひらがな・カタカナ・漢字・全角の記号）が、文字列・テンプレート・正規表現・JSX の文字・識別子に無い（コメントは許す。messages/ は文言の置き場）
//     - fetch を使うのは、API クライアントと、同一オリジン中継の窓口だけ（画面の部品が、直接、通信しない）
//     - process.env を読むのは、設定を読む 3 つのモジュールだけ
//     - 外部の URL の直書きは、bot 判定の設定ファイルだけ（予約された .invalid のホストを除く）
//     - localStorage・sessionStorage・indexedDB・document.cookie を使わない（CSRF トークンは、メモリにだけ持つ）
//     - HTML を直接差し込む形（dangerouslySetInnerHTML・innerHTML・insertAdjacentHTML・document.write）・eval・new Function を使わない
//     - console.log・debug・info・trace・dir を残さない（失敗の記録は console.error）
//   範囲
//     - core/contract（#3 の契約）が、変更されていない（git status）
// 走査器は、最初に、自己検査（違反の見本を見つけ、違反でない見本を通す）を行う。
//
// 使い方: node scan_sources.cjs --repo <リポジトリのルート>
// 終了コード: 0 = 問題なし / 1 = 違反または自己検査の失敗 / 2 = 引数の不備 / 3 = 確認できなかった（TypeScript が無い）

const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { loadTypeScript } = require('./messages_loader.cjs');

const EXIT_OK = 0;
const EXIT_FINDINGS = 1;
const EXIT_USAGE = 2;
const EXIT_UNAVAILABLE = 3;

const repoIndex = process.argv.indexOf('--repo');
const repo = repoIndex >= 0 && process.argv[repoIndex + 1] ? path.resolve(process.argv[repoIndex + 1]) : '';
if (repo === '' || !fs.existsSync(path.join(repo, 'src', 'frontend', 'app'))) {
  console.log('FAIL 使い方: node scan_sources.cjs --repo <リポジトリのルート>');
  process.exit(EXIT_USAGE);
}
const ts = loadTypeScript(repo);
if (ts === null) {
  console.log('SKIP TypeScript（src/frontend/node_modules/typescript）が見つかりません。frontend の依存を導入してください（確認できなかった）');
  process.exit(EXIT_UNAVAILABLE);
}

// ---------------------------------------------------------------------------------------------
// 対象
// ---------------------------------------------------------------------------------------------

const FRONTEND = path.join(repo, 'src', 'frontend');
// この issue の対象（ディレクトリは、配下のすべて。ファイルは、そのファイルだけ）
const SCOPE = [
  'app/api',
  'app/account',
  'app/page.tsx',
  'app/page.test.tsx',
  'app/layout.tsx',
  'app/layout.providers.test.tsx',
  'app/web-analytics.tsx',
  'app/web-analytics.test.tsx',
  'lib/api',
  'lib/recaptcha',
  'components/landing',
  'components/account',
  'messages/landing.ts',
  'messages/account.ts',
  'messages/api-notices.ts',
];
const TEST_DIRECTORY = path.resolve(__dirname, '..');
const TEXT_EXTENSIONS = new Set(['.ts', '.tsx', '.css', '.cjs', '.js', '.json', '.md', '.sh', '.txt', '']);
const SKIPPED_DIRECTORIES = new Set(['node_modules', '.next', '.cache', 'vendor']);

function walk(target, files) {
  const stat = fs.statSync(target);
  if (stat.isDirectory()) {
    if (SKIPPED_DIRECTORIES.has(path.basename(target))) {
      return;
    }
    for (const entry of fs.readdirSync(target).sort()) {
      walk(path.join(target, entry), files);
    }
  } else if (TEXT_EXTENSIONS.has(path.extname(target))) {
    files.push(target);
  }
}

function collect(roots) {
  const files = [];
  for (const root of roots) {
    if (fs.existsSync(root)) {
      walk(root, files);
    }
  }
  return files;
}

const isTestFile = (file) => /\.test\.tsx?$/.test(file) || /test-support\.tsx?$/.test(file);
const relative = (file) => path.relative(repo, file);

// ---------------------------------------------------------------------------------------------
// 検知器（テキスト）
// ---------------------------------------------------------------------------------------------

function joined(...parts) {
  return parts.join('');
}

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

// 削除系の語（CI の hygiene と同じ規則）。語は、部品から組み立てる
const before = '(?<![A-Za-z0-9_.-])';
const after = '(?![A-Za-z0-9_./-])';
const optionBefore = '(?<![A-Za-z0-9_-])';
const optionAfter = '(?![A-Za-z0-9_-])';
const DELETION_RULES = [
  ['ファイル・ディレクトリを消すコマンド', new RegExp(`${before}(?:${joined('r', 'm')}(?:dir|i)?|${joined('un', 'link')}|${joined('sh', 'red')})${after}`)],
  ['削除のオプション', new RegExp(`${optionBefore}--?${joined('del', 'ete')}(?:-[a-z]+)?${optionAfter}`)],
  ['git の削除系', new RegExp(`${optionBefore}git\\s+(?:${joined('cle', 'an')}|worktree\\s+${joined('rem', 'ove')}|branch\\s+-[A-Za-z]*[dD][A-Za-z]*)${optionAfter}`)],
  ['docker の削除系', new RegExp(`${optionBefore}docker[^#\\n]*\\s${joined('do', 'wn')}${optionAfter}`)],
  ['docker の自動削除のオプション', new RegExp(`${optionBefore}--${joined('r', 'm')}${optionAfter}`)],
  ['不要な資源の一括削除', new RegExp(`${optionBefore}${joined('pru', 'ne')}${optionAfter}`)],
  ['ファイル削除の呼び出し', new RegExp(`(?<![A-Za-z0-9_])(?:FileUtils|File|Dir|Pathname|fs|os|shutil)\\.(?:${joined('r', 'm')}\\w*|[Rr]emove\\w*|${joined('del', 'ete')}\\w*|${joined('un', 'link')}\\w*)`)],
  ['Node の再帰削除の道具', new RegExp(`${optionBefore}${joined('rim', 'raf')}${optionAfter}`)],
  ['Rails のファイル削除タスク', new RegExp(`${optionBefore}(?:log|tmp):${joined('cl', 'ear')}${optionAfter}|${optionBefore}assets:${joined('cl', 'obber')}${optionAfter}`)],
];

// 不可視の文字: ゼロ幅（200B-200F・2060-2064・FEFF）・双方向の制御（202A-202E・2066-2069）・C0/C1 の制御（改行・タブ・復帰を除く）・DEL
const INVISIBLE_PATTERN = /[\u{200B}-\u{200F}\u{2060}-\u{2064}\u{FEFF}\u{202A}-\u{202E}\u{2066}-\u{2069}\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}\u{007F}-\u{009F}]/u;

const SECRET_RULES = [
  ['秘密鍵', /BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY/],
  ['AWS のアクセスキー', /AKIA[0-9A-Z]{16}/],
  ['GitHub のトークン', /gh[pousr]_[A-Za-z0-9]{20,}/],
  ['Google の API キー', /AIza[0-9A-Za-z_-]{20,}/],
  ['Bearer トークン', /[Bb]earer\s+[A-Za-z0-9._~+/-]{24,}/],
  ['RTMP の配信キーを含む URL', /rtmps?:\/\/[^\s"']*[A-Za-z0-9_-]{16,}/],
];

function findInLines(text, rules, label) {
  const found = [];
  text.split('\n').forEach((line, index) => {
    for (const [rule, pattern] of rules) {
      if (pattern.test(line)) {
        found.push({ line: index + 1, rule: `${label}: ${rule}`, text: line.trim().slice(0, 70) });
      }
    }
  });
  return found;
}

function findEmoji(text) {
  const found = [];
  text.split('\n').forEach((line, index) => {
    const match = EMOJI_PATTERN.exec(line);
    if (match !== null) {
      found.push({ line: index + 1, rule: '絵文字', text: `U+${match[0].codePointAt(0).toString(16).toUpperCase()}` });
    }
  });
  return found;
}

function findInvisible(text) {
  const found = [];
  text.split('\n').forEach((line, index) => {
    const match = INVISIBLE_PATTERN.exec(line);
    if (match !== null) {
      found.push({ line: index + 1, rule: '不可視の制御文字', text: `U+${match[0].codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}` });
    }
  });
  return found;
}

const findDeletion = (text) => findInLines(text, DELETION_RULES, '削除系');
const findSecrets = (text) => findInLines(text, SECRET_RULES, '秘密らしい文字列');

// ---------------------------------------------------------------------------------------------
// 検知器（構文木）
// ---------------------------------------------------------------------------------------------

const JAPANESE = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}\u{3000}-\u{303F}\u{FF00}-\u{FFEF}]/u;
const NATIVE_DIALOGS = new Set(['alert', 'confirm', 'prompt']);
const GLOBAL_OBJECTS = new Set(['window', 'globalThis', 'self']);
const STORAGE_GLOBALS = new Set(['localStorage', 'sessionStorage', 'indexedDB']);
const HTML_SINK_PROPERTIES = new Set(['innerHTML', 'outerHTML', 'insertAdjacentHTML']);
const CONSOLE_FORBIDDEN = new Set(['log', 'debug', 'info', 'trace', 'dir']);

// fetch を使ってよいモジュール（API クライアントと、同一オリジン中継の窓口）。process.env を読んでよいモジュール。外部 URL の直書きを許す設定ファイル
const FETCH_ALLOWED = new Set(['lib/api/client.ts', 'app/api/[...path]/route.ts', 'app/api/[...path]/forward.ts']);
const ENV_ALLOWED = new Set(['lib/api/client-environment.ts', 'app/api/[...path]/route.ts', 'lib/recaptcha/site-key.ts']);
const EXTERNAL_URL_ALLOWED = new Set(['lib/recaptcha/config.ts']);
const EXTERNAL_URL = /^(?:https?|wss?):\/\/([^/?#:]+)/i;

function isPropertyNamePosition(node) {
  const parent = node.parent;
  if (ts.isPropertyAccessExpression(parent) && parent.name === node) return true;
  if (ts.isQualifiedName(parent) && parent.right === node) return true;
  if (
    (ts.isPropertyAssignment(parent) ||
      ts.isPropertySignature(parent) ||
      ts.isMethodSignature(parent) ||
      ts.isPropertyDeclaration(parent) ||
      ts.isMethodDeclaration(parent) ||
      ts.isGetAccessorDeclaration(parent) ||
      ts.isSetAccessorDeclaration(parent) ||
      ts.isEnumMember(parent) ||
      ts.isBindingElement(parent) ||
      ts.isJsxAttribute(parent)) &&
    parent.name === node
  ) {
    return true;
  }
  return false;
}

/** 構文木を走査して、違反を集める。options.relativePath は、許可リストの照合に使う（src/frontend からの相対） */
function findInSyntax(text, fileName, options) {
  const found = [];
  const kind = fileName.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const source = ts.createSourceFile(fileName, text, ts.ScriptTarget.Latest, true, kind);
  const add = (node, rule, detail) => {
    const { line } = source.getLineAndCharacterOfPosition(node.getStart(source));
    found.push({ line: line + 1, rule, text: detail });
  };
  const checkJapanese = !options.isMessageFile;

  function visit(node) {
    // 日本語
    if (checkJapanese) {
      if (
        (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node) || ts.isRegularExpressionLiteral(node) || ts.isJsxText(node) ||
          ts.isTemplateHead(node) || ts.isTemplateMiddle(node) || ts.isTemplateTail(node)) &&
        JAPANESE.test(node.text === undefined ? node.getText(source) : node.text)
      ) {
        add(node, '日本語の直書き（文言は messages/ へ）', ts.SyntaxKind[node.kind]);
      } else if (ts.isIdentifier(node) && JAPANESE.test(node.text)) {
        add(node, '日本語の識別子', node.text);
      }
    }
    // ネイティブのダイアログ
    if (ts.isCallExpression(node)) {
      const callee = node.expression;
      if (ts.isIdentifier(callee) && NATIVE_DIALOGS.has(callee.text)) {
        add(node, `ネイティブのダイアログ: ${callee.text}()`, callee.text);
      } else if (ts.isPropertyAccessExpression(callee) && NATIVE_DIALOGS.has(callee.name.text) && ts.isIdentifier(callee.expression) && GLOBAL_OBJECTS.has(callee.expression.text)) {
        add(node, `ネイティブのダイアログ: ${callee.expression.text}.${callee.name.text}()`, callee.getText(source));
      }
      // eval・new Function 以外の、文字列を実行する形
      if (ts.isIdentifier(callee) && callee.text === 'eval') {
        add(node, 'eval の呼び出し', 'eval');
      }
      if (ts.isPropertyAccessExpression(callee) && callee.name.text === 'write' && ts.isIdentifier(callee.expression) && callee.expression.text === 'document') {
        add(node, 'document.write の呼び出し', 'document.write');
      }
      if (ts.isPropertyAccessExpression(callee) && ts.isIdentifier(callee.expression) && callee.expression.text === 'console' && CONSOLE_FORBIDDEN.has(callee.name.text)) {
        add(node, `console.${callee.name.text} が残っている（失敗の記録は console.error）`, callee.getText(source));
      }
      if (ts.isPropertyAccessExpression(callee) && callee.name.text === 'insertAdjacentHTML') {
        add(node, 'HTML を直接差し込む形', 'insertAdjacentHTML');
      }
    }
    if (ts.isNewExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'Function') {
      add(node, 'new Function（文字列を実行する）', 'new Function');
    }
    if (node.kind === ts.SyntaxKind.DebuggerStatement) {
      add(node, 'debugger が残っている', 'debugger');
    }
    // HTML を直接差し込む形
    if (ts.isJsxAttribute(node) && ts.isIdentifier(node.name) && node.name.text === 'dangerouslySetInnerHTML') {
      add(node, 'HTML を直接差し込む形', 'dangerouslySetInnerHTML');
    }
    if (ts.isPropertyAccessExpression(node) && HTML_SINK_PROPERTIES.has(node.name.text) && node.name.text !== 'insertAdjacentHTML') {
      add(node, 'HTML を直接差し込む形', node.name.text);
    }
    // 識別子の参照
    if (ts.isIdentifier(node) && !isPropertyNamePosition(node)) {
      if (node.text === 'fetch' && !options.fetchAllowed) {
        add(node, 'fetch の直接の使用（通信は、API クライアントだけ）', 'fetch');
      }
      if (STORAGE_GLOBALS.has(node.text)) {
        add(node, `${node.text} の使用（CSRF トークンは、メモリにだけ持つ）`, node.text);
      }
    }
    if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression)) {
      const owner = node.expression.text;
      const name = node.name.text;
      if (GLOBAL_OBJECTS.has(owner) && name === 'fetch' && !options.fetchAllowed) {
        add(node, 'fetch の直接の使用（通信は、API クライアントだけ）', `${owner}.fetch`);
      }
      if (GLOBAL_OBJECTS.has(owner) && STORAGE_GLOBALS.has(name)) {
        add(node, `${name} の使用（CSRF トークンは、メモリにだけ持つ）`, `${owner}.${name}`);
      }
      if (owner === 'document' && name === 'cookie') {
        add(node, 'document.cookie の使用', 'document.cookie');
      }
      if (owner === 'process' && name === 'env' && !options.envAllowed) {
        add(node, 'process.env の直接の参照（設定を読むモジュールだけ）', 'process.env');
      }
    }
    // 外部の URL の直書き
    if ((ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) && !options.externalUrlAllowed) {
      const match = EXTERNAL_URL.exec(node.text);
      if (match !== null && !match[1].toLowerCase().endsWith('.invalid')) {
        add(node, '外部の URL の直書き（設定ファイルへ）', match[1]);
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return found;
}

// ---------------------------------------------------------------------------------------------
// 自己検査（検知器が、違反の見本を見つけ、違反でない見本を通すこと）
// ---------------------------------------------------------------------------------------------

function selfTest() {
  const problems = [];
  const codePoint = (value) => String.fromCodePoint(value);
  const expectFound = (label, found, rulePart) => {
    if (!found.some((entry) => entry.rule.includes(rulePart))) {
      problems.push(`違反の見本を見つけられない: ${label}（${rulePart}）`);
    }
  };
  const expectClean = (label, found) => {
    if (found.length > 0) {
      problems.push(`違反でない見本を、違反とした: ${label}（${JSON.stringify(found)}）`);
    }
  };
  const defaults = { isMessageFile: false, fetchAllowed: false, envAllowed: false, externalUrlAllowed: false };
  const syntax = (code, fileName = 'sample.tsx', overrides = {}) => findInSyntax(code, fileName, { ...defaults, ...overrides });
  const jp = codePoint(0x65e5) + codePoint(0x672c); // 日本

  // テキスト
  expectFound('絵文字', findEmoji(`const x = "${codePoint(0x1f600)}";`), '絵文字');
  expectFound('絵文字（異体字選択子つき）', findEmoji(`a${codePoint(0x2764)}${codePoint(0xfe0f)}`), '絵文字');
  expectClean('通常の記号（矢印・米印・波ダッシュ・星・音符）', findEmoji(`${codePoint(0x2192)} ${codePoint(0x203b)} ${codePoint(0x301c)} ${codePoint(0x2605)} ${codePoint(0x266a)}`));
  expectFound('不可視の文字（ゼロ幅スペース）', findInvisible(`a${codePoint(0x200b)}b`), '不可視');
  expectFound('不可視の文字（双方向の制御）', findInvisible(`a${codePoint(0x202e)}b`), '不可視');
  expectClean('通常の空白・日本語・タブ', findInvisible(`a b\tc ${jp}\n`));
  expectFound('削除系（ファイルを消すコマンド）', findDeletion(`${joined('r', 'm')} -rf /tmp/x`), '削除系');
  expectFound('削除系（削除のオプション）', findDeletion(`tool --${joined('del', 'ete')} x`), '削除系');
  expectFound('削除系（git）', findDeletion(`git ${joined('cle', 'an')} -df`), '削除系');
  expectFound('削除系（docker）', findDeletion(`docker compose ${joined('do', 'wn')}`), '削除系');
  expectFound('削除系（ファイル削除の呼び出し）', findDeletion(`fs.${joined('r', 'm')}Sync(x)`), '削除系');
  expectClean('削除系に見えるだけの語（form・format・prefix・unlinked・DELETE のメソッド名・deleteAccount）', findDeletion('form format prefix unlinked DELETE deleteAccount transform'));
  expectFound('秘密らしい文字列（秘密鍵）', findSecrets(`-----BEGIN ${joined('PRIVATE', ' KEY')}-----`), '秘密');
  expectFound('秘密らしい文字列（Google の API キー）', findSecrets(`key = "AIza${'x'.repeat(30)}"`), '秘密');
  expectClean('ダミーのトークン', findSecrets('dummy-csrf-token-0123456789abcdef'));

  // 構文木
  expectFound('ネイティブのダイアログ（alert）', syntax('alert("x");'), 'ネイティブ');
  expectFound('ネイティブのダイアログ（window.confirm）', syntax('window.confirm("x");'), 'ネイティブ');
  expectFound('ネイティブのダイアログ（globalThis.prompt）', syntax('globalThis.prompt("x");'), 'ネイティブ');
  expectClean('alert という名前のプロパティ・変数', syntax('const alertLevel = 1; notice.alert(); const o = { confirm: 1 };'));
  expectFound('日本語の文字列', syntax(`const a = "${jp}";`), '日本語');
  expectFound('日本語のテンプレート', syntax(`const a = \`${jp}\`;`), '日本語');
  expectFound('日本語のテンプレート（式つき）', syntax(`const a = \`${jp}\${b}x\`;`), '日本語');
  expectFound('日本語の JSX の文字', syntax(`const a = <p>${jp}</p>;`), '日本語');
  expectFound('日本語の正規表現', syntax(`const a = /${jp}/;`), '日本語');
  expectFound('日本語の識別子', syntax(`const ${jp} = 1;`), '日本語');
  expectFound('全角の記号', syntax(`const a = "${codePoint(0xff08)}x${codePoint(0xff09)}";`), '日本語');
  expectClean('日本語のコメント', syntax(`// ${jp}\n/** ${jp} */\nconst a = "x"; /* ${jp} */`));
  expectClean('文言の置き場（messages/）は、日本語を許す', syntax(`export const m = { a: "${jp}" };`, 'messages.ts', { isMessageFile: true }));
  expectFound('fetch の直接の使用', syntax('const r = fetch("/x");'), 'fetch');
  expectFound('globalThis.fetch', syntax('const r = globalThis.fetch("/x");'), 'fetch');
  expectClean('deps.fetch・プロパティの fetch・型の fetch', syntax('const r = deps.fetch(u); const o = { fetch: 1 }; interface D { readonly fetch: () => void }'));
  expectClean('許可されたモジュールの fetch', syntax('const r = fetch("/x");', 'client.ts', { fetchAllowed: true }));
  expectFound('process.env', syntax('const v = process.env.X;'), 'process.env');
  expectClean('許可されたモジュールの process.env', syntax('const v = process.env.X;', 'a.ts', { envAllowed: true }));
  expectFound('外部の URL の直書き', syntax('const u = "https://example.com/x";'), '外部の URL');
  expectFound('外部の URL の直書き（ws）', syntax('const u = "wss://example.com/x";'), '外部の URL');
  expectClean('予約された .invalid のホスト・相対の経路', syntax('const u = "http://relative.invalid"; const p = "/api/state";'));
  expectClean('許可された設定ファイルの外部 URL', syntax('const u = "https://example.com/x";', 'config.ts', { externalUrlAllowed: true }));
  expectFound('localStorage', syntax('localStorage.setItem("a", "b");'), 'localStorage');
  expectFound('window.sessionStorage', syntax('window.sessionStorage.getItem("a");'), 'sessionStorage');
  expectFound('document.cookie', syntax('document.cookie = "a=b";'), 'document.cookie');
  expectClean('storage に似た名前', syntax('const localStorageLike = 1; const o = { indexedDB: 1 };'));
  expectFound('innerHTML', syntax('el.innerHTML = "x";'), 'HTML');
  expectFound('dangerouslySetInnerHTML', syntax('const a = <div dangerouslySetInnerHTML={{ __html: x }} />;'), 'HTML');
  expectFound('insertAdjacentHTML', syntax('el.insertAdjacentHTML("beforeend", x);'), 'HTML');
  expectFound('document.write', syntax('document.write("x");'), 'document.write');
  expectFound('eval', syntax('eval("1");'), 'eval');
  expectFound('new Function', syntax('const f = new Function("return 1");'), 'new Function');
  expectFound('console.log', syntax('console.log("x");'), 'console.log');
  expectFound('debugger', syntax('debugger;'), 'debugger');
  expectClean('console.error', syntax('console.error("x");'));
  return problems;
}

// ---------------------------------------------------------------------------------------------
// 実行
// ---------------------------------------------------------------------------------------------

let failures = 0;
let passes = 0;
const pass = (label) => {
  passes += 1;
  console.log(`ok   ${label}`);
};
const fail = (label, detail) => {
  failures += 1;
  console.log(`FAIL ${label}`);
  for (const line of detail) {
    console.log(`       ${line}`);
  }
};
const note = (text) => console.log(`NOTE ${text}`);
const report = (label, findings) => {
  if (findings.length === 0) {
    pass(label);
    return;
  }
  fail(`${label}（${findings.length} 件）`, findings.slice(0, 12).map((entry) => `${entry.file}:${entry.line}  ${entry.rule}  ${entry.text}`));
};

const problems = selfTest();
if (problems.length > 0) {
  fail('走査器の自己検査', problems);
  console.log(`\n成功 ${passes} 件・失敗 ${failures} 件`);
  process.exit(EXIT_FINDINGS);
}
pass('走査器の自己検査（違反の見本を見つけ、違反でない見本を通す）');

const productFiles = collect(SCOPE.map((entry) => path.join(FRONTEND, entry)));
const testFiles = collect([TEST_DIRECTORY]);
const sourceFiles = productFiles.filter((file) => /\.tsx?$/.test(file) && !isTestFile(file));
note(`走査する対象: 画面・中継のソース ${productFiles.length} ファイル（うち、テストでない .ts・.tsx は ${sourceFiles.length}）・このテストのディレクトリ ${testFiles.length} ファイル`);

const textFindings = { emoji: [], deletion: [], invisible: [], secret: [] };
for (const file of [...productFiles, ...testFiles]) {
  const text = fs.readFileSync(file, 'utf8');
  for (const [key, finder] of [['emoji', findEmoji], ['deletion', findDeletion], ['invisible', findInvisible], ['secret', findSecrets]]) {
    for (const entry of finder(text)) {
      textFindings[key].push({ file: relative(file), ...entry });
    }
  }
}
report('絵文字が無い（CI の hygiene と同じ範囲）', textFindings.emoji);
report('削除系の語の実行形が無い（CI の hygiene と同じ規則。対象は、ソースとこのテストの全ファイル）', textFindings.deletion);
report('不可視の制御文字（ゼロ幅・双方向の制御・制御文字）が無い', textFindings.invisible);
report('秘密らしい文字列（秘密鍵・各種のトークンの形）が無い', textFindings.secret);

const syntaxFindings = { dialogs: [], japanese: [], fetch: [], env: [], url: [], storage: [], sinks: [], console: [] };
for (const file of sourceFiles) {
  const relativeToFrontend = path.relative(FRONTEND, file).split(path.sep).join('/');
  const options = {
    isMessageFile: relativeToFrontend.startsWith('messages/'),
    fetchAllowed: FETCH_ALLOWED.has(relativeToFrontend),
    envAllowed: ENV_ALLOWED.has(relativeToFrontend),
    externalUrlAllowed: EXTERNAL_URL_ALLOWED.has(relativeToFrontend),
  };
  for (const entry of findInSyntax(fs.readFileSync(file, 'utf8'), file, options)) {
    const record = { file: relative(file), ...entry };
    if (entry.rule.startsWith('ネイティブのダイアログ')) syntaxFindings.dialogs.push(record);
    else if (entry.rule.startsWith('日本語')) syntaxFindings.japanese.push(record);
    else if (entry.rule.startsWith('fetch')) syntaxFindings.fetch.push(record);
    else if (entry.rule.startsWith('process.env')) syntaxFindings.env.push(record);
    else if (entry.rule.startsWith('外部の URL')) syntaxFindings.url.push(record);
    else if (/^(localStorage|sessionStorage|indexedDB|document\.cookie)/.test(entry.rule)) syntaxFindings.storage.push(record);
    else if (entry.rule.startsWith('console.') || entry.rule.startsWith('debugger')) syntaxFindings.console.push(record);
    else syntaxFindings.sinks.push(record);
  }
}
report('ネイティブのダイアログ（alert・confirm・prompt）を呼ばない', syntaxFindings.dialogs);
report('日本語の直書きが無い（文字列・テンプレート・正規表現・JSX の文字・識別子。コメントと messages/ を除く）', syntaxFindings.japanese);
report('fetch を使うのは、API クライアントと、同一オリジン中継の窓口だけ', syntaxFindings.fetch);
report('process.env を読むのは、設定を読む 3 つのモジュールだけ', syntaxFindings.env);
report('外部の URL の直書きは、bot 判定の設定ファイルだけ（.invalid を除く）', syntaxFindings.url);
report('localStorage・sessionStorage・indexedDB・document.cookie を使わない', syntaxFindings.storage);
report('HTML を直接差し込む形・eval・new Function・document.write を使わない', syntaxFindings.sinks);
report('console.log・debug・info・trace・dir・debugger が残っていない', syntaxFindings.console);

// core/contract（#3 の契約）が、変更されていない
const contractPath = 'src/frontend/core/contract';
const status = childProcess.spawnSync('git', ['status', '--porcelain', '--', contractPath], { cwd: repo, encoding: 'utf8' });
if (status.error !== undefined || status.status !== 0) {
  fail('core/contract が変更されていない（git status）', [`git status を実行できません: ${status.error ? status.error.message : status.stderr.trim()}`]);
} else {
  const changed = status.stdout.split('\n').filter((line) => line.trim() !== '');
  report('core/contract（#3 の契約）が変更されていない（git status）', changed.map((line) => ({ file: contractPath, line: 0, rule: '変更あり', text: line })));
}

console.log(`\n成功 ${passes} 件・失敗 ${failures} 件`);
process.exit(failures > 0 ? EXIT_FINDINGS : EXIT_OK);
