// 受付の拒否理由（http-rejections.json）の検査: 14 種の網羅・9.2 の順・HTTP ステータス・区分（resolution）・再試行の目安時刻の規則。
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { isDocumentKey, loadContracts } from "./helpers.mjs";

const { rejections: contract, enums } = loadContracts();

/** 設計メモ（issue #3 の「拒否理由と HTTP ステータス・区分」）の写し。9.2 の順 0〜13。 */
const EXPECTED_REJECTIONS = [
  ["invalid_input", 422, "fix_input"],
  ["not_logged_in", 401, "log_in"],
  ["rate_limited", 429, "wait"],
  ["bot_check_failed", 403, "wait"],
  ["broadcast_in_progress", 409, "stop_first"],
  ["youtube_not_connected", 409, "connect"],
  ["authorization_revoked", 409, "reconnect"],
  ["live_not_enabled", 409, "enable_live"],
  ["allowance_consumed", 409, "next_usage_day"],
  ["attempts_exhausted", 409, "next_usage_day"],
  ["intake_paused", 503, "after_release"],
  ["transfer_budget_exceeded", 503, "next_month"],
  ["capacity_full", 503, "wait"],
  ["quota_insufficient", 503, "next_quota_day"],
];

/**
 * retry_at を入れる拒否理由と、その時刻の決め方（設計メモ）。それ以外は retry_at が null。
 *   rate_limited             頻度の枠が空く時刻
 *   allowance_consumed       次の JST 03:00
 *   attempts_exhausted       次の JST 03:00
 *   transfer_budget_exceeded 翌月 1 日 00:00 JST
 *   quota_insufficient       次の割り当て日の始まり（太平洋時間の 0 時）を JST で表した時刻
 */
const EXPECTED_RETRY_AT_RULES = {
  rate_limited: "rate_limit_window",
  allowance_consumed: "next_usage_day_start",
  attempts_exhausted: "next_usage_day_start",
  transfer_budget_exceeded: "next_month_start",
  quota_insufficient: "next_quota_day_start",
};

const entries = Object.entries(contract.rejections);

describe("http-rejections.json の構造", () => {
  test("トップレベルは、retry_at_rules と rejections（と文書用のキー）だけ", () => {
    assert.deepEqual(
      Object.keys(contract)
        .filter((key) => !isDocumentKey(key))
        .sort(),
      ["rejections", "retry_at_rules"],
    );
    assert.equal(typeof contract.$comment, "string");
  });

  test("各拒否理由は、order・http_status・resolution・retry_at_rule だけを持つ", () => {
    for (const [reason, entry] of entries) {
      const keys = Object.keys(entry).filter((key) => !isDocumentKey(key));
      assert.deepEqual(keys.sort(), ["http_status", "order", "resolution", "retry_at_rule"], reason);
    }
  });
});

describe("拒否理由 14 種の網羅", () => {
  test("14 種ある", () => {
    assert.equal(entries.length, 14);
  });

  test("拒否理由は、列挙 rejection_reason の 14 値と過不足なく一致する（各 1 回）", () => {
    assert.deepEqual(Object.keys(contract.rejections).sort(), [...enums.enums.rejection_reason.values].sort());
  });

  test("order は、列挙 rejection_reason の添字（9.2 の順 0〜13）と一致する", () => {
    const values = enums.enums.rejection_reason.values;
    for (const [reason, { order }] of entries) {
      assert.equal(order, values.indexOf(reason), reason);
    }
    assert.deepEqual(
      entries.map(([, { order }]) => order).sort((a, b) => a - b),
      Array.from({ length: 14 }, (_, index) => index),
    );
  });
});

describe("HTTP ステータスと区分（resolution）", () => {
  for (const [reason, status, resolution] of EXPECTED_REJECTIONS) {
    test(`${reason}: ${status}・${resolution}`, () => {
      assert.equal(contract.rejections[reason].http_status, status);
      assert.equal(contract.rejections[reason].resolution, resolution);
    });
  }

  test("resolution は、列挙 resolution の値。11 値すべてが、いずれかの拒否理由で使われる", () => {
    const used = new Set(entries.map(([, { resolution }]) => resolution));
    const allowed = new Set(enums.enums.resolution.values);
    for (const resolution of used) {
      assert.ok(allowed.has(resolution), `列挙 resolution に無い: ${resolution}`);
    }
    assert.deepEqual([...used].sort(), [...allowed].sort());
  });

  test("HTTP ステータスは 401・403・409・422・429・503 のいずれか", () => {
    for (const [reason, { http_status: status }] of entries) {
      assert.ok([401, 403, 409, 422, 429, 503].includes(status), `${reason}: ${status}`);
    }
  });

  test("システム都合の一時的な理由（429・503）より先に、利用者自身の状態に起因する理由（409）を判定する（9.2）", () => {
    // 順 4〜9 は 409（進行中・未接続・認可失効・ライブ未有効・利用枠・試行上限）。順 10〜13 が 503（受付停止・転送量・満員・割り当て）
    const byOrder = [...entries].sort(([, a], [, b]) => a.order - b.order).map(([, entry]) => entry.http_status);
    assert.deepEqual(byOrder, [422, 401, 429, 403, 409, 409, 409, 409, 409, 409, 503, 503, 503, 503]);
  });
});

describe("再試行の目安時刻（retry_at）の規則", () => {
  test("retry_at_rules は、none と 4 つの規則", () => {
    assert.deepEqual(contract.retry_at_rules, [
      "none",
      "rate_limit_window",
      "next_usage_day_start",
      "next_month_start",
      "next_quota_day_start",
    ]);
  });

  for (const [reason] of EXPECTED_REJECTIONS) {
    const expected = EXPECTED_RETRY_AT_RULES[reason] ?? "none";
    test(`${reason}: retry_at は ${expected === "none" ? "null（none）" : expected}`, () => {
      assert.equal(contract.rejections[reason].retry_at_rule, expected);
    });
  }

  test("retry_at を入れる拒否理由は 5 つだけ", () => {
    const withTime = entries.filter(([, { retry_at_rule: rule }]) => rule !== "none").map(([reason]) => reason);
    assert.deepEqual(withTime.sort(), Object.keys(EXPECTED_RETRY_AT_RULES).sort());
  });

  test("規則は retry_at_rules に載っているものだけ", () => {
    for (const [reason, { retry_at_rule: rule }] of entries) {
      assert.ok(contract.retry_at_rules.includes(rule), `${reason}: ${rule}`);
    }
  });

  test("再試行が時刻で解消する区分（wait の一部・next_usage_day・next_month・next_quota_day）だけが retry_at を持つ", () => {
    for (const [reason, { resolution, retry_at_rule: rule }] of entries) {
      if (["fix_input", "log_in", "stop_first", "connect", "reconnect", "enable_live", "after_release"].includes(resolution)) {
        assert.equal(rule, "none", `${reason}: 操作で解消する区分なのに retry_at がある`);
      }
      if (["next_usage_day", "next_month", "next_quota_day"].includes(resolution)) {
        assert.notEqual(rule, "none", `${reason}: 時刻で解消する区分なのに retry_at が無い`);
      }
    }
  });
});
