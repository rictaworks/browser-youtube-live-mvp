import { ApiClient } from "./client";
import { authenticatedState, createFakeFetch, DUMMY_CSRF_TOKEN, emptyResponse, jsonResponse } from "./test-support";

// CSRF トークンは、メモリだけに持つ（localStorage・sessionStorage・Cookie へ置かない。契約 1.2）。ブラウザの環境（jsdom）で検査する。

describe("ApiClient: CSRF トークンの保管先", () => {
  it("getState・状態を変える要求を通じて、localStorage・sessionStorage・document.cookie へ、何も書かない・読まない", async () => {
    const setItem = jest.spyOn(Storage.prototype, "setItem");
    const getItem = jest.spyOn(Storage.prototype, "getItem");
    const { fetch } = createFakeFetch((url) => (url === "/api/state" ? jsonResponse(200, authenticatedState()) : emptyResponse(204)));
    const client = new ApiClient({ fetch });

    await client.getState();
    await client.logout();

    expect(setItem).not.toHaveBeenCalled();
    expect(getItem).not.toHaveBeenCalled();
    expect(window.localStorage.length).toBe(0);
    expect(window.sessionStorage.length).toBe(0);
    expect(document.cookie).toBe("");
    expect(JSON.stringify(window.localStorage)).not.toContain(DUMMY_CSRF_TOKEN);
    setItem.mockRestore();
    getItem.mockRestore();
  });
});
