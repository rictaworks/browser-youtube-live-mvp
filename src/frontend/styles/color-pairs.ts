// 実際に使う色の組（文字と背景・操作部品の境界・状態の図形）。contrast.test.ts が、トークンの値からコントラスト比を計算して検査する。
// 値（色）は書かない。トークンの名前（tokens/colors.css・app-colors.css）だけを書く。
// 新しい色の組を CSS へ足したら、ここへ足す（color-usage.test.ts が、足し忘れを検知する）。

/** text = 文字と背景（4.5:1）、boundary = 操作部品の境界（3:1）、graphic = 状態の図形（アイコン・フォーカスの輪郭。3:1） */
export type PairKind = "text" | "boundary" | "graphic";

export const MINIMUM_RATIO: Readonly<Record<PairKind, number>> = { text: 4.5, boundary: 3, graphic: 3 };

export interface ColorPair {
  readonly id: string;
  /** どこで使うか（部品・状態） */
  readonly use: string;
  readonly kind: PairKind;
  /** 前景（文字・境界線・図形）のトークン */
  readonly foreground: string;
  /** 背景の層（下から。最下層は不透明）。前景が載る面と、その面が自分で重ねる色（ボタンの色味など） */
  readonly surface: readonly string[];
  /** 無効の状態。基準に届かないが、WCAG 2.2 の 1.4.3・1.4.11 は無効の部品を対象外とする（理由）。基準へ届いたら、この注記を外す */
  readonly inactive?: string;
}

// 面（背景の層）。ページの背景は --bg、カードはその上に --card-bg（半透明）、通知は色味を重ねる。
const PAGE = ["--bg"] as const;
const CARD = ["--bg", "--card-bg"] as const;
const FOOTER = ["--bg-footer"] as const;
const NOTICE_INFO = ["--bg", "--teal-05"] as const;
const NOTICE_WARNING = ["--bg", "--warn-bg"] as const;
const NOTICE_ERROR = ["--bg", "--live-bg"] as const;

// ボタンが載る面: ページ・カード・エラーの通知（対処の操作の欄）
const BUTTON_SURFACES = [
  ["page", PAGE],
  ["card", CARD],
  ["notice-error", NOTICE_ERROR],
] as const;

const DISABLED_EXEMPTION = "無効の部品は WCAG 2.2 の 1.4.11 の対象外（要件 17.2 は免除を明記していない。要判断）";

function pair(
  kind: PairKind,
  id: string,
  use: string,
  foreground: string,
  surface: readonly string[],
  inactive?: string,
): ColorPair {
  return inactive === undefined ? { id, use, kind, foreground, surface } : { id, use, kind, foreground, surface, inactive };
}

const buttonPairs: ColorPair[] = BUTTON_SURFACES.flatMap(([name, surface]) => [
  pair("text", `button.default.${name}`, `ボタン（通常）の文字・ホバー前（${name}）`, "--silver", surface),
  pair("text", `button.default.hover.${name}`, `ボタン（通常）のホバーの文字（${name}）`, "--teal", surface),
  pair("text", `button.default.pressed.${name}`, `ボタン（通常）の押下の文字（${name}）`, "--teal", [...surface, "--teal-10"]),
  pair("text", `button.primary.${name}`, `ボタン（主要）の文字（${name}）`, "--teal", [...surface, "--teal-05"]),
  pair("text", `button.primary.hover.${name}`, `ボタン（主要）のホバーの文字（${name}）`, "--teal", [...surface, "--teal-dim"]),
  pair("text", `button.primary.pressed.${name}`, `ボタン（主要）の押下の文字（${name}）`, "--teal", [...surface, "--teal-30"]),
  pair("text", `button.stop.${name}`, `ボタン（停止・ライブ）の文字（${name}）`, "--white", [...surface, "--live-bg"]),
  pair("text", `button.disabled.${name}`, `ボタン（無効・処理中）の文字（${name}）`, "--silver-70", surface),
  pair("boundary", `button.default.border.${name}`, `ボタン（通常）の枠（${name}）`, "--silver-60", surface),
  pair("boundary", `button.primary.border.${name}`, `ボタン（主要）の枠・ホバーの枠（${name}）`, "--teal", surface),
  pair("boundary", `button.stop.border.${name}`, `ボタン（停止・ライブ）の枠（${name}）`, "--live", surface),
]);

