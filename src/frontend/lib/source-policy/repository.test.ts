/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { findClientOnlyFeatures, hasUseClientDirective } from "./client-boundary";
import { findEmoji, findJapaneseInCode, findNativeDialogCalls } from "./detectors";
import { listFiles } from "./files";

// リポジトリ（フロントエンド: src/frontend）全体への、方針の検知（CLAUDE.md・IMPLEMENTER_GUIDE.md）。
//   1. 利用者に表示する文字列を、コードに直書きしない（日本語のリテラルは、文言カタログ messages/ へ置く）
//   2. 絵文字を使わない（コード・テスト・文言・コメント・ドキュメント。アイコンは FontAwesome）
//   3. ネイティブの alert()・confirm()・prompt() を使わない（beforeunload の離脱確認は対象外）
//   4. イベントハンドラー・状態を持つフックを使う画面・部品は、先頭に "use client" を持つ（無いと、実行時に失敗する）
// 注: コンテナから見えるのは src/frontend だけ（backend・relay・contracts は、各層の検査で行う）。

const PROJECT_ROOT = path.resolve(__dirname, "../..");
const allFiles = listFiles(PROJECT_ROOT);

function read(relativePath: string): string {
  return fs.readFileSync(path.join(PROJECT_ROOT, relativePath), "utf8");
}

function isTypeScript(file: string): boolean {
  return /\.tsx?$/.test(file);
}

describe("日本語のリテラルを、文言カタログ（messages/）の外に置かない", () => {
  // 走査するディレクトリ。messages/（文言カタログ）は、日本語を置く場所なので、走査しない。
  // core/ は、別の issue（契約）が作る。走査の仕組みには含め、そこに日本語が無いことを前提にする。
  const SCANNED_DIRECTORIES = ["app", "components", "core", "lib", "config"];

  // 除外は最小にし、理由を付ける
  const EXCLUSIONS: readonly { readonly matches: (file: string) => boolean; readonly reason: string }[] = [
    {
      matches: (file) => /\.test\.tsx?$/.test(file),
      reason: "テストのファイル: テストの題・試験データであって、利用者に表示する文字列ではない（画面の文言は、テストでも t() で参照する）",
    },
    {
      matches: (file) => file === "config/brand.ts",
      reason: "製品名の定数: 将来、製品名が日本語になっても、この 1 か所だけが許される（CLAUDE.md U11）",
    },
  ];

  const targets = allFiles.filter(
    (file) =>
      isTypeScript(file) &&
      SCANNED_DIRECTORIES.some((directory) => file.startsWith(`${directory}/`)) &&
      !EXCLUSIONS.some((exclusion) => exclusion.matches(file)),
  );

  it("走査の対象に、app・components・lib のファイルが含まれる（走査が空振りしていない）", () => {
    for (const directory of ["app", "components", "lib"]) {
      expect(targets.some((file) => file.startsWith(`${directory}/`))).toBe(true);
    }
  });

  it("core/ を、走査のディレクトリに含める", () => {
    expect(SCANNED_DIRECTORIES).toContain("core");
  });

  it("除外は、テストのファイルと製品名の定数だけ（理由つき）", () => {
    expect(EXCLUSIONS).toHaveLength(2);
    for (const exclusion of EXCLUSIONS) {
      expect(exclusion.reason.length).toBeGreaterThan(10);
    }
  });

  it("検知は、実際のカタログのファイルの日本語を見つける（カタログの外へ置けば、失敗する）", () => {
    expect(findJapaneseInCode("messages/terms.ts", read("messages/terms.ts")).length).toBeGreaterThan(0);
  });

  it("走査の対象のファイルに、日本語のリテラルが無い", () => {
    const findings = targets.flatMap((file) =>
      findJapaneseInCode(file, read(file)).map((finding) => `${file}:${finding.line}:${finding.column} ${finding.text}`),
    );

    expect(findings).toEqual([]);
  });
});

