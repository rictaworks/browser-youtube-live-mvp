// 回線計測（requirements.md 11.8）の、注入する境界の型。実際の WebSocket・タイマは、#27・#28 が、この型に合わせて実装する。

/**
 * 中継との計測の経路。実際の WebSocket（probe の送信と、probe_result の受信）を、この形で包む。
 * 計測データは、probe フレームの本文（任意のバイト列）。フレーム（ヘッダ 17 バイト）にするのは、実装側（FrameCodec.encode({ type: "probe", payload })）。
 */
export interface ProbeChannel {
  /**
   * 計測データを 1 つ送る。同期でも、非同期（Promise）でもよい。非同期なら、そのデータを、送信側が受け付けてから（送信の詰まりが解けてから）解決する。
   * 失敗は、例外（Promise なら拒否）で返す（黙って捨てない）。
   */
  sendProbe(bytes: Uint8Array): void | Promise<void>;

  /**
   * 計測結果（probe_result の throughput_kbps）の受信を登録する。解除の関数を返す。
   * 結果は 1 回だけ届く（中継は、最初の計測データから 3 秒後に 1 回だけ返す）。
   */
  onProbeResult(callback: (throughputKbps: number) => void): () => void;
}

/**
 * 計測が使う時計（実時計・タイマを、Domain Core が直接持たないための注入）。
 * 時刻は、単調に増える任意の基準のミリ秒（performance.now() の値でも、テストの仮想の時刻でもよい）。
 */
export interface ProbeClock {
  /** 現在時刻（ミリ秒）。単調に増える */
  nowMs(): number;
  /** milliseconds ミリ秒のあとに解決する。0 以下なら、すぐ解決してよい */
  wait(milliseconds: number): Promise<void>;
}

export interface UplinkProbeOptions {
  /** 計測の長さ（ミリ秒）。既定は契約の line_probe.duration_seconds（3 秒） */
  readonly durationMs?: number;
  /** 最大の送信レート（kbps）。既定は契約の line_probe.max_rate_kbps（6,000） */
  readonly maxRateKbps?: number;
  /** 計測データ（フレームの本文）の大きさ（バイト）。既定は契約の line_probe.message_bytes_hint（32,768） */
  readonly messageBytes?: number;
  /** 窓（計測の長さ）が終わってから、結果を待つ猶予（ミリ秒）。既定は DEFAULT_RESULT_GRACE_MS */
  readonly resultGraceMs?: number;
  /** 計測データの擬似乱数の種（1 以上、2^32 未満の整数）。同じ種からは、同じ内容 */
  readonly seed?: number;
}
