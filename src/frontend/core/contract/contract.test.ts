// 契約（src/contracts）と、TypeScript の定数モジュール（enums.ts・limits.ts・http-rejections.ts）の一致。
//
// 契約のディレクトリを、/contracts・../contracts・../../contracts・このファイルから src/contracts へ上る相対パスの順に探し、
// 見つからなければ、探した場所を並べて失敗する（黙ってスキップしない）。
// JSON にあるものがモジュールに無い、モジュールにあるものが JSON に無い、のどちらも失敗する（両方向）。
import fs from "node:fs";
import path from "node:path";

import ts from "typescript";

import * as contract from "./index";
import * as enumModule from "./enums";
import { HTTP_REJECTIONS, RETRY_AT_RULES } from "./http-rejections";
import { LIMITS } from "./limits";
import type { EndReason, Profile, RejectionReason, WsMessageType } from "./enums";

// ---------------------------------------------------------------------------
// 契約のディレクトリの探し方
// ---------------------------------------------------------------------------

/** 契約のディレクトリの目印のファイル */
const MARKER_FILE = "enums.json";

/** この test のあるディレクトリ（src/frontend/core/contract）から、src/contracts へ上る相対パス */
const RELATIVE_FROM_TEST_DIR = "../../../contracts";

/**
 * 契約のディレクトリの候補を、探す順に返す。同じ場所を指す候補は、最初の 1 つだけを残す。
 *   1. /contracts          docker compose のマウント（読み取り専用）
 *   2. <cwd>/../contracts  CI のチェックアウト（作業ディレクトリが src/<層>）
 *   3. <cwd>/../../contracts
 *   4. このファイルから src/contracts へ上る相対パス（作業ディレクトリに依らない）
 */
function candidateDirs(cwd: string, testDir: string): string[] {
  const candidates = [
    "/contracts",
    path.resolve(cwd, "../contracts"),
    path.resolve(cwd, "../../contracts"),
    path.resolve(testDir, RELATIVE_FROM_TEST_DIR),
  ];
  return [...new Set(candidates)];
}

/** 候補を順に探し、最初に見つかったディレクトリを返す。1 つも無ければ、探した場所を並べて例外にする。 */
function locateContractsDir(candidates: string[], markerExists: (dir: string) => boolean): string {
  const found = candidates.find((dir) => markerExists(dir));
  if (found !== undefined) {
    return found;
  }
  throw new Error(
    [
      "契約のディレクトリ（src/contracts）が見つかりません。黙ってスキップせず、失敗します。",
      "探した場所（この順）:",
      ...candidates.map((dir) => `  - ${dir}（${MARKER_FILE} が無い）`),
      "対処: docker compose の環境では scripts/test_frontend.sh を使ってください（/contracts へ読み取り専用でマウントされます）。",
      "CI では、リポジトリをチェックアウトしたうえで、src/frontend を作業ディレクトリにして実行してください（../contracts が src/contracts になります）。",
    ].join("\n"),
  );
}

const CONTRACTS_DIR = locateContractsDir(candidateDirs(process.cwd(), __dirname), (dir) =>
  fs.existsSync(path.join(dir, MARKER_FILE)),
);

function readJson(name: string): unknown {
  return JSON.parse(fs.readFileSync(path.join(CONTRACTS_DIR, name), "utf8"));
}

/** 文書用のキー（$comment・note・*_note）。定数モジュールへは複製しない。 */
function isDocumentKey(key: string): boolean {
  return key === "$comment" || key === "note" || key.endsWith("_note");
}

/** 文書用のキーを、再帰的に取り除いた複製を返す。 */
function stripDocumentKeys(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(stripDocumentKeys);
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !isDocumentKey(key))
        .map(([key, child]) => [key, stripDocumentKeys(child)]),
    );
  }
  return value;
}

