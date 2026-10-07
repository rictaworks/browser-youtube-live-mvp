// サーバーコンポーネントとクライアントコンポーネントの境界の検知（Next.js App Router）。
// イベントハンドラー（onClick など）・状態を持つフック（useState・useEffect・usePathname など）を使うファイルは、
// 先頭に "use client" が要る。無いと、サーバーコンポーネントとして描画されて、実行時に失敗する
// （「Event handlers cannot be passed to Client Component props」）。ユニットテスト（jsdom）では、この失敗が現れないため、静的に検知する。
// ファイルは読まない（リポジトリ全体への適用は repository.test.ts）。

import ts from "typescript";
import type { PolicyFinding } from "./detectors";

// サーバーコンポーネントでも使える useId・use は含めない
const CLIENT_ONLY_HOOKS: ReadonlySet<string> = new Set([
  "useState",
  "useReducer",
  "useEffect",
  "useLayoutEffect",
  "useInsertionEffect",
  "useRef",
  "useMemo",
  "useCallback",
  "useContext",
  "useImperativeHandle",
  "useSyncExternalStore",
  "useTransition",
  "useDeferredValue",
  "useOptimistic",
  "useActionState",
  "usePathname",
  "useRouter",
  "useSearchParams",
  "useParams",
  "useSelectedLayoutSegment",
  "useSelectedLayoutSegments",
]);

const EVENT_HANDLER_ATTRIBUTE = /^on[A-Z]/;

function parseSource(fileName: string, source: string): ts.SourceFile {
  const scriptKind = fileName.endsWith(".tsx") ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  return ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, scriptKind);
}

function walk(node: ts.Node, visit: (node: ts.Node) => void): void {
  visit(node);
  ts.forEachChild(node, (child) => walk(child, visit));
}

/** ファイルの先頭（import より前）に、"use client" のディレクティブがあるか。 */
export function hasUseClientDirective(fileName: string, source: string): boolean {
  const sourceFile = parseSource(fileName, source);
  for (const statement of sourceFile.statements) {
    if (!ts.isExpressionStatement(statement) || !ts.isStringLiteral(statement.expression)) {
      return false;
    }
    if (statement.expression.text === "use client") {
      return true;
    }
  }
  return false;
}

/** イベントハンドラーの属性（onClick など）と、クライアントでしか動かないフックの呼び出しを返す。 */
export function findClientOnlyFeatures(fileName: string, source: string): PolicyFinding[] {
  const sourceFile = parseSource(fileName, source);
  const findings: PolicyFinding[] = [];
  const add = (node: ts.Node) => {
    const { line, character } = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile));
    findings.push({ line: line + 1, column: character + 1, text: node.getText(sourceFile).replace(/\s+/g, " ").slice(0, 80) });
  };
  walk(sourceFile, (node) => {
    if (ts.isJsxAttribute(node) && ts.isIdentifier(node.name) && EVENT_HANDLER_ATTRIBUTE.test(node.name.text)) {
      add(node);
    } else if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && CLIENT_ONLY_HOOKS.has(node.expression.text)) {
      add(node);
    }
  });
  return findings;
}
