import { useCallback, useEffect, useRef, useState } from "react";
import type { ConnectResult } from "@/core/contract";
import {
  ApiAbortedError,
  ApiClient,
  ApiError,
  describeFailure,
  formatApiTimestamp,
  navigateToAuthorization,
  type AuthenticatedState,
  type Navigate,
  type YoutubeView,
} from "@/lib/api";
import { RECAPTCHA_ACTIONS, type RecaptchaTokenSource } from "@/lib/recaptcha";
import { noticeForConnectResult, outcomeForFailure, type AccountAction, type AccountNotice } from "./account-notices";
import { CONNECT_QUERY, COOLDOWN_MARGIN_MS } from "./config";

/** 確認のダイアログを開く操作（取り消せない操作） */
export type DialogKind = "disconnect" | "delete";

export type AccountLoad =
  | { readonly status: "loading" }
  /** 状態を取得できなかった（再試行できる） */
  | { readonly status: "failed" }
  /** 未ログイン・セッション切れ。ランディングへ移るところ */
  | { readonly status: "redirecting" }
  | { readonly status: "ready"; readonly state: AuthenticatedState };

export interface DialogState {
  readonly kind: DialogKind;
  /** 確認の操作に失敗した（ダイアログの中に、失敗の通知を出す） */
  readonly failed: boolean;
}

export interface UseAccountOptions {
  readonly client: ApiClient;
  readonly recaptcha: RecaptchaTokenSource;
  /** ランディングへ移る（未ログイン・ログアウト・アカウントの削除） */
  readonly goHome: () => void;
  readonly navigate: Navigate;
  /** URL の connect（サーバー側で検証済み）。不成立なら、通知を出す */
  readonly initialConnectResult: ConnectResult | null;
  /** 現在時刻（ミリ秒）。再確認できる時刻の判定に使う。テストで差し替える */
  readonly now: () => number;
}

export interface AccountController {
  readonly load: AccountLoad;
  readonly notice: AccountNotice | null;
  /** 処理中の操作。成功して画面が移る操作（接続・ログアウト・削除）は、移るまで、処理中のまま */
  readonly pending: AccountAction | null;
  readonly dialog: DialogState | null;
  /** 再確認できる時刻まで、再確認を無効にしている */
  readonly cooling: boolean;
  /** 再確認できる時刻（JST の日時の文字列）。無効にしている間だけ */
  readonly recheckAvailableAt: string | null;
  reload(): void;
  recheck(): void;
  connect(): void;
  logout(): void;
  openDialog(kind: DialogKind): void;
  closeDialog(): void;
  confirmDialog(): void;
}

/** 状態の取得の結果（画面への反映は、applyLoadResult） */
type LoadResult =
  | { readonly type: "ready"; readonly state: AuthenticatedState }
  | { readonly type: "unauthenticated" }
  | { readonly type: "failed" }
  | { readonly type: "aborted" };

function parseTime(value: string | null): number | null {
  if (value === null) {
    return null;
  }
  const time = Date.parse(value);
  return Number.isNaN(time) ? null : time;
}

/** 状態の YouTube の接続を置き換える（チャンネル名は、再確認の応答に含まれないため、保持している値を引き継ぐ） */
function withYoutube(load: AccountLoad, youtube: YoutubeView, keepChannelTitle: boolean): AccountLoad {
  if (load.status !== "ready") {
    return load;
  }
  const channelTitle = keepChannelTitle ? load.state.youtube.channel_title : youtube.channel_title;
  return { status: "ready", state: { ...load.state, youtube: { ...youtube, channel_title: channelTitle } } };
}

/**
 * アカウント画面の状態と操作（要件 7.2・7.4・16.1）。
 *   - 画面の初期化: getState（チャンネル名つき）。未ログインはランディングへ。URL の connect は、読んだあと、URL から取り除く
 *   - 再確認・接続（bot 判定 → 認可 URL へ遷移）・接続の解除・アカウントの削除（確認のダイアログ → API）・ログアウト
 *   - 失敗は、account-notices.ts の対応（通知・状態の取得し直し・ランディングへ）。処理中は、二重に操作を始めない
 */
