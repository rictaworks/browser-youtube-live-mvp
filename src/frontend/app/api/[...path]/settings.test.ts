/**
 * @jest-environment node
 */
import { BffConfigError, loadBffSettings } from "./settings";

const SECRET = "dummy-bff-secret-0123456789abcdef";

describe("loadBffSettings: 正しい設定", () => {
  it("転送先の origin・共有の秘密値・環境を返す", () => {
    const settings = loadBffSettings({
      NODE_ENV: "production",
      BACKEND_ORIGIN: "https://backend.internal.example",
      BFF_SHARED_SECRET: SECRET,
    });

    expect(settings).toEqual({
      backendOrigin: "https://backend.internal.example",
      sharedSecret: SECRET,
      environment: "production",
    });
  });

  it("開発では、http の転送先（compose のネットワーク内）を許す", () => {
    const settings = loadBffSettings({
      NODE_ENV: "development",
      BACKEND_ORIGIN: "http://backend:3001",
      BFF_SHARED_SECRET: SECRET,
    });

    expect(settings.backendOrigin).toBe("http://backend:3001");
    expect(settings.environment).toBe("development");
  });

  it("test でも、http の転送先を許す", () => {
    expect(
      loadBffSettings({ NODE_ENV: "test", BACKEND_ORIGIN: "http://127.0.0.1:4010", BFF_SHARED_SECRET: SECRET }).backendOrigin,
    ).toBe("http://127.0.0.1:4010");
  });

  it("末尾のスラッシュは、取り除く（origin だけにそろえる）", () => {
    const settings = loadBffSettings({
      NODE_ENV: "production",
      BACKEND_ORIGIN: "https://backend.internal.example/",
      BFF_SHARED_SECRET: SECRET,
    });

    expect(settings.backendOrigin).toBe("https://backend.internal.example");
  });
});

describe("loadBffSettings: 設定エラー（欠けている・不正な変数の名前だけを持つ）", () => {
  function catchConfigError(env: Record<string, string | undefined>): BffConfigError {
    try {
      loadBffSettings(env);
    } catch (error) {
      if (error instanceof BffConfigError) {
        return error;
      }
      throw error;
    }
    throw new Error("設定エラーになるはずが、成功した");
  }

  it.each([
    ["BACKEND_ORIGIN が無い", { NODE_ENV: "production", BFF_SHARED_SECRET: SECRET }, ["BACKEND_ORIGIN"], []],
    ["BFF_SHARED_SECRET が無い", { NODE_ENV: "production", BACKEND_ORIGIN: "https://backend.internal.example" }, ["BFF_SHARED_SECRET"], []],
    ["両方無い", { NODE_ENV: "production" }, ["BACKEND_ORIGIN", "BFF_SHARED_SECRET"], []],
    ["空文字は、無いものとして扱う", { NODE_ENV: "production", BACKEND_ORIGIN: "", BFF_SHARED_SECRET: "" }, ["BACKEND_ORIGIN", "BFF_SHARED_SECRET"], []],
    ["空白だけは、無いものとして扱う", { NODE_ENV: "production", BACKEND_ORIGIN: "   ", BFF_SHARED_SECRET: SECRET }, ["BACKEND_ORIGIN"], []],
    ["開発でも、欠けていれば設定エラー（既定の値で続行しない）", { NODE_ENV: "development" }, ["BACKEND_ORIGIN", "BFF_SHARED_SECRET"], []],
  ] as const)("%s", (_title, env, missing, invalid) => {
    const error = catchConfigError(env);

    expect(error.missing).toEqual(missing);
    expect(error.invalid).toEqual(invalid);
  });

  it.each([
    ["URL として解釈できない", "not a url"],
    ["スキームが無い", "backend.internal.example"],
    ["http・https 以外のスキーム", "ftp://backend.internal.example"],
    ["資格情報を含む", "https://user:password@backend.internal.example"],
    ["経路を含む", "https://backend.internal.example/api"],
    ["クエリを含む", "https://backend.internal.example/?x=1"],
    ["フラグメントを含む", "https://backend.internal.example/#x"],
  ])("BACKEND_ORIGIN が不正（%s）", (_title, value) => {
    const error = catchConfigError({ NODE_ENV: "development", BACKEND_ORIGIN: value, BFF_SHARED_SECRET: SECRET });

    expect(error.invalid).toEqual(["BACKEND_ORIGIN"]);
    expect(error.missing).toEqual([]);
  });

  it("本番では、BACKEND_ORIGIN が https でなければ、設定エラー（要件 6.1: HTTPS）", () => {
    const error = catchConfigError({
      NODE_ENV: "production",
      BACKEND_ORIGIN: "http://backend.internal.example",
      BFF_SHARED_SECRET: SECRET,
    });

    expect(error.invalid).toEqual(["BACKEND_ORIGIN"]);
  });

  it.each([["http://127.0.0.1:4010"], ["http://localhost:3001"], ["http://[::1]:3001"]])(
    "本番でも、同じ計算機の内側（ループバック）の宛先は、http を許す（通信が外へ出ない。本番の構成の検査に使う）: %s",
    (origin) => {
      const settings = loadBffSettings({ NODE_ENV: "production", BACKEND_ORIGIN: origin, BFF_SHARED_SECRET: SECRET });

      expect(settings.backendOrigin).toBe(origin);
      expect(settings.environment).toBe("production");
    },
  );

  it.each([["http://127.0.0.1.example.test"], ["http://localhost.example.test"], ["http://10.0.0.5:3001"], ["http://backend:3001"]])(
    "ループバックに見えるだけの宛先・内部のアドレスは、本番では、http を許さない: %s",
    (origin) => {
      const error = catchConfigError({ NODE_ENV: "production", BACKEND_ORIGIN: origin, BFF_SHARED_SECRET: SECRET });

      expect(error.invalid).toEqual(["BACKEND_ORIGIN"]);
    },
  );

  it.each([[undefined], [""], ["staging"]])("NODE_ENV が %j なら、NODE_ENV が不正（既定の環境へ倒さない）", (nodeEnv) => {
    const error = catchConfigError({
      NODE_ENV: nodeEnv,
      BACKEND_ORIGIN: "https://backend.internal.example",
      BFF_SHARED_SECRET: SECRET,
    });

    expect(error.invalid).toEqual(["NODE_ENV"]);
  });

  it("メッセージには変数の名前だけを含め、値（秘密値・不正な転送先）を含めない", () => {
    const badOrigin = "https://user:topsecret@backend.internal.example/path";
    const error = catchConfigError({ NODE_ENV: "production", BACKEND_ORIGIN: badOrigin, BFF_SHARED_SECRET: SECRET });

    expect(error.message).toContain("BACKEND_ORIGIN");
    expect(error.message).not.toContain(SECRET);
    expect(error.message).not.toContain("topsecret");
    expect(error.message).not.toContain("backend.internal.example");
  });

  it("欠けている変数を含むときも、ほかの変数の値を、メッセージへ含めない", () => {
    const error = catchConfigError({ NODE_ENV: "production", BFF_SHARED_SECRET: SECRET });

    expect(error.message).toContain("BACKEND_ORIGIN");
    expect(error.message).not.toContain(SECRET);
  });
});