function isDeepFrozen(value: unknown): boolean {
  if (value === null || typeof value !== "object") {
    return true;
  }
  return Object.isFrozen(value) && Object.values(value).every(isDeepFrozen);
}

function toPascal(name: string): string {
  return name
    .split("_")
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join("");
}

interface EnumDefinition {
  values: string[];
  attributes?: Record<string, { hex: string; on_hex?: string }>;
}

const ENUMS = (readJson("enums.json") as { enums: Record<string, EnumDefinition> }).enums;
const LIMITS_JSON = stripDocumentKeys(readJson("limits.json"));
const REJECTIONS_JSON = stripDocumentKeys(readJson("http-rejections.json")) as {
  rejections: Record<string, unknown>;
  retry_at_rules: string[];
};

/** requirements.md 20.4（マスタデータ件数）の 17 区分の件数。表の順。 */
const REQUIREMENTS_20_4_COUNTS: ReadonlyArray<readonly [string, number]> = [
  ["source_kind", 5],
  ["layout", 4],
  ["profile", 2],
  ["broadcast_state", 6],
  ["settlement_state", 4],
  ["end_reason", 13],
  ["rejection_reason", 14],
  ["youtube_connection_state", 4],
  ["studio_state", 10],
  ["source_state", 5],
  ["ws_message_type", 14],
  ["internal_call", 4],
  ["broadcast_event_type", 24],
  ["usage_event_type", 20],
  ["setting_key", 9],
  ["adaptive_condition", 7],
  ["color_role", 12],
];

/** 契約独自の 7 区分の件数（設計メモ）。 */
const CONTRACT_ONLY_COUNTS: ReadonlyArray<readonly [string, number]> = [
  ["fatal_code", 10],
  ["relay_event_kind", 6],
  ["interrupt_cause", 4],
  ["browser_event_kind", 8],
  ["connect_result", 6],
  ["login_error", 2],
  ["resolution", 11],
];

const exportsByName = enumModule as unknown as Record<string, unknown>;

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

describe("契約のディレクトリの探し方", () => {
  test("候補は /contracts・../contracts・../../contracts・テストの隣からの相対パスの順（同じ場所は 1 つにまとめる）", () => {
    expect(candidateDirs("/work/src/frontend", "/work/src/frontend/core/contract")).toEqual([
      "/contracts",
      "/work/src/contracts",
      "/work/contracts",
    ]);
  });

  test("コンテナの中（作業ディレクトリが /app）では、すべて /contracts になる", () => {
    expect(candidateDirs("/app", "/app/core/contract")).toEqual(["/contracts"]);
  });

  test("CI のチェックアウトでは、作業ディレクトリが src/frontend のとき、../contracts が src/contracts を指す", () => {
    expect(candidateDirs("/repo/src/frontend", "/elsewhere/core/contract")).toContain("/repo/src/contracts");
  });

  test("最初に見つかった候補を返す", () => {
    expect(locateContractsDir(["/a", "/b", "/c"], (dir) => dir === "/b" || dir === "/c")).toBe("/b");
  });

  test("1 つも無ければ、探した場所をすべて並べて失敗する（黙ってスキップしない）", () => {
    const candidates = ["/contracts", "/x/contracts", "/contracts-missing"];
    expect(() => locateContractsDir(candidates, () => false)).toThrow(/スキップせず/);
    for (const dir of candidates) {
      expect(() => locateContractsDir(candidates, () => false)).toThrow(dir);
    }
  });

  test("実際の環境で、契約のディレクトリが見つかる", () => {
    expect(fs.existsSync(path.join(CONTRACTS_DIR, MARKER_FILE))).toBe(true);
  });
});

