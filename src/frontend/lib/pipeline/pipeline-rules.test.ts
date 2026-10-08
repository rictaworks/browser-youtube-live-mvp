/**
 * @jest-environment node
 */
// 配信パイプライン（lib/pipeline・workers/pipeline。issue #27）の実装の方針を、ソースの構文木で走査して検査する
// （requirements.md 11.4・11.6・13.1・30.1、CLAUDE.md の不変条件）。
//   1. 時刻の採番に、実時計・画面の描画周期を使わない（Date・performance・requestAnimationFrame・requestIdleCallback の大域の参照が無い）。
//      時刻は、音声の累積サンプル数だけから決まる（MediaClock）。タイマ（setTimeout・setInterval）の大域の参照は、既定のタイマの定義（timers.ts）に限る。
//      ほかのファイルは、注入されたタイマ（scheduler・timers）だけを使う
//   2. 代替スレート・プレビューに、文字を描かない（fillText・strokeText・measureText・font を使わない）
//   3. ワーカーのコードは、画面・DOM・ネットワークに依存しない（document・window・fetch・XMLHttpRequest・WebSocket が無い。react・next・画面の部品を import しない）。
//      送信（WebSocket）は #28
//   4. import.meta は、既定のワーカーの作り方（defaultWorker.ts）に限る（Jest が読み込めなくなるため）
//   5. 日本語の文字列リテラルを、コードに書かない（利用者に表示する文字列は、文言カタログへ。コメント・テストは対象外）。絵文字・ネイティブのダイアログも無い
//   6. 映像トラックを止めない（track.stop()・MediaStream の getTracks 系の呼び出しが無い）。トラックを止めるのは、SourceManager（#26）だけ
// テストのファイル（*.test.ts）と、テストの道具（test-support.ts・host-support.ts・loopback-support.ts）は走査しない。
// 走査器の自己検査（違反の例が、実際に検知されること）つき。走査が空振りしていないことも確かめる。
import fs from "node:fs";
import path from "node:path";
import ts from "typescript";
import { findEmoji, findJapaneseInCode, findNativeDialogCalls } from "@/lib/source-policy/detectors";

const FRONTEND_ROOT = path.resolve(__dirname, "../..");
const DIRECTORIES = ["lib/pipeline", "workers/pipeline"] as const;

interface Finding {
  readonly line: number;
  readonly rule: string;
  readonly text: string;
}

const WALL_CLOCK_AND_FRAME_TIMERS = ["Date", "performance", "requestAnimationFrame", "requestIdleCallback", "cancelAnimationFrame"];
const GLOBAL_TIMERS = ["setTimeout", "setInterval", "clearTimeout", "clearInterval"];
const DOM_AND_NETWORK = ["document", "window", "fetch", "XMLHttpRequest", "WebSocket", "localStorage", "sessionStorage"];
const TEXT_DRAWING_PROPERTIES = ["fillText", "strokeText", "measureText", "font"];
const GLOBAL_OBJECTS = ["globalThis", "self", "window"];
/** MediaStream から全トラックを取り出す呼び出し（止めるために使う）。パイプラインは、MediaStream に触れない */
const TRACK_COLLECTION_METHODS = ["getTracks", "getVideoTracks", "getAudioTracks"];

function parse(fileName: string, source: string): ts.SourceFile {
  return ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
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
      ts.isShorthandPropertyAssignment(parent) ||
      ts.isPropertySignature(parent) ||
      ts.isMethodSignature(parent) ||
      ts.isPropertyDeclaration(parent) ||
      ts.isMethodDeclaration(parent) ||
      ts.isGetAccessorDeclaration(parent) ||
      ts.isSetAccessorDeclaration(parent) ||
      ts.isEnumMember(parent) ||
      ts.isParameter(parent) ||
      ts.isBindingElement(parent)) &&
    parent.name === identifier
  ) {
    return true;
  }
  return ts.isBindingElement(parent) && parent.propertyName === identifier;
}

interface Rules {
  readonly forbiddenIdentifiers: ReadonlySet<string>;
  readonly forbiddenProperties: ReadonlySet<string>;
  /** グローバルオブジェクト（globalThis・self・window）の、これらのプロパティの参照を禁じる */
  readonly forbiddenGlobalMembers: ReadonlySet<string>;
  readonly forbiddenModulePrefixes: readonly string[];
  readonly forbidImportMeta: boolean;
}

