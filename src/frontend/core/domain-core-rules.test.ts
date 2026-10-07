/**
 * @jest-environment node
 */
// Domain Core（src/frontend/core/）の規則を、ソースの構文木で走査して検査する（requirements.md 2.5・11.6・15・27、CLAUDE.md の不変条件）。
//   1. 実時計・乱数・タイマ（Date・performance・setTimeout など、Math.random）を参照しない。時刻・乱数・タイマは、引数・注入で受け取る
//   2. DOM・WebSocket・React・next・window・navigator などの大域を参照しない。環境は、注入されたオブジェクトからだけ読む
//      （プロパティの名前（env.navigator・型の項目名）は、大域の参照ではないので許す。変数・引数・型の名前としての使用は許さない）
//   3. import は、core の中の相対パスだけ（next・react・lib・app・components などへ依存しない）
//   4. 再代入できるモジュール直下の変数（let・var）を持たない（グローバルな可変の状態を作らない）。var はどこにも使わない
//   5. 文字列・テンプレートのリテラルは、画面に出す文章を持たない（ASCII の印字可能な文字と改行だけ。日本語はコメントだけ）
//   6. メディアクロックは、BigInt を使わない（Number の安全整数の範囲で、整数演算だけで厳密に計算する）
// テストのファイル（*.test.ts）は走査しない（検査のための実時計や Date を使えるように）。core/contract も、同じ規則で走査する。
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";

const CORE_ROOT = __dirname;

/** 参照してはならない大域の名前（実時計・乱数・タイマ・入出力・DOM・環境）。 */
const FORBIDDEN_GLOBALS: ReadonlySet<string> = new Set([
  // 実時計・タイマ
  "Date",
  "performance",
  "setTimeout",
  "setInterval",
  "setImmediate",
  "clearTimeout",
  "clearInterval",
  "queueMicrotask",
  "requestAnimationFrame",
  "requestIdleCallback",
  // 乱数・暗号
  "crypto",
  // 入出力・ネットワーク・ログ
  "fetch",
  "XMLHttpRequest",
  "WebSocket",
  "console",
  "process",
  // DOM・ブラウザの大域
  "window",
  "document",
  "navigator",
  "self",
  "globalThis",
  "localStorage",
  "sessionStorage",
  "indexedDB",
  "location",
  "history",
  "alert",
  "confirm",
  "prompt",
  // ブラウザの機能（環境オブジェクトから読む）
  "Worker",
  "Blob",
  "URL",
  "structuredClone",
  "ReadableStream",
  "OffscreenCanvas",
  "VideoFrame",
  "VideoEncoder",
  "AudioEncoder",
  "AudioContext",
  "AudioWorkletNode",
  "MediaStreamTrackProcessor",
  // UI
  "React",
  // 動的な評価
  "eval",
]);

interface Finding {
  readonly line: number;
  readonly rule: string;
  readonly text: string;
}

function parse(fileName: string, source: string): ts.SourceFile {
  return ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
}

/** プロパティ・メンバーの名前の位置（大域の参照ではない）。 */
function isPropertyNamePosition(identifier: ts.Identifier): boolean {
  const parent = identifier.parent;
  if (ts.isPropertyAccessExpression(parent) && parent.name === identifier) {
    return true;
  }
  if (ts.isQualifiedName(parent) && parent.right === identifier) {
    return true;
  }
  if (
    (ts.isPropertyAssignment(parent) ||
      ts.isPropertySignature(parent) ||
      ts.isMethodSignature(parent) ||
      ts.isPropertyDeclaration(parent) ||
      ts.isMethodDeclaration(parent) ||
      ts.isGetAccessorDeclaration(parent) ||
      ts.isSetAccessorDeclaration(parent) ||
      ts.isEnumMember(parent)) &&
    parent.name === identifier
  ) {
    return true;
  }
  return ts.isBindingElement(parent) && parent.propertyName === identifier;
}

function lineOf(sourceFile: ts.SourceFile, node: ts.Node): number {
  return sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;
}

function walk(node: ts.Node, visit: (node: ts.Node) => void): void {
  visit(node);
  ts.forEachChild(node, (child) => walk(child, visit));
}

/** 構文木の節が、文字列・テンプレートのリテラルの文字（式の部分を除く）を持つなら、その文字。 */
function literalText(node: ts.Node): string | undefined {
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node) || ts.isTemplateHead(node) || ts.isTemplateMiddle(node) || ts.isTemplateTail(node)) {
    return node.text;
  }
  return undefined;
}

