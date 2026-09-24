package atri

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestBrowserCryptoCompatibility(t *testing.T) {
	secret := "0123456789abcdefghijklmnopqrstuv"
	params := map[string]any{
		"email":    "test+tag@example.com",
		"password": "p@ss word!中文",
	}

	const expectedBody = "C2ZsEYiBzxwriZD7uR/gPMa1/1+ASZ79FoxZKL1m9Qi0mbFmD3xxYayKc6NydZ5rLjHik7nZwflHqKEvfzXG1g=="
	const expectedSignature = "967068adf2ccda7e62659652ffc71add"

	body, err := encryptParams(params, secret)
	if err != nil {
		t.Fatal(err)
	}
	if body != expectedBody {
		t.Fatalf("body mismatch:\nwant %s\ngot  %s", expectedBody, body)
	}
	if got := signature(params, secret); got != expectedSignature {
		t.Fatalf("signature mismatch: want %s, got %s", expectedSignature, got)
	}

	plain, err := decryptPayload(body, secret)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(plain, &decoded); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, params) {
		t.Fatalf("decoded params mismatch: %#v", decoded)
	}
}

func TestSignatureIgnoresEmptyAndObjectValues(t *testing.T) {
	params := map[string]any{
		"email":   "user@example.com",
		"empty":   "",
		"sign":    "ignored",
		"nested":  map[string]any{"a": "b"},
		"version": 2,
	}
	want := signature(map[string]any{
		"email":   "user@example.com",
		"version": 2,
	}, "0123456789abcdefghijklmnopqrstuv")
	if got := signature(params, "0123456789abcdefghijklmnopqrstuv"); got != want {
		t.Fatalf("signature mismatch: want %s, got %s", want, got)
	}
}
