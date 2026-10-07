"use client";

import { Button, ButtonLink } from "@/components/ui";
import { t } from "@/messages";
import { STUDIO_ROUTE } from "./config";
import { LandingIcon } from "./LandingIcon";
import { useLandingLogin, type LoginPlacement } from "./LandingLogin";
import styles from "./LoginButton.module.css";

export interface LoginButtonProps {
  /** ヒーローか、最後の CTA か（通知を、押した場所の近くへ出すため） */
  placement: LoginPlacement;
}

/**
 * 「LOG IN WITH GOOGLE」。押すと、bot 判定 → ログインの開始 → Google の認可の画面へ遷移する。
 * 処理中は、文言が進行形になり、二重に押せない。ログイン済みなら、スタジオへ誘導するリンクに替わる（開発者向けの近道は、出さない）。
 */
export function LoginButton({ placement }: LoginButtonProps) {
  const { session, busy, login } = useLandingLogin();

  if (session === "authenticated") {
    return (
      <ButtonLink href={STUDIO_ROUTE} variant="primary" className={styles.cta}>
        {t("provisional.landing.hero.openStudio")}
        <LandingIcon name="next" />
      </ButtonLink>
    );
  }
  return (
    <Button
      variant="primary"
      className={styles.cta}
      busy={busy}
      busyLabel={t("provisional.landing.hero.loginBusy")}
      onClick={() => login(placement)}
    >
      {t("provisional.landing.hero.login")}
      <LandingIcon name="next" />
    </Button>
  );
}
