// 状態報告（report。ws-protocol.md の 5.6）に載せる、ブラウザ側の出来事の型（ドメインの形）。
// 出来事は、符号と数値だけで表す（自由記述の文字列・ソースのデバイス名・ラベルを、型の上で持てない）。
// ワイヤ（JSON の detail）への変換は ReportBuilder が行う：
//   source_added・source_lost       detail = { source: <列挙 source_kind の値> }
//   fallback_switched               detail = { layout: <列挙 layout の値> }
//   bitrate_down・bitrate_up        detail = { from_kbps, to_kbps }
//   video_dropped                   detail = { frames }（破棄した映像のフレーム数が分かるとき。分からなければ detail なし）
//   degraded_started・degraded_cleared   detail なし

import type { Layout, SourceKind } from "../contract";

export type BrowserEvent =
  | { readonly kind: "source_added"; readonly source: SourceKind }
  | { readonly kind: "source_lost"; readonly source: SourceKind }
  | { readonly kind: "fallback_switched"; readonly layout: Layout }
  | { readonly kind: "bitrate_down"; readonly fromKbps: number; readonly toKbps: number }
  | { readonly kind: "bitrate_up"; readonly fromKbps: number; readonly toKbps: number }
  | { readonly kind: "video_dropped"; readonly frames?: number }
  | { readonly kind: "degraded_started" }
  | { readonly kind: "degraded_cleared" };
