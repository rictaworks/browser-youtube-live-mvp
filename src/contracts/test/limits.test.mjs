// 制限値・定数（limits.json）の検査: 設計メモ（issue #3 の「3. 制限値・定数」）との一致・数値どうしの整合・符号の重複。
import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { isDocumentKey, loadContracts, withoutDocumentKeys } from "./helpers.mjs";
import { INCOMING_DIRECTION, REFERENCE_TYPES } from "./ws_reference.mjs";

const { limits: contract, enums } = loadContracts();
const limits = withoutDocumentKeys(contract);

/** 設計メモ（issue #3 の「3. 制限値・定数」）の写し。文書用のキー（$comment・note・*_note）は含めない。 */
const EXPECTED_LIMITS = {
  // プロファイル（11.7）と回線計測の閾値（11.8）
  profiles: {
    "720p": {
      width: 1280,
      height: 720,
      framerate: 30,
      video_bitrate_min_kbps: 3000,
      video_bitrate_initial_kbps: 4500,
      video_bitrate_max_kbps: 6000,
      line_threshold_kbps: 4100,
    },
    "480p": {
      width: 854,
      height: 480,
      framerate: 30,
      video_bitrate_min_kbps: 800,
      video_bitrate_initial_kbps: 1500,
      video_bitrate_max_kbps: 2500,
      line_threshold_kbps: 1200,
    },
  },
  video: {
    codec_main: "avc1.4D401F",
    codec_constrained_baseline: "avc1.42E01F",
    keyframe_interval_seconds: 2,
  },
  audio: {
    codec: "mp4a.40.2",
    sample_rate_hz: 44100,
    channels: 2,
    bitrate_kbps: 128,
    samples_per_video_frame: 1470,
  },
  // 回線計測（11.8）
  line_probe: {
    duration_seconds: 3,
    max_rate_kbps: 6000,
    message_bytes_hint: 32768,
    start_bitrate_throughput_ratio: 0.75,
  },
  // 適応制御（12 章）
  adaptive: {
    evaluation_interval_ms: 1000,
    target_change_min_interval_ms: 1000,
    encoder_queue_max_frames: 2,
    conditions: {
      backlog_high_twice: { backlog_over_ms: 1500, consecutive_evaluations: 2, decrease_percent: 30 },
      backlog_low_no_drop: { backlog_under_ms: 300, no_drop_window_seconds: 10, increase_percent: 10 },
      backlog_critical: { backlog_over_ms: 4000 },
      video_ack_stalled: { stalled_seconds: 10 },
      backlog_severe_sustained: { backlog_over_ms: 8000, duration_seconds: 10 },
      degraded_enter: { backlog_over_ms: 1500, duration_seconds: 20 },
      degraded_exit: { backlog_at_most_ms: 1500, duration_seconds: 10 },
    },
  },
  // WebSocket 転送フレーム（11.9）
  ws_frame: {
    magic: [0x42, 0x4c],
    version: 1,
    header_bytes: 17,
    header_fields: {
      magic: { offset: 0, length: 2 },
      version: { offset: 2, length: 1 },
      type: { offset: 3, length: 1 },
      attributes: { offset: 4, length: 1 },
      timestamp_us: { offset: 5, length: 8 },
      body_length: { offset: 13, length: 4 },
    },
    keyframe_attribute_bit: 0,
    max_message_bytes: 2097152,
    directions: ["browser_to_relay", "relay_to_browser"],
    types: {
      hello: { code: 0x01, direction: "browser_to_relay" },
      probe: { code: 0x02, direction: "browser_to_relay" },
      start: { code: 0x03, direction: "browser_to_relay" },
      video: { code: 0x04, direction: "browser_to_relay" },
      audio: { code: 0x05, direction: "browser_to_relay" },
      report: { code: 0x06, direction: "browser_to_relay" },
      end: { code: 0x07, direction: "browser_to_relay" },
      accepted: { code: 0x81, direction: "relay_to_browser" },
      probe_result: { code: 0x82, direction: "relay_to_browser" },
      ack: { code: 0x83, direction: "relay_to_browser" },
      keyframe_request: { code: 0x84, direction: "relay_to_browser" },
      throttle: { code: 0x85, direction: "relay_to_browser" },
      status: { code: 0x86, direction: "relay_to_browser" },
      fatal: { code: 0x87, direction: "relay_to_browser" },
    },
  },
  // 中継（11.9・11.10）
  relay: {
    hello_timeout_seconds: 10,
    ingress_bitrate_limit_factor: 1.5,
    ingress_bitrate_window_seconds: 10,
    ingress_bitrate_limit_probe_profile: "720p",
    media_stall_seconds: 5,
    heartbeat_interval_seconds: 2,
    heartbeat_lost_stop_seconds: 60,
    egress_buffer_limit_ms: 3000,
    egress_throttle_ms: 1500,
    ack_interval_ms: 500,
    report_interval_ms: 1000,
  },
  tickets: { ttl_seconds: 60 },
  // 期限（13.2）
  deadlines: {
    reserved_seconds: 90,
    awaiting_media_seconds: 30,
    confirming_seconds: 120,
    interrupted_relay_notified_seconds: 30,
    interrupted_heartbeat_lost_seconds: 75,
    heartbeat_lost_detect_seconds: 10,
    max_resumes: 10,
    live_confirm_poll_interval_seconds: 5,
    live_check_interval_seconds: 300,
    deadline_monitor_max_interval_seconds: 5,
    reconnect_backoff_cap_ms: 5000,
    time_limit_notice_before_seconds: 300,
    settlement_retry_delays_seconds: [60, 120, 240],
  },
  // 割り当て台帳（8.4）
  quota: {
    common_units: 500,
    safety_margin_units: 500,
    broadcast_usable_units_at_default: 9000,
    broadcast_reservation_units: 550,
    prep_reservation_units: 340,
    settle_reservation_units: 210,
    unit_costs: { list: 1, insert: 50, update: 50, bind: 50, transition: 50, delete: 50 },
  },
  // RTMPS の送出先の許可（10.1・28.1）と、開発用の疑似の取り込み口
  rtmps_ingest: {
    scheme: "rtmps",
    hosts: ["a.rtmps.youtube.com", "b.rtmps.youtube.com"],
    port: 443,
    userinfo_allowed: false,
    query_allowed: false,
  },
  dev_ingest: {
    scheme: "rtmps",
    host: "fake-ingest",
    port: 1935,
    tls: "self_signed",
    allowed_environments: ["development", "test"],
  },
  // 頻度（28.1）
  rate_limits: {
    login_start: { scope: "ip", limit: 30, window_seconds: 3600 },
    connect_start: { scope: "ip", limit: 30, window_seconds: 3600 },
    recheck_per_minute: { scope: "account", limit: 1, window_seconds: 60 },
    recheck_per_day: { scope: "account", limit: 20, window_seconds: 86400 },
    intake: { scope: "account", limit_setting: "intake_rate_per_hour", window_seconds: 3600 },
  },
  // 保持（20.3）
  retention: {
    youtube_broadcast_id_days_after_end: 30,
    health_samples_days: 30,
    broadcast_events_days: 30,
    relay_ticket_days_after_expiry: 1,
    session_days_after_last_use: 30,
    stream_id_days_after_last_verified: 30,
    channel_title_memory_max_minutes: 10,
  },
  // 設定の既定値（8 章）
  setting_defaults: {
    daily_allowance: 1,
    attempt_limit: 3,
    concurrent_limit: 3,
    time_limit_minutes: 60,
    intake_rate_per_hour: 10,
    monthly_transfer_budget_gb: 10,
    daily_quota_units: 10000,
    bot_score_threshold: 0.5,
    intake_paused: false,
  },
};