/** 走査する規則。fileName は、core からの相対パス（/ 区切り）。 */
function findViolations(fileName: string, source: string): Finding[] {
  const sourceFile = parse(fileName, source);
  const findings: Finding[] = [];
  const add = (node: ts.Node, rule: string, text: string): void => {
    findings.push({ line: lineOf(sourceFile, node), rule, text });
  };
  const isClockModule = fileName.startsWith("clock/");

  walk(sourceFile, (node) => {
    // 1・2・6. 参照してはならない大域の名前（プロパティの名前の位置は除く）
    if (ts.isIdentifier(node) && !isPropertyNamePosition(node)) {
      if (FORBIDDEN_GLOBALS.has(node.text)) {
        add(node, "forbidden-global", node.text);
      }
      if (isClockModule && node.text === "BigInt") {
        add(node, "clock-bigint", node.text);
      }
    }
    // 1. 乱数
    if (ts.isPropertyAccessExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "Math" && node.name.text === "random") {
      add(node, "random", "Math.random");
    }
    // 6. BigInt のリテラル（1n）
    if (isClockModule && ts.isBigIntLiteral(node)) {
      add(node, "clock-bigint", node.text);
    }
    // 3. import・export from・動的 import・require
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier !== undefined && ts.isStringLiteral(node.moduleSpecifier)) {
      const specifier = node.moduleSpecifier.text;
      if (!specifier.startsWith(".")) {
        add(node, "non-relative-import", specifier);
      } else {
        const resolved = path.resolve(path.dirname(path.join(CORE_ROOT, fileName)), specifier);
        if (resolved !== CORE_ROOT && !resolved.startsWith(CORE_ROOT + path.sep)) {
          add(node, "import-outside-core", specifier);
        }
      }
    }
    if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword || (ts.isIdentifier(node.expression) && node.expression.text === "require"))) {
      add(node, "dynamic-import", node.getText(sourceFile).slice(0, 40));
    }
    // 4. 再代入できる変数
    if (ts.isVariableDeclarationList(node)) {
      const isConst = (node.flags & ts.NodeFlags.Const) !== 0;
      const isLet = (node.flags & ts.NodeFlags.Let) !== 0;
      const isModuleLevel = ts.isVariableStatement(node.parent) && node.parent.parent === sourceFile;
      if (!isConst && !isLet) {
        add(node, "var", "var");
      } else if (isLet && isModuleLevel) {
        add(node, "module-level-let", "let");
      }
    }
    // 5. 文字列・テンプレートのリテラル
    const text = literalText(node);
    if (text !== undefined && !/^[\x20-\x7e\n]*$/.test(text)) {
      add(node, "non-ascii-literal", text.slice(0, 20));
    }
  });
  return findings;
}

function listSourceFiles(directory: string): string[] {
  const found: string[] = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      found.push(...listSourceFiles(full));
    } else if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts")) {
      found.push(full);
    }
  }
  return found.sort();
}

