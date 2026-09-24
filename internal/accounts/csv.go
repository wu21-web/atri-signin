package accounts

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strings"
)

type Account struct {
	Email    string
	Password string
	Line     int
}

func Load(path string) ([]Account, []string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	return Parse(file)
}

func Parse(reader io.Reader) ([]Account, []string, error) {
	r := csv.NewReader(reader)
	r.FieldsPerRecord = -1

	var accounts []Account
	var warnings []string
	seen := make(map[string]bool)
	first := true

	for {
		record, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, warnings, err
		}
		line, _ := r.FieldPos(0)
		if len(record) == 1 && strings.TrimSpace(record[0]) == "" {
			continue
		}
		if len(record) != 2 {
			return nil, warnings, fmt.Errorf("line %d: expected email,password", line)
		}

		email := strings.TrimSpace(record[0])
		if first {
			email = strings.TrimPrefix(email, "\ufeff")
			first = false
		}
		password := record[1]
		if email == "" {
			return nil, warnings, fmt.Errorf("line %d: email is empty", line)
		}
		if password == "" {
			return nil, warnings, fmt.Errorf("line %d: password is empty", line)
		}

		key := strings.ToLower(email)
		if seen[key] {
			warnings = append(warnings, fmt.Sprintf("line %d: duplicate account %s skipped", line, email))
			continue
		}
		seen[key] = true
		accounts = append(accounts, Account{
			Email:    email,
			Password: password,
			Line:     line,
		})
	}
	return accounts, warnings, nil
}
