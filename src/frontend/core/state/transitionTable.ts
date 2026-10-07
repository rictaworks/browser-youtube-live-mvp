// 状態機械の遷移表の共通部品（スタジオ 25.3・ソース 25.5）。状態ごとに、事象 -> 次の状態の表を持つ。
// 表は、すべての状態の行を持つことを、型で強制する（状態の追加で、行の書き忘れがコンパイルエラーになる）。
// 表に無い（状態, 事象）の組は、「定義のない組」で、状態を変えない（25.1・25.3・25.5・15 章）。

/** 状態ごとの、事象 -> 次の状態。 */
export type TransitionTable<State extends string, Event extends string> = Readonly<
  Record<State, Readonly<Partial<Record<Event, State>>>>
>;

/** 遷移表を作る。実行時にも変更できないよう、行も表も凍結する。 */
export function defineTransitions<State extends string, Event extends string>(
  table: Record<State, Partial<Record<Event, State>>>,
): TransitionTable<State, Event> {
  for (const row of Object.values<Partial<Record<Event, State>>>(table)) {
    Object.freeze(row);
  }
  return Object.freeze(table);
}

/** 表を引いて、次の状態を返す。表に無い組は、状態を変えない（現在の状態を返す）。 */
export function lookupNextState<State extends string, Event extends string>(
  table: TransitionTable<State, Event>,
  state: State,
  event: Event,
): State {
  return table[state][event] ?? state;
}
