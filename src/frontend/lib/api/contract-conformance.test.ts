/**
 * @jest-environment node
 */
import fs from "node:fs";
import path from "node:path";
import { API_ENDPOINTS } from "./config";
import { API_ERROR_CODES } from "./error-codes";

// API クライアントの、エンドポイントとエラーの符号が、契約（src/contracts/http-api.md）と一致すること（両方向）。
// 契約のディレクトリは、core/contract/contract.test.ts と同じ順に探す（/contracts・../contracts・../../contracts・相対パス）。

const CANDIDATES = [
  "/contracts",
  path.resolve(process.cwd(), "../contracts"),
  path.resolve(process.cwd(), "../../contracts"),
  path.resolve(__dirname, "../../../contracts"),
];

function locateHttpApiDocument(): string {
  const found = CANDIDATES.map((dir) => path.join(dir, "http-api.md")).find((file) => fs.existsSync(file));
  if (found === undefined) {
    throw new Error(`http-api.md was not found. searched: ${CANDIDATES.join(", ")}`);
  }
  return fs.readFileSync(found, "utf8");
}

const document = locateHttpApiDocument();

describe("エンドポイント（契約 3 章の見出し）", () => {
  const documented = Array.from(document.matchAll(/^### `(GET|POST|PUT|PATCH|DELETE) (\/api\/[^`]+)`$/gm), (match) => `${match[1]} ${match[2]}`).sort();
  const implemented = Object.values(API_ENDPOINTS)
    .map((endpoint) => `${endpoint.method} ${endpoint.path}`)
    .sort();

  it("契約の見出しを、1 件以上、読み取れている（走査が空振りしていない）", () => {
    expect(documented.length).toBeGreaterThanOrEqual(15);
  });

  it("契約のすべてのエンドポイントが、クライアントの定義にある（ブラウザの遷移のコールバックを含む）", () => {
    expect(implemented).toEqual(documented);
  });

  it("コールバックの GET（認可コードの戻り先）だけが、クライアントの関数を持たない遷移（navigation）", () => {
    const navigation = Object.entries(API_ENDPOINTS)
      .filter(([, endpoint]) => "navigation" in endpoint && endpoint.navigation === true)
      .map(([, endpoint]) => endpoint.path)
      .sort();

    expect(navigation).toEqual(["/api/auth/callback", "/api/youtube/connect/callback"]);
  });
});

describe("エラーの符号（契約 1.6 の表）", () => {
  const section = document.slice(document.indexOf("### 1.6 エラーの形と種類"), document.indexOf("### 1.7 頻度制限"));
  const documented = Array.from(section.matchAll(/^\| `([a-z_]+)` \| \d{3} \|/gm), (match) => match[1]).sort();

  it("契約の表を、読み取れている（走査が空振りしていない）", () => {
    expect(documented.length).toBeGreaterThanOrEqual(16);
  });

  it("クライアントが知っている符号は、契約の表と一致する（両方向）", () => {
    expect([...API_ERROR_CODES].sort()).toEqual(documented);
  });
});
