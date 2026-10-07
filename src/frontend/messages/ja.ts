// 文言カタログ（日本語版のみ）。利用者に表示する文字列（見出し・案内・ボタン・エラー・ラベル）は、すべて messages/ へ置く。
// 取り出しは t(key, params?)（index.ts）。キーは、名前空間をドットでつないだ文字列（例: "provisional.terms.service.body"）。
//
// 【仮置き】本文は、app-ui/ のモックの語句をそのまま写したもので、公開用の文章ではない。
// 利用者が読む文章は Gemini が書く（CLAUDE.md「執筆体制」）。仮置きの文言は、すべて名前空間 provisional の下に置く。
// 公開用の文章が確定したら、その名前空間を provisional の外へ移す（ja.test.ts の「最上位」の検査も更新する）。
// モックに無い文言（requirements.md の語句と 17.1「断定と対処」で補った最小の文）は、各ファイルのコメントで「モックに無い」と示す。
// 外部リンクの URL は、モックのまま。確認済みではない（GPT のファクトチェック未実施。app-ui/README.md）。
//
// 後続の画面は、messages/<名前空間>.ts を足し、ここへ 1 行で登録する（例: landing・studio・account）。
import { BRAND_NAME } from "@/config/brand";
import { common } from "./common";
import { privacy } from "./privacy";
import { system } from "./system";
import { terms } from "./terms";

export const ja = {
  // 製品名は設定の定数（config/brand.ts）。文章ではないため、provisional の外に置く
  brand: { name: BRAND_NAME },
  provisional: {
    ...common,
    ...system,
    terms,
    privacy,
  },
} as const;
