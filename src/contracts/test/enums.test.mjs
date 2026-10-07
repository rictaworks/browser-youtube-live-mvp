// 列挙（enums.json）の検査: 設計メモ（issue #3）との一致・requirements.md 20.4 の件数・符号の形式と重複・色の役割。
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { loadContracts } from "./helpers.mjs";

const { enums: contract } = loadContracts();

/** 設計メモ（issue #3 の「2. 列挙」の表）の写し。値の順も契約の一部。color_role の値は 17.2 の 12 役割。 */
const EXPECTED_VALUES = {
  source_kind: ["camera", "screen", "microphone", "shared_audio", "slate"],
  layout: ["screen_with_wipe", "screen_only", "camera_only", "slate"],
  profile: ["720p", "480p"],
  broadcast_state: ["reserved", "awaiting_media", "confirming", "live", "interrupted", "ended"],
  settlement_state: ["none", "pending", "settled", "abandoned"],
  end_reason: [
    "user_stop", "time_limit", "connection_lost", "youtube_ended", "authorization_revoked", "admin_stop", "start_timeout",
    "confirm_timeout", "prepare_failed", "prior_unsettled", "insufficient_bandwidth", "user_cancel", "relay_disconnect",
  ],
  rejection_reason: [
    "invalid_input", "not_logged_in", "rate_limited", "bot_check_failed", "broadcast_in_progress", "youtube_not_connected",
    "authorization_revoked", "live_not_enabled", "allowance_consumed", "attempts_exhausted", "intake_paused",
    "transfer_budget_exceeded", "capacity_full", "quota_insufficient",
  ],
  youtube_connection_state: ["not_connected", "connected", "live_not_enabled", "revoked"],
  studio_state: [
    "idle", "requesting", "connecting", "probing", "starting", "live", "degraded", "reconnecting", "stopping", "ended",
  ],
  source_state: ["detached", "requesting", "active", "denied", "lost"],
  ws_message_type: [
    "hello", "probe", "start", "video", "audio", "report", "end", "accepted", "probe_result", "ack", "keyframe_request",
    "throttle", "status", "fatal",
  ],
  internal_call: ["verify", "provision", "heartbeat", "event"],
  broadcast_event_type: [
    "accepted", "verified", "probe_done", "provision_started", "provision_done", "publish_started", "live_confirmed",
    "source_added", "source_lost", "fallback_switched", "bitrate_down", "bitrate_up", "video_dropped", "degraded_started",
    "degraded_cleared", "interrupted", "resumed", "throttle_directed", "keyframe_requested", "youtube_warning",
    "time_limit_notice", "ended", "settlement_succeeded", "settlement_failed",
  ],
  usage_event_type: [
    "login_started", "login_completed", "connect_started", "connect_completed", "connect_failed", "capability_detected",
    "source_granted", "source_denied", "start_requested", "start_rejected", "line_measured", "prepared", "live_confirmed",
    "degraded", "reconnect_started", "reconnect_succeeded", "broadcast_ended", "watch_url_copied", "disconnected",
    "account_deleted",
  ],
  setting_key: [
    "daily_allowance", "attempt_limit", "concurrent_limit", "time_limit_minutes", "intake_rate_per_hour",
    "monthly_transfer_budget_gb", "daily_quota_units", "bot_score_threshold", "intake_paused",
  ],
  adaptive_condition: [
    "backlog_high_twice", "backlog_low_no_drop", "backlog_critical", "video_ack_stalled", "backlog_severe_sustained",
    "degraded_enter", "degraded_exit",
  ],
  color_role: [
    "base", "surface", "surface_raised", "divider", "control_border", "text_primary", "text_secondary", "accent", "live",
    "warning", "success", "focus",
  ],
  fatal_code: [
    "message_too_large", "bitrate_exceeded", "hello_timeout", "invalid_ticket", "stale_epoch", "broadcast_ended",
    "protocol_violation", "heartbeat_lost", "publish_failed", "internal_error",
  ],
  relay_event_kind: ["publish_started", "interrupted", "resumed", "publish_failed", "relay_disconnected", "session_ended"],
  interrupt_cause: ["browser_disconnected", "media_stalled", "rtmps_disconnected", "buffer_overflow"],
  browser_event_kind: [
    "source_added", "source_lost", "fallback_switched", "bitrate_down", "bitrate_up", "video_dropped", "degraded_started",
    "degraded_cleared",
  ],
  connect_result: ["connected", "live_not_enabled", "scope_denied", "no_refresh_token", "no_channel", "unverifiable"],
  login_error: ["registration_held", "oauth_failed"],
  resolution: [
    "fix_input", "log_in", "wait", "stop_first", "connect", "reconnect", "enable_live", "next_usage_day", "after_release",
    "next_month", "next_quota_day",
  ],
};

