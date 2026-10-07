import { isLoginError, type LoginError } from "@/core/contract";
import { EnvironmentSection } from "@/components/landing/EnvironmentSection";
import { FinalSection } from "@/components/landing/FinalSection";
import { HeroSection } from "@/components/landing/HeroSection";
import { LandingLoginProvider } from "@/components/landing/LandingLogin";
import { LimitsSection } from "@/components/landing/LimitsSection";
import { ValueSection } from "@/components/landing/ValueSection";
import { LOGIN_ERROR_QUERY } from "@/components/landing/config";

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

/** URL の login_error（認可コードのコールバックの失敗）を検証する。未知の値・複数の値は、無いものとして扱う（別の通知へ倒さない） */
function parseLoginError(value: string | string[] | undefined): LoginError | null {
  return typeof value === "string" && isLoginError(value) ? value : null;
}

/**
 * ランディング（/）。ログイン不要。提供価値・制限・対応環境の説明と、Google ログインの操作（requirements.md 16.1）。
 * 構成・文言は app-ui/Landing.dc.html（文言は仮置き。公開用の文章は Gemini が書く）。
 * ログインの拒否・失敗（/?login_error=registration_held・oauth_failed）は、通知で示す。
 * ルートのレイアウトが動的（bot 判定のサイトキーを、要求のたびに読む）のため、この画面も、要求のたびに描画する。
 */
export default async function HomePage({ searchParams }: { searchParams: SearchParams }) {
  const query = await searchParams;
  return (
    <LandingLoginProvider initialLoginError={parseLoginError(query[LOGIN_ERROR_QUERY])}>
      <HeroSection />
      <ValueSection />
      <LimitsSection />
      <EnvironmentSection />
      <FinalSection />
    </LandingLoginProvider>
  );
}
