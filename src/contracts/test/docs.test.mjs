// 文書（README.md・http-api.md・internal-api.md・ws-protocol.md）と JSON の整合。
//
// 文書の文章そのものは検査しない。文書に書かれた符号・種別符号・HTTP ステータス・エンドポイント・limits.json への参照が、
// JSON（契約の正）と食い違っていないことだけを機械的に確かめる。
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { loadContracts, readContractFile } from "./helpers.mjs";

const { dir, enums, limits, rejections } = loadContracts();
const doc = (name) => readContractFile(dir, name);
const code = (text) => `\`${text}\``;
const valuesOf = (name) => enums.enums[name].values;

const readme = doc("README.md");
const http = doc("http-api.md");
const internal = doc("internal-api.md");
const ws = doc("ws-protocol.md");

/** Markdown の表の行（| で始まる行）のうち、条件を満たす行を返す。 */
function tableRows(text, predicate) {
  return text.split("\n").filter((line) => line.startsWith("|") && predicate(line));
}

describe("README.md", () => {
  test("契約のファイルをすべて挙げている", () => {
    for (const name of [
      "enums.json",
      "limits.json",
      "http-rejections.json",
      "http-api.md",
      "internal-api.md",
      "ws-protocol.md",
      "ws-frame-vectors.json",
      "scripts/test_contracts.sh",
    ]) {
      assert.ok(readme.includes(code(name)), `${name} が README.md に無い`);
    }
  });

  test("24 の列挙のすべての値を、符号として載せている（要件の用語との対応表）", () => {
    for (const [name, definition] of Object.entries(enums.enums)) {
      assert.ok(readme.includes(code(name)), `列挙 ${name} が README.md に無い`);
      for (const value of definition.values) {
        assert.ok(readme.includes(code(value)), `${name} の値 ${value} が README.md に無い`);
      }
    }
  });

  test("3 層のテストの実行の手順（Ruby・TypeScript・Go）と、契約のディレクトリの探し方を書いている", () => {
    assert.ok(readme.includes("scripts/test_backend.sh --no-db spec/domain/contract"));
    assert.ok(readme.includes("scripts/test_frontend.sh core/contract"));
    assert.ok(readme.includes("scripts/test_relay.sh ./core/contract/..."));
    assert.ok(readme.includes("../contracts") && readme.includes("../../contracts") && readme.includes("/contracts"));
  });
});

describe("ws-protocol.md", () => {
  for (const [name, { code: typeCode, direction }] of Object.entries(limits.ws_frame.types)) {
    test(`${name} の行に、種別符号 0x${typeCode.toString(16).toUpperCase().padStart(2, "0")} と方向がある`, () => {
      const hex = `0x${typeCode.toString(16).toUpperCase().padStart(2, "0")}`;
      const rows = tableRows(ws, (line) => line.includes(`| ${code(name)} | ${code(hex)} |`));
      assert.equal(rows.length, 1, `${name} の表の行が ${rows.length} 行`);
      const arrow = direction === "browser_to_relay" ? "B→R" : "R→B";
      assert.ok(rows[0].includes(arrow), `${name}: 方向 ${arrow} が行に無い`);
    });
  }

  test("検証エラーの 7 種の符号を、検証の順の表に載せている", () => {
    for (const error of ["truncated_header", "invalid_magic", "unsupported_version", "unknown_type", "wrong_direction", "too_large", "length_mismatch"]) {
      assert.ok(tableRows(ws, (line) => line.includes(code(error))).length >= 1, `${error} の表の行が無い`);
    }
  });

  test("検証の順は、切り詰め・識別子・版・未知の種別・方向・2 MB 超・本文長の不一致", () => {
    const order = ["truncated_header", "invalid_magic", "unsupported_version", "unknown_type", "wrong_direction", "too_large", "length_mismatch"];
    const positions = order.map((error) => ws.indexOf(`| ${code(error)} |`));
    positions.forEach((position, index) => assert.ok(position >= 0, `${order[index]} の行が無い`));
    for (let index = 1; index < positions.length; index += 1) {
      assert.ok(positions[index - 1] < positions[index], `${order[index - 1]} は ${order[index]} より前に書く`);
    }
  });

  test("致命通知の符号（10 種）を、すべて載せている", () => {
    for (const fatal of valuesOf("fatal_code")) {
      assert.ok(tableRows(ws, (line) => line.includes(`| ${code(fatal)} |`)).length >= 1, `${fatal} の行が無い`);
    }
  });

  test("1 メッセージの上限 2,097,152 バイトと、Close コード 1009 の扱いを書いている", () => {
    assert.ok(ws.includes("2,097,152"));
    assert.ok(ws.includes("1009"));
    assert.ok(ws.includes(code("fatal(message_too_large)")) || ws.includes(code("message_too_large")));
  });

  test("識別子・版・ヘッダの長さを、limits.json と同じ値で書いている", () => {
    assert.ok(ws.includes("0x42") && ws.includes("0x4C"));
    assert.ok(ws.includes("17 バイト"));
  });

  test("共有テストベクタ（ws-frame-vectors.json）を参照している", () => {
    assert.ok(ws.includes(code("ws-frame-vectors.json")));
  });

  test("プロファイル・終了理由・ブラウザ側の出来事など、本文に現れる符号を、列挙の値として載せている", () => {
    for (const value of [...valuesOf("browser_event_kind"), "user_stop", "user_cancel", "insufficient_bandwidth", "youtube_stream_unhealthy"]) {
      assert.ok(ws.includes(code(value)), `${value} が ws-protocol.md に無い`);
    }
  });
});

