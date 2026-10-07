import { createTranslator, type MessageKeys } from "@/lib/messages";
import { ja } from "./ja";

export { ja };

/** 文言のキー（例: "provisional.terms.service.body"）。存在しないキーは、型の検査で弾く。 */
export type MessageKey = MessageKeys<typeof ja>;

/**
 * 翻訳関数。t(key) で文言を返す。文言に {name} があれば、t(key, { name: ... }) で値を渡す。
 * 存在しないキー・足りない値は、既定の文言を補わず、例外にする。
 */
export const t = createTranslator(ja);