describe("契約の列挙（TypeScript の定数モジュール）", () => {
  const counts = new Map<string, number>([...REQUIREMENTS_20_4_COUNTS, ...CONTRACT_ONLY_COUNTS]);

  test("24 の列挙がある（20.4 の 17 区分と、契約独自の 7 区分）", () => {
    expect(Object.keys(ENUMS).sort()).toEqual([...counts.keys()].sort());
    expect(Object.keys(ENUMS)).toHaveLength(24);
  });

  test("20.4 の件数は 5・4・2・6・4・13・14・4・10・5・14・4・24・20・9・7・12", () => {
    expect(REQUIREMENTS_20_4_COUNTS.map(([, count]) => count)).toEqual([5, 4, 2, 6, 4, 13, 14, 4, 10, 5, 14, 4, 24, 20, 9, 7, 12]);
  });

  test("モジュールの公開は、列挙ごとの 3 つ（<名前>_VALUES・型ガード・型）と、COLOR_ROLE_ATTRIBUTES だけ", () => {
    const expected = Object.keys(ENUMS).flatMap((name) => [`${name.toUpperCase()}_VALUES`, `is${toPascal(name)}`]);
    expect(Object.keys(enumModule).sort()).toEqual([...expected, "COLOR_ROLE_ATTRIBUTES"].sort());
  });

  describe.each(Object.entries(ENUMS))("%s", (name, definition) => {
    const values = exportsByName[`${name.toUpperCase()}_VALUES`] as readonly string[];
    const guard = exportsByName[`is${toPascal(name)}`] as (value: unknown) => boolean;

    test(`${counts.get(name)} 件`, () => {
      expect(values).toHaveLength(counts.get(name) ?? -1);
    });

    test("JSON の values と一致する（順も含む）", () => {
      expect([...values]).toEqual(definition.values);
    });

    test("凍結されている（実行時に変更できない）", () => {
      expect(Object.isFrozen(values)).toBe(true);
    });

    test("符号は英小文字の snake_case（数字を含んでよい）で、重複が無い", () => {
      for (const value of values) {
        expect(value).toMatch(/^[a-z0-9]+(_[a-z0-9]+)*$/);
      }
      expect(new Set(values).size).toBe(values.length);
    });

    test("型ガードは、各値で真", () => {
      for (const value of values) {
        expect(guard(value)).toBe(true);
      }
    });

    test("型ガードは、符号に似ていても、符号でないものは偽（型違い・大文字・空白・未知の値）", () => {
      const invalid: unknown[] = [undefined, null, "", " ", "unknown", 0, 1.5, true, [], {}, Symbol("x"), "x".repeat(100)];
      for (const value of values) {
        invalid.push(` ${value}`, `${value} `, `${value}\n`, value.toUpperCase(), `${value}_`, [value], { value });
      }
      for (const candidate of invalid) {
        if (typeof candidate === "string" && values.includes(candidate)) {
          continue;
        }
        expect(guard(candidate)).toBe(false);
      }
    });
  });

  test("color_role の属性（17.2 の 16 進値）は、JSON と一致し、凍結されている", () => {
    expect(enumModule.COLOR_ROLE_ATTRIBUTES).toStrictEqual(ENUMS.color_role.attributes);
    expect(Object.keys(enumModule.COLOR_ROLE_ATTRIBUTES)).toEqual([...enumModule.COLOR_ROLE_VALUES]);
    expect(isDeepFrozen(enumModule.COLOR_ROLE_ATTRIBUTES)).toBe(true);
  });

  test("ブラウザ側の出来事は、配信の出来事の種別の部分集合", () => {
    const events = new Set<string>(enumModule.BROADCAST_EVENT_TYPE_VALUES);
    for (const kind of enumModule.BROWSER_EVENT_KIND_VALUES) {
      expect(events.has(kind)).toBe(true);
    }
  });

  test("拒否理由の順は 9.2 の順 0〜13（先頭は入力不備、末尾は API 割り当て不足）", () => {
    expect(enumModule.REJECTION_REASON_VALUES[0]).toBe("invalid_input");
    expect(enumModule.REJECTION_REASON_VALUES[13]).toBe("quota_insufficient");
  });

  test("型として、契約の値だけを受け付ける（コンパイル時の検査。tsc --noEmit が確かめる）", () => {
    const reason: EndReason = "user_stop";
    const profile: Profile = "720p";
    const message: WsMessageType = "keyframe_request";
    const rejection: RejectionReason = "quota_insufficient";
    // @ts-expect-error 契約に無い値は、型として受け付けない
    const unknownReason: EndReason = "unknown_reason";
    expect([reason, profile, message, rejection, unknownReason]).toHaveLength(5);
  });
});

