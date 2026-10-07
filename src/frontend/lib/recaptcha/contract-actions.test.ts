/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { RECAPTCHA_ACTIONS } from "./config";

// 行為名（reCAPTCHA の action）が、契約（src/contracts/http-api.md 1.8 の表）と一致すること（両方向）。

const CANDIDATES = [
  "/contracts",
  path.resolve(process.cwd(), "../contracts"),
  path.resolve(process.cwd(), "../../contracts"),
  path.resolve(__dirname, "../../../contracts"),
];

function readDocument(): string {
  const found = CANDIDATES.map((dir) => path.join(dir, "http-api.md")).find((file) => fs.existsSync(file));
  if (found === undefined) {
    throw new Error(`http-api.md was not found. searched: ${CANDIDATES.join(", ")}`);
  }
  return fs.readFileSync(found, "utf8");
}

describe("reCAPTCHA の行為名（契約 1.8）", () => {
  const document = readDocument();
  const section = document.slice(document.indexOf("### 1.8 bot 判定"), document.indexOf("## 2. 共通の型"));
  const documented = Object.fromEntries(
    Array.from(section.matchAll(/^\| `POST (\/api\/[^`]+)` \| `([a-z_]+)` \|$/gm), (match) => [match[1], match[2]]),
  );

  it("契約の表（エンドポイントと行為名）を、読み取れている（走査が空振りしていない）", () => {
    expect(Object.keys(documented)).toHaveLength(3);
  });

  it("ログインの開始・YouTube 接続の開始・配信の開始要求に、契約の行為名を使う", () => {
    expect(documented).toEqual({
      "/api/auth/login/start": RECAPTCHA_ACTIONS.login,
      "/api/youtube/connect/start": RECAPTCHA_ACTIONS.youtubeConnect,
      "/api/broadcasts": RECAPTCHA_ACTIONS.broadcastStart,
    });
  });
});