const valuesOf = (name) => enums.enums[name].values;

describe("limits.json の構造", () => {
  test("文書用のキーを除くと、設計メモの写しと完全に一致する（過不足なし）", () => {
    assert.deepEqual(limits, EXPECTED_LIMITS);
  });

  test("トップレベルのキーは、$comment と、設計メモのセクションだけ", () => {
    assert.deepEqual(
      Object.keys(contract)
        .filter((key) => key !== "$comment")
        .sort(),
      Object.keys(EXPECTED_LIMITS).sort(),
    );
    assert.equal(typeof contract.$comment, "string");
  });

  test("文書用のキー（*_note）は文字列", () => {
    const visit = (value, where) => {
      if (value !== null && typeof value === "object" && !Array.isArray(value)) {
        for (const [key, child] of Object.entries(value)) {
          if (isDocumentKey(key)) {
            assert.equal(typeof child, "string", `${where}.${key} が文字列ではありません`);
          } else {
            visit(child, `${where}.${key}`);
          }
        }
      }
    };
    visit(contract, "limits");
  });

  test("仮置きと外部事実の注記がある（bot 判定の閾値・RTMPS の許可ホスト・単価の出どころ・疑似の取り込み口）", () => {
    assert.match(contract.setting_defaults.bot_score_threshold_note, /仮置き/);
    assert.match(contract.setting_defaults.bot_score_threshold_note, /U4/);
    assert.match(contract.rtmps_ingest.note, /OBS/);
    assert.match(contract.rtmps_ingest.note, /実機/);
    assert.match(contract.quota.unit_costs_note, /determine_quota_cost/);
    assert.match(contract.dev_ingest.note, /production/);
  });

  test("数値は有限の数、真偽値は真偽値（NaN・文字列の数値を含まない）", () => {
    const visit = (value, where) => {
      if (Array.isArray(value)) {
        value.forEach((child, index) => visit(child, `${where}[${index}]`));
      } else if (value !== null && typeof value === "object") {
        for (const [key, child] of Object.entries(value)) {
          visit(child, `${where}.${key}`);
        }
      } else {
        assert.ok(["number", "boolean", "string"].includes(typeof value), `${where}: 型が不正（${typeof value}）`);
        if (typeof value === "number") {
          assert.ok(Number.isFinite(value), `${where}: 有限の数ではありません`);
        }
      }
    };
    visit(limits, "limits");
  });
});