describe("契約の制限値（TypeScript の定数 LIMITS）", () => {
  test("文書用のキーを除いた JSON と、完全に一致する（セクション・キー・値。過不足なし）", () => {
    expect(LIMITS).toStrictEqual(LIMITS_JSON);
  });

  test("セクションは、JSON のトップレベルと過不足なく一致する", () => {
    expect(Object.keys(LIMITS).sort()).toEqual(Object.keys(LIMITS_JSON as object).sort());
  });

  test("深く凍結されている（オブジェクト・配列）", () => {
    expect(isDeepFrozen(LIMITS)).toBe(true);
  });

  test("文書用のキー（$comment・note・*_note）を複製しない", () => {
    const keys: string[] = [];
    const collect = (value: unknown): void => {
      if (Array.isArray(value)) {
        value.forEach(collect);
      } else if (value !== null && typeof value === "object") {
        for (const [key, child] of Object.entries(value)) {
          keys.push(key);
          collect(child);
        }
      }
    };
    collect(LIMITS);
    expect(keys.filter(isDocumentKey)).toEqual([]);
  });

  test("プロファイルのキーは、列挙 profile の値", () => {
    expect(Object.keys(LIMITS.profiles)).toEqual([...enumModule.PROFILE_VALUES]);
  });

  test("適応制御の条件のキーは、列挙 adaptive_condition の値（12 章の表の順）", () => {
    expect(Object.keys(LIMITS.adaptive.conditions)).toEqual([...enumModule.ADAPTIVE_CONDITION_VALUES]);
  });

  test("設定の既定値のキーは、列挙 setting_key の値（8 章の 9 設定）", () => {
    expect(Object.keys(LIMITS.setting_defaults)).toEqual([...enumModule.SETTING_KEY_VALUES]);
  });

  test("WebSocket フレームの種別は、列挙 ws_message_type の値。種別符号は重複せず、方向は符号の最上位ビットで決まる", () => {
    const types = LIMITS.ws_frame.types;
    expect(Object.keys(types)).toEqual([...enumModule.WS_MESSAGE_TYPE_VALUES]);
    const codes = Object.values(types).map(({ code }) => code);
    expect(new Set(codes).size).toBe(14);
    for (const { code, direction } of Object.values(types)) {
      expect(direction).toBe((code & 0x80) === 0 ? "browser_to_relay" : "relay_to_browser");
    }
    expect(types.hello.code).toBe(0x01);
    expect(types.end.code).toBe(0x07);
    expect(types.accepted.code).toBe(0x81);
    expect(types.fatal.code).toBe(0x87);
  });

  test("フレームの定数：識別子 0x42 0x4C・版 1・ヘッダ 17 バイト・1 メッセージ 2,097,152 バイト", () => {
    expect(LIMITS.ws_frame.magic).toEqual([0x42, 0x4c]);
    expect(LIMITS.ws_frame.version).toBe(1);
    expect(LIMITS.ws_frame.header_bytes).toBe(17);
    expect(LIMITS.ws_frame.max_message_bytes).toBe(2_097_152);
  });

  test("設計メモの値（抜き取り）：プロファイル・閾値・適応制御・期限・台帳", () => {
    expect(LIMITS.profiles["720p"]).toEqual({
      width: 1280,
      height: 720,
      framerate: 30,
      video_bitrate_min_kbps: 3000,
      video_bitrate_initial_kbps: 4500,
      video_bitrate_max_kbps: 6000,
      line_threshold_kbps: 4100,
    });
    expect(LIMITS.profiles["480p"].line_threshold_kbps).toBe(1200);
    expect(LIMITS.adaptive.conditions.backlog_high_twice).toEqual({ backlog_over_ms: 1500, consecutive_evaluations: 2, decrease_percent: 30 });
    expect(LIMITS.relay.hello_timeout_seconds).toBe(10);
    expect(LIMITS.relay.heartbeat_lost_stop_seconds).toBe(60);
    expect(LIMITS.deadlines.settlement_retry_delays_seconds).toEqual([60, 120, 240]);
    expect(LIMITS.quota.broadcast_reservation_units).toBe(550);
    expect(LIMITS.quota.prep_reservation_units + LIMITS.quota.settle_reservation_units).toBe(550);
    expect(LIMITS.setting_defaults.bot_score_threshold).toBe(0.5);
    expect(LIMITS.setting_defaults.intake_paused).toBe(false);
  });

  test("RTMPS の送出先の許可（ホスト・ポート 443・rtmps）と、疑似の取り込み口（fake-ingest・1935）", () => {
    expect(LIMITS.rtmps_ingest.hosts).toEqual(["a.rtmps.youtube.com", "b.rtmps.youtube.com"]);
    expect(LIMITS.rtmps_ingest.port).toBe(443);
    expect(LIMITS.rtmps_ingest.scheme).toBe("rtmps");
    expect(LIMITS.dev_ingest).toEqual({ scheme: "rtmps", host: "fake-ingest", port: 1935, tls: "self_signed", allowed_environments: ["development", "test"] });
  });
});