function set(...values: string[]): ReadonlySet<string> {
  return new Set(values);
}

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
      if (ts.isIdentifier(node.expression) && GLOBAL_OBJECTS.includes(node.expression.text) && rules.forbiddenGlobalMembers.has(node.name.text)) {
        findings.push({ line: lineOf(sourceFile, node), rule: "forbidden global member", text: `${node.expression.text}.${node.name.text}` });
      }
      if (ts.isIdentifier(node.expression) && node.expression.text === "Math" && node.name.text === "random") {
        findings.push({ line: lineOf(sourceFile, node), rule: "forbidden member", text: "Math.random" });
      }
    }
    if (ts.isElementAccessExpression(node) && ts.isStringLiteralLike(node.argumentExpression) && rules.forbiddenProperties.has(node.argumentExpression.text)) {
      findings.push({ line: lineOf(sourceFile, node), rule: "forbidden property", text: node.argumentExpression.text });
    }
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
      const method = node.expression.name.text;
      const receiver = node.expression.expression.getText(sourceFile);
      if ((method === "stop" && /track/i.test(receiver)) || TRACK_COLLECTION_METHODS.includes(method)) {
        findings.push({ line: lineOf(sourceFile, node), rule: "track stop", text: `${receiver}.${method}` });
      }
    }
    if (rules.forbidImportMeta && ts.isMetaProperty(node) && node.keywordToken === ts.SyntaxKind.ImportKeyword) {
      findings.push({ line: lineOf(sourceFile, node), rule: "import.meta", text: "import.meta" });
    }
    if (ts.isImportDeclaration(node) && ts.isStringLiteral(node.moduleSpecifier)) {
      const specifier = node.moduleSpecifier.text;
      if (rules.forbiddenModulePrefixes.some((prefix) => specifier === prefix || specifier.startsWith(`${prefix}/`))) {
        findings.push({ line: lineOf(sourceFile, node), rule: "forbidden import", text: specifier });
      }
    }
  });
  return findings;
}

const COMMON_RULES: Rules = {
  forbiddenIdentifiers: set(...WALL_CLOCK_AND_FRAME_TIMERS, ...GLOBAL_TIMERS, ...DOM_AND_NETWORK),
  forbiddenProperties: set(...TEXT_DRAWING_PROPERTIES),
  forbiddenGlobalMembers: set(...GLOBAL_TIMERS, ...WALL_CLOCK_AND_FRAME_TIMERS),
  forbiddenModulePrefixes: ["react", "react-dom", "next", "@/components", "@/app"],
  forbidImportMeta: true,
};

/** 既定のタイマの定義（timers.ts）だけが、大域のタイマ（globalThis.setTimeout・clearTimeout）を参照してよい。 */
const TIMERS_FILE_RULES: Rules = { ...COMMON_RULES, forbiddenGlobalMembers: set(...WALL_CLOCK_AND_FRAME_TIMERS) };
/** 既定のワーカーの作り方（defaultWorker.ts）だけが、import.meta を使ってよい。 */
const DEFAULT_WORKER_FILE_RULES: Rules = { ...COMMON_RULES, forbidImportMeta: false };

function rulesFor(relativePath: string): Rules {
  if (relativePath === "lib/pipeline/timers.ts") {
    return TIMERS_FILE_RULES;
  }
  if (relativePath === "lib/pipeline/defaultWorker.ts") {
    return DEFAULT_WORKER_FILE_RULES;
  }
  return COMMON_RULES;
}

const SUPPORT_FILES = new Set(["test-support.ts", "host-support.ts", "loopback-support.ts"]);

