// 応答の JSON を検証する小さな部品。型どおりでなければ ShapeError（不正な項目の「位置」だけを持つ。値は、トークンなどを含みうるため、持たない）。

/** 契約の形に合わない応答。位置は、ドット区切りの項目名（根は $） */
export class ShapeError extends Error {
  readonly path: string;

  constructor(path: string) {
    const where = path === "" ? "$" : path;
    super(`unexpected response shape at ${where}`);
    this.name = "ShapeError";
    this.path = where;
  }
}

/** 親の位置に、項目名をつないだ位置（根は、空文字） */
export function childPath(parent: string, key: string): string {
  return parent === "" ? key : `${parent}.${key}`;
}

export function expectObject(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ShapeError(path);
  }
  return value as Record<string, unknown>;
}

export function expectString(value: unknown, path: string): string {
  if (typeof value !== "string") {
    throw new ShapeError(path);
  }
  return value;
}

export function expectNonEmptyString(value: unknown, path: string): string {
  if (typeof value !== "string" || value === "") {
    throw new ShapeError(path);
  }
  return value;
}

/** 契約: 応答のキーは、値が無いとき null で、必ず持つ。undefined（キーが無い）は、不正 */
export function expectNullableString(value: unknown, path: string): string | null {
  return value === null ? null : expectString(value, path);
}

export function expectBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") {
    throw new ShapeError(path);
  }
  return value;
}

export function expectNonNegativeInteger(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new ShapeError(path);
  }
  return value;
}

export function expectNullableNonNegativeInteger(value: unknown, path: string): number | null {
  return value === null ? null : expectNonNegativeInteger(value, path);
}

export function expectEnum<T extends string>(value: unknown, guard: (candidate: unknown) => candidate is T, path: string): T {
  if (!guard(value)) {
    throw new ShapeError(path);
  }
  return value;
}

export function expectNullableEnum<T extends string>(value: unknown, guard: (candidate: unknown) => candidate is T, path: string): T | null {
  return value === null ? null : expectEnum(value, guard, path);
}

export function expectStringArray(value: unknown, path: string): readonly string[] {
  if (!Array.isArray(value) || !value.every((item): item is string => typeof item === "string")) {
    throw new ShapeError(path);
  }
  return value;
}

/** WebSocket の URL（ws: または wss:）。契約: relay_url は、完全な WebSocket の URL */
export function expectWebSocketUrl(value: unknown, path: string): string {
  const text = expectNonEmptyString(value, path);
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    throw new ShapeError(path);
  }
  if (url.protocol !== "ws:" && url.protocol !== "wss:") {
    throw new ShapeError(path);
  }
  return text;
}
