package rtmps

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/rictaworks/browser-youtube-live-mvp/relay/core/contract"
	"github.com/rictaworks/browser-youtube-live-mvp/relay/internal/appenv"
)

// 送出先の検証（requirements.md 6.1・10.1・28.1）。送出先は、YouTube の取り込み口であることを確認した RTMPS の宛先に限る。
// 平文の rtmp・443 以外のポート・ユーザー情報・クエリ・過大なパスを拒否し、利用者が宛先を指定する手段を持たない。

func mustPolicyFor(t *testing.T, env appenv.Environment) Policy {
	t.Helper()
	policy, err := PolicyFor(env)
	if err != nil {
		t.Fatalf("PolicyFor(%q): %v", env, err)
	}
	return policy
}

// fullwidth は、全角の文字（ASCII の 0x21 から 0x7E を、0xFF01 から 0xFF5E へ移した文字）。
// 非 ASCII の文字は、ソースへ直接書かず、コードポイントから作る。
func fullwidth(ascii rune) string { return string(rune(0xFF00 + (ascii - 0x20))) }

func TestValidateAcceptsYouTubeIngestInProduction(t *testing.T) {
	policy := mustPolicyFor(t, appenv.Production)
	cases := []struct {
		name     string
		url      string
		wantHost string
		wantPort int
		wantApp  string
	}{
		{name: "主系 a", url: "rtmps://a.rtmps.youtube.com:443/live2", wantHost: "a.rtmps.youtube.com", wantPort: 443, wantApp: "live2"},
		{name: "副系 b（クエリの無い形）", url: "rtmps://b.rtmps.youtube.com:443/live2", wantHost: "b.rtmps.youtube.com", wantPort: 443, wantApp: "live2"},
		{name: "ホストの大文字は小文字へそろえる", url: "rtmps://A.RTMPS.YouTube.com:443/live2", wantHost: "a.rtmps.youtube.com", wantPort: 443, wantApp: "live2"},
		{name: "スキームの大文字は同じ意味（URL の規則）", url: "RTMPS://a.rtmps.youtube.com:443/live2", wantHost: "a.rtmps.youtube.com", wantPort: 443, wantApp: "live2"},
		{name: "別のアプリ名（live）", url: "rtmps://a.rtmps.youtube.com:443/live", wantHost: "a.rtmps.youtube.com", wantPort: 443, wantApp: "live"},
		{name: "アプリ名に _ と -", url: "rtmps://a.rtmps.youtube.com:443/app_1-x", wantHost: "a.rtmps.youtube.com", wantPort: 443, wantApp: "app_1-x"},
		{name: "アプリ名が上限ちょうど", url: "rtmps://a.rtmps.youtube.com:443/" + strings.Repeat("a", maxAppNameBytes), wantHost: "a.rtmps.youtube.com", wantPort: 443, wantApp: strings.Repeat("a", maxAppNameBytes)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dest, err := Validate(c.url, policy)
			if err != nil {
				t.Fatalf("Validate(%q): %v", c.url, err)
			}
			if dest.host != c.wantHost || dest.port != c.wantPort || dest.app != c.wantApp {
				t.Fatalf("destination = %q:%d app %q, want %q:%d app %q", dest.host, dest.port, dest.app, c.wantHost, c.wantPort, c.wantApp)
			}
			if dest.skipTLSVerify {
				t.Errorf("a YouTube ingest must always be verified")
			}
			if !dest.valid() {
				t.Errorf("a validated destination must be valid")
			}
			wantAddr := c.wantHost + ":" + strconv.Itoa(c.wantPort)
			if dest.addr() != wantAddr {
				t.Errorf("addr = %q, want %q", dest.addr(), wantAddr)
			}
			if want := "rtmps://" + wantAddr + "/" + c.wantApp; dest.tcURL() != want {
				t.Errorf("tcURL = %q, want %q", dest.tcURL(), want)
			}
		})
	}
}

