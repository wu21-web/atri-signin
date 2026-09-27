package atri

import (
	"encoding/json"
	"testing"
	"time"
)

func TestParseCheckinData(t *testing.T) {
	amount, balance := parseCheckinData(json.RawMessage(`{
		"amount": "0.14",
		"balance": "8.57",
		"checkin": {"today_amount": "0.14"}
	}`))
	if amount != "0.14" {
		t.Fatalf("amount mismatch: %q", amount)
	}
	if balance != "8.57" {
		t.Fatalf("balance mismatch: %q", balance)
	}
}

func TestParseCheckinDataFallsBackToTodayAmount(t *testing.T) {
	amount, _ := parseCheckinData(json.RawMessage(`{
		"checkin": {"today_amount": 0.14}
	}`))
	if amount != "0.14" {
		t.Fatalf("amount mismatch: %q", amount)
	}
}

func TestNormalizeBaseURL(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "empty", input: "", want: DefaultBaseURL},
		{name: "hostname", input: "shop.atrishop.work", want: "https://shop.atrishop.work"},
		{name: "hostname path", input: "example.com/shop/", want: "https://example.com/shop"},
		{name: "http url", input: "http://example.com/shop/", want: "http://example.com/shop"},
		{name: "https url", input: "https://example.com/", want: "https://example.com"},
		{name: "bad scheme", input: "ftp://example.com", wantErr: true},
		{name: "missing host", input: "https://", wantErr: true},
		{name: "missing hostname", input: "https://:443", wantErr: true},
		{name: "invalid port", input: "https://example.com:70000", wantErr: true},
		{name: "non-numeric port", input: "https://example.com:http", wantErr: true},
		{name: "query", input: "https://example.com/?token=1", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := NormalizeBaseURL(test.input)
			if test.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("want %q, got %q", test.want, got)
			}
		})
	}
}

func TestClientCenterPathIncludesBasePath(t *testing.T) {
	root, err := NewClient("https://example.com", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if got := root.centerPath(); got != "/user/center" {
		t.Fatalf("root center path: want %q, got %q", "/user/center", got)
	}

	prefixed, err := NewClient("https://example.com/shop/", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if got := prefixed.centerPath(); got != "/shop/user/center" {
		t.Fatalf("prefixed center path: want %q, got %q", "/shop/user/center", got)
	}
}
