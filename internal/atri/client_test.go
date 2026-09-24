package atri

import (
	"encoding/json"
	"testing"
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
