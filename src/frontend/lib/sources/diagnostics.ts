// 診断（デバッグでたどるための記録）の出力先。ソースの取得と音声の混合が、何が・どの種別で・なぜ失敗したかを、この形で出す。
// 項目は、文字列・数値・真偽・null だけ。デバイス名・ラベル・デバイスの識別子・トークンなど、機微な値は、呼び出し側が入れない
// （ログ・測定イベント・中継へ出さない。requirements.md 11.2・CLAUDE.md の不変条件）。

export type DiagnosticFields = Readonly<Record<string, string | number | boolean | null>>;

/** 診断の出力先。event は、出来事の名前（英小文字と _ だけ）。 */
export type DiagnosticSink = (event: string, fields: DiagnosticFields) => void;

/** 何も出力しない出力先（既定）。 */
export const NO_DIAGNOSTICS: DiagnosticSink = () => undefined;

/** console.debug へ、1 行（接頭辞: 出来事の名前 項目の JSON）で出力する出力先を作る。 */
export function createConsoleDiagnosticSink(prefix: string, output: Pick<Console, "debug"> = console): DiagnosticSink {
  return (event, fields) => {
    output.debug(`${prefix}: ${event} ${JSON.stringify(fields)}`);
  };
}
