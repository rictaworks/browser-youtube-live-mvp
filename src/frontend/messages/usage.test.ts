/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { BRAND_NAME } from "@/config/brand";
import { findTextInCode } from "@/lib/source-policy/detectors";
import { listFiles } from "@/lib/source-policy/files";
import { collectMessageKeyUsage } from "@/lib/source-policy/message-usage";
import { flattenMessages } from "@/lib/messages";
import { ja } from "./index";

// 文言のキーの検査（リポジトリ全体）。
//   存在: t("キー") の呼び出しの、キーが、カタログにある
//   未使用: カタログのキーが、どこかで参照されている（後続の issue が文言を足すとき、使わない文言を残さない）
// 参照を数えるのは、文言のカタログ（messages/）とテストの外のソース。

const PROJECT_ROOT = path.resolve(__dirname, "..");
const catalogKeys = Object.keys(flattenMessages(ja));

const sourceFiles = listFiles(PROJECT_ROOT).filter(
  (file) => /\.tsx?$/.test(file) && !/\.test\.tsx?$/.test(file) && !file.startsWith("messages/"),
);

const usages = sourceFiles.map((file) => ({
  file,
  usage: collectMessageKeyUsage(file, fs.readFileSync(path.join(PROJECT_ROOT, file), "utf8")),
}));

describe("文言のキーの存在", () => {
  it("t() の呼び出しが、1 件以上ある（走査が空振りしていない）", () => {
    expect(usages.flatMap(({ usage }) => usage.translated).length).toBeGreaterThan(0);
  });

  it("t(\"キー\") の、すべてのキーが、カタログにある", () => {
    const missing = usages.flatMap(({ file, usage }) =>
      usage.translated.filter((key) => !catalogKeys.includes(key)).map((key) => `${file}: ${key}`),
    );

    expect(missing).toEqual([]);
  });

  it("動的なキーの接頭辞は、カタログのキーのどれかに一致する", () => {
    const unmatched = usages.flatMap(({ file, usage }) =>
      usage.dynamicPrefixes.filter((prefix) => !catalogKeys.some((key) => key.startsWith(prefix))).map((prefix) => `${file}: ${prefix}`),
    );

    expect(unmatched).toEqual([]);
  });
});

describe("文言のキーの未使用", () => {
  const referencedLiterals = new Set(usages.flatMap(({ usage }) => usage.literals));
  const dynamicPrefixes = usages.flatMap(({ usage }) => usage.dynamicPrefixes);

  it("カタログのキーは、すべて参照されている（呼び出し・キーを書いた表・動的なキーの接頭辞）", () => {
    const unused = catalogKeys.filter(
      (key) => !referencedLiterals.has(key) && !dynamicPrefixes.some((prefix) => key.startsWith(prefix)),
    );

    expect(unused).toEqual([]);
  });
});

describe("製品名（brand.name）は、設定の定数 1 か所", () => {
  it("製品名の文字列は、config/brand.ts のほか、文言カタログ・ソースのどこにも書かれていない（コメントを除く）", () => {
    const files = listFiles(PROJECT_ROOT).filter(
      (file) => /\.(ts|tsx)$/.test(file) && !/\.test\.tsx?$/.test(file) && /^(app|components|lib|messages|config|core)\//.test(file),
    );

    const containing = files.filter(
      (file) => findTextInCode(file, fs.readFileSync(path.join(PROJECT_ROOT, file), "utf8"), BRAND_NAME).length > 0,
    );

    expect(containing).toEqual(["config/brand.ts"]);
  });
});