/** requirements.md 20.4（マスタデータ件数）の 17 区分の件数。表の順。 */
const REQUIREMENTS_20_4_COUNTS = [
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

/** 契約独自の 7 区分の件数（設計メモの表）。 */
const CONTRACT_ONLY_COUNTS = [
  ["fatal_code", 10],
  ["relay_event_kind", 6],
  ["interrupt_cause", 4],
  ["browser_event_kind", 8],
  ["connect_result", 6],
  ["login_error", 2],
  ["resolution", 11],
];

/** 17.2 の配色（符号と 16 進値）。ライブとアクセントは、上に載せる文字の色も持つ。 */
const EXPECTED_COLORS = {
  base: { hex: "#0F1115" },
  surface: { hex: "#171A21" },
  surface_raised: { hex: "#1F2430" },
  divider: { hex: "#2B3140" },
  control_border: { hex: "#6B7488" },
  text_primary: { hex: "#F2F4F8" },
  text_secondary: { hex: "#A9B1C1" },
  accent: { hex: "#3FB6A8", on_hex: "#06201D" },
  live: { hex: "#CE2C31", on_hex: "#FFFFFF" },
  warning: { hex: "#F5A524" },
  success: { hex: "#46A758" },
  focus: { hex: "#8AB4F8" },
};

const CODE_PATTERN = /^[a-z0-9]+(?:_[a-z0-9]+)*$/;

describe("enums.json の構造", () => {
  test("トップレベルは $comment と enums だけ", () => {
    assert.deepEqual(Object.keys(contract).sort(), ["$comment", "enums"]);
  });

  test("列挙の名前は、設計メモの 24 区分と一致する（過不足なし）", () => {
    assert.deepEqual(Object.keys(contract.enums).sort(), Object.keys(EXPECTED_VALUES).sort());
    assert.equal(Object.keys(contract.enums).length, 24);
  });

  test("各列挙は、values（文字列の配列）と、出どころ（source）を持つ", () => {
    for (const [name, definition] of Object.entries(contract.enums)) {
      assert.ok(Array.isArray(definition.values), `${name}: values が配列ではありません`);
      assert.equal(typeof definition.source, "string", `${name}: source がありません`);
      assert.ok(definition.source.length > 0, `${name}: source が空です`);
      const allowedKeys = new Set(["source", "note", "values", "attributes"]);
      for (const key of Object.keys(definition)) {
        assert.ok(allowedKeys.has(key), `${name}: 未知のキー ${key}`);
      }
    }
  });
});

describe("件数（requirements.md 20.4 と設計メモ）", () => {
  for (const [name, count] of REQUIREMENTS_20_4_COUNTS) {
    test(`${name} は ${count} 件（20.4）`, () => {
      assert.equal(contract.enums[name].values.length, count);
    });
  }

  for (const [name, count] of CONTRACT_ONLY_COUNTS) {
    test(`${name} は ${count} 件（契約独自）`, () => {
      assert.equal(contract.enums[name].values.length, count);
    });
  }

  test("20.4 の 17 区分の件数の並びは 5・4・2・6・4・13・14・4・10・5・14・4・24・20・9・7・12", () => {
    assert.deepEqual(
      REQUIREMENTS_20_4_COUNTS.map(([name]) => contract.enums[name].values.length),
      [5, 4, 2, 6, 4, 13, 14, 4, 10, 5, 14, 4, 24, 20, 9, 7, 12],
    );
  });
});

describe("値（設計メモとの一致・形式・重複）", () => {
  for (const [name, expected] of Object.entries(EXPECTED_VALUES)) {
    test(`${name}: 設計メモと一致する（順も含む）`, () => {
      assert.deepEqual(contract.enums[name].values, expected);
    });

    test(`${name}: 符号は英小文字の snake_case（数字を含んでよい）で、重複が無い`, () => {
      const values = contract.enums[name].values;
      for (const value of values) {
        assert.equal(typeof value, "string");
        assert.match(value, CODE_PATTERN, `${name}: 符号の形式が不正: ${JSON.stringify(value)}`);
      }
      assert.equal(new Set(values).size, values.length, `${name}: 符号が重複しています`);
    });
  }

  test("profile の符号は 720p・480p だけが数字で始まる（ほかは英小文字で始まる）", () => {
    for (const [name, definition] of Object.entries(contract.enums)) {
      for (const value of definition.values) {
        if (/^[0-9]/.test(value)) {
          assert.equal(name, "profile", `${name}: 数字で始まる符号 ${value}`);
        }
      }
    }
    assert.deepEqual(contract.enums.profile.values, ["720p", "480p"]);
  });
});

describe("列挙どうしの整合", () => {
  const values = (name) => new Set(contract.enums[name].values);
  const isSubset = (small, large) => [...small].every((value) => large.has(value));

  test("ブラウザ側の出来事は、配信の出来事の種別の部分集合", () => {
    assert.ok(isSubset(values("browser_event_kind"), values("broadcast_event_type")));
  });

  test("ブラウザが送れる終了の理由（end・cancel）は、終了理由の部分集合", () => {
    const fromBrowser = ["user_stop", "user_cancel", "insufficient_bandwidth"];
    assert.ok(isSubset(new Set(fromBrowser), values("end_reason")));
  });

  test("状態報告の状態（live・degraded）は、スタジオの状態の部分集合", () => {
    assert.ok(isSubset(new Set(["live", "degraded"]), values("studio_state")));
  });

  test("中継の事象のうち、送出開始・中断・復帰は、配信の出来事の種別に同じ符号がある", () => {
    const relay = values("relay_event_kind");
    for (const kind of ["publish_started", "interrupted", "resumed"]) {
      assert.ok(relay.has(kind) && values("broadcast_event_type").has(kind));
    }
  });

  test("接続の結果のうち connected・live_not_enabled は、YouTube 接続状態と同じ符号", () => {
    assert.ok(isSubset(new Set(["connected", "live_not_enabled"]), values("youtube_connection_state")));
    assert.ok(isSubset(new Set(["connected", "live_not_enabled"]), values("connect_result")));
  });

  test("拒否理由のうち、終了理由と同じ語（authorization_revoked）は同じ符号", () => {
    assert.ok(values("rejection_reason").has("authorization_revoked") && values("end_reason").has("authorization_revoked"));
  });

  test("setting_key は 8 章の 9 設定（受付停止を含む）", () => {
    assert.ok(values("setting_key").has("intake_paused"));
    assert.ok(values("setting_key").has("bot_score_threshold"));
  });
});

describe("color_role（17.2 の 12 役割）", () => {
  const { values, attributes } = contract.enums.color_role;

  test("属性は、12 役割すべてについて、17.2 の 16 進値と一致する", () => {
    assert.deepEqual(Object.keys(attributes).sort(), [...values].sort());
    assert.deepEqual(attributes, EXPECTED_COLORS);
  });

  test("16 進値は # と 6 桁の大文字の 16 進数", () => {
    for (const [role, { hex, on_hex: onHex }] of Object.entries(attributes)) {
      assert.match(hex, /^#[0-9A-F]{6}$/, role);
      if (onHex !== undefined) {
        assert.match(onHex, /^#[0-9A-F]{6}$/, role);
      }
    }
  });

  test("上に載せる文字の色（on_hex）を持つのは、アクセントとライブだけ", () => {
    assert.deepEqual(
      Object.entries(attributes)
        .filter(([, definition]) => definition.on_hex !== undefined)
        .map(([role]) => role)
        .sort(),
      ["accent", "live"],
    );
  });

  test("モックとの差の注記がある（app-ui のトークンは 17.2 と一致しない）", () => {
    assert.match(contract.enums.color_role.note, /app-ui/);
    assert.match(contract.enums.color_role.note, /17\.2/);
  });

  // WCAG 2.x の相対輝度とコントラスト比。17.2 の要件：文字 4.5:1 以上、操作部品の境界と状態の図形は 3:1 以上
  const linear = (channel) => {
    const value = channel / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  const luminance = (hex) => {
    const [red, green, blue] = [1, 3, 5].map((start) => linear(parseInt(hex.slice(start, start + 2), 16)));
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
  };
  const contrast = (foreground, background) => {
    const [light, dark] = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
    return (light + 0.05) / (dark + 0.05);
  };
  const hexOf = (role) => attributes[role].hex;

  const textOn = [
    ["text_primary", "base"],
    ["text_primary", "surface"],
    ["text_primary", "surface_raised"],
    ["text_secondary", "base"],
    ["text_secondary", "surface"],
    ["text_secondary", "surface_raised"],
  ];
  for (const [foreground, background] of textOn) {
    test(`文字 ${foreground} は ${background} の上で 4.5:1 以上`, () => {
      assert.ok(contrast(hexOf(foreground), hexOf(background)) >= 4.5);
    });
  }

  // ライブの赤は、面（浮き）の上では 2.98:1 で 3:1 に届かない。ライブの表示はプレビューと面の上に置く（17.4）ため、検査の対象にしない
  const graphicsOn = [
    ["control_border", ["base", "surface", "surface_raised"]],
    ["focus", ["base", "surface", "surface_raised"]],
    ["accent", ["base", "surface", "surface_raised"]],
    ["warning", ["base", "surface", "surface_raised"]],
    ["success", ["base", "surface", "surface_raised"]],
    ["live", ["base", "surface"]],
  ];
  for (const [foreground, backgrounds] of graphicsOn) {
    for (const background of backgrounds) {
      test(`境界・状態の図形 ${foreground} は ${background} の上で 3:1 以上`, () => {
        assert.ok(contrast(hexOf(foreground), hexOf(background)) >= 3);
      });
    }
  }

  test("アクセントの上の文字（on_hex）は 4.5:1 以上", () => {
    assert.ok(contrast(attributes.accent.on_hex, hexOf("accent")) >= 4.5);
  });

  test("ライブの上の文字（on_hex）は 4.5:1 以上", () => {
    assert.ok(contrast(attributes.live.on_hex, hexOf("live")) >= 4.5);
  });
});

describe("拒否理由の順（9.2 の順 0〜13）", () => {
  test("配列の添字が 9.2 の順", () => {
    const order = [
      "invalid_input",
      "not_logged_in",
      "rate_limited",
      "bot_check_failed",
      "broadcast_in_progress",
      "youtube_not_connected",
      "authorization_revoked",
      "live_not_enabled",
      "allowance_consumed",
      "attempts_exhausted",
      "intake_paused",
      "transfer_budget_exceeded",
      "capacity_full",
      "quota_insufficient",
    ];
    assert.deepEqual(contract.enums.rejection_reason.values, order);
  });
});
