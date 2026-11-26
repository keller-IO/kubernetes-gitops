// Package rebuildcontract exercises the real image in a network-isolated container.
package rebuildcontract

import (
	"bytes"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRuntime(t *testing.T) {
	if os.Getenv("GOPHISH_RUNTIME_CONTRACT") != "1" {
		t.Skip("opt-in isolated runtime test")
	}
	const base = "http://127.0.0.1:3333"
	const initial = "synthetic-bootstrap-password-12345"
	const changed = "synthetic-changed-password-67890"
	var logs bytes.Buffer
	start := func() *exec.Cmd {
		t.Helper()
		cmd := exec.Command("/opt/gophish/gophish", "--config", "/test/config.json", "--disable-mailer")
		cmd.Env = append(os.Environ(), "GOPHISH_INITIAL_ADMIN_PASSWORD="+initial)
		cmd.Stdout, cmd.Stderr = &logs, &logs
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { cmd.Process.Kill() })
		deadline := time.Now().Add(15 * time.Second)
		client := &http.Client{Timeout: 200 * time.Millisecond}
		for time.Now().Before(deadline) {
			resp, err := client.Get(base + "/login")
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode == http.StatusOK {
					return cmd
				}
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatal("application did not become ready")
		return nil
	}
	stop := func(cmd *exec.Cmd) {
		t.Helper()
		if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("SIGTERM was not graceful: %v", err)
			}
		case <-time.After(12 * time.Second):
			t.Fatal("SIGTERM shutdown timed out")
		}
	}
	newClient := func() *http.Client {
		jar, _ := cookiejar.New(nil)
		return &http.Client{Jar: jar, Timeout: 3 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	get := func(client *http.Client, path string, want int) string {
		t.Helper()
		resp, err := client.Get(base + path)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != want {
			t.Fatalf("GET %s: status %d, want %d", path, resp.StatusCode, want)
		}
		return string(body)
	}
	token := func(body string) string {
		t.Helper()
		match := regexp.MustCompile(`name="csrf_token" value="([^"]+)"`).FindStringSubmatch(body)
		if len(match) != 2 {
			t.Fatal("CSRF token absent")
		}
		return html.UnescapeString(match[1])
	}
	post := func(client *http.Client, path, origin string, fields url.Values, want int) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, base+path, strings.NewReader(fields.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Origin", origin)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("POST %s: status %d, want %d: %s", path, resp.StatusCode, want, body)
		}
	}
	login := func(client *http.Client, password string, want int) {
		t.Helper()
		csrf := token(get(client, "/login", 200))
		post(client, "/login", base, url.Values{
			"username": {"admin"}, "password": {password}, "csrf_token": {csrf},
		}, want)
	}
	cmd := start()
	client := newClient()
	// A valid token must not make an untrusted origin acceptable.
	csrf := token(get(client, "/login", 200))
	post(client, "/login", "http://evil.example", url.Values{
		"username": {"admin"}, "password": {initial}, "csrf_token": {csrf},
	}, 403)
	// Missing token must remain forbidden even on the loopback HTTP endpoint.
	post(client, "/login", base, url.Values{
		"username": {"admin"}, "password": {initial},
	}, 403)
	login(client, initial, 302)
	csrf = token(get(client, "/reset_password", 200))
	post(client, "/reset_password", base, url.Values{
		"password": {changed}, "confirm_password": {changed}, "csrf_token": {csrf},
	}, 302)
	get(client, "/", 200)
	get(client, "/js/dist/vendor.min.js", 200)
	get(client, "/css/dist/gophish.css", 200)
	// API must not be usable without an API key.
	get(newClient(), "/api/groups/", 401)
	stop(cmd)
	if strings.Contains(logs.String(), initial) || strings.Contains(logs.String(), changed) {
		t.Fatal("runtime logs disclosed a password")
	}
	cmd = start()
	login(newClient(), initial, 401)
	login(newClient(), changed, 302)
	stop(cmd)
	if strings.Contains(logs.String(), initial) || strings.Contains(logs.String(), changed) {
		t.Fatal("restart logs disclosed a password")
	}
	fmt.Println("runtime contract: login, CSRF, assets, password persistence, logs and SIGTERM passed")
}
