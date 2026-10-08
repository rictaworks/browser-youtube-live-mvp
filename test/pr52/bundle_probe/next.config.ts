import type { NextConfig } from "next";

// 確認用の設定。作業用のディレクトリの node_modules は、リポジトリの src/frontend/node_modules への参照なので、Turbopack の root を広げる。
// 型の検査は、リポジトリの tsc（scripts/dc.sh exec -T frontend npx tsc --noEmit）が受け持つので、ここでは行わない。
const nextConfig: NextConfig = {
  poweredByHeader: false,
  turbopack: { root: "/" },
  typescript: { ignoreBuildErrors: true },
};

export default nextConfig;