describe("プロファイル（11.7・11.8）", () => {
  test("プロファイルのキーは、列挙 profile の値と一致する", () => {
    assert.deepEqual(Object.keys(limits.profiles), valuesOf("profile"));
  });

  for (const [profile, spec] of Object.entries(EXPECTED_LIMITS.profiles)) {
    test(`${profile}: 下限 < 初期値 < 上限、閾値は上限以下`, () => {
      const actual = limits.profiles[profile];
      assert.ok(actual.video_bitrate_min_kbps < actual.video_bitrate_initial_kbps);
      assert.ok(actual.video_bitrate_initial_kbps < actual.video_bitrate_max_kbps);
      assert.ok(actual.line_threshold_kbps < actual.video_bitrate_max_kbps + limits.audio.bitrate_kbps);
      assert.equal(actual.framerate, spec.framerate);
    });

    test(`${profile}: 回線の閾値は、（映像の下限 + 音声）の 1.3 倍を 100 kbps 単位に丸めた値（11.8）`, () => {
      const actual = limits.profiles[profile];
      const raw = (actual.video_bitrate_min_kbps + limits.audio.bitrate_kbps) * 1.3;
      assert.equal(Math.round(raw / 100) * 100, actual.line_threshold_kbps, `${raw} を丸めた値`);
    });
  }

  test("回線不足の境界は、軽量（480p）の閾値 1,200 kbps（30.3：上り回線の実効スループット）", () => {
    assert.equal(Math.min(...Object.values(limits.profiles).map((spec) => spec.line_threshold_kbps)), 1200);
  });

  test("標準（720p）の閾値は 4,100 kbps", () => {
    assert.equal(limits.profiles["720p"].line_threshold_kbps, 4100);
  });
});