describe("走査の検知（この走査が、違反を見つけること）", () => {
  test.each<[string, string, string]>([
    ["Date.now()", "export const f = () => Date.now();", "forbidden-global"],
    ["new Date()", "export const f = () => new Date();", "forbidden-global"],
    ["performance.now()", "export const f = () => performance.now();", "forbidden-global"],
    ["setTimeout", "export function f(): void { setTimeout(() => undefined, 1); }", "forbidden-global"],
    ["setInterval", "export function f(): void { setInterval(() => undefined, 1); }", "forbidden-global"],
    ["Math.random()", "export const f = () => Math.random();", "random"],
    ["window", "export const f = () => window.innerWidth;", "forbidden-global"],
    ["document", "export const f = () => document.title;", "forbidden-global"],
    ["navigator", "export const f = () => navigator.userAgent;", "forbidden-global"],
    ["WebSocket", "export const f = () => new WebSocket('wss://example.invalid');", "forbidden-global"],
    ["fetch", "export const f = () => fetch('/api');", "forbidden-global"],
    ["localStorage", "export const f = () => localStorage.getItem('x');", "forbidden-global"],
    ["console", "export function f(): void { console.log('x'); }", "forbidden-global"],
    ["型としての WebSocket", "export type T = WebSocket;", "forbidden-global"],
    ["変数名として大域の名前を宣言する", "export const f = (env: { navigator: unknown }) => { const navigator = env.navigator; return navigator; };", "forbidden-global"],
    ["省略形のプロパティで大域を参照する", "export const f = () => ({ window });", "forbidden-global"],
    ["globalThis", "export const f = () => globalThis;", "forbidden-global"],
    ["react の import", "import React from 'react';\nexport const f = React;", "non-relative-import"],
    ["next の import", "import Link from 'next/link';\nexport const f = Link;", "non-relative-import"],
    ["node の import", "import fs from 'node:fs';\nexport const f = fs;", "non-relative-import"],
    ["core の外の相対 import", "import { x } from '../../lib/x';\nexport const f = x;", "import-outside-core"],
    ["動的 import", "export const f = () => import('./x');", "dynamic-import"],
    ["require", "export const f = () => require('./x');", "dynamic-import"],
    ["モジュール直下の let", "let counter = 0;\nexport const next = () => counter + 1;", "module-level-let"],
    ["var", "export function f(): number { var x = 1; return x; }", "var"],
    ["日本語の文字列リテラル", "export const label = 'あいう';", "non-ascii-literal"],
    ["日本語のテンプレート", "export const label = `あ${1}`;", "non-ascii-literal"],
  ])("%s", (_label, source, rule) => {
    const findings = findViolations("sample/file.ts", source);
    expect(findings.map((finding) => finding.rule)).toContain(rule);
  });

  test("メディアクロックの BigInt（識別子・リテラル）を見つける。clock 以外では、BigInt の規則を課さない", () => {
    expect(findViolations("clock/x.ts", "export const f = (n: number) => BigInt(n);").map((finding) => finding.rule)).toContain("clock-bigint");
    expect(findViolations("clock/x.ts", "export const one = 1n;").map((finding) => finding.rule)).toContain("clock-bigint");
    expect(findViolations("transport/x.ts", "export const f = (n: number) => BigInt(n);")).toEqual([]);
  });

  test.each<[string, string]>([
    ["環境オブジェクトの項目（env.navigator・env.Worker）", "export const f = (env: { navigator?: { locks?: unknown }; Worker?: unknown }) => [env.navigator?.locks, env.Worker];"],
    ["型の項目名・メソッド名・オブジェクトのキー", "export interface Env { readonly navigator?: unknown; readonly WebSocket?: unknown; setTimeout(): void }\nexport const e = { window: 1, document: 2 };"],
    ["クラスのメンバー名", "export class C { navigator = 1; fetch(): void {} }"],
    ["分割代入のプロパティ名（別名を付ける）", "export const f = (env: { Worker?: unknown }) => { const { Worker: workerConstructor } = env; return workerConstructor; };"],
    ["コメント（Date.now()・setTimeout・window）", "// Date.now() と setTimeout と window を使わない\n/* performance.now() */\nexport const x = 1;"],
    ["文字列の中の語（'Date.now'・'window'）", "export const names = ['Date.now', 'window', 'navigator', 'setTimeout'];"],
    ["関数の中の let", "export function f(): number { let total = 0; for (let i = 0; i < 3; i += 1) { total += i; } return total; }"],
    ["core の中の相対 import", "import { x } from './helpers';\nimport { y } from '../contract';\nexport const f = x + y;"],
    ["Reflect・Object・Math（乱数以外）", "export const f = (o: object) => [Reflect.get(o, 'a'), Object.freeze({}), Math.floor(1.5)];"],
  ])("違反ではない：%s", (_label, source) => {
    expect(findViolations("sample/file.ts", source)).toEqual([]);
  });
});

describe("Domain Core（core/ の、テスト以外の .ts）の規則", () => {
  const files = listSourceFiles(CORE_ROOT);
  const relative = (file: string): string => path.relative(CORE_ROOT, file).split(path.sep).join("/");

  test("走査の対象に、本 issue（#24）のモジュールと契約が含まれる（走査が空振りしていない）", () => {
    const names = files.map(relative);
    expect(names).toEqual(
      expect.arrayContaining([
        "contract/enums.ts",
        "clock/MediaClock.ts",
        "layout/resolveLayout.ts",
        "layout/containRect.ts",
        "layout/wipeRect.ts",
        "capability/evaluateCapabilities.ts",
        "capability/classifyBrowser.ts",
        "capability/readBrowserCapabilities.ts",
        "profile/selectProfile.ts",
        "reconnect/ReconnectPolicy.ts",
        "tablock/TabLockGuard.ts",
        "start/validateStartInput.ts",
        "state/transitionStudio.ts",
        "state/transitionSource.ts",
      ]),
    );
    expect(names.length).toBeGreaterThanOrEqual(30);
  });

  test("テストのファイル（*.test.ts）は走査の対象に含まれない", () => {
    expect(files.some((file) => file.endsWith(".test.ts"))).toBe(false);
  });

  test("実時計・乱数・タイマ・DOM・WebSocket・React・next・window・navigator を参照せず、import は core の中だけで、再代入できるモジュール直下の変数・日本語の文字列リテラル・メディアクロックの BigInt が無い", () => {
    const report = files.flatMap((file) =>
      findViolations(relative(file), fs.readFileSync(file, "utf8")).map((finding) => `${relative(file)}:${finding.line} [${finding.rule}] ${finding.text}`),
    );
    expect(report).toEqual([]);
  });
});
