/**
 * @jest-environment node
 */
import { YOUTUBE_CONNECTION_STATE_VALUES } from "@/core/contract";
import { t } from "@/messages";
import { chipViewFor, connectViewFor, guideFor, visibilityFor } from "./account-view";

// アカウント画面の、YouTube の接続状態ごとの表示の決め（チップ・案内文・操作）。モック（app-ui/Account.dc.html）の 4 状態。

describe("chipViewFor: 接続状態のチップ（文言と、形の異なる図形。色だけで区別しない）", () => {
  it.each([
    ["connected", "ok", "check", t("provisional.account.youtube.states.connected.chip")],
    ["not_connected", "neutral", "circle", t("provisional.account.youtube.states.notConnected.chip")],
    ["live_not_enabled", "warn", "warning", t("provisional.account.youtube.states.liveNotEnabled.chip")],
    ["revoked", "bad", "error", t("provisional.account.youtube.states.revoked.chip")],
  ] as const)("%s: 色 %s・図形 %s・文言", (state, tone, icon, label) => {
    expect(chipViewFor(state)).toEqual({ tone, icon, label });
  });

  it("4 状態の図形は、互いに異なる", () => {
    const icons = YOUTUBE_CONNECTION_STATE_VALUES.map((state) => chipViewFor(state).icon);

    expect(new Set(icons).size).toBe(4);
  });

  it("4 状態の文言は、互いに異なる", () => {
    const labels = YOUTUBE_CONNECTION_STATE_VALUES.map((state) => chipViewFor(state).label);

    expect(new Set(labels).size).toBe(4);
  });
});

describe("visibilityFor: 状態ごとに出す操作・行（モックのとおり）", () => {
  it.each([
    ["connected", { recheck: true, connect: true, disconnect: true, channel: true }],
    ["not_connected", { recheck: false, connect: true, disconnect: false, channel: false }],
    ["live_not_enabled", { recheck: true, connect: true, disconnect: true, channel: true }],
    ["revoked", { recheck: false, connect: true, disconnect: true, channel: false }],
  ] as const)("%s", (state, expected) => {
    expect(visibilityFor(state)).toEqual(expected);
  });
});

describe("connectViewFor: 接続の操作の文言と強調", () => {
  it.each([
    ["not_connected", t("provisional.account.youtube.actions.connect"), true],
    ["revoked", t("provisional.account.youtube.actions.reconnect"), true],
    ["connected", t("provisional.account.youtube.actions.reconnect"), false],
    ["live_not_enabled", t("provisional.account.youtube.actions.reconnect"), false],
  ] as const)("%s: 文言 %s・主要な操作（強調）= %s", (state, label, primary) => {
    expect(connectViewFor(state)).toEqual({ label, primary });
  });
});

describe("guideFor: 案内文（断定と対処）", () => {
  it("接続済み: 配信を開始できる旨。進行中の配信があるときは、開始できる旨を除く", () => {
    expect(guideFor("connected", { broadcasting: false, afterConnectFailure: false })).toBe(t("provisional.account.youtube.states.connected.guide"));
    expect(guideFor("connected", { broadcasting: true, afterConnectFailure: false })).toBe(
      t("provisional.account.youtube.states.connected.guideBroadcasting"),
    );
  });

  it("未接続: 接続を案内し、チャンネルが無い場合の作成も案内する。接続の不成立の通知があるときは、短い案内にする", () => {
    expect(guideFor("not_connected", { broadcasting: false, afterConnectFailure: false })).toBe(t("provisional.account.youtube.states.notConnected.guide"));
    expect(guideFor("not_connected", { broadcasting: false, afterConnectFailure: true })).toBe(
      t("provisional.account.youtube.states.notConnected.guideAfterFailure"),
    );
  });

  it("ライブ未有効: 有効にする手順と、再確認の操作を案内する", () => {
    expect(guideFor("live_not_enabled", { broadcasting: false, afterConnectFailure: false })).toBe(
      t("provisional.account.youtube.states.liveNotEnabled.guide"),
    );
  });

  it("認可失効: 再接続を案内する", () => {
    expect(guideFor("revoked", { broadcasting: false, afterConnectFailure: false })).toBe(t("provisional.account.youtube.states.revoked.guide"));
  });
});
