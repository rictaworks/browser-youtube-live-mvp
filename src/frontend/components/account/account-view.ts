import type { YoutubeConnectionState } from "@/core/contract";
import type { ChipTone } from "@/components/ui";
import { t } from "@/messages";
import type { AccountIconName } from "./icons";

// YouTube の接続状態（契約の列挙 youtube_connection_state の 4 値）ごとの、表示の決め。出どころ: app-ui/Account.dc.html の 4 状態。

export interface ChipView {
  readonly tone: ChipTone;
  readonly icon: AccountIconName;
  readonly label: string;
}

/** 接続状態のチップ。文言と、状態ごとに形の異なる図形を伴う（色だけで区別しない。要件 17.2） */
export function chipViewFor(state: YoutubeConnectionState): ChipView {
  switch (state) {
    case "connected":
      return { tone: "ok", icon: "check", label: t("provisional.account.youtube.states.connected.chip") };
    case "not_connected":
      return { tone: "neutral", icon: "circle", label: t("provisional.account.youtube.states.notConnected.chip") };
    case "live_not_enabled":
      return { tone: "warn", icon: "warning", label: t("provisional.account.youtube.states.liveNotEnabled.chip") };
    case "revoked":
      return { tone: "bad", icon: "error", label: t("provisional.account.youtube.states.revoked.chip") };
  }
}

export interface ActionVisibility {
  /** 再確認（ライブ配信が有効かの確認）。接続済み・ライブ未有効 */
  readonly recheck: boolean;
  /** 接続・再接続。すべての状態 */
  readonly connect: boolean;
  /** 接続の解除。未接続以外 */
  readonly disconnect: boolean;
  /** 接続先のチャンネルの行と、チャンネル名の扱いの注記。接続済み・ライブ未有効 */
  readonly channel: boolean;
}

export function visibilityFor(state: YoutubeConnectionState): ActionVisibility {
  switch (state) {
    case "connected":
    case "live_not_enabled":
      return { recheck: true, connect: true, disconnect: true, channel: true };
    case "not_connected":
      return { recheck: false, connect: true, disconnect: false, channel: false };
    case "revoked":
      return { recheck: false, connect: true, disconnect: true, channel: false };
  }
}

export interface ConnectView {
  readonly label: string;
  /** 次に取れる操作として、強調する（未接続・認可失効）。接続済み・ライブ未有効の再接続は、強調しない */
  readonly primary: boolean;
}

export function connectViewFor(state: YoutubeConnectionState): ConnectView {
  if (state === "not_connected") {
    return { label: t("provisional.account.youtube.actions.connect"), primary: true };
  }
  return { label: t("provisional.account.youtube.actions.reconnect"), primary: state === "revoked" };
}

export interface GuideContext {
  /** 進行中の配信がある */
  readonly broadcasting: boolean;
  /** 接続の不成立の通知（権限の拒否・更新トークンなし・チャンネルなし）を出している */
  readonly afterConnectFailure: boolean;
}

/** 接続状態ごとの案内文（断定と対処。要件 7.2 の表） */
export function guideFor(state: YoutubeConnectionState, context: GuideContext): string {
  switch (state) {
    case "connected":
      return context.broadcasting
        ? t("provisional.account.youtube.states.connected.guideBroadcasting")
        : t("provisional.account.youtube.states.connected.guide");
    case "not_connected":
      return context.afterConnectFailure
        ? t("provisional.account.youtube.states.notConnected.guideAfterFailure")
        : t("provisional.account.youtube.states.notConnected.guide");
    case "live_not_enabled":
      return t("provisional.account.youtube.states.liveNotEnabled.guide");
    case "revoked":
      return t("provisional.account.youtube.states.revoked.guide");
  }
}
