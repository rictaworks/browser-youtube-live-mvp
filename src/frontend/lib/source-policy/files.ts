// 検知の対象のファイルを列挙する（リポジトリの読み取りだけ。ファイルの作成・変更・削除はしない）。
import fs from "node:fs";
import path from "node:path";

/** 降りないディレクトリ: 依存・ビルドの出力・キャッシュ・テストの出力（このプロジェクトの成果物ではない） */
export const SKIPPED_DIRECTORIES: readonly string[] = ["node_modules", ".next", ".cache", ".swc", "coverage", "out", "build"];

/**
 * root の下のすべてのファイルを、root からの相対パス（/ 区切り）で、ソートして返す。
 * SKIPPED_DIRECTORIES へは降りない。シンボリックリンクは辿らない。root が無ければ例外（空の結果で素通りさせない）。
 */
export function listFiles(root: string): string[] {
  const found: string[] = [];
  const visit = (relativeDirectory: string): void => {
    for (const entry of fs.readdirSync(path.join(root, relativeDirectory), { withFileTypes: true })) {
      const relativePath = relativeDirectory === "" ? entry.name : `${relativeDirectory}/${entry.name}`;
      if (entry.isDirectory()) {
        if (!SKIPPED_DIRECTORIES.includes(entry.name)) {
          visit(relativePath);
        }
      } else if (entry.isFile()) {
        found.push(relativePath);
      }
    }
  };
  visit("");
  return found.sort();
}
