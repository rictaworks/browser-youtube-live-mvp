/**
 * @jest-environment node
 */
// 既定のワーカーの作り方（issue #27）。Next.js のワーカーのバンドルは、new Worker(new URL("…", import.meta.url), { type: "module" }) の式を、
// 静的に解析して行う（Turbopack は、この式のワーカーの入り口と、そのモジュールの塊を、別に出力する）。式の形を変えると、バンドルされなくなる。
// import.meta は、Jest（CommonJS への変換）では構文エラーになるので、このファイルは、Jest が読み込む部品（index.ts など）から import しない。
// 実際にバンドルされ、実ブラウザで動くことは、test/ の確認（next build と Playwright の Chromium）が受け持つ。
import fs from "node:fs";
import path from "node:path";

const LIB_DIRECTORY = __dirname;
/** コメントの行を除いた、コードだけ（コメントの中の式の説明に、検査が反応しないように）。 */
function codeOf(file: string): string {
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("//"))
    .join("\n");
}
const SOURCE = codeOf(path.join(LIB_DIRECTORY, "defaultWorker.ts"));

describe("defaultWorker.ts", () => {
  it("new Worker(new URL(\"…\", import.meta.url), { type: \"module\" }) の式で、ワーカーを作る（Next.js が静的に解析できる形）", () => {
    const pattern = /new Worker\(\s*new URL\(\s*"([^"]+)"\s*,\s*import\.meta\.url\s*\)\s*,\s*\{\s*type:\s*"module"\s*\}\s*\)/;

    expect(SOURCE).toMatch(pattern);
  });

  it("URL の指すファイルが、実在する（ワーカーのスクリプト本体 workers/pipeline/pipeline.worker.ts）", () => {
    const match = /new URL\(\s*"([^"]+)"/.exec(SOURCE);
    expect(match).not.toBeNull();
    const target = path.resolve(LIB_DIRECTORY, match?.[1] ?? "");

    expect(path.relative(path.join(LIB_DIRECTORY, "..", ".."), target)).toBe(path.join("workers", "pipeline", "pipeline.worker.ts"));
    expect(fs.existsSync(target)).toBe(true);
  });

  it("公開の入り口（index.ts）は、defaultWorker を import・再公開しない（import.meta を含むため、Jest が読み込めなくなる）。使う側が、直接 import する", () => {
    const index = codeOf(path.join(LIB_DIRECTORY, "index.ts"));
    const withComments = fs.readFileSync(path.join(LIB_DIRECTORY, "index.ts"), "utf8");

    expect(index).not.toMatch(/defaultWorker/);
    expect(withComments).toMatch(/lib\/pipeline\/defaultWorker/);
  });

  it("ワーカーのスクリプト本体は、副作用として、入り口（startPipelineWorker）を 1 回呼ぶだけ", () => {
    const entry = codeOf(path.join(LIB_DIRECTORY, "..", "..", "workers", "pipeline", "pipeline.worker.ts"));

    expect(entry.match(/startPipelineWorker\(/g)).toHaveLength(1);
  });
});
