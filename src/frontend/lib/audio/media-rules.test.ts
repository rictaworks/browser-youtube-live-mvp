/**
 * @jest-environment node
 */
// メディア（ソースの取得 lib/sources・音声の混合 lib/audio・Worklet public/worklets）の実装の方針を、ソースの構文木で走査して検査する
// （requirements.md 11.2・11.6、CLAUDE.md の不変条件、issue #26）。
//   1. 音声の時刻の採番に、実時計・タイマを使わない（Date・performance・setInterval・requestAnimationFrame・setTimeout の大域の参照が無い）。
//      時刻は、累積サンプル数だけから決まる（MediaClock）。start の待ち時間の期限だけは、注入された環境（AudioEnvironment）のタイマを使う
//   2. 配信者自身への音声の折り返し再生をしない: 出力先（AudioContext の destination）へ接続しない。<audio>・音声の要素・再生（play）・srcObject を使わない。
//      SourceManager（lib/sources）は、取得したトラックを持つだけで、音声のグラフ（AudioContext・AudioWorkletNode・MediaStreamAudioSourceNode）を作らない
//   3. Worklet は、自己完結の 1 つのスクリプト（import・export・fetch・タイマ・乱数・動的評価が無い）で、日本語の文字列リテラルを持たない
// テストのファイル（*.test.ts）と、テストの道具（test-support.ts・worklet-harness.ts）は走査しない。
// 走査器の自己検査（違反の例が、実際に検知されること）つき。走査が空振りしていないことも確かめる。
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import { findJapaneseInCode } from "@/lib/source-policy/detectors";

const FRONTEND_ROOT = path.resolve(__dirname, "../..");

interface Finding {
  readonly line: number;
  readonly rule: string;
  readonly text: string;
}

interface Rules {
  /** 大域の参照として使ってはならない名前（変数・型の名前としての出現）。プロパティの名前の位置は、対象外 */
  readonly forbiddenIdentifiers: ReadonlySet<string>;
  /** プロパティのアクセス（a.b の b）として使ってはならない名前 */
  readonly forbiddenProperties: ReadonlySet<string>;
  /** Math.random のような、(オブジェクト, プロパティ) の組 */
  readonly forbiddenMembers: readonly (readonly [string, string])[];
  /** import・export の宣言を許さない（自己完結のスクリプト） */
  readonly forbidModuleSyntax: boolean;
}

function names(...values: string[]): ReadonlySet<string> {
  return new Set(values);
}

const WALL_CLOCK_AND_TIMERS = ["Date", "performance", "setInterval", "setTimeout", "clearTimeout", "clearInterval", "requestAnimationFrame", "requestIdleCallback"];
const PLAYBACK_PROPERTIES = ["srcObject", "play", "createMediaElementSource", "createElement"];
const PLAYBACK_IDENTIFIERS = ["HTMLAudioElement", "HTMLMediaElement", "Audio"];

/** lib/audio（実行時のコード）: 実時計・タイマを使わない。出力先へつながない。音声の要素を使わない。 */
const AUDIO_RULES: Rules = {
  forbiddenIdentifiers: names(...WALL_CLOCK_AND_TIMERS, ...PLAYBACK_IDENTIFIERS),
  forbiddenProperties: names("destination", ...PLAYBACK_PROPERTIES),
  forbiddenMembers: [["Math", "random"]],
  forbidModuleSyntax: false,
};

/** lib/sources（実行時のコード）: 音声のグラフを作らない。再生しない。実時計を使わない（タイマは、通知の例外の投げ直し（emitter.ts）だけ）。 */
const SOURCES_RULES: Rules = {
  forbiddenIdentifiers: names("Date", "performance", "AudioContext", "OfflineAudioContext", "AudioWorkletNode", ...PLAYBACK_IDENTIFIERS),
  forbiddenProperties: names("destination", "createMediaStreamSource", "createMediaStreamDestination", ...PLAYBACK_PROPERTIES),
  forbiddenMembers: [["Math", "random"]],
  forbidModuleSyntax: false,
};