describe("http-api.md", () => {
  const endpoints = [
    "GET /api/state",
    "POST /api/auth/login/start",
    "GET /api/auth/callback",
    "POST /api/auth/logout",
    "POST /api/youtube/connect/start",
    "GET /api/youtube/connect/callback",
    "POST /api/youtube/recheck",
    "POST /api/youtube/disconnect",
    "DELETE /api/account",
    "POST /api/broadcasts",
    "POST /api/broadcasts/:id/ticket",
    "POST /api/broadcasts/:id/stop",
    "POST /api/broadcasts/:id/cancel",
    "GET /api/broadcasts/:id",
    "POST /api/usage-events",
  ];
  for (const endpoint of endpoints) {
    test(`${endpoint} の節がある`, () => {
      assert.ok(http.includes(`### ${code(endpoint)}`), `見出し ### ${code(endpoint)} が無い`);
    });
  }

  for (const [reason, { http_status: status, resolution, order }] of Object.entries(rejections.rejections)) {
    test(`拒否理由 ${reason} の行に、順 ${order}・HTTP ${status}・区分 ${resolution} がある`, () => {
      const rows = tableRows(http, (line) => line.includes(`| ${code(reason)} |`) && line.includes(`| ${code(resolution)} |`));
      assert.ok(rows.length >= 1, `${reason} と ${resolution} を持つ表の行が無い`);
      assert.ok(
        rows.some((row) => row.includes(`| ${status} |`) && row.startsWith(`| ${order} |`)),
        `${reason}: 順 ${order}・HTTP ${status} の行が無い`,
      );
    });
  }

  test("ログインの失敗の種類・YouTube 接続の結果の符号を載せている", () => {
    for (const value of [...valuesOf("login_error"), ...valuesOf("connect_result")]) {
      assert.ok(http.includes(code(value)), `${value} が http-api.md に無い`);
    }
  });

  test("YouTube 接続の状態・配信の状態・終了理由の符号を載せている", () => {
    for (const name of ["youtube_connection_state", "broadcast_state", "end_reason"]) {
      for (const value of valuesOf(name)) {
        assert.ok(http.includes(code(value)), `${name} の ${value} が http-api.md に無い`);
      }
    }
  });

  test("ヘッダと Cookie の名前を載せている", () => {
    for (const name of ["X-BFF-Secret", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-BL-Client", "X-CSRF-Token", "bl_session", "bl_oauth"]) {
      assert.ok(http.includes(code(name)), `${name} が http-api.md に無い`);
    }
  });

  test("エラーの符号（共通・各エンドポイント）を、エラーの種類の表に載せている", () => {
    for (const error of [
      "not_logged_in",
      "csrf_invalid",
      "forbidden",
      "not_found",
      "invalid_input",
      "unsupported_event",
      "bot_check_failed",
      "rate_limited",
      "broadcast_in_progress",
      "broadcast_ended",
      "not_resumable",
      "already_live",
      "not_connected",
      "unverifiable",
      "internal_error",
      "bad_gateway",
    ]) {
      assert.ok(tableRows(http, (line) => line.includes(`| ${code(error)} |`)).length >= 1, `エラー ${error} の表の行が無い`);
    }
  });

  test("ブラウザが送れる測定イベントの種別（5 種）を載せている", () => {
    for (const type of ["capability_detected", "source_granted", "source_denied", "line_measured", "watch_url_copied"]) {
      assert.ok(http.includes(code(type)), type);
    }
  });

  test("reCAPTCHA の行為名（login・youtube_connect・broadcast_start）を載せている", () => {
    for (const action of ["login", "youtube_connect", "broadcast_start"]) {
      assert.ok(http.includes(code(action)), action);
    }
  });
});

describe("internal-api.md", () => {
  for (const endpoint of [
    "POST /internal/v1/verify",
    "POST /internal/v1/broadcasts/:id/provision",
    "POST /internal/v1/broadcasts/:id/heartbeat",
    "POST /internal/v1/broadcasts/:id/events",
  ]) {
    test(`${endpoint} の節がある`, () => {
      assert.ok(internal.includes(`### ${code(endpoint)}`), `見出し ### ${code(endpoint)} が無い`);
    });
  }

  test("内部側の口（3101）・共有の秘密値のヘッダ・公開側の口の 404 を書いている", () => {
    assert.ok(internal.includes("3101"));
    assert.ok(internal.includes(code("X-Relay-Secret")));
    assert.ok(internal.includes("404"));
  });

  test("中継の事象の種類（6 種）と、中断の原因（4 種）を載せている", () => {
    for (const value of [...valuesOf("relay_event_kind"), ...valuesOf("interrupt_cause")]) {
      assert.ok(internal.includes(code(value)), `${value} が internal-api.md に無い`);
    }
  });

  test("エラーの符号を、エラーの種類の表に載せている", () => {
    for (const error of [
      "unauthorized",
      "ticket_invalid",
      "broadcast_not_attachable",
      "stale_epoch",
      "broadcast_ended",
      "prior_unsettled",
      "prepare_failed",
      "authorization_revoked",
      "live_not_enabled",
      "not_found",
      "invalid_input",
    ]) {
      assert.ok(tableRows(internal, (line) => line.includes(`| ${code(error)} |`)).length >= 1, `エラー ${error} の表の行が無い`);
    }
  });

  test("心拍の応答の指示（continue・stop）と、状態通知の項目を書いている", () => {
    for (const word of ["continue", "stop", "notices", "epoch", "account_key", "seq"]) {
      assert.ok(internal.includes(code(word)), word);
    }
  });
});

describe("文書が参照する limits.json のキー", () => {
  /** `relay.hello_timeout_seconds` のような、limits.json のセクションから始まる、ドットでつないだ参照。 */
  const sections = new Set(Object.keys(limits).filter((key) => !key.startsWith("$")));
  const referencePattern = /`([a-z_]+(?:\.[A-Za-z0-9_]+)+)`/g;

  const resolve = (reference) => {
    let current = limits;
    for (const segment of reference.split(".")) {
      if (current === null || typeof current !== "object" || !Object.hasOwn(current, segment)) {
        return false;
      }
      current = current[segment];
    }
    return true;
  };

  for (const [name, text] of [
    ["README.md", readme],
    ["http-api.md", http],
    ["internal-api.md", internal],
    ["ws-protocol.md", ws],
  ]) {
    test(`${name}: limits.json のセクションから始まる参照は、すべて実在する`, () => {
      const references = [...text.matchAll(referencePattern)].map((match) => match[1]).filter((reference) => sections.has(reference.split(".")[0]));
      for (const reference of references) {
        assert.ok(resolve(reference), `limits.json に ${reference} が無い`);
      }
    });
  }

  test("文書は、制限値を limits.json の参照つきで書いている（少なくとも 1 つ以上の参照がある）", () => {
    const total = [readme, http, internal, ws].flatMap((text) => [...text.matchAll(referencePattern)].map((match) => match[1])).filter((reference) => sections.has(reference.split(".")[0]));
    assert.ok(total.length >= 10, `参照が ${total.length} 個しかありません`);
  });
});
