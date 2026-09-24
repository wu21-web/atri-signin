package main

import (
	"context"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/wu21-web/atri-signin/internal/accounts"
	"github.com/wu21-web/atri-signin/internal/atri"
	"github.com/wu21-web/atri-signin/internal/report"
	"github.com/wu21-web/atri-signin/internal/runner"
)

func main() {
	os.Exit(run())
}

func run() int {
	fs := flag.NewFlagSet("atri-signin", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	accountsPath := fs.String("accounts", "accounts.csv", "path to the email,password CSV file")
	maxSigninCount := fs.Int("max-signin-count", 2, "maximum number of account subprocesses running at once")
	resultsDir := fs.String("results", "results", "directory for the results CSV")
	requestTimeout := fs.Duration("timeout", 25*time.Second, "timeout for each HTTP request")
	workerTimeout := fs.Duration("worker-timeout", 2*time.Minute, "timeout for one account subprocess")
	worker := fs.Bool("worker", false, "internal single-account worker mode")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "Usage: atri-signin [options]\n\nOptions:\n")
		fs.VisitAll(func(f *flag.Flag) {
			if f.Name == "worker" {
				return
			}
			fmt.Fprintf(fs.Output(), "  -%s %s\n", f.Name, f.Value)
			fmt.Fprintf(fs.Output(), "        %s\n", f.Usage)
		})
	}
	if err := fs.Parse(os.Args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 1
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *worker {
		if err := runner.RunWorker(ctx); err != nil {
			fmt.Fprintln(os.Stderr, "worker:", err)
			return 1
		}
		return 0
	}
	if *maxSigninCount < 1 {
		fmt.Fprintln(os.Stderr, "max-signin-count must be at least 1")
		return 1
	}

	loaded, warnings, err := accounts.Load(*accountsPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "accounts:", err)
		return 1
	}
	for _, warning := range warnings {
		fmt.Fprintln(os.Stderr, "warning:", warning)
	}
	if len(loaded) == 0 {
		fmt.Fprintln(os.Stderr, "accounts: no accounts found")
		return 1
	}
	shuffle(loaded)

	fmt.Printf("loaded %d accounts, concurrency %d\n", len(loaded), *maxSigninCount)
	completed := 0
	results, runErr := runner.Run(ctx, runner.Config{
		Accounts:       loaded,
		BaseURL:        atri.DefaultBaseURL,
		MaxConcurrent:  *maxSigninCount,
		RequestTimeout: *requestTimeout,
		WorkerTimeout:  *workerTimeout,
	}, func(result runner.Result) {
		completed++
		fmt.Printf("[%d/%d] %s -> %s: %s\n", completed, len(loaded), result.Email, result.Status, resultDetail(result))
	})

	if len(results) > 0 {
		path, err := report.Write(*resultsDir, results)
		if err != nil {
			fmt.Fprintln(os.Stderr, "report:", err)
			return 1
		}
		counts := report.Summarize(results)
		fmt.Printf("summary: %d success, %d already signed, %d failed\n", counts["success"], counts["already_signed"], counts["failed"])
		fmt.Println("report:", path)
	}
	if runErr != nil {
		fmt.Fprintln(os.Stderr, "run:", runErr)
		return 1
	}
	if report.Summarize(results)["failed"] > 0 {
		return 2
	}
	return 0
}

func resultDetail(result runner.Result) string {
	if result.Amount == "" {
		return result.Message
	}
	detail := result.Message + " (reward ¥" + formatMoney(result.Amount)
	if result.Balance != "" {
		detail += ", balance ¥" + formatMoney(result.Balance)
	}
	return detail + ")"
}

func formatMoney(value string) string {
	number, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return value
	}
	return strconv.FormatFloat(number, 'f', 2, 64)
}

func shuffle(items []accounts.Account) {
	for i := len(items) - 1; i > 0; i-- {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(i+1)))
		if err != nil {
			return
		}
		j := int(n.Int64())
		items[i], items[j] = items[j], items[i]
	}
}
