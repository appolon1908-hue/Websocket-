#!/usr/bin/env python3
"""Apply the final reviewed gateway corrections before protected merge."""

from __future__ import annotations

import os
import re
from pathlib import Path

FINAL_DIGEST = "b39cdffe56a8185c91174228f0423df68b1137f34875f6ee52f9914f904bf724"
PROVISIONAL_DIGESTS = {
    "856f55ce980fe661a6a326c1a70207496f0eb3fc4bc335141e874c075b5a7e93",
    "0f3d217399472073f1bf5fbe250a054ae86d963eebca33c517d02b1b7d28bba6",
    "41b7e1897bad0886fbc8a209f635df28cfd9f80ab3aadd5c04f9ae8e92ac1077",
}


def require_digest(name: str) -> str:
    value = os.environ.get(name, "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise SystemExit(f"{name} is not an immutable sha256 digest")
    return value


def replace_once(source: str, old: str, new: str, label: str) -> str:
    if old not in source:
        if new in source:
            return source
        raise SystemExit(f"expected {label} source block is absent")
    return source.replace(old, new, 1)


def update_main() -> None:
    path = Path("cmd/gateway/main.go")
    source = path.read_text(encoding="utf-8")
    for digest in PROVISIONAL_DIGESTS:
        source = source.replace(digest, FINAL_DIGEST)

    digest_line = f'const contractDigest = "{FINAL_DIGEST}"\n'
    if "var errTicketDenied" not in source:
        source = replace_once(
            source,
            digest_line,
            digest_line + '\nvar errTicketDenied = errors.New("ticket denied")\n',
            "contract digest",
        )

    old_agent = '''\tp, err := s.consumeTicket(r.Context(), ticket)\n\tif err != nil || !p.Active || p.ExpiresAt.Before(time.Now()) || p.TenantID == "" || p.CampaignID == "" || p.AgentID == "" {\n\t\ts.reject(w, "ticket denied", http.StatusUnauthorized)\n\t\treturn\n\t}\n'''
    new_agent = '''\tp, err := s.consumeTicket(r.Context(), ticket)\n\tif err != nil {\n\t\tif errors.Is(err, errTicketDenied) {\n\t\t\ts.reject(w, "ticket denied", http.StatusUnauthorized)\n\t\t\treturn\n\t\t}\n\t\tw.Header().Set("Retry-After", "1")\n\t\ts.reject(w, "ticket authority unavailable; obtain a new ticket before retry", http.StatusServiceUnavailable)\n\t\treturn\n\t}\n\tif !p.Active || p.ExpiresAt.Before(time.Now()) || p.TenantID == "" || p.CampaignID == "" || p.AgentID == "" || (p.Role != "telephony_agent" && p.Role != "telephony_supervisor") {\n\t\ts.reject(w, "ticket denied", http.StatusUnauthorized)\n\t\treturn\n\t}\n'''
    source = replace_once(source, old_agent, new_agent, "ticket admission")

    old_status = '''\tif resp.StatusCode != http.StatusOK {\n\t\tio.Copy(io.Discard, io.LimitReader(resp.Body, 4096))\n\t\treturn principal{}, fmt.Errorf("ticket consume status %d", resp.StatusCode)\n\t}\n'''
    new_status = '''\tif resp.StatusCode != http.StatusOK {\n\t\tio.Copy(io.Discard, io.LimitReader(resp.Body, 4096))\n\t\tswitch resp.StatusCode {\n\t\tcase http.StatusBadRequest, http.StatusUnauthorized, http.StatusForbidden, http.StatusConflict, http.StatusGone:\n\t\t\treturn principal{}, errTicketDenied\n\t\tdefault:\n\t\t\treturn principal{}, fmt.Errorf("ticket authority status %d", resp.StatusCode)\n\t\t}\n\t}\n'''
    source = replace_once(source, old_status, new_status, "ticket response")

    old_read = '''\t\tcase data := <-reads:\n\t\t\tif subtle.ConstantTimeCompare(data, []byte("ping")) == 1 {\n'''
    new_read = '''\t\tcase data, ok := <-reads:\n\t\t\tif !ok {\n\t\t\t\treturn\n\t\t\t}\n\t\t\tif subtle.ConstantTimeCompare(data, []byte("ping")) == 1 {\n'''
    source = replace_once(source, old_read, new_read, "socket read channel")

    old_headers = '''\treq.Header.Set("X-Agent-ID", p.AgentID)\n'''
    new_headers = '''\treq.Header.Set("X-Agent-ID", p.AgentID)\n\treq.Header.Set("X-Role", p.Role)\n'''
    source = replace_once(source, old_headers, new_headers, "principal stream headers")

    if FINAL_DIGEST not in source:
        raise SystemExit("final contract digest was not written to gateway source")
    if any(digest in source for digest in PROVISIONAL_DIGESTS):
        raise SystemExit("provisional contract digest remains in gateway source")
    path.write_text(source, encoding="utf-8")


def update_readme() -> None:
    path = Path("README.md")
    source = path.read_text(encoding="utf-8")
    for digest in PROVISIONAL_DIGESTS:
        source = source.replace(digest, FINAL_DIGEST)
    note = (
        "\nMiddleware transport and 5xx failures return HTTP 503 with `Retry-After`. "
        "A client must obtain a new one-use ticket before reconnecting because an "
        "ambiguous consume may already have invalidated the prior ticket.\n"
    )
    if "ambiguous consume may already have invalidated" not in source:
        source += note
    if FINAL_DIGEST not in source:
        raise SystemExit("final contract digest was not written to README")
    path.write_text(source, encoding="utf-8")


def update_tests() -> None:
    path = Path("cmd/gateway/main_test.go")
    source = path.read_text(encoding="utf-8")
    if '\t"errors"\n' not in source:
        source = replace_once(
            source,
            'import (\n\t"context"\n',
            'import (\n\t"context"\n\t"errors"\n',
            "test imports",
        )

    tests = r'''

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestTicketAuthorityOutageIsRetryable(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("middleware unavailable")
	})}
	s := newServer(config{
		middlewareURL: "http://middleware.invalid",
		serviceToken: "service",
		origins: map[string]struct{}{"https://odoo.codestra.co": {}},
		maxConnections: 1,
	}, client)
	r := httptest.NewRequest(http.MethodGet, "/ws/agent?ticket="+strings.Repeat("x", 32), nil)
	r.Header.Set("Origin", "https://odoo.codestra.co")
	w := httptest.NewRecorder()
	s.agent(w, r)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("got %d want %d: %s", w.Code, http.StatusServiceUnavailable, w.Body.String())
	}
	if w.Header().Get("Retry-After") != "1" {
		t.Fatalf("Retry-After=%q", w.Header().Get("Retry-After"))
	}
}

func TestRejectedTicketRemainsUnauthorized(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusGone)
	}))
	defer upstream.Close()
	s := newServer(config{
		middlewareURL: upstream.URL,
		serviceToken: "service",
		origins: map[string]struct{}{"https://odoo.codestra.co": {}},
		maxConnections: 1,
	}, upstream.Client())
	r := httptest.NewRequest(http.MethodGet, "/ws/agent?ticket="+strings.Repeat("x", 32), nil)
	r.Header.Set("Origin", "https://odoo.codestra.co")
	w := httptest.NewRecorder()
	s.agent(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("got %d want %d: %s", w.Code, http.StatusUnauthorized, w.Body.String())
	}
}

func TestFinalProtectedContractDigest(t *testing.T) {
	const expected = "b39cdffe56a8185c91174228f0423df68b1137f34875f6ee52f9914f904bf724"
	if contractDigest != expected {
		t.Fatalf("contract digest=%s want=%s", contractDigest, expected)
	}
}
'''
    if "TestTicketAuthorityOutageIsRetryable" not in source:
        source += tests
    path.write_text(source, encoding="utf-8")


def update_dockerfile() -> None:
    builder = require_digest("BUILDER_DIGEST")
    runtime = require_digest("RUNTIME_DIGEST")
    content = f'''FROM mirror.gcr.io/library/golang:1.23-alpine@{builder} AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /gateway ./cmd/gateway

FROM gcr.io/distroless/static-debian12:nonroot@{runtime}
COPY --from=build /gateway /gateway
USER 65532:65532
ENTRYPOINT ["/gateway"]
'''
    Path("Dockerfile").write_text(content, encoding="utf-8")


def main() -> None:
    update_main()
    update_readme()
    update_tests()
    update_dockerfile()
    print("GATEWAY_FINALIZATION=PASS")


if __name__ == "__main__":
    main()