describe("契約の拒否理由（TypeScript の定数 HTTP_REJECTIONS）", () => {
  test("rejections は、JSON と一致する", () => {
    expect(HTTP_REJECTIONS).toStrictEqual(REJECTIONS_JSON.rejections);
  });

  test("RETRY_AT_RULES は、JSON の retry_at_rules と一致する", () => {
    expect([...RETRY_AT_RULES]).toEqual(REJECTIONS_JSON.retry_at_rules);
  });

  test("深く凍結されている", () => {
    expect(isDeepFrozen(HTTP_REJECTIONS)).toBe(true);
    expect(Object.isFrozen(RETRY_AT_RULES)).toBe(true);
  });

  test("拒否理由は、列挙 rejection_reason の 14 値と過不足なく一致する（順も同じ）", () => {
    expect(Object.keys(HTTP_REJECTIONS)).toEqual([...enumModule.REJECTION_REASON_VALUES]);
  });

  test("order は、列挙の添字（9.2 の順 0〜13）と一致する", () => {
    enumModule.REJECTION_REASON_VALUES.forEach((reason, index) => {
      expect(HTTP_REJECTIONS[reason].order).toBe(index);
    });
  });

  test("区分（resolution）は、列挙 resolution の値で、11 値すべてが使われる", () => {
    const used = new Set<string>(Object.values(HTTP_REJECTIONS).map(({ resolution }) => resolution));
    expect([...used].sort()).toEqual([...enumModule.RESOLUTION_VALUES].sort());
  });

  test.each([
    ["invalid_input", 422, "fix_input", "none"],
    ["not_logged_in", 401, "log_in", "none"],
    ["rate_limited", 429, "wait", "rate_limit_window"],
    ["bot_check_failed", 403, "wait", "none"],
    ["broadcast_in_progress", 409, "stop_first", "none"],
    ["youtube_not_connected", 409, "connect", "none"],
    ["authorization_revoked", 409, "reconnect", "none"],
    ["live_not_enabled", 409, "enable_live", "none"],
    ["allowance_consumed", 409, "next_usage_day", "next_usage_day_start"],
    ["attempts_exhausted", 409, "next_usage_day", "next_usage_day_start"],
    ["intake_paused", 503, "after_release", "none"],
    ["transfer_budget_exceeded", 503, "next_month", "next_month_start"],
    ["capacity_full", 503, "wait", "none"],
    ["quota_insufficient", 503, "next_quota_day", "next_quota_day_start"],
  ] as const)("%s: HTTP %i・%s・retry_at は %s（設計メモの表）", (reason, status, resolution, rule) => {
    expect(HTTP_REJECTIONS[reason].http_status).toBe(status);
    expect(HTTP_REJECTIONS[reason].resolution).toBe(resolution);
    expect(HTTP_REJECTIONS[reason].retry_at_rule).toBe(rule);
  });
});

