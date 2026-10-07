// CSS の宣言（プロパティと値）を、ファイルの文字列から読む簡易の読み取り。
// 配色の検査（どのトークンを、どの用途で使っているか）と、値の直書きの検知が使う（実行時の画面は使わない）。
// CSS Modules・グローバル CSS の、ネストしない普通の書き方だけを対象にする（プリプロセッサーの記法は扱わない）。

export interface CssDeclaration {
  /** 小文字にそろえたプロパティ名（カスタムプロパティを含む） */
  readonly property: string;
  readonly value: string;
  /** 宣言の始まりの行（1 始まり） */
  readonly line: number;
}

const COMMENT_PATTERN = /\/\*[\s\S]*?\*\//g;
// セレクターの疑似クラス（a:hover { ）や @media の条件は、値のあとが「{」なので、先読みで除く
const DECLARATION_PATTERN = /([A-Za-z-]+)\s*:\s*([^;{}]+?)\s*(?=;|\})/g;
const VAR_REFERENCE_PATTERN = /var\(\s*(--[A-Za-z0-9_-]+)/g;

/** コメントを、同じ長さの空白（改行は残す）へ置き換える。行番号を保つため。 */
function blankOutComments(css: string): string {
  return css.replace(COMMENT_PATTERN, (comment) => comment.replace(/[^\n]/g, " "));
}

export function parseDeclarations(css: string): CssDeclaration[] {
  const text = blankOutComments(css);
  const declarations: CssDeclaration[] = [];
  for (const match of text.matchAll(DECLARATION_PATTERN)) {
    const index = match.index ?? 0;
    declarations.push({
      property: match[1].toLowerCase(),
      value: match[2],
      line: text.slice(0, index).split("\n").length,
    });
  }
  return declarations;
}

/** 値の中の var(--name) の名前を、出現順に返す（フォールバックの有無に依らない）。 */
export function tokensReferencedBy(value: string): string[] {
  return Array.from(value.matchAll(VAR_REFERENCE_PATTERN), (match) => match[1]);
}

/**
 * 値を、括弧の外の空白・カンマで区切った要素に分ける。
 * 関数（var(--a, b)・calc(...)）は、中の空白・カンマで区切らず、1 つの要素として残す。
 */
export function splitValueTokens(value: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let depth = 0;
  for (const character of value) {
    if (character === "(") {
      depth += 1;
    } else if (character === ")") {
      depth -= 1;
    }
    if (depth === 0 && (/\s/.test(character) || character === ",")) {
      if (current !== "") {
        tokens.push(current);
        current = "";
      }
    } else {
      current += character;
    }
  }
  if (current !== "") {
    tokens.push(current);
  }
  return tokens;
}
