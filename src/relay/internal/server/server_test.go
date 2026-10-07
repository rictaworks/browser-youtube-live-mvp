package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestMain(m *testing.M) {
	gin.SetMode(gin.TestMode)
	os.Exit(m.Run())
}

func newTestRouter(t *testing.T, accessLog, errorLog io.Writer) *gin.Engine {
	t.Helper()
	router, err := NewRouter(accessLog, errorLog)
	if err != nil {
		t.Fatalf("NewRouter() error = %v; want nil", err)
	}
	return router
}

func TestHealthReturns200WithJSON(t *testing.T) {
	router := newTestRouter(t, io.Discard, io.Discard)

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health status = %d; want %d", rec.Code, http.StatusOK)
	}
	if contentType := rec.Header().Get("Content-Type"); !strings.HasPrefix(contentType, "application/json") {
		t.Fatalf("GET /health Content-Type = %q; want application/json", contentType)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("GET /health body is not JSON: %v (body: %q)", err, rec.Body.String())
	}
	if body["status"] != HealthStatusOK {
		t.Fatalf("GET /health status field = %q; want %q", body["status"], HealthStatusOK)
	}
}

func TestOnlyHealthIsRouted(t *testing.T) {
	cases := []struct {
		name   string
		method string
		path   string
	}{
		{name: "ルートは 404", method: http.MethodGet, path: "/"},
		{name: "未実装のパスは 404", method: http.MethodGet, path: "/ws"},
		{name: "health への POST は成功させない", method: http.MethodPost, path: "/health"},
	}
	router := newTestRouter(t, io.Discard, io.Discard)

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, nil))
			if rec.Code != http.StatusNotFound {
				t.Fatalf("%s %s status = %d; want %d", tc.method, tc.path, rec.Code, http.StatusNotFound)
			}
		})
	}
}

func TestAccessLogOmitsHealthChecks(t *testing.T) {
	var accessLog bytes.Buffer
	router := newTestRouter(t, &accessLog, io.Discard)

	router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/health", nil))

	if accessLog.Len() != 0 {
		t.Fatalf("access log for /health = %q; want empty (health checks are skipped)", accessLog.String())
	}
}

// アクセスログに、クエリ文字列（接続チケットなどの秘密を含み得る）とクライアントの IP アドレスを出さない
func TestAccessLogOmitsQueryStringAndClientIP(t *testing.T) {
	var accessLog bytes.Buffer
	router := newTestRouter(t, &accessLog, io.Discard)

	req := httptest.NewRequest(http.MethodGet, "/missing?ticket=dummy-ticket-value", nil)
	req.RemoteAddr = "203.0.113.7:51234"
	router.ServeHTTP(httptest.NewRecorder(), req)

	logged := accessLog.String()
	if !strings.Contains(logged, "/missing") {
		t.Errorf("access log = %q; want it to contain the request path", logged)
	}
	for _, secret := range []string{"ticket", "dummy-ticket-value", "203.0.113.7"} {
		if strings.Contains(logged, secret) {
			t.Errorf("access log = %q; must not contain %q", logged, secret)
		}
	}
}

// パニックを回復して 500 を返し、原因とスタックを残す。リクエストのヘッダ（Cookie など）とクエリは出さない
func TestRecoveryLogsPanicWithoutRequestDetails(t *testing.T) {
	var errorLog bytes.Buffer
	router := newTestRouter(t, io.Discard, &errorLog)
	router.GET("/boom", func(*gin.Context) { panic("dummy panic reason") })

	req := httptest.NewRequest(http.MethodGet, "/boom?ticket=dummy-ticket-value", nil)
	req.Header.Set("Cookie", "session=dummy-cookie-value")
	req.Header.Set("Authorization", "Bearer dummy-token-value")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("GET /boom status = %d; want %d", rec.Code, http.StatusInternalServerError)
	}
	logged := errorLog.String()
	for _, want := range []string{"dummy panic reason", "/boom", "goroutine"} {
		if !strings.Contains(logged, want) {
			t.Errorf("error log = %q; want it to contain %q", logged, want)
		}
	}
	for _, secret := range []string{"ticket", "dummy-ticket-value", "dummy-cookie-value", "dummy-token-value"} {
		if strings.Contains(logged, secret) {
			t.Errorf("error log must not contain %q", secret)
		}
	}
}
