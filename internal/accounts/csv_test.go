package accounts

import (
	"strings"
	"testing"
)

func TestParseHeaderlessCSV(t *testing.T) {
	input := "\ufeffone@example.com,pass one\n\n" +
		"two@example.com,\"pass,two\"\n" +
		"ONE@example.com,duplicate\n"
	got, warnings, err := Parse(strings.NewReader(input))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 accounts, got %d", len(got))
	}
	if got[0].Email != "one@example.com" || got[0].Password != "pass one" {
		t.Fatalf("unexpected first account: %#v", got[0])
	}
	if got[1].Email != "two@example.com" || got[1].Password != "pass,two" {
		t.Fatalf("unexpected second account: %#v", got[1])
	}
	if len(warnings) != 1 {
		t.Fatalf("expected one duplicate warning, got %#v", warnings)
	}
}

func TestParseRejectsMalformedRows(t *testing.T) {
	_, _, err := Parse(strings.NewReader("one@example.com\n"))
	if err == nil {
		t.Fatal("expected malformed row error")
	}
}