const disabledBorderPairs: ColorPair[] = [
  pair("boundary", "button.disabled.border.page", "ボタン（無効・処理中）の枠（page）", "--silver-40", PAGE, DISABLED_EXEMPTION),
  pair("boundary", "button.disabled.border.card", "ボタン（無効・処理中）の枠（card）", "--silver-40", CARD, DISABLED_EXEMPTION),
];

const chipPairs: ColorPair[] = [
  pair("text", "chip.neutral.text", "チップ（未取得など）の文字", "--silver", CARD),
  pair("boundary", "chip.neutral.border", "チップ（未取得など）の枠", "--silver-60", CARD),
  pair("text", "chip.ok.text", "チップ（取得済み）の文字", "--teal", CARD),
  pair("boundary", "chip.ok.border", "チップ（取得済み）の枠", "--teal-50", CARD),
  pair("text", "chip.warn.text", "チップ（警告・喪失）の文字", "--warn", CARD),
  pair("boundary", "chip.warn.border", "チップ（警告・喪失）の枠", "--warn", CARD),
  pair("text", "chip.bad.text", "チップ（拒否・エラー）の文字", "--white", CARD),
  pair("boundary", "chip.bad.border", "チップ（拒否・エラー）の枠", "--live", CARD),
  pair("graphic", "chip.bad.icon", "チップ（拒否・エラー）のアイコン（ライブの赤）", "--live", CARD),
];

const noticePairs: ColorPair[] = [
  pair("text", "notice.info.text", "通知（情報）の文字", "--white", NOTICE_INFO),
  pair("graphic", "notice.info.icon", "通知（情報）のアイコン", "--teal", NOTICE_INFO),
  pair("text", "notice.warning.text", "通知（警告）の文字", "--white", NOTICE_WARNING),
  pair("graphic", "notice.warning.icon", "通知（警告）のアイコン（警告の琥珀）", "--warn", NOTICE_WARNING),
  pair("text", "notice.error.text", "通知（エラー）の文字", "--white", NOTICE_ERROR),
  pair("graphic", "notice.error.icon", "通知（エラー）のアイコン（ライブの赤）", "--live", NOTICE_ERROR),
];

const FOCUS_SURFACES = [
  ["page", PAGE],
  ["card", CARD],
  ["footer", FOOTER],
  ["notice-info", NOTICE_INFO],
  ["notice-warning", NOTICE_WARNING],
  ["notice-error", NOTICE_ERROR],
] as const;

const focusPairs: ColorPair[] = FOCUS_SURFACES.map(([name, surface]) =>
  pair("graphic", `focus.ring.${name}`, `フォーカスの輪郭（${name}）`, "--white", surface),
);

export const COLOR_PAIRS: readonly ColorPair[] = [
  // 本文・見出し・補足・強調（ページ・カード・フッター）
  pair("text", "text.primary.page", "本文・見出し（ページ題・ワードマーク）", "--white", PAGE),
  pair("text", "text.primary.card", "本文・見出し（カードの値）", "--white", CARD),
  pair("text", "text.body.page", "本文（リンクの既定の色）", "--silver", PAGE),
  pair("text", "text.body.card", "本文（カードの説明）", "--silver", CARD),
  pair("text", "text.body.footer", "本文（フッターのリンク）", "--silver", FOOTER),
  pair("text", "text.secondary.page", "補足（ナビのリンク・副題）", "--silver-70", PAGE),
  pair("text", "text.secondary.card", "補足（カードの項目名）", "--silver-70", CARD),
  pair("text", "text.accent.page", "強調（ワードマークの強調・ナビの現在位置・ホバー）", "--teal", PAGE),
  pair("text", "text.accent.card", "強調（カードの中のリンク）", "--teal", CARD),
  pair("text", "text.accent.footer", "強調（フッターのリンクのホバー・スキップリンクの枠）", "--teal", FOOTER),
  pair("text", "text.eyebrow.card", "補足（カードの見出しのアイブロウ）", "--section-label", CARD),
  pair("text", "skiplink.text", "スキップリンクの文字", "--white", FOOTER),
  ...buttonPairs,
  ...disabledBorderPairs,
  ...chipPairs,
  ...noticePairs,
  ...focusPairs,
];