export function useAccount(options: UseAccountOptions): AccountController {
  const { client, recaptcha, goHome, navigate, initialConnectResult, now } = options;
  const [load, setLoad] = useState<AccountLoad>({ status: "loading" });
  const [notice, setNotice] = useState<AccountNotice | null>(() =>
    initialConnectResult === null ? null : noticeForConnectResult(initialConnectResult),
  );
  const [pending, setPending] = useState<AccountAction | null>(null);
  const [dialog, setDialog] = useState<DialogState | null>(null);
  const [canRecheckAt, setCanRecheckAt] = useState<string | null>(null);
  const [nowMs, setNowMs] = useState<number>(() => now());
  const inFlight = useRef(false);

  /** 再確認できる時刻を設定する（時刻の判定に使う現在時刻も、同時に更新する） */
  const applyCooldown = useCallback(
    (value: string | null): void => {
      setCanRecheckAt(value);
      setNowMs(now());
    },
    [now],
  );

  /** 状態を取得する（状態は変えない）。結果は、applyLoadResult で、画面へ反映する */
  const loadState = useCallback(
    async (signal?: AbortSignal): Promise<LoadResult> => {
      try {
        const state = await client.getState({ withChannel: true, signal });
        return state.authenticated ? { type: "ready", state } : { type: "unauthenticated" };
      } catch (error) {
        if (error instanceof ApiAbortedError) {
          return { type: "aborted" };
        }
        console.error(`account: could not read the state (${describeFailure(error)})`);
        return { type: "failed" };
      }
    },
    [client],
  );

  /** 取得した状態を画面へ反映する。未ログインなら、ランディングへ。取得に失敗したら、再試行できる表示にする */
  const applyLoadResult = useCallback(
    (result: LoadResult): void => {
      switch (result.type) {
        case "ready":
          setLoad({ status: "ready", state: result.state });
          applyCooldown(result.state.youtube.can_recheck_at);
          return;
        case "unauthenticated":
          setLoad({ status: "redirecting" });
          goHome();
          return;
        case "failed":
          setLoad({ status: "failed" });
          return;
        case "aborted":
          return;
      }
    },
    [applyCooldown, goHome],
  );

  const refresh = useCallback(async (): Promise<void> => {
    applyLoadResult(await loadState());
  }, [applyLoadResult, loadState]);

  useEffect(() => {
    const controller = new AbortController();
    loadState(controller.signal).then(applyLoadResult);
    return () => controller.abort();
  }, [applyLoadResult, loadState]);

  // 結果のクエリ（?connect=...）は、読んだあと、URL から取り除く（履歴を増やさず、再読み込みで、通知を繰り返さない）
  useEffect(() => {
    const url = new URL(window.location.href);
    if (url.searchParams.has(CONNECT_QUERY)) {
      url.searchParams.delete(CONNECT_QUERY);
      window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
    }
  }, []);

  // 認可の画面から、戻る操作でこのページが復元されたとき（bfcache）、処理中のまま固まらないようにする
  useEffect(() => {
    const restore = (event: Event): void => {
      if ((event as PageTransitionEvent).persisted) {
        inFlight.current = false;
        setPending(null);
        setDialog((current) => (current === null ? null : { ...current, failed: false }));
      }
    };
    window.addEventListener("pageshow", restore);
    return () => window.removeEventListener("pageshow", restore);
  }, []);

  // 再確認できる時刻まで、時刻になったら、無効を解く
  const cooldownUntil = parseTime(canRecheckAt);
  const cooling = cooldownUntil !== null && cooldownUntil > nowMs;
  useEffect(() => {
    if (cooldownUntil === null || cooldownUntil <= nowMs) {
      return undefined;
    }
    const timer = setTimeout(() => setNowMs(now()), Math.max(cooldownUntil - now(), 0) + COOLDOWN_MARGIN_MS);
    return () => clearTimeout(timer);
  }, [cooldownUntil, nowMs, now]);

  /** 失敗への対応（通知・状態の取得し直し・ランディングへ）。ダイアログの中の操作の失敗は、ダイアログの中に出す */
  const handleFailure = useCallback(
    async (error: unknown, action: AccountAction, inDialog: DialogKind | null): Promise<void> => {
      console.error(`account: ${action} failed (${describeFailure(error)})`);
      const outcome = outcomeForFailure(error, action);
      switch (outcome.type) {
        case "redirect_home":
          setLoad({ status: "redirecting" });
          goHome();
          return;
        case "refresh":
          setNotice(outcome.notice);
          setDialog(null);
          await refresh();
          return;
        case "notice":
          if (inDialog !== null) {
            setDialog({ kind: inDialog, failed: true });
          } else {
            setNotice(outcome.notice);
          }
          if (action === "recheck" && error instanceof ApiError && error.code === "rate_limited") {
            applyCooldown(error.retryAt);
          }
          return;
        case "ignore":
          return;
      }
    },
    [applyCooldown, goHome, refresh],
  );

  const recheck = useCallback((): void => {
    if (inFlight.current || load.status !== "ready") {
      return;
    }
    inFlight.current = true;
    setPending("recheck");
    setNotice(null);
    (async () => {
      try {
        const youtube = await client.recheckYouTube();
        setLoad((current) => withYoutube(current, youtube, true));
        applyCooldown(youtube.can_recheck_at);
      } catch (error) {
        await handleFailure(error, "recheck", null);
      } finally {
        inFlight.current = false;
        setPending(null);
      }
    })();
  }, [applyCooldown, client, handleFailure, load.status]);

  const connect = useCallback((): void => {
    if (inFlight.current || load.status !== "ready") {
      return;
    }
    inFlight.current = true;
    setPending("connect");
    setNotice(null);
    (async () => {
      try {
        const token = await recaptcha.getToken(RECAPTCHA_ACTIONS.youtubeConnect);
        const { authorization_url: authorizationUrl } = await client.startYouTubeConnect(token);
        // 成功したら、Google の認可の画面へ移る。ページを離れるまで、処理中のまま（二重に始めない）
        navigateToAuthorization(authorizationUrl, navigate);
      } catch (error) {
        inFlight.current = false;
        setPending(null);
        await handleFailure(error, "connect", null);
      }
    })();
  }, [client, handleFailure, load.status, navigate, recaptcha]);

  const logout = useCallback((): void => {
    if (inFlight.current || load.status !== "ready") {
      return;
    }
    inFlight.current = true;
    setPending("logout");
    setNotice(null);
    (async () => {
      try {
        await client.logout();
        // 成功したら、ランディングへ移る。移るまで、処理中のまま
        goHome();
      } catch (error) {
        inFlight.current = false;
        setPending(null);
        await handleFailure(error, "logout", null);
      }
    })();
  }, [client, goHome, handleFailure, load.status]);

  const openDialog = useCallback(
    (kind: DialogKind): void => {
      if (inFlight.current || load.status !== "ready" || load.state.broadcast !== null) {
        return;
      }
      setNotice(null);
      setDialog({ kind, failed: false });
    },
    [load],
  );

  const closeDialog = useCallback((): void => {
    if (inFlight.current) {
      return;
    }
    setDialog(null);
  }, []);

  const confirmDialog = useCallback((): void => {
    if (inFlight.current || dialog === null) {
      return;
    }
    const { kind } = dialog;
    inFlight.current = true;
    setPending(kind);
    setDialog({ kind, failed: false });
    (async () => {
      try {
        if (kind === "disconnect") {
          const youtube = await client.disconnectYouTube();
          setLoad((current) => withYoutube(current, youtube, false));
          applyCooldown(youtube.can_recheck_at);
          setDialog(null);
          inFlight.current = false;
          setPending(null);
        } else {
          await client.deleteAccount();
          // 成功したら、ランディングへ移る。移るまで、ダイアログを開いたまま、処理中のまま（二重に押せない）
          goHome();
        }
      } catch (error) {
        inFlight.current = false;
        setPending(null);
        await handleFailure(error, kind, kind);
      }
    })();
  }, [applyCooldown, client, dialog, goHome, handleFailure]);

  const reload = useCallback((): void => {
    setLoad({ status: "loading" });
    refresh();
  }, [refresh]);

  const availableAt = cooling ? formatApiTimestamp(canRecheckAt) : null;
  return {
    load,
    notice,
    pending,
    dialog,
    cooling,
    recheckAvailableAt: availableAt,
    reload,
    recheck,
    connect,
    logout,
    openDialog,
    closeDialog,
    confirmDialog,
  };
}