describe("モジュールの公開（index.ts）", () => {
  test("index は、3 つのモジュールの公開をすべて再エクスポートする", () => {
    const expected = [...Object.keys(enumModule), "LIMITS", "HTTP_REJECTIONS", "RETRY_AT_RULES"].sort();
    expect(Object.keys(contract).sort()).toEqual(expected);
  });
});

describe("Domain Core の規則（入出力・実時計を参照しない）と、画面に出す文言を含まない", () => {
  const sourceFiles = fs
    .readdirSync(__dirname)
    .filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts"))
    .map((name) => path.join(__dirname, name));

  const parse = (file: string): ts.SourceFile => ts.createSourceFile(file, fs.readFileSync(file, "utf8"), ts.ScriptTarget.Latest, true);

  const collect = (file: string, pick: (node: ts.Node) => string | undefined): string[] => {
    const found: string[] = [];
    const visit = (node: ts.Node): void => {
      const picked = pick(node);
      if (picked !== undefined) {
        found.push(picked);
      }
      ts.forEachChild(node, visit);
    };
    visit(parse(file));
    return found;
  };

  test("モジュールのファイルは、enums・limits・http-rejections・deep-freeze・index だけ", () => {
    expect(sourceFiles.map((file) => path.basename(file)).sort()).toEqual(["deep-freeze.ts", "enums.ts", "http-rejections.ts", "index.ts", "limits.ts"]);
  });

  test("文字列リテラルは、すべて ASCII（日本語はコメントだけ）で、文章に見えるものが無い", () => {
    for (const file of sourceFiles) {
      const literals = collect(file, (node) => (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node) ? node.text : undefined));
      for (const literal of literals) {
        expect(literal).toMatch(/^[A-Za-z0-9_.#:/-]*$/);
      }
    }
  });

  test("DOM・WebSocket・React・実時計・タイマ・ネットワーク・環境変数の識別子を使わない", () => {
    const forbidden = new Set(["Date", "performance", "setTimeout", "setInterval", "fetch", "WebSocket", "document", "window", "localStorage", "React", "process", "XMLHttpRequest"]);
    for (const file of sourceFiles) {
      const identifiers = collect(file, (node) => (ts.isIdentifier(node) ? node.text : undefined));
      for (const identifier of identifiers) {
        expect(forbidden.has(identifier)).toBe(false);
      }
    }
  });

  test("import は、同じディレクトリのモジュール（./）だけ", () => {
    for (const file of sourceFiles) {
      const specifiers = collect(file, (node) => (ts.isImportDeclaration(node) && ts.isStringLiteral(node.moduleSpecifier) ? node.moduleSpecifier.text : undefined));
      for (const specifier of specifiers) {
        expect(specifier.startsWith("./")).toBe(true);
      }
    }
  });

  test("再代入できる変数（let・var）を使わない（定数だけ）", () => {
    for (const file of sourceFiles) {
      const kinds = collect(file, (node) => {
        if (!ts.isVariableDeclarationList(node)) {
          return undefined;
        }
        if ((node.flags & ts.NodeFlags.Const) !== 0) {
          return "const";
        }
        return (node.flags & ts.NodeFlags.Let) !== 0 ? "let" : "var";
      });
      expect(kinds.filter((kind) => kind !== "const")).toEqual([]);
    }
  });
});