/** public/worklets: 自己完結で、実時計・タイマ・乱数・ネットワーク・動的評価を使わない。 */
const WORKLET_RULES: Rules = {
  forbiddenIdentifiers: names(...WALL_CLOCK_AND_TIMERS, "fetch", "XMLHttpRequest", "importScripts", "eval", "Function", "WebSocket"),
  forbiddenProperties: names(),
  forbiddenMembers: [["Math", "random"]],
  forbidModuleSyntax: true,
};

function parse(fileName: string, source: string): ts.SourceFile {
  return ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, fileName.endsWith(".js") ? ts.ScriptKind.JS : ts.ScriptKind.TS);
}

function walk(node: ts.Node, visit: (node: ts.Node) => void): void {
  visit(node);
  ts.forEachChild(node, (child) => walk(child, visit));
}

function lineOf(sourceFile: ts.SourceFile, node: ts.Node): number {
  return sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;
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

/** import・export の宣言（export の修飾子つきの宣言を含む）。 */
function isModuleSyntax(node: ts.Node): boolean {
  if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node) || ts.isExportAssignment(node) || ts.isImportEqualsDeclaration(node)) {
    return true;
  }
  const modifiers = ts.canHaveModifiers(node) ? ts.getModifiers(node) : undefined;
  return modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword) ?? false;
}

/** ソースを走査して、方針に反する箇所を返す（コメントは対象外）。 */
function scanSource(fileName: string, source: string, rules: Rules): Finding[] {
  const sourceFile = parse(fileName, source);
  const findings: Finding[] = [];
  walk(sourceFile, (node) => {
    if (ts.isIdentifier(node) && !isPropertyNamePosition(node) && rules.forbiddenIdentifiers.has(node.text)) {
      findings.push({ line: lineOf(sourceFile, node), rule: "forbidden identifier", text: node.text });
    }
    if (ts.isPropertyAccessExpression(node)) {
      if (rules.forbiddenProperties.has(node.name.text)) {
        findings.push({ line: lineOf(sourceFile, node), rule: "forbidden property", text: node.name.text });
      }
      for (const [objectName, propertyName] of rules.forbiddenMembers) {
        if (ts.isIdentifier(node.expression) && node.expression.text === objectName && node.name.text === propertyName) {
          findings.push({ line: lineOf(sourceFile, node), rule: "forbidden member", text: `${objectName}.${propertyName}` });
        }
      }
    }
    if (ts.isElementAccessExpression(node) && ts.isStringLiteralLike(node.argumentExpression) && rules.forbiddenProperties.has(node.argumentExpression.text)) {
      findings.push({ line: lineOf(sourceFile, node), rule: "forbidden property", text: node.argumentExpression.text });
    }
    if (rules.forbidModuleSyntax && isModuleSyntax(node)) {
      findings.push({ line: lineOf(sourceFile, node), rule: "module syntax", text: node.getText(sourceFile).slice(0, 40) });
    }
    if (rules.forbidModuleSyntax && ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      findings.push({ line: lineOf(sourceFile, node), rule: "module syntax", text: "import()" });
    }
  });
  return findings;
}

function listFiles(directory: string, accept: (fileName: string) => boolean): string[] {
  const root = path.join(FRONTEND_ROOT, directory);
  return fs
    .readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isFile() && accept(entry.name))
    .map((entry) => path.join(directory, entry.name))
    .sort();
}

function isRuntimeSource(fileName: string): boolean {
  return /\.ts$/.test(fileName) && !/\.test\.ts$/.test(fileName) && fileName !== "test-support.ts" && fileName !== "worklet-harness.ts";
}

function read(relativePath: string): string {
  return fs.readFileSync(path.join(FRONTEND_ROOT, relativePath), "utf8");
}

function scanFiles(files: readonly string[], rules: Rules): string[] {
  return files.flatMap((file) => scanSource(file, read(file), rules).map((finding) => `${file}:${finding.line} ${finding.rule}: ${finding.text}`));
}

