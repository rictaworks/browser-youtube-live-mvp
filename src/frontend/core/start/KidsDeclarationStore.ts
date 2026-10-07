// 子ども向けの申告の記憶（requirements.md 9.1・16.3）。
// 申告は、初回は未選択とし、利用者の明示的な選択を必須とする。選択はブラウザ内に記憶し、次回以降の初期値として表示する。
//   - 記憶の場所は、注入するストレージ（Web Storage の形。本物の localStorage をそのまま渡せる）
//   - 読めない（ストレージが無い・例外）・壊れている（"true"・"false" 以外）ときは、未選択（null）として扱う。
//     利用者に、明示的な選択をさせる側へ倒す。誤った値を、初期値にしない
//   - 書けなかったときは false を返す（例外にしない）。選択の記憶は、配信の開始を妨げない。記憶できなかったことは、呼び出し側が知れる

/** ストレージ（Web Storage の getItem・setItem の形）。 */
export interface KeyValueStorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/** 記憶に使うキー（ASCII の固定値）。 */
export const KIDS_DECLARATION_STORAGE_KEY = "bl.kids-declaration";

const STORED_YES = "true";
const STORED_NO = "false";

export class KidsDeclarationStore {
  constructor(
    private readonly storage: KeyValueStorageLike | null | undefined,
    private readonly key: string = KIDS_DECLARATION_STORAGE_KEY,
  ) {}

  /** 前回の選択（はい = true・いいえ = false）。記憶が無い・読めない・壊れているときは、未選択（null）。 */
  read(): boolean | null {
    if (this.storage === null || this.storage === undefined) {
      return null;
    }
    let stored: string | null;
    try {
      stored = this.storage.getItem(this.key);
    } catch {
      return null;
    }
    if (stored === STORED_YES) {
      return true;
    }
    if (stored === STORED_NO) {
      return false;
    }
    return null;
  }

  /**
   * 選択を記憶する。記憶できたら true。ストレージが無い・例外のときは false（例外にしない）。
   * 真偽値でない値（未選択を表す null・undefined を含む）は、記憶として書かず RangeError。
   */
  write(madeForKids: boolean): boolean {
    if (typeof madeForKids !== "boolean") {
      throw new RangeError(`madeForKids must be a boolean: ${String(madeForKids)}`);
    }
    if (this.storage === null || this.storage === undefined) {
      return false;
    }
    try {
      this.storage.setItem(this.key, madeForKids ? STORED_YES : STORED_NO);
    } catch {
      return false;
    }
    return true;
  }
}