describe("音声・メディアクロック（11.5・11.6）", () => {
  test("映像 1 フレーム = 音声 1,470 サンプル（44,100 ÷ 30）", () => {
    assert.equal(limits.audio.sample_rate_hz / limits.profiles["720p"].framerate, limits.audio.samples_per_video_frame);
    assert.equal(limits.audio.sample_rate_hz / limits.profiles["480p"].framerate, limits.audio.samples_per_video_frame);
  });

  test("キーフレーム間隔は 2 秒（YouTube の推奨。4 秒を超えない：3 章）", () => {
    assert.equal(limits.video.keyframe_interval_seconds, 2);
    assert.ok(limits.video.keyframe_interval_seconds <= 4);
  });

  test("H.264 のコーデック文字列は Level 3.1（末尾 1F）の Main と Constrained Baseline", () => {
    assert.match(limits.video.codec_main, /^avc1\.4D401F$/);
    assert.match(limits.video.codec_constrained_baseline, /^avc1\.42E01F$/);
  });
});

describe("適応制御（12 章）", () => {
  test("条件のキーは、列挙 adaptive_condition の値と一致する（12 章の表の 7 行の順）", () => {
    assert.deepEqual(Object.keys(limits.adaptive.conditions), valuesOf("adaptive_condition"));
  });

  test("引き下げ幅（30%）より引き上げ幅（10%）が小さい（回復を緩やかにする）", () => {
    const { backlog_high_twice: down, backlog_low_no_drop: up } = limits.adaptive.conditions;
    assert.ok(up.increase_percent < down.decrease_percent);
  });

  test("引き上げの条件（滞留が 0.3 秒未満）は、引き下げの条件（1.5 秒超）より小さい", () => {
    const { backlog_high_twice: down, backlog_low_no_drop: up } = limits.adaptive.conditions;
    assert.ok(up.backlog_under_ms < down.backlog_over_ms);
  });

  test("滞留の閾値は 1.5 秒 < 4 秒 < 8 秒の順（引き下げ・全破棄・再接続）", () => {
    const { backlog_high_twice: a, backlog_critical: b, backlog_severe_sustained: c } = limits.adaptive.conditions;
    assert.ok(a.backlog_over_ms < b.backlog_over_ms && b.backlog_over_ms < c.backlog_over_ms);
  });

  test("目標ビットレートの変更は 1 秒に 1 回まで = 評価の間隔（毎秒）", () => {
    assert.equal(limits.adaptive.target_change_min_interval_ms, limits.adaptive.evaluation_interval_ms);
  });
});

describe("WebSocket 転送フレーム（11.9）", () => {
  const frame = limits.ws_frame;

  test("識別子は 0x42 0x4C（\"BL\"）、版は 1、ヘッダは 17 バイト", () => {
    assert.deepEqual(frame.magic, [0x42, 0x4c]);
    assert.equal(String.fromCharCode(...frame.magic), "BL");
    assert.equal(frame.version, 1);
    assert.equal(frame.header_bytes, 17);
  });

  test("ヘッダの欄は隙間なく並び、長さの合計がヘッダの長さ（2・1・1・1・8・4）", () => {
    const fields = Object.entries(frame.header_fields);
    assert.deepEqual(
      fields.map(([name, { length }]) => [name, length]),
      [
        ["magic", 2],
        ["version", 1],
        ["type", 1],
        ["attributes", 1],
        ["timestamp_us", 8],
        ["body_length", 4],
      ],
    );
    let expectedOffset = 0;
    for (const [name, { offset, length }] of fields) {
      assert.equal(offset, expectedOffset, `${name} の位置`);
      expectedOffset += length;
    }
    assert.equal(expectedOffset, frame.header_bytes);
  });

  test("1 メッセージの上限は 2 MiB（2,097,152 バイト）", () => {
    assert.equal(frame.max_message_bytes, 2 * 1024 * 1024);
  });

  test("種別の名前は、列挙 ws_message_type の値と一致する（順も同じ）", () => {
    assert.deepEqual(Object.keys(frame.types), valuesOf("ws_message_type"));
  });

  test("種別符号は重複せず、0〜255 の範囲にある", () => {
    const codes = Object.values(frame.types).map(({ code }) => code);
    assert.equal(new Set(codes).size, codes.length, "種別符号が重複しています");
    for (const code of codes) {
      assert.ok(Number.isInteger(code) && code >= 0 && code <= 255, `範囲外: ${code}`);
    }
  });

  test("方向は directions の 2 つのどちらか。前の 7 種がブラウザ → 中継（0x01〜0x07）、後の 7 種が中継 → ブラウザ（0x81〜0x87）", () => {
    const entries = Object.entries(frame.types);
    assert.equal(entries.length, 14);
    entries.forEach(([name, { code, direction }], index) => {
      assert.ok(frame.directions.includes(direction), `${name}: 方向が不正`);
      if (index < 7) {
        assert.equal(direction, "browser_to_relay", name);
        assert.equal(code, 0x01 + index, name);
      } else {
        assert.equal(direction, "relay_to_browser", name);
        assert.equal(code, 0x81 + (index - 7), name);
      }
    });
  });

  test("方向は、種別符号の最上位ビットで決まる（0 = ブラウザ → 中継、1 = 中継 → ブラウザ）", () => {
    for (const [name, { code, direction }] of Object.entries(frame.types)) {
      assert.equal(direction, (code & 0x80) === 0 ? "browser_to_relay" : "relay_to_browser", name);
    }
  });

  test("テストの参照実装の表（ws_reference.mjs）と一致する", () => {
    assert.deepEqual(frame.types, REFERENCE_TYPES);
    assert.deepEqual(Object.values(INCOMING_DIRECTION).sort(), [...frame.directions].sort());
  });

  test("キーフレームの属性は bit0", () => {
    assert.equal(frame.keyframe_attribute_bit, 0);
  });
});

