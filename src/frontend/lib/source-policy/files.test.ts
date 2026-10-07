/**
 * @jest-environment node
 */
import path from "node:path";
import { SKIPPED_DIRECTORIES, listFiles } from "./files";

const PROJECT_ROOT = path.resolve(__dirname, "../..");

describe("listFiles（検知の対象のファイルの列挙）", () => {
  const files = listFiles(PROJECT_ROOT);

  it("プロジェクトのファイルを、ルートからの相対パス（/ 区切り）で返す", () => {
    expect(files).toContain("package.json");
    expect(files).toContain("app/layout.tsx");
    expect(files).toContain("lib/source-policy/files.ts");
  });

  it("このテスト自身も含む（実際のファイルを走査している）", () => {
    expect(files).toContain("lib/source-policy/files.test.ts");
  });

  it("依存・ビルドの出力・キャッシュの置き場へは降りない", () => {
    for (const directory of SKIPPED_DIRECTORIES) {
      expect(files.filter((file) => file.startsWith(`${directory}/`))).toEqual([]);
    }
  });

  it("node_modules・.next・.cache を、降りない置き場に含む", () => {
    expect(SKIPPED_DIRECTORIES).toEqual(expect.arrayContaining(["node_modules", ".next", ".cache"]));
  });

  it("ソートして返す（実行ごとに順序が変わらない）", () => {
    expect(files).toEqual([...files].sort());
  });

  it("ディレクトリは含めない（ファイルだけ）", () => {
    expect(files).not.toContain("app");
    expect(files).not.toContain("lib");
  });

  it("存在しないディレクトリは、例外にする（空の結果にして、検知を素通りさせない）", () => {
    expect(() => listFiles(path.join(PROJECT_ROOT, "no-such-directory"))).toThrow();
  });
});
