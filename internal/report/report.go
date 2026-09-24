package report

import (
	"encoding/csv"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"

	"github.com/wu21-web/atri-signin/internal/runner"
)

func Write(dir string, results []runner.Result) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	base := "signin-" + time.Now().Format("20060102-150405")
	var path string
	var file *os.File
	for suffix := 0; ; suffix++ {
		name := base + ".csv"
		if suffix > 0 {
			name = base + "-" + strconv.Itoa(suffix) + ".csv"
		}
		path = filepath.Join(dir, name)
		var err error
		file, err = os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrExist) {
			return "", err
		}
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	if err := writer.Write([]string{"timestamp", "email", "status", "message", "amount", "balance", "duration_ms"}); err != nil {
		return "", err
	}
	sorted := append([]runner.Result(nil), results...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Email < sorted[j].Email
	})
	for _, result := range sorted {
		row := []string{
			result.Timestamp.Format(time.RFC3339),
			result.Email,
			result.Status,
			result.Message,
			result.Amount,
			result.Balance,
			strconv.FormatInt(result.DurationMS, 10),
		}
		if err := writer.Write(row); err != nil {
			return "", err
		}
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		return "", err
	}
	return path, nil
}

func Summarize(results []runner.Result) map[string]int {
	counts := map[string]int{
		"total":          len(results),
		"success":        0,
		"already_signed": 0,
		"failed":         0,
	}
	for _, result := range results {
		switch result.Status {
		case "success":
			counts["success"]++
		case "already_signed":
			counts["already_signed"]++
		default:
			counts["failed"]++
		}
	}
	return counts
}
