// API クライアント（ブラウザ → 同一オリジンの /api/*）。画面からは、ここから import する。
export { ApiClient } from "./client";
export type { ApiClientOptions, ApiFetch, ApiRequestInit, ApiResponseLike, GetStateOptions, RequestOptions } from "./client";
export { clientAppEnvironment } from "./client-environment";
export { API_ENDPOINTS, API_REQUEST_TIMEOUT_MS } from "./config";
export { describeFailure } from "./describe-failure";
export { API_ERROR_CODES, isApiErrorCode } from "./error-codes";
export type { ApiErrorCode } from "./error-codes";
export {
  ApiAbortedError,
  ApiClientError,
  ApiError,
  ApiNetworkError,
  ApiRejected,
  ApiTimeoutError,
  createApiError,
  CsrfInvalidError,
  MissingCsrfTokenError,
  NotLoggedInError,
  UnexpectedResponse,
} from "./errors";
export { formatApiTimestamp } from "./format-time";
export { assertSafeAuthorizationUrl, browserNavigate, navigateToAuthorization, UnsafeAuthorizationUrlError } from "./navigation";
export type { Navigate } from "./navigation";
export type {
  AuthenticatedState,
  AuthorizationStart,
  BroadcastView,
  BrowserClass,
  BrowserUsageEventType,
  CancelReason,
  PrivacyStatus,
  ProfileLimits,
  RejectedBody,
  StartAccepted,
  StartLimits,
  StartRequest,
  StateResponse,
  TicketIssued,
  UnauthenticatedState,
  UsageEventRequest,
  UsageView,
  YoutubeView,
} from "./types";
