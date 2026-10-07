// ソースコードの方針違反（CLAUDE.md・IMPLEMENTER_GUIDE.md）を検知する純粋な関数。
//   - 日本語のリテラル（利用者に表示する文字列は、文言カタログ messages/ へ分離する）
//   - 絵文字（コード・テスト・文言・コメント・ドキュメントのすべてで使わない。アイコンは FontAwesome）
//   - alert()・confirm()・prompt()（ネイティブのダイアログは使わない。beforeunload は対象外）
// 検知の対象の選定（どのファイルへ適用するか）は repository.test.ts にある。ここはファイルを読まない。

import ts from "typescript";

export interface PolicyFinding {
  /** 1 始まり */
  readonly line: number;
  /** 1 始まり（UTF-16 の単位） */
  readonly column: number;
  /** 見つけた箇所のソース（長いものは切り詰める） */
  readonly text: string;
}

const MAX_FINDING_TEXT_LENGTH = 80;

// ひらがな・カタカナ（半角を含む）・漢字
const JAPANESE_PATTERN = new RegExp("[\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Han}]", "u");

// 絵文字: 絵柄の文字（Extended_Pictographic）・国旗（地域指示記号）・キーキャップ・絵文字表示の指定（VS16）。
// 著作権記号・登録商標記号・商標記号は、絵柄の文字に含まれるが、組版の記号なので除く。
const EMOJI_PATTERN = new RegExp(
  "\\p{Extended_Pictographic}|\\p{Regional_Indicator}|[0-9#*]\\uFE0F?\\u20E3|\\uFE0F",
  "gu",
);
const TYPOGRAPHIC_SYMBOLS = new Set(["©", "®", "™"]);

const NATIVE_DIALOG_NAMES: ReadonlySet<string> = new Set(["alert", "confirm", "prompt"]);
const GLOBAL_OBJECT_NAMES: ReadonlySet<string> = new Set(["window", "globalThis", "self"]);

function truncate(text: string): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > MAX_FINDING_TEXT_LENGTH ? `${oneLine.slice(0, MAX_FINDING_TEXT_LENGTH)}...` : oneLine;
}

function parseSource(fileName: string, sourceText: string): ts.SourceFile {
  const scriptKind = fileName.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  return ts.createSourceFile(fileName, sourceText, ts.ScriptTarget.Latest, true, scriptKind);
}

function walk(node: ts.Node, visit: (node: ts.Node) => void): void {
  visit(node);
  ts.forEachChild(node, (child) => walk(child, visit));
}

function findingAt(sourceFile: ts.SourceFile, node: ts.Node): PolicyFinding {
  const { line, character } = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile));
  return { line: line + 1, column: character + 1, text: truncate(node.getText(sourceFile)) };
}

/** 構文木の節のうち、ソースの文字そのもの（コメントを除く）を持つもの。 */
function sourceText(node: ts.Node): string | undefined {
  if (
    ts.isStringLiteral(node) ||
    ts.isNoSubstitutionTemplateLiteral(node) ||
    ts.isTemplateHead(node) ||
    ts.isTemplateMiddle(node) ||
    ts.isTemplateTail(node) ||
    ts.isRegularExpressionLiteral(node) ||
    ts.isIdentifier(node) ||
    ts.isPrivateIdentifier(node)
  ) {
    return node.text;
  }
  if (ts.isJsxText(node) && !node.containsOnlyTriviaWhiteSpaces) {
    return node.text;
  }
  return undefined;
}

/** コードの中の文字（文字列・テンプレート・JSX の文字・正規表現・識別子。コメントを除く）のうち、条件に合うものを返す。 */
function findInCodeText(fileName: string, source: string, matches: (text: string) => boolean): PolicyFinding[] {
  const sourceFile = parseSource(fileName, source);
  const findings: PolicyFinding[] = [];
  walk(sourceFile, (node) => {
    const text = sourceText(node);
    if (text !== undefined && matches(text)) {
      findings.push(findingAt(sourceFile, node));
    }
  });
  return findings;
}

/**
 * 日本語（ひらがな・カタカナ・漢字）を含む、文字列・テンプレート・JSX の文字・正規表現・識別子を返す。
 * コメントは対象にしない。文字列のエスケープ（\u65E5 など）は、展開した値で判定する。
 */
export function findJapaneseInCode(fileName: string, source: string): PolicyFinding[] {
  return findInCodeText(fileName, source, (text) => JAPANESE_PATTERN.test(text));
}

/** 指定の文字列（製品名など）を含む、コードの中の文字を返す。コメントは対象にしない。 */
export function findTextInCode(fileName: string, source: string, needle: string): PolicyFinding[] {
  return findInCodeText(fileName, source, (text) => text.includes(needle));
}

/** 文字列に含まれる絵文字を、位置つきで返す。コメントも対象にする。 */
export function findEmoji(text: string): PolicyFinding[] {
  const findings: PolicyFinding[] = [];
  for (const match of text.matchAll(EMOJI_PATTERN)) {
    if (TYPOGRAPHIC_SYMBOLS.has(match[0])) {
      continue;
    }
    const index = match.index ?? 0;
    const before = text.slice(0, index);
    const line = before.split("\n").length;
    const column = index - (before.lastIndexOf("\n") + 1) + 1;
    findings.push({ line, column, text: match[0] });
  }
  return findings;
}

function isNativeDialogCallee(callee: ts.Expression): boolean {
  if (ts.isIdentifier(callee)) {
    return NATIVE_DIALOG_NAMES.has(callee.text);
  }
  if (ts.isPropertyAccessExpression(callee)) {
    return (
      ts.isIdentifier(callee.expression) &&
      GLOBAL_OBJECT_NAMES.has(callee.expression.text) &&
      NATIVE_DIALOG_NAMES.has(callee.name.text)
    );
  }
  if (ts.isElementAccessExpression(callee)) {
    return (
      ts.isIdentifier(callee.expression) &&
      GLOBAL_OBJECT_NAMES.has(callee.expression.text) &&
      ts.isStringLiteralLike(callee.argumentExpression) &&
      NATIVE_DIALOG_NAMES.has(callee.argumentExpression.text)
    );
  }
  return false;
}

/**
 * alert()・confirm()・prompt() の呼び出し（window・globalThis・self 経由を含む）を返す。
 * 他のオブジェクトの同名のメソッド（dialog.confirm() など）・文字列・コメントは対象にしない。
 */
export function findNativeDialogCalls(fileName: string, source: string): PolicyFinding[] {
  const sourceFile = parseSource(fileName, source);
  const findings: PolicyFinding[] = [];
  walk(sourceFile, (node) => {
    if (ts.isCallExpression(node) && isNativeDialogCallee(node.expression)) {
      findings.push(findingAt(sourceFile, node));
    }
  });
  return findings;
}
