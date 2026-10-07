"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { LoginError } from "@/core/contract";
import {
  ApiAbortedError,
  ApiClient,
  browserNavigate,
  describeFailure,
  navigateToAuthorization,
  type Navigate,
} from "@/lib/api";
import { RECAPTCHA_ACTIONS, useRecaptcha } from "@/lib/recaptcha";
import { noticeForFailure, noticeForLoginError, type LoginNotice } from "./login-notices";

/** ログインのボタン（ヒーロー・最後の CTA）の場所。通知は、押したボタンの近くへ出す */
export type LoginPlacement = "hero" | "final";

/** ログイン済みか。unknown は、判定の前・判定に失敗したとき（ログインのボタンを出す） */
export type LandingSession = "unknown" | "anonymous" | "authenticated";

export interface PlacedLoginNotice {
  readonly notice: LoginNotice;
  readonly placement: LoginPlacement;
}

interface LandingLoginValue {
  readonly session: LandingSession;
  /** ログインの開始から、遷移（ページを離れる）までの間、真 */
  readonly busy: boolean;
  readonly notice: PlacedLoginNotice | null;
  login(placement: LoginPlacement): void;
}

const LandingLoginContext = createContext<LandingLoginValue | null>(null);

export interface LandingLoginProviderProps {
  /** URL の login_error（サーバー側で検証済み）。あれば、ヒーローに通知を出す */
  initialLoginError: LoginError | null;
  /** テストで差し替える。既定は、同一オリジンの /api/* を呼ぶクライアント */
  client?: ApiClient;
  /** テストで差し替える。既定は、ブラウザの遷移 */
  navigate?: Navigate;
  children: ReactNode;
}

/**
 * ランディングのログインの状態（ログイン済みか・処理中か・通知）と、操作（ログインの開始）を、配下のボタン・通知へ渡す。
 * 操作: bot 判定のトークン（行為名 login）を取得 → startLogin → 認可 URL（検査済み）へ遷移。
 * 処理中は、二重に開始しない。遷移を始めたあとは、ページを離れるまで処理中のまま（戻る操作で復元されたときは、解除する）。
 */
export function LandingLoginProvider({ initialLoginError, client, navigate = browserNavigate, children }: LandingLoginProviderProps) {
  const recaptcha = useRecaptcha();
  const [apiClient] = useState(() => client ?? new ApiClient());
  const [session, setSession] = useState<LandingSession>("unknown");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<PlacedLoginNotice | null>(
    initialLoginError === null ? null : { notice: noticeForLoginError(initialLoginError), placement: "hero" },
  );
  const inFlight = useRef(false);

  // ログイン済みかを、1 回だけ判定する。判定できなくても、ログインのボタンを出し続ける（通知は出さない。失敗は、コンソールへ）
  useEffect(() => {
    const controller = new AbortController();
    apiClient.getState({ signal: controller.signal }).then(
      (state) => setSession(state.authenticated ? "authenticated" : "anonymous"),
      (error: unknown) => {
        if (!(error instanceof ApiAbortedError)) {
          console.error(`landing: could not read the login state (${describeFailure(error)})`);
        }
      },
    );
    return () => controller.abort();
  }, [apiClient]);

  // 認可の画面から、戻る操作でこのページが復元されたとき（bfcache）、処理中のまま固まらないようにする
  useEffect(() => {
    const restore = (event: Event): void => {
      if ((event as PageTransitionEvent).persisted) {
        inFlight.current = false;
        setBusy(false);
      }
    };
    window.addEventListener("pageshow", restore);
    return () => window.removeEventListener("pageshow", restore);
  }, []);

  const login = useCallback(
    (placement: LoginPlacement): void => {
      if (inFlight.current) {
        return;
      }
      inFlight.current = true;
      setBusy(true);
      setNotice(null);
      (async () => {
        try {
          const token = await recaptcha.getToken(RECAPTCHA_ACTIONS.login);
          const { authorization_url: authorizationUrl } = await apiClient.startLogin(token);
          navigateToAuthorization(authorizationUrl, navigate);
        } catch (error) {
          console.error(`landing: login failed (${describeFailure(error)})`);
          const failure = noticeForFailure(error);
          inFlight.current = false;
          setBusy(false);
          setNotice(failure === null ? null : { notice: failure, placement });
        }
      })();
    },
    [apiClient, navigate, recaptcha],
  );

  const value = useMemo<LandingLoginValue>(() => ({ session, busy, notice, login }), [session, busy, notice, login]);
  return <LandingLoginContext.Provider value={value}>{children}</LandingLoginContext.Provider>;
}

/** ランディングのログインの状態と操作。LandingLoginProvider の配下で使う（無ければ、例外にする） */
export function useLandingLogin(): LandingLoginValue {
  const value = useContext(LandingLoginContext);
  if (value === null) {
    throw new Error("useLandingLogin must be used within LandingLoginProvider");
  }
  return value;
}