describe("絵文字を使わない", () => {
  const EXTENSIONS = [".ts", ".tsx", ".js", ".mjs", ".cjs", ".css", ".md", ".json", ".html"];
  const targets = allFiles.filter((file) => EXTENSIONS.some((extension) => file.endsWith(extension)));

  it("走査の対象に、コード・スタイル・文書が含まれる（走査が空振りしていない）", () => {
    for (const extension of [".ts", ".tsx", ".css", ".md", ".json"]) {
      expect(targets.some((file) => file.endsWith(extension))).toBe(true);
    }
  });

  it("どのファイルにも、絵文字が無い", () => {
    const findings = targets.flatMap((file) =>
      findEmoji(read(file)).map((finding) => `${file}:${finding.line}:${finding.column} U+${finding.text.codePointAt(0)?.toString(16)}`),
    );

    expect(findings).toEqual([]);
  });
});

describe("ネイティブの alert()・confirm()・prompt() を使わない（beforeunload は対象外）", () => {
  const targets = allFiles.filter(isTypeScript);

  it("走査の対象に、app・components・lib のファイルが含まれる（走査が空振りしていない）", () => {
    for (const directory of ["app", "components", "lib"]) {
      expect(targets.some((file) => file.startsWith(`${directory}/`))).toBe(true);
    }
  });

  it("どのファイルにも、呼び出しが無い", () => {
    const findings = targets.flatMap((file) =>
      findNativeDialogCalls(file, read(file)).map((finding) => `${file}:${finding.line}:${finding.column} ${finding.text}`),
    );

    expect(findings).toEqual([]);
  });
});

describe("クライアントでしか動かない機能を使う画面・部品は、先頭に use client を持つ", () => {
  // jsdom のユニットテストでは、サーバーコンポーネントとしての描画の失敗（Event handlers cannot be passed to Client Component props）が
  // 現れないため、静的に検知する。対象は、画面（app/）と部品（components/）の .tsx
  const targets = allFiles.filter(
    (file) => /\.tsx$/.test(file) && !/\.test\.tsx$/.test(file) && (file.startsWith("app/") || file.startsWith("components/")),
  );

  it("走査の対象に、画面と部品が含まれる（走査が空振りしていない）", () => {
    expect(targets).toEqual(expect.arrayContaining(["app/layout.tsx", "components/ui/Button.tsx", "components/layout/NavLink.tsx"]));
  });

  it("検知は、実際のクライアントコンポーネントの機能を見つける", () => {
    expect(findClientOnlyFeatures("components/ui/Button.tsx", read("components/ui/Button.tsx")).length).toBeGreaterThan(0);
    expect(findClientOnlyFeatures("components/layout/NavLink.tsx", read("components/layout/NavLink.tsx")).length).toBeGreaterThan(0);
    expect(findClientOnlyFeatures("app/error.tsx", read("app/error.tsx")).length).toBeGreaterThan(0);
  });

  it("イベントハンドラー・フックを使うファイルは、すべて use client を持つ", () => {
    const missing = targets
      .filter((file) => findClientOnlyFeatures(file, read(file)).length > 0)
      .filter((file) => !hasUseClientDirective(file, read(file)));

    expect(missing).toEqual([]);
  });

  it("エラー境界（app/error.tsx）は、use client を持つ（Next.js の要件）", () => {
    expect(hasUseClientDirective("app/error.tsx", read("app/error.tsx"))).toBe(true);
  });
});

describe("検知の部品（lib/source-policy）は、テストからだけ使う", () => {
  // typescript（開発用の依存）と node:fs を使うため、画面・部品から import すると、本番のビルドへ巻き込まれる
  it("画面・部品・設定・文言・スタイルの、実行時のコードから import していない", () => {
    const offenders = allFiles
      .filter((file) => isTypeScript(file) && !/\.test\.tsx?$/.test(file) && !file.startsWith("lib/source-policy/"))
      .filter((file) => read(file).includes("source-policy"));

    expect(offenders).toEqual([]);
  });
});