describe("中継・期限（11.9・11.10・13.2）", () => {
  const { relay, deadlines } = limits;

  test("中断の期限（中継の通知）30 秒は、YouTube の自動停止（送出の停止から約 1 分）より短い", () => {
    assert.ok(deadlines.interrupted_relay_notified_seconds < 60);
  });

  test("中断の期限（心拍の途絶）75 秒は、中継が自ら送出を止めるまでの時間 60 秒より長い", () => {
    assert.ok(deadlines.interrupted_heartbeat_lost_seconds > relay.heartbeat_lost_stop_seconds);
  });

  test("心拍の途絶の判定（10 秒）は、心拍の間隔（2 秒）の整数倍", () => {
    assert.equal(deadlines.heartbeat_lost_detect_seconds % relay.heartbeat_interval_seconds, 0);
  });

  test("抑制指示（1.5 秒分）は、送出待ちの上限（3 秒分）より小さい", () => {
    assert.ok(relay.egress_throttle_ms < relay.egress_buffer_limit_ms);
  });

  test("確定待ちの期限 120 秒 ÷ 確認の間隔 5 秒 = 24 回（8.4 の表）", () => {
    assert.equal(deadlines.confirming_seconds / deadlines.live_confirm_poll_interval_seconds, 24);
  });

  test("時間上限 60 分 ÷ 定期確認の間隔 5 分 = 12 回（8.4 の表）", () => {
    assert.equal((limits.setting_defaults.time_limit_minutes * 60) / deadlines.live_check_interval_seconds, 12);
  });

  test("清算の再試行は 1 分・2 分・4 分の最大 3 回（倍々）", () => {
    assert.deepEqual(deadlines.settlement_retry_delays_seconds, [60, 120, 240]);
  });

  test("心拍の応答が 60 秒得られなければ停止。再接続の待機の上限は 5 秒", () => {
    assert.equal(relay.heartbeat_lost_stop_seconds, 60);
    assert.equal(deadlines.reconnect_backoff_cap_ms, 5000);
  });

  test("計測中（プロファイル未確定）の受信上限に使うプロファイルは、列挙 profile の値（720p）", () => {
    assert.ok(valuesOf("profile").includes(relay.ingress_bitrate_limit_probe_profile));
    assert.equal(relay.ingress_bitrate_limit_probe_profile, "720p");
  });

  test("受信ビットレートの上限は、プロファイルの映像ビットレートの上限 × 1.5（720p は 9,000 kbps・480p は 3,750 kbps）", () => {
    const cap = (profile) => limits.profiles[profile].video_bitrate_max_kbps * relay.ingress_bitrate_limit_factor;
    assert.equal(cap("720p"), 9000);
    assert.equal(cap("480p"), 3750);
  });
});