describe("走査器の自己検査（違反の例を、実際に検知する）", () => {
  it("実時計・タイマの大域の参照を検知する。プロパティの名前・コメント・文字列は、対象外", () => {
    const violating = "const a = Date.now(); const b = performance.now(); setTimeout(() => 1, 1); requestAnimationFrame(() => 1);";
    const allowed = "const env = { setTimeout: 1 }; env.setTimeout; // Date.now() in a comment\nconst text = 'Date.now()';";

    expect(scanSource("x.ts", violating, AUDIO_RULES).map((finding) => finding.text)).toEqual(["Date", "performance", "setTimeout", "requestAnimationFrame"]);
    expect(scanSource("x.ts", allowed, AUDIO_RULES)).toEqual([]);
  });

  it("出力先（destination）への接続・音声の要素・再生・srcObject を検知する", () => {
    const source = "context.destination; node.connect(context.destination); el.srcObject = s; el.play(); const a = new Audio(); document.createElement('audio');";

    const found = scanSource("x.ts", source, AUDIO_RULES).map((finding) => finding.text);

    expect(found).toEqual(expect.arrayContaining(["destination", "srcObject", "play", "Audio", "createElement"]));
  });

  it("lib/sources の規則: 音声のグラフ（AudioContext・createMediaStreamSource）を検知する", () => {
    const source = "const c = new AudioContext(); c.createMediaStreamSource(s); c.createMediaStreamDestination();";

    expect(scanSource("x.ts", source, SOURCES_RULES).map((finding) => finding.text)).toEqual(["AudioContext", "createMediaStreamSource", "createMediaStreamDestination"]);
  });

  it("Worklet の規則: import・export・動的 import・fetch・乱数・動的評価を検知する", () => {
    const source = "import x from 'y'; export const z = 1; import('w'); fetch('u'); Math.random(); eval('1'); new Function('1');";

    const found = scanSource("x.js", source, WORKLET_RULES).map((finding) => finding.rule);

    expect(found.filter((rule) => rule === "module syntax")).toHaveLength(3);
    expect(scanSource("x.js", source, WORKLET_RULES).map((finding) => finding.text)).toEqual(expect.arrayContaining(["fetch", "Math.random", "eval", "Function"]));
  });
});

describe("lib/audio（実行時のコード）", () => {
  const files = listFiles("lib/audio", isRuntimeSource);

  it("走査の対象に、主要なファイルが含まれる（走査が空振りしていない）", () => {
    expect(files).toEqual(
      expect.arrayContaining(["lib/audio/AudioMixer.ts", "lib/audio/MixerCore.ts", "lib/audio/AudioClockDriver.ts", "lib/audio/bindSourcesToMixer.ts", "lib/audio/environment.ts", "lib/audio/workletProtocol.ts"]),
    );
    expect(files.some((file) => file.includes("test-support") || file.endsWith(".test.ts"))).toBe(false);
  });

  it("実時計・タイマを使わない。出力先へつながない。音声の要素・再生を使わない（折り返し再生をしない）", () => {
    expect(scanFiles(files, AUDIO_RULES)).toEqual([]);
  });
});

describe("lib/sources（実行時のコード）", () => {
  const files = listFiles("lib/sources", isRuntimeSource);

  it("走査の対象に、主要なファイルが含まれる（走査が空振りしていない）", () => {
    expect(files).toEqual(expect.arrayContaining(["lib/sources/SourceManager.ts", "lib/sources/DeviceCatalog.ts", "lib/sources/constraints.ts", "lib/sources/emitter.ts"]));
  });

  it("音声のグラフを作らない。取得した音声を再生へ接続しない（折り返し再生をしない）。実時計を使わない", () => {
    expect(scanFiles(files, SOURCES_RULES)).toEqual([]);
  });
});

describe("Worklet（public/worklets）", () => {
  const files = listFiles("public/worklets", (name) => name.endsWith(".js"));

  it("走査の対象に、ミキサーのプロセッサが含まれる（走査が空振りしていない）", () => {
    expect(files).toEqual(["public/worklets/stream-mixer-processor.js"]);
  });

  it("自己完結で、実時計・タイマ・乱数・ネットワーク・動的評価を使わない", () => {
    expect(scanFiles(files, WORKLET_RULES)).toEqual([]);
  });

  it("日本語の文字列リテラルを持たない（利用者に表示する文字列は、文言カタログへ。コメントは対象外）", () => {
    const findings = files.flatMap((file) => findJapaneseInCode(file, read(file)).map((finding) => `${file}:${finding.line} ${finding.text}`));

    expect(findings).toEqual([]);
  });
});
