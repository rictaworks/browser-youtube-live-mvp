/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { clientAppEnvironment } from "./client-environment";

// ブラウザで動くコードの環境の判定。Next.js は、ブラウザ向けのコードの process.env.NODE_ENV（リテラルの参照）だけを、ビルド時に値へ置き換える。
// process.env というオブジェクトを渡して読む形（lib/app-environment.ts の currentAppEnvironment）は、ブラウザでは空になり、例外になる。

const env = process.env as Record<string, string | undefined>;
const saved = env.NODE_ENV;

afterEach(() => {
  env.NODE_ENV = saved;
});

describe("clientAppEnvironment", () => {
  it.each(["development", "test", "production"] as const)("NODE_ENV が %s なら、その環境", (value) => {
    env.NODE_ENV = value;

    expect(clientAppEnvironment()).toBe(value);
  });

  it("未知の値は、既定の環境へ倒さず、例外にする", () => {
    env.NODE_ENV = "staging";

    expect(() => clientAppEnvironment()).toThrow("staging");
  });
});

describe("ブラウザで動くコードは、環境を、リテラルの process.env.NODE_ENV で読む", () => {
  // このタスクのブラウザ向けのモジュール（"use client" の配下で呼ばれる）。currentAppEnvironment() は、ブラウザで例外になるため、使わない
  const CLIENT_SIDE_FILES = ["lib/api/navigation.ts", "lib/recaptcha/RecaptchaProvider.tsx"];

  it.each(CLIENT_SIDE_FILES)("%s は、currentAppEnvironment を使わない", (file) => {
    const source = fs.readFileSync(path.resolve(__dirname, "../..", file), "utf8");

    expect(source).not.toContain("currentAppEnvironment");
    expect(source).toContain("clientAppEnvironment");
  });

  it("clientAppEnvironment は、リテラルの process.env.NODE_ENV を読む（process.env オブジェクトを渡さない）", () => {
    // コメント（説明の文章）を除いた、コードだけを調べる
    const code = fs
      .readFileSync(path.resolve(__dirname, "client-environment.ts"), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/\/\/.*$/gm, "");

    expect(code).toContain("process.env.NODE_ENV");
    expect(code).not.toMatch(/currentAppEnvironment\s*\(/);
  });
});
