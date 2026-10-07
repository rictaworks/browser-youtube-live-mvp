import { ApiClientError } from "./errors";

/**
 * 失敗を、ログの 1 行（何が起きたか）にする。API クライアントのエラーは、メッセージ（符号・ステータス・位置だけ。値を含まない）を、
 * ほかの例外は、種類の名前だけを返す（文面には、トークン・URL などが含まれうるため）。
 */
export function describeFailure(error: unknown): string {
  if (error instanceof ApiClientError) {
    return error.message;
  }
  if (typeof error === "object" && error !== null && typeof (error as { name?: unknown }).name === "string") {
    return (error as { name: string }).name;
  }
  return typeof error;
}