describe("割り当て台帳（8.4）", () => {
  const { quota, setting_defaults: defaults } = limits;

  test("1 日の割り当て − 共通枠 − 安全余裕 = 配信に使える上限（9,000）", () => {
    assert.equal(defaults.daily_quota_units - quota.common_units - quota.safety_margin_units, quota.broadcast_usable_units_at_default);
  });

  test("配信 1 本の予約 550 = 準備・確認 340 + 終了・清算 210", () => {
    assert.equal(quota.prep_reservation_units + quota.settle_reservation_units, quota.broadcast_reservation_units);
  });

  test("すべての配信が予約を使い切る場合の、1 日の開始数は 16 本（9,000 ÷ 550）", () => {
    assert.equal(Math.floor(quota.broadcast_usable_units_at_default / quota.broadcast_reservation_units), 16);
  });

  test("単価は、一覧取得が 1、作成・更新・紐づけ・遷移・削除が各 50", () => {
    assert.deepEqual(quota.unit_costs, { list: 1, insert: 50, update: 50, bind: 50, transition: 50, delete: 50 });
  });
});

describe("RTMPS の送出先の許可・疑似の取り込み口", () => {
  const { rtmps_ingest: ingest, dev_ingest: dev } = limits;

  test("許可ホストは YouTube の取り込み口（.rtmps.youtube.com）で、ポートは 443 のみ、平文の RTMP を許さない", () => {
    assert.equal(ingest.scheme, "rtmps");
    assert.equal(ingest.port, 443);
    for (const host of ingest.hosts) {
      assert.match(host, /^[a-z]\.rtmps\.youtube\.com$/);
    }
    assert.equal(new Set(ingest.hosts).size, ingest.hosts.length);
  });

  test("ユーザー情報・クエリを許さない", () => {
    assert.equal(ingest.userinfo_allowed, false);
    assert.equal(ingest.query_allowed, false);
  });

  test("疑似の取り込み口は、開発・テストの環境だけで許可し、production に存在しない。本物の許可ホストと重ならない", () => {
    assert.deepEqual(dev.allowed_environments, ["development", "test"]);
    assert.ok(!dev.allowed_environments.includes("production"));
    assert.equal(dev.host, "fake-ingest");
    assert.equal(dev.port, 1935);
    assert.equal(dev.scheme, "rtmps");
    assert.ok(!ingest.hosts.includes(dev.host));
  });
});

describe("頻度・保持・設定の既定値", () => {
  test("受付の頻度の上限は、設定 intake_rate_per_hour（列挙 setting_key の値）で決まる", () => {
    assert.ok(valuesOf("setting_key").includes(limits.rate_limits.intake.limit_setting));
    assert.equal(limits.setting_defaults[limits.rate_limits.intake.limit_setting], 10);
  });

  test("設定の既定値のキーは、列挙 setting_key の 9 設定と一致する（順も同じ）", () => {
    assert.deepEqual(Object.keys(limits.setting_defaults), valuesOf("setting_key"));
  });

  test("頻度の枠の単位は、IP またはアカウント", () => {
    for (const [name, policy] of Object.entries(limits.rate_limits)) {
      assert.ok(["ip", "account"].includes(policy.scope), name);
      assert.ok(policy.window_seconds > 0, name);
    }
  });

  test("bot 判定の閾値は 0 より大きく 1 以下（reCAPTCHA v3 のスコア）", () => {
    const threshold = limits.setting_defaults.bot_score_threshold;
    assert.ok(threshold > 0 && threshold <= 1);
  });

  test("保持の期間はすべて正の整数", () => {
    for (const [name, value] of Object.entries(limits.retention)) {
      assert.ok(Number.isInteger(value) && value > 0, name);
    }
  });

  test("接続チケットは 60 秒で失効する（11.9）", () => {
    assert.equal(limits.tickets.ttl_seconds, 60);
  });
});
