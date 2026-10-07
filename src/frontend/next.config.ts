import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // X-Powered-By を返さない（使っている技術を、応答から知らせない）
  poweredByHeader: false,
};

export default nextConfig;
