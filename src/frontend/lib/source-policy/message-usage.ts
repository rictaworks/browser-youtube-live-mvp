// 文言カタログのキーの参照（t("キー") の呼び出しと、キーと同じ値の文字列のリテラル）を、ソースから集める。
// キーの存在の検査（呼び出しのキーが、カタログにあるか）と、未使用の検査（カタログのキーが、どこからも参照されていないか）が使う。
// ファイルは読まない（リポジトリ全体への適用は messages/usage.test.ts）。

import ts from "typescript";

export interface MessageKeyUsage {
  /** t("キー") の呼び出しの、キー（文字列のリテラル・置換の無いテンプレート） */
  readonly translated: readonly string[];
  /** t(`接頭辞${x}`) の、静的な接頭辞（その名前空間のキーは、すべて使われうる） */
  readonly dynamicPrefixes: readonly string[];
  /** ソースの中の、文字列のリテラルの値（キーを表やオブジェクトに書く使い方の参照を見つけるため） */
  readonly literals: readonly string[];
}

function walk(node: ts.Node, visit: (node: ts.Node) => void): void {
  visit(node);
  ts.forEachChild(node, (child) => walk(child, visit));
}

/** t(...) の呼び出し（識別子 t だけ。i18n.t(...) などのメソッドは対象にしない）。 */
function isTranslatorCall(node: ts.Node, translatorName: string): node is ts.CallExpression {
  return ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === translatorName;
}

export function collectMessageKeyUsage(fileName: string, source: string, translatorName = "t"): MessageKeyUsage {
  const scriptKind = fileName.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const sourceFile = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, scriptKind);
  const translated: string[] = [];
  const dynamicPrefixes: string[] = [];
  const literals: string[] = [];

  walk(sourceFile, (node) => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      literals.push(node.text);
    }
    if (!isTranslatorCall(node, translatorName) || node.arguments.length === 0) {
      return;
    }
    const [key] = node.arguments;
    if (ts.isStringLiteral(key) || ts.isNoSubstitutionTemplateLiteral(key)) {
      translated.push(key.text);
    } else if (ts.isTemplateExpression(key)) {
      if (key.head.text === "") {
        throw new RangeError(
          `${fileName}: ${translatorName}() is called with a fully dynamic key; give it a static prefix so that unused keys can be detected`,
        );
      }
      dynamicPrefixes.push(key.head.text);
    }
  });

  return { translated, dynamicPrefixes, literals };
}