func TestValidateRejects(t *testing.T) {
	policy := mustPolicyFor(t, appenv.Production)
	cases := []struct {
		name    string
		url     string
		wantErr error
	}{
		// 形式
		{name: "空", url: "", wantErr: ErrInvalidURL},
		{name: "前に空白", url: " rtmps://a.rtmps.youtube.com:443/live2", wantErr: ErrInvalidURL},
		{name: "後ろに空白", url: "rtmps://a.rtmps.youtube.com:443/live2 ", wantErr: ErrInvalidURL},
		{name: "途中に空白", url: "rtmps://a.rtmps.youtube.com:443/live 2", wantErr: ErrInvalidURL},
		{name: "タブ", url: "rtmps://a.rtmps.youtube.com:443/live2\t", wantErr: ErrInvalidURL},
		{name: "改行", url: "rtmps://a.rtmps.youtube.com:443/live2\n", wantErr: ErrInvalidURL},
		{name: "復帰", url: "rtmps://a.rtmps.youtube.com:443/live2\r", wantErr: ErrInvalidURL},
		{name: "NUL", url: "rtmps://a.rtmps.youtube.com:443/live2\x00", wantErr: ErrInvalidURL},
		{name: "DEL", url: "rtmps://a.rtmps.youtube.com:443/live2\x7f", wantErr: ErrInvalidURL},
		{name: "全角の数字（パス）", url: "rtmps://a.rtmps.youtube.com:443/live" + fullwidth('2'), wantErr: ErrInvalidURL},
		{name: "全角の文字（ホスト）", url: "rtmps://" + fullwidth('a') + ".rtmps.youtube.com:443/live2", wantErr: ErrInvalidURL},
		{name: "ケルビン記号（小文字化すると k になる文字）", url: "rtmps://a.rtmps.you" + string(rune(0x212A)) + "tube.com:443/live2", wantErr: ErrInvalidURL},
		{name: "長すぎる（上限の 1 バイト超）", url: "rtmps://a.rtmps.youtube.com:443/" + strings.Repeat("a", maxURLBytes), wantErr: ErrInvalidURL},
		{name: "スキームの無い形", url: "a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "パスだけ", url: "/live2", wantErr: ErrSchemeNotAllowed},
		{name: "不透明な形（//が無い）", url: "rtmps:a.rtmps.youtube.com:443/live2", wantErr: ErrInvalidURL},
		{name: "ホストの無い形", url: "rtmps:///live2", wantErr: ErrHostNotAllowed},

		// スキーム：平文の rtmp などを拒否する
		{name: "平文の rtmp", url: "rtmp://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "平文の rtmp（1935）", url: "rtmp://a.rtmps.youtube.com:1935/live2", wantErr: ErrSchemeNotAllowed},
		{name: "平文の rtmp（大文字）", url: "RTMP://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "rtmpe", url: "rtmpe://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "rtmpt", url: "rtmpt://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "rtmpts", url: "rtmpts://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "rtmps に似たスキーム（rtmpss）", url: "rtmpss://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "https", url: "https://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "http", url: "http://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "wss", url: "wss://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "ftp", url: "ftp://a.rtmps.youtube.com:443/live2", wantErr: ErrSchemeNotAllowed},
		{name: "file", url: "file:///etc/hosts", wantErr: ErrSchemeNotAllowed},

		// ユーザー情報
		{name: "ユーザーとパスワード", url: "rtmps://user:pass@a.rtmps.youtube.com:443/live2", wantErr: ErrUserInfoNotAllowed},
		{name: "ユーザーだけ", url: "rtmps://user@a.rtmps.youtube.com:443/live2", wantErr: ErrUserInfoNotAllowed},
		{name: "空のユーザー情報（@ だけ）", url: "rtmps://@a.rtmps.youtube.com:443/live2", wantErr: ErrUserInfoNotAllowed},
		{name: "許可ホストをユーザー情報に見せかける", url: "rtmps://a.rtmps.youtube.com:443@evil.example:443/live2", wantErr: ErrUserInfoNotAllowed},
		{name: "許可ホストをユーザー情報に見せかける（パスワードの形）", url: "rtmps://a.rtmps.youtube.com:secret@evil.example:443/live2", wantErr: ErrUserInfoNotAllowed},

		// クエリ・フラグメント（?backup=1 を含む）
		{name: "バックアップのクエリ", url: "rtmps://b.rtmps.youtube.com:443/live2?backup=1", wantErr: ErrQueryNotAllowed},
		{name: "クエリ", url: "rtmps://a.rtmps.youtube.com:443/live2?x=y", wantErr: ErrQueryNotAllowed},
		{name: "空のクエリ（? だけ）", url: "rtmps://a.rtmps.youtube.com:443/live2?", wantErr: ErrQueryNotAllowed},
		{name: "パスの無いクエリ", url: "rtmps://a.rtmps.youtube.com:443?x=y", wantErr: ErrQueryNotAllowed},
		{name: "フラグメント", url: "rtmps://a.rtmps.youtube.com:443/live2#frag", wantErr: ErrQueryNotAllowed},
		{name: "空のフラグメント（# だけ）", url: "rtmps://a.rtmps.youtube.com:443/live2#", wantErr: ErrQueryNotAllowed},

		// ホスト：許可リストに一致するものだけ
		{name: "許可リストに無いホスト", url: "rtmps://evil.example:443/live2", wantErr: ErrHostNotAllowed},
		{name: "許可ホストを前に含む別のホスト", url: "rtmps://a.rtmps.youtube.com.evil.example:443/live2", wantErr: ErrHostNotAllowed},
		{name: "許可ホストを後ろに含む別のホスト", url: "rtmps://evil-a.rtmps.youtube.com:443/live2", wantErr: ErrHostNotAllowed},
		{name: "許可ホストの前に文字を足した別のホスト", url: "rtmps://xa.rtmps.youtube.com:443/live2", wantErr: ErrHostNotAllowed},
		{name: "親のドメイン", url: "rtmps://rtmps.youtube.com:443/live2", wantErr: ErrHostNotAllowed},
		{name: "youtube.com", url: "rtmps://youtube.com:443/live2", wantErr: ErrHostNotAllowed},
		{name: "ほかの YouTube のホスト（c）", url: "rtmps://c.rtmps.youtube.com:443/live2", wantErr: ErrHostNotAllowed},
		{name: "末尾のドット", url: "rtmps://a.rtmps.youtube.com.:443/live2", wantErr: ErrHostNotAllowed},
		{name: "IP アドレス（IPv4）", url: "rtmps://127.0.0.1:443/live2", wantErr: ErrHostNotAllowed},
		{name: "IP アドレス（IPv6）", url: "rtmps://[::1]:443/live2", wantErr: ErrHostNotAllowed},
		{name: "localhost", url: "rtmps://localhost:443/live2", wantErr: ErrHostNotAllowed},
		{name: "開発用の疑似の取り込み口は、production に存在しない", url: "rtmps://fake-ingest:1935/live2", wantErr: ErrHostNotAllowed},
		{name: "開発用の疑似の取り込み口（443）も、production に存在しない", url: "rtmps://fake-ingest:443/live2", wantErr: ErrHostNotAllowed},

		// ポート：443 のみ
		{name: "ポート 80", url: "rtmps://a.rtmps.youtube.com:80/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 444", url: "rtmps://a.rtmps.youtube.com:444/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 1935（RTMP の既定）", url: "rtmps://a.rtmps.youtube.com:1935/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 4430", url: "rtmps://a.rtmps.youtube.com:4430/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 44", url: "rtmps://a.rtmps.youtube.com:44/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 0443（数値は 443 でも、文字列が違う）", url: "rtmps://a.rtmps.youtube.com:0443/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 00443", url: "rtmps://a.rtmps.youtube.com:00443/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 443443", url: "rtmps://a.rtmps.youtube.com:443443/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 65536", url: "rtmps://a.rtmps.youtube.com:65536/live2", wantErr: ErrPortNotAllowed},
		{name: "ポート 0", url: "rtmps://a.rtmps.youtube.com:0/live2", wantErr: ErrPortNotAllowed},
		{name: "ポートの無い形", url: "rtmps://a.rtmps.youtube.com/live2", wantErr: ErrPortNotAllowed},
		{name: "ポートが空（: だけ）", url: "rtmps://a.rtmps.youtube.com:/live2", wantErr: ErrPortNotAllowed},
		{name: "ポートが +443", url: "rtmps://a.rtmps.youtube.com:+443/live2", wantErr: ErrInvalidURL},
		{name: "ポートが 0x1BB", url: "rtmps://a.rtmps.youtube.com:0x1BB/live2", wantErr: ErrInvalidURL},
		{name: "ポートの重複（net/url は、後ろの :443 だけをポートとみなし、前の部分をホスト名にする）", url: "rtmps://a.rtmps.youtube.com:443:443/live2", wantErr: ErrHostNotAllowed},

		// パス：アプリ名 1 つだけ（配信キーを URL に混ぜない）
		{name: "パスの無い形", url: "rtmps://a.rtmps.youtube.com:443", wantErr: ErrPathNotAllowed},
		{name: "ルートだけ", url: "rtmps://a.rtmps.youtube.com:443/", wantErr: ErrPathNotAllowed},
		{name: "末尾のスラッシュ", url: "rtmps://a.rtmps.youtube.com:443/live2/", wantErr: ErrPathNotAllowed},
		{name: "配信キーをパスに含める", url: "rtmps://a.rtmps.youtube.com:443/live2/abcd-efgh-ijkl-mnop-qrst", wantErr: ErrPathNotAllowed},
		{name: "スラッシュの重複", url: "rtmps://a.rtmps.youtube.com:443//live2", wantErr: ErrPathNotAllowed},
		{name: "親のディレクトリ", url: "rtmps://a.rtmps.youtube.com:443/live2/../x", wantErr: ErrPathNotAllowed},
		{name: "ドットだけ", url: "rtmps://a.rtmps.youtube.com:443/..", wantErr: ErrPathNotAllowed},
		{name: "ドットを含むアプリ名", url: "rtmps://a.rtmps.youtube.com:443/live.2", wantErr: ErrPathNotAllowed},
		{name: "パーセントエンコード（l）", url: "rtmps://a.rtmps.youtube.com:443/%6Cive2", wantErr: ErrPathNotAllowed},
		{name: "パーセントエンコード（数字）", url: "rtmps://a.rtmps.youtube.com:443/live%32", wantErr: ErrPathNotAllowed},
		{name: "パーセントエンコード（スラッシュ）", url: "rtmps://a.rtmps.youtube.com:443/live2%2Fkey", wantErr: ErrPathNotAllowed},
		{name: "パーセントエンコード（空白）", url: "rtmps://a.rtmps.youtube.com:443/a%20b", wantErr: ErrPathNotAllowed},
		{name: "セミコロン", url: "rtmps://a.rtmps.youtube.com:443/live2;x", wantErr: ErrPathNotAllowed},
		{name: "コロン", url: "rtmps://a.rtmps.youtube.com:443/live2:x", wantErr: ErrPathNotAllowed},
		{name: "アットマーク", url: "rtmps://a.rtmps.youtube.com:443/live2@evil", wantErr: ErrPathNotAllowed},
		{name: "アプリ名が長すぎる（上限の 1 バイト超）", url: "rtmps://a.rtmps.youtube.com:443/" + strings.Repeat("a", maxAppNameBytes+1), wantErr: ErrPathNotAllowed},
		{name: "バックスラッシュ", url: "rtmps://a.rtmps.youtube.com:443/live2\\x", wantErr: ErrPathNotAllowed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dest, err := Validate(c.url, policy)
			if err == nil {
				t.Fatalf("Validate(%q) accepted %q:%d app %q, want %v", c.url, dest.host, dest.port, dest.app, c.wantErr)
			}
			if !errors.Is(err, c.wantErr) {
				t.Fatalf("Validate(%q) error = %v, want %v", c.url, err, c.wantErr)
			}
			if dest.valid() {
				t.Errorf("a rejected destination must be the zero value (invalid)")
			}
			if dest != (ValidatedDestination{}) {
				t.Errorf("a rejected destination must be the zero value")
			}
		})
	}
}

// 開発用の許可（契約 dev_ingest）：GIN_MODE が production でないときに限り、疑似の取り込み口を追加で許可し、
// そのホストに限り TLS の証明書検証を省略できる。
func TestValidateInDevelopmentAndTest(t *testing.T) {
	for _, env := range []appenv.Environment{appenv.Development, appenv.Test} {
		t.Run(string(env), func(t *testing.T) {
			policy := mustPolicyFor(t, env)

			dest, err := Validate("rtmps://fake-ingest:1935/live2", policy)
			if err != nil {
				t.Fatalf("the development ingest must be allowed in %s: %v", env, err)
			}
			if dest.host != "fake-ingest" || dest.port != 1935 || dest.app != "live2" {
				t.Errorf("destination = %q:%d app %q", dest.host, dest.port, dest.app)
			}
			if !dest.skipTLSVerify {
				t.Errorf("the development ingest uses a self-signed certificate, so the verification may be skipped for it")
			}

			// YouTube の取り込み口は、開発・試験でも、検証を省略しない
			youtube, err := Validate("rtmps://a.rtmps.youtube.com:443/live2", policy)
			if err != nil {
				t.Fatalf("a YouTube ingest must stay allowed: %v", err)
			}
			if youtube.skipTLSVerify {
				t.Errorf("the verification must never be skipped for YouTube")
			}

			for name, c := range map[string]struct {
				url     string
				wantErr error
			}{
				"疑似の取り込み口でも、443 は許可しない（ポートは 1935）": {"rtmps://fake-ingest:443/live2", ErrPortNotAllowed},
				"疑似の取り込み口でも、平文の rtmp は拒否":          {"rtmp://fake-ingest:1935/live2", ErrSchemeNotAllowed},
				"疑似の取り込み口でも、ユーザー情報は拒否":             {"rtmps://u:p@fake-ingest:1935/live2", ErrUserInfoNotAllowed},
				"疑似の取り込み口でも、クエリは拒否":                {"rtmps://fake-ingest:1935/live2?x=1", ErrQueryNotAllowed},
				"疑似の取り込み口でも、パスは 1 つのアプリ名だけ":        {"rtmps://fake-ingest:1935/live2/key", ErrPathNotAllowed},
				"疑似の取り込み口に似たホスト":                   {"rtmps://fake-ingest.evil.example:1935/live2", ErrHostNotAllowed},
				"YouTube のホストは、1935 を許可しない":        {"rtmps://a.rtmps.youtube.com:1935/live2", ErrPortNotAllowed},
			} {
				if _, err := Validate(c.url, policy); !errors.Is(err, c.wantErr) {
					t.Errorf("%s: Validate(%q) error = %v, want %v", name, c.url, err, c.wantErr)
				}
			}
		})
	}
}

// production には、開発用の許可が存在しない（GIN_MODE が release のとき）。環境変数の名前は増やさず、GIN_MODE だけで決める。
func TestProductionHasNoDevelopmentAllowance(t *testing.T) {
	policy, err := PolicyForGinMode(gin.ReleaseMode)
	if err != nil {
		t.Fatalf("PolicyForGinMode(%q): %v", gin.ReleaseMode, err)
	}

	want := contract.RTMPSIngestHosts()
	targets := policy.Targets()
	if len(targets) != len(want) {
		t.Fatalf("production targets = %v, want exactly the %d YouTube ingest hosts", targets, len(want))
	}
	for i, target := range targets {
		if target.Host != want[i] || target.Port != contract.RTMPSIngestPort {
			t.Errorf("target %d = %+v, want %s:%d", i, target, want[i], contract.RTMPSIngestPort)
		}
		if target.Host == contract.DevIngestHost {
			t.Errorf("the development ingest host %q must not exist in production", target.Host)
		}
	}
	for _, allowed := range policy.allowed {
		if allowed.skipTLSVerify {
			t.Errorf("production must not skip the TLS verification for any host (%q does)", allowed.Host)
		}
	}
	if _, err := Validate("rtmps://"+contract.DevIngestHost+":"+strconv.Itoa(contract.DevIngestPort)+"/live2", policy); !errors.Is(err, ErrHostNotAllowed) {
		t.Errorf("the development ingest must be rejected in production, got %v", err)
	}
}

func TestPolicyForGinMode(t *testing.T) {
	cases := []struct {
		mode        string
		wantErr     bool
		wantDevHost bool
	}{
		{mode: gin.DebugMode, wantDevHost: true},
		{mode: gin.TestMode, wantDevHost: true},
		{mode: gin.ReleaseMode, wantDevHost: false},
		{mode: "", wantErr: true},
		{mode: "staging", wantErr: true},
		{mode: "RELEASE", wantErr: true},
		{mode: " release", wantErr: true},
	}
	for _, c := range cases {
		t.Run(strconv.Quote(c.mode), func(t *testing.T) {
			policy, err := PolicyForGinMode(c.mode)
			if c.wantErr {
				var unknown *appenv.UnknownGinModeError
				if !errors.As(err, &unknown) {
					t.Fatalf("PolicyForGinMode(%q) error = %v, want *appenv.UnknownGinModeError (an unknown mode must not fall back to a default)", c.mode, err)
				}
				if len(policy.allowed) != 0 {
					t.Errorf("a failed lookup must return an empty policy")
				}
				return
			}
			if err != nil {
				t.Fatalf("PolicyForGinMode(%q): %v", c.mode, err)
			}
			hasDev := false
			for _, target := range policy.Targets() {
				if target.Host == contract.DevIngestHost {
					hasDev = true
				}
			}
			if hasDev != c.wantDevHost {
				t.Errorf("development ingest present = %v, want %v", hasDev, c.wantDevHost)
			}
		})
	}
}

func TestPolicyForRejectsAnUnknownEnvironment(t *testing.T) {
	for _, env := range []appenv.Environment{"", "staging", "Production", "release"} {
		if _, err := PolicyFor(env); !errors.Is(err, ErrUnknownEnvironment) {
			t.Errorf("PolicyFor(%q) error = %v, want ErrUnknownEnvironment", env, err)
		}
	}
}

// 許可リストは、契約（#3）の定数から作る。コードへ直書きしない。
func TestPolicyIsBuiltFromTheContract(t *testing.T) {
	if contract.RTMPSIngestScheme != "rtmps" || contract.DevIngestScheme != "rtmps" {
		t.Fatalf("the contract schemes are %q and %q; this package accepts rtmps only", contract.RTMPSIngestScheme, contract.DevIngestScheme)
	}
	if contract.RTMPSIngestUserinfoAllowed || contract.RTMPSIngestQueryAllowed {
		t.Fatalf("the contract must not allow user information or a query")
	}
	if contract.RTMPSIngestPort != 443 {
		t.Fatalf("the contract port is %d, want 443", contract.RTMPSIngestPort)
	}

	dev := mustPolicyFor(t, appenv.Development)
	var found *allowedTarget
	for i := range dev.allowed {
		if dev.allowed[i].Host == contract.DevIngestHost {
			found = &dev.allowed[i]
		}
	}
	if found == nil {
		t.Fatalf("the development policy has no %q", contract.DevIngestHost)
	}
	if found.Port != contract.DevIngestPort || !found.skipTLSVerify {
		t.Errorf("development ingest = %+v, want port %d with the verification skipped", *found, contract.DevIngestPort)
	}
	for _, env := range contract.DevIngestAllowedEnvironments() {
		policy := mustPolicyFor(t, appenv.Environment(env))
		if _, err := Validate("rtmps://"+contract.DevIngestHost+":"+strconv.Itoa(contract.DevIngestPort)+"/live2", policy); err != nil {
			t.Errorf("the contract allows the development ingest in %q: %v", env, err)
		}
	}
}

func TestNewPolicy(t *testing.T) {
	cases := []struct {
		name    string
		targets []Target
		wantErr bool
	}{
		{name: "1 つ", targets: []Target{{Host: "localhost", Port: 8443}}},
		{name: "2 つ", targets: []Target{{Host: "a.example", Port: 443}, {Host: "b.example", Port: 443}}},
		{name: "ハイフンと数字を含むホスト", targets: []Target{{Host: "ingest-1.example", Port: 1935}}},
		{name: "ポートの下限（1）", targets: []Target{{Host: "localhost", Port: 1}}},
		{name: "ポートの上限（65535）", targets: []Target{{Host: "localhost", Port: 65535}}},
		{name: "数字を含むが、最後のラベルは数字だけではない", targets: []Target{{Host: "1a.b2", Port: 443}}},
		{name: "1 つも無い", targets: nil, wantErr: true},
		{name: "ホストが空", targets: []Target{{Host: "", Port: 443}}, wantErr: true},
		{name: "ホストに大文字（そろえずに拒否する）", targets: []Target{{Host: "Localhost", Port: 443}}, wantErr: true},
		{name: "IP アドレス（IPv4）", targets: []Target{{Host: "127.0.0.1", Port: 443}}, wantErr: true},
		{name: "IP アドレス（IPv6）", targets: []Target{{Host: "::1", Port: 443}}, wantErr: true},
		{name: "最後のラベルが数字だけ（127.1 は、IP アドレスとして解決され得る）", targets: []Target{{Host: "127.1", Port: 443}}, wantErr: true},
		{name: "最後のラベルが数字だけ（a.123）", targets: []Target{{Host: "a.123", Port: 443}}, wantErr: true},
		{name: "数字だけのホスト", targets: []Target{{Host: "2130706433", Port: 443}}, wantErr: true},
		{name: "16 進の形（0x7f.0x1。inet_aton が IP アドレスとして読む）", targets: []Target{{Host: "0x7f.0x1", Port: 443}}, wantErr: true},
		{name: "16 進の形（0x7f000001）", targets: []Target{{Host: "0x7f000001", Port: 443}}, wantErr: true},
		{name: "0x で始まるが、16 進の数ではない最後のラベルは可", targets: []Target{{Host: "a.0xyz", Port: 443}}},
		{name: "最後のラベルが 0x だけ（16 進の数ではない）は可", targets: []Target{{Host: "a.0x", Port: 443}}},
		{name: "ホストにポートを含む", targets: []Target{{Host: "localhost:443", Port: 443}}, wantErr: true},
		{name: "ホストに空白", targets: []Target{{Host: "local host", Port: 443}}, wantErr: true},
		{name: "ホストの末尾がドット", targets: []Target{{Host: "localhost.", Port: 443}}, wantErr: true},
		{name: "ホストの先頭がドット", targets: []Target{{Host: ".localhost", Port: 443}}, wantErr: true},
		{name: "ホストのラベルが空", targets: []Target{{Host: "a..example", Port: 443}}, wantErr: true},
		{name: "ホストに非 ASCII", targets: []Target{{Host: "a" + string(rune(0x00E9)) + ".example", Port: 443}}, wantErr: true},
		{name: "ホストに記号", targets: []Target{{Host: "a_b.example", Port: 443}}, wantErr: true},
		{name: "ホストが長すぎる", targets: []Target{{Host: strings.Repeat("a", 254), Port: 443}}, wantErr: true},
		{name: "ポート 0", targets: []Target{{Host: "localhost", Port: 0}}, wantErr: true},
		{name: "ポートが負", targets: []Target{{Host: "localhost", Port: -1}}, wantErr: true},
		{name: "ポート 65536", targets: []Target{{Host: "localhost", Port: 65536}}, wantErr: true},
		{name: "2 つ目が不正", targets: []Target{{Host: "localhost", Port: 443}, {Host: "", Port: 443}}, wantErr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			policy, err := NewPolicy(c.targets...)
			if c.wantErr {
				if !errors.Is(err, ErrInvalidPolicy) {
					t.Fatalf("NewPolicy error = %v, want ErrInvalidPolicy", err)
				}
				if len(policy.allowed) != 0 {
					t.Errorf("a rejected policy must be empty")
				}
				return
			}
			if err != nil {
				t.Fatalf("NewPolicy: %v", err)
			}
			got := policy.Targets()
			if len(got) != len(c.targets) {
				t.Fatalf("Targets() = %v, want %v", got, c.targets)
			}
			for i := range got {
				if got[i] != c.targets[i] {
					t.Errorf("Targets()[%d] = %+v, want %+v", i, got[i], c.targets[i])
				}
			}
			for _, allowed := range policy.allowed {
				if allowed.skipTLSVerify {
					t.Errorf("NewPolicy must never skip the TLS verification (only PolicyFor, for the development ingest)")
				}
			}
		})
	}
}

// 注入した許可リストで検証できる（本番の設定は変えずに、試験用の policy を渡す）。
func TestValidateWithAnInjectedPolicy(t *testing.T) {
	policy, err := NewPolicy(Target{Host: "localhost", Port: 8443}, Target{Host: "other.example", Port: 443})
	if err != nil {
		t.Fatal(err)
	}
	dest, err := Validate("rtmps://localhost:8443/live2", policy)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if dest.host != "localhost" || dest.port != 8443 || dest.skipTLSVerify {
		t.Errorf("destination = %+v", dest)
	}
	for name, c := range map[string]struct {
		url     string
		wantErr error
	}{
		"注入したホストでも、ポートが違えば拒否":    {"rtmps://localhost:443/live2", ErrPortNotAllowed},
		"注入したホストでも、平文の rtmp は拒否": {"rtmp://localhost:8443/live2", ErrSchemeNotAllowed},
		"本番のホストは、注入した許可リストに無い":   {"rtmps://a.rtmps.youtube.com:443/live2", ErrHostNotAllowed},
	} {
		if _, err := Validate(c.url, policy); !errors.Is(err, c.wantErr) {
			t.Errorf("%s: error = %v, want %v", name, err, c.wantErr)
		}
	}
}

// 許可リストが空（零値）なら、何も許可しない。
func TestValidateWithAnEmptyPolicyRejectsEverything(t *testing.T) {
	for _, url := range []string{"rtmps://a.rtmps.youtube.com:443/live2", "rtmps://localhost:443/live2"} {
		if _, err := Validate(url, Policy{}); !errors.Is(err, ErrHostNotAllowed) {
			t.Errorf("Validate(%q, Policy{}) error = %v, want ErrHostNotAllowed", url, err)
		}
	}
}

// Targets は、コピーを返す（呼び出し側が書き換えても、許可リストは変わらない）。
func TestPolicyTargetsReturnsACopy(t *testing.T) {
	policy := mustPolicyFor(t, appenv.Production)
	targets := policy.Targets()
	targets[0].Host = "evil.example"
	targets[0].Port = 1
	if _, err := Validate("rtmps://a.rtmps.youtube.com:443/live2", policy); err != nil {
		t.Errorf("the policy was changed through Targets(): %v", err)
	}
	if _, err := Validate("rtmps://evil.example:1/live2", policy); err == nil {
		t.Errorf("the policy was changed through Targets()")
	}
}

// 検証のエラーは、URL の内容（ユーザー情報・パスに混ざった配信キーなど）を含まない。
func TestValidationErrorsDoNotEchoTheInput(t *testing.T) {
	const marker = "SECRETMARKER-0123456789"
	policy := mustPolicyFor(t, appenv.Production)
	inputs := []string{
		"rtmps://user:" + marker + "@a.rtmps.youtube.com:443/live2",
		"rtmps://a.rtmps.youtube.com:443/live2/" + marker,
		"rtmps://a.rtmps.youtube.com:443/live2?key=" + marker,
		"rtmps://a.rtmps.youtube.com:443/live2#" + marker,
		"rtmps://" + marker + ".example:443/live2",
		"rtmps://a.rtmps.youtube.com:" + "9999/" + marker,
		"rtmp://a.rtmps.youtube.com:443/" + marker,
		"https://" + marker,
		marker,
		marker + " " + marker,
		"rtmps://a.rtmps.youtube.com:443/" + strings.Repeat(marker, 40),
	}
	for _, input := range inputs {
		_, err := Validate(input, policy)
		if err == nil {
			t.Fatalf("Validate(%q) was accepted", input)
		}
		for _, text := range []string{err.Error(), fmt.Sprintf("%v", err), fmt.Sprintf("%+v", err), fmt.Sprintf("%#v", err)} {
			if strings.Contains(text, marker) {
				t.Errorf("the error for %q echoes the input: %q", input, text)
			}
		}
	}
}

// ValidatedDestination は、ログ・%v へ出さない（取り込み先は、ログへ出さない）。
func TestValidatedDestinationIsRedactedWhenFormatted(t *testing.T) {
	policy := mustPolicyFor(t, appenv.Production)
	dest, err := Validate("rtmps://a.rtmps.youtube.com:443/live2", policy)
	if err != nil {
		t.Fatal(err)
	}
	for _, text := range []string{
		dest.String(), fmt.Sprintf("%v", dest), fmt.Sprintf("%+v", dest), fmt.Sprintf("%#v", dest), fmt.Sprintf("%s", dest),
		fmt.Sprintf("%v", &dest), fmt.Sprintf("%v", []ValidatedDestination{dest}), fmt.Sprintf("%+v", struct{ D ValidatedDestination }{dest}),
	} {
		for _, secret := range []string{"a.rtmps.youtube.com", "youtube", "live2", "443"} {
			if strings.Contains(text, secret) {
				t.Errorf("formatting a destination exposed %q: %q", secret, text)
			}
		}
	}
}

// 零値の ValidatedDestination は、無効（Validate を通っていない）。
func TestZeroValidatedDestinationIsInvalid(t *testing.T) {
	if (ValidatedDestination{}).valid() {
		t.Fatal("the zero ValidatedDestination must be invalid")
	}
}

func FuzzValidate(f *testing.F) {
	for _, seed := range []string{
		"rtmps://a.rtmps.youtube.com:443/live2",
		"rtmps://b.rtmps.youtube.com:443/live2?backup=1",
		"rtmp://a.rtmps.youtube.com:443/live2",
		"rtmps://user:pass@a.rtmps.youtube.com:443/live2",
		"rtmps://a.rtmps.youtube.com:0443/live2",
		"rtmps://a.rtmps.youtube.com:443/live2/key",
		"rtmps://[::1]:443/live2",
		"",
		"%",
		"rtmps://",
		"rtmps://a.rtmps.youtube.com:443@evil.example/",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, input string) {
		production, err := PolicyFor(appenv.Production)
		if err != nil {
			t.Fatal(err)
		}
		dest, err := Validate(input, production)
		if err != nil {
			if dest != (ValidatedDestination{}) {
				t.Fatalf("a rejected destination must be the zero value")
			}
			if len(input) >= 8 && strings.Contains(err.Error(), input) {
				t.Fatalf("the error echoes the input")
			}
			return
		}
		// 受理したものは、許可の規則をすべて満たす
		if !strings.HasPrefix(strings.ToLower(input), "rtmps://") {
			t.Fatalf("accepted a non-rtmps URL: %q", input)
		}
		if dest.port != 443 || (dest.host != "a.rtmps.youtube.com" && dest.host != "b.rtmps.youtube.com") || dest.skipTLSVerify {
			t.Fatalf("accepted %q:%d (skip %v) from %q", dest.host, dest.port, dest.skipTLSVerify, input)
		}
		if strings.ContainsAny(input, "?#@% \t\r\n") {
			t.Fatalf("accepted a URL with a forbidden character: %q", input)
		}
		if len(dest.app) < 1 || len(dest.app) > maxAppNameBytes {
			t.Fatalf("accepted an app name of %d bytes", len(dest.app))
		}
		for _, r := range dest.app {
			ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
			if !ok {
				t.Fatalf("accepted an app name with %q", r)
			}
		}
		for _, r := range input {
			if r < 0x21 || r > 0x7E {
				t.Fatalf("accepted a URL with a non-printable or non-ASCII character %U", r)
			}
		}
	})
}