function listRuntimeFiles(directory: string): string[] {
  return fs
    .readdirSync(path.join(FRONTEND_ROOT, directory), { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts") && !SUPPORT_FILES.has(entry.name))
    .map((entry) => `${directory}/${entry.name}`)
    .sort();
}

function read(relativePath: string): string {
  return fs.readFileSync(path.join(FRONTEND_ROOT, relativePath), "utf8");
}

const RUNTIME_FILES = DIRECTORIES.flatMap(listRuntimeFiles);

describe("走査器の自己検査（違反の例を、実際に検知する）", () => {
  it("実時計・画面の描画周期・大域のタイマの参照を検知する。プロパティの名前・コメント・文字列は、対象外", () => {
    const violating = "const a = Date.now(); const b = performance.now(); requestAnimationFrame(() => 1); setTimeout(() => 1, 1); setInterval(() => 1, 1);";
    const allowed = "const env = { setTimeout: 1 }; env.setTimeout; this.timers.setTimeout(); // Date.now() in a comment\nconst text = 'Date.now()';";

    expect(scanSource("x.ts", violating, COMMON_RULES).map((finding) => finding.text)).toEqual(["Date", "performance", "requestAnimationFrame", "setTimeout", "setInterval"]);
    expect(scanSource("x.ts", allowed, COMMON_RULES)).toEqual([]);
  });

  it("globalThis・self・window 経由のタイマ・実時計も検知する（timers.ts の規則だけが、タイマを許す）", () => {
    const source = "globalThis.setTimeout(f, 1); self.setInterval(f, 1); window.clearTimeout(h); globalThis.performance.now();";

    expect(scanSource("x.ts", source, COMMON_RULES).map((finding) => finding.text)).toEqual(
      expect.arrayContaining(["globalThis.setTimeout", "self.setInterval", "window.clearTimeout", "globalThis.performance"]),
    );
    expect(scanSource("x.ts", "globalThis.setTimeout(f, 1); globalThis.performance.now();", TIMERS_FILE_RULES).map((finding) => finding.text)).toEqual(["globalThis.performance"]);
  });

  it("文字を描く API（fillText・strokeText・measureText・font）を検知する", () => {
    const source = "ctx.fillText('a', 0, 0); ctx.strokeText('a', 0, 0); ctx.measureText('a'); ctx.font = '12px sans-serif'; ctx['fillText']('a', 0, 0);";

    expect(scanSource("x.ts", source, COMMON_RULES).map((finding) => finding.text)).toEqual(["fillText", "strokeText", "measureText", "font", "fillText"]);
  });

  it("画面・DOM・ネットワークの参照、画面の部品の import、Math.random、import.meta を検知する", () => {
    const source = "import { x } from 'react'; import { y } from '@/components/ui'; document.title; window.alert; fetch('u'); new WebSocket('u'); Math.random(); const u = import.meta.url;";

    const found = scanSource("x.ts", source, COMMON_RULES);

    expect(found.map((finding) => finding.rule)).toEqual(
      expect.arrayContaining(["forbidden import", "forbidden identifier", "forbidden member", "import.meta"]),
    );
    expect(found.filter((finding) => finding.rule === "forbidden import")).toHaveLength(2);
    expect(scanSource("x.ts", "const u = import.meta.url;", DEFAULT_WORKER_FILE_RULES)).toEqual([]);
  });

  it("トラックの停止（track.stop()・getTracks 系）を検知する。ワーカーのポンプ・タイマの stop は、対象外", () => {
    const violating = "track.stop(); this.cameraTrack.stop(); source.track.stop(); stream.getTracks().forEach((t) => t.stop()); s.getVideoTracks(); s.getAudioTracks();";
    const allowed = "pump.stop(); this.ticker.stop(); const track = null; // track.stop()\nconst text = 'track.stop()';";

    expect(scanSource("x.ts", violating, COMMON_RULES).map((finding) => finding.text)).toEqual(["track.stop", "this.cameraTrack.stop", "source.track.stop", "stream.getTracks", "s.getVideoTracks", "s.getAudioTracks"]);
    expect(scanSource("x.ts", allowed, COMMON_RULES)).toEqual([]);
  });

  it("日本語のリテラル・絵文字・ネイティブのダイアログを検知する（既存の方針の検知器）", () => {
    expect(findJapaneseInCode("x.ts", "const a = 'あ';")).toHaveLength(1);
    expect(findJapaneseInCode("x.ts", "// あ\nconst a = 'a';")).toEqual([]);
    expect(findEmoji(String.fromCodePoint(0x1f600))).toHaveLength(1);
    expect(findNativeDialogCalls("x.ts", "alert('a');")).toHaveLength(1);
  });
});

describe("走査の対象", () => {
  it("lib/pipeline と workers/pipeline の主要なファイルが含まれる（走査が空振りしていない）。テストの道具は含まない", () => {
    expect(RUNTIME_FILES).toEqual(
      expect.arrayContaining([
        "lib/pipeline/PipelineClient.ts",
        "lib/pipeline/drawPlan.ts",
        "lib/pipeline/encoderConfig.ts",
        "lib/pipeline/defaultWorker.ts",
        "lib/pipeline/timers.ts",
        "lib/pipeline/sourceBridge.ts",
        "workers/pipeline/PipelineHost.ts",
        "workers/pipeline/VideoCompositor.ts",
        "workers/pipeline/VideoEncoderPipeline.ts",
        "workers/pipeline/AudioEncoderPipeline.ts",
        "workers/pipeline/FrameStore.ts",
        "workers/pipeline/PreviewTicker.ts",
        "workers/pipeline/pipeline.worker.ts",
      ]),
    );
    expect(RUNTIME_FILES.some((file) => file.endsWith(".test.ts") || file.includes("test-support") || file.includes("host-support") || file.includes("loopback-support"))).toBe(false);
    expect(RUNTIME_FILES.length).toBeGreaterThan(20);
  });
});

describe("実行時のコード", () => {
  it("実時計・画面の描画周期を使わない。大域のタイマは、既定のタイマの定義（timers.ts）だけ。時刻は、音声の累積サンプル数だけから決まる", () => {
    const findings = RUNTIME_FILES.flatMap((file) =>
      scanSource(file, read(file), rulesFor(file))
        .filter((finding) => ["forbidden identifier", "forbidden global member", "forbidden member"].includes(finding.rule))
        .map((finding) => `${file}:${finding.line} ${finding.rule}: ${finding.text}`),
    );

    expect(findings).toEqual([]);
  });

  it("映像トラックを止めない（止めるのは SourceManager。#26）。MediaStream から全トラックを取り出す呼び出しも無い", () => {
    const findings = RUNTIME_FILES.flatMap((file) =>
      scanSource(file, read(file), rulesFor(file))
        .filter((finding) => finding.rule === "track stop")
        .map((finding) => `${file}:${finding.line} ${finding.text}`),
    );

    expect(findings).toEqual([]);
  });

  it("文字を描かない（代替スレート・プレビュー）", () => {
    const findings = RUNTIME_FILES.flatMap((file) =>
      scanSource(file, read(file), rulesFor(file))
        .filter((finding) => finding.rule === "forbidden property")
        .map((finding) => `${file}:${finding.line} ${finding.text}`),
    );

    expect(findings).toEqual([]);
  });

  it("画面の部品・react・next を import しない。import.meta は、既定のワーカーの作り方だけ", () => {
    const findings = RUNTIME_FILES.flatMap((file) =>
      scanSource(file, read(file), rulesFor(file))
        .filter((finding) => finding.rule === "forbidden import" || finding.rule === "import.meta")
        .map((finding) => `${file}:${finding.line} ${finding.rule}: ${finding.text}`),
    );

    expect(findings).toEqual([]);
    expect(scanSource("lib/pipeline/defaultWorker.ts", read("lib/pipeline/defaultWorker.ts"), COMMON_RULES).some((finding) => finding.rule === "import.meta")).toBe(true);
  });

  it("日本語の文字列リテラルを持たない（利用者に表示する文字列は、文言カタログへ。コメントは対象外）", () => {
    const findings = RUNTIME_FILES.flatMap((file) => findJapaneseInCode(file, read(file)).map((finding) => `${file}:${finding.line} ${finding.text}`));

    expect(findings).toEqual([]);
  });

  it("絵文字を使わない・ネイティブの alert・confirm・prompt を使わない（テスト・テストの道具も含めて、2 つのディレクトリ全体）", () => {
    const everything = DIRECTORIES.flatMap((directory) =>
      fs
        .readdirSync(path.join(FRONTEND_ROOT, directory), { withFileTypes: true })
        .filter((entry) => entry.isFile() && entry.name.endsWith(".ts"))
        .map((entry) => `${directory}/${entry.name}`),
    );

    const emoji = everything.flatMap((file) => findEmoji(read(file)).map((finding) => `${file}:${finding.line}`));
    const dialogs = everything.flatMap((file) => findNativeDialogCalls(file, read(file)).map((finding) => `${file}:${finding.line}`));

    expect(emoji).toEqual([]);
    expect(dialogs).toEqual([]);
  });
});
