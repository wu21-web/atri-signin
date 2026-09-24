package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/wu21-web/atri-signin/internal/accounts"
	"github.com/wu21-web/atri-signin/internal/atri"
)

type Config struct {
	Accounts       []accounts.Account
	BaseURL        string
	MaxConcurrent  int
	RequestTimeout time.Duration
	WorkerTimeout  time.Duration
}

type Result struct {
	atri.Result
	Timestamp time.Time
}

type workerInput struct {
	Email          string `json:"email"`
	Password       string `json:"password"`
	BaseURL        string `json:"base_url"`
	RequestTimeout int64  `json:"request_timeout_ms"`
}

func Run(ctx context.Context, cfg Config, onResult func(Result)) ([]Result, error) {
	if len(cfg.Accounts) == 0 {
		return nil, errors.New("no accounts to process")
	}
	if cfg.MaxConcurrent < 1 {
		return nil, errors.New("max concurrency must be at least 1")
	}
	if cfg.WorkerTimeout <= 0 {
		cfg.WorkerTimeout = 2 * time.Minute
	}
	if cfg.RequestTimeout <= 0 {
		cfg.RequestTimeout = 25 * time.Second
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = atri.DefaultBaseURL
	}

	path, err := os.Executable()
	if err != nil {
		return nil, err
	}

	workers := cfg.MaxConcurrent
	if workers > len(cfg.Accounts) {
		workers = len(cfg.Accounts)
	}
	jobs := make(chan accounts.Account)
	results := make(chan Result)

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for account := range jobs {
				result := runWorker(ctx, path, account, cfg)
				results <- result
			}
		}()
	}

	go func() {
		defer close(jobs)
		for _, account := range cfg.Accounts {
			select {
			case <-ctx.Done():
				return
			case jobs <- account:
			}
		}
	}()

	go func() {
		wg.Wait()
		close(results)
	}()

	var collected []Result
	for result := range results {
		collected = append(collected, result)
		if onResult != nil {
			onResult(result)
		}
	}
	if err := ctx.Err(); err != nil {
		return collected, err
	}
	return collected, nil
}

func RunWorker(ctx context.Context) error {
	var input workerInput
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		return err
	}
	if input.BaseURL == "" {
		input.BaseURL = atri.DefaultBaseURL
	}
	timeout := time.Duration(input.RequestTimeout) * time.Millisecond
	if timeout <= 0 {
		timeout = 25 * time.Second
	}
	client, err := atri.NewClient(input.BaseURL, timeout)
	if err != nil {
		return err
	}
	if err := atri.SleepJitter(ctx, 0, 3*time.Second); err != nil {
		return err
	}
	result := client.CheckIn(ctx, input.Email, input.Password)
	return json.NewEncoder(os.Stdout).Encode(result)
}

func runWorker(ctx context.Context, executable string, account accounts.Account, cfg Config) Result {
	started := time.Now()
	workerCtx, cancel := context.WithTimeout(ctx, cfg.WorkerTimeout)
	defer cancel()

	input, err := json.Marshal(workerInput{
		Email:          account.Email,
		Password:       account.Password,
		BaseURL:        cfg.BaseURL,
		RequestTimeout: cfg.RequestTimeout.Milliseconds(),
	})
	if err != nil {
		return failedResult(account.Email, started, err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command := exec.CommandContext(workerCtx, executable, "--worker")
	command.Stdin = bytes.NewReader(input)
	command.Stdout = &stdout
	command.Stderr = &stderr
	command.WaitDelay = 5 * time.Second

	err = command.Run()
	if err != nil {
		if errors.Is(workerCtx.Err(), context.DeadlineExceeded) {
			return Result{
				Result: atri.Result{
					Email:      account.Email,
					Status:     atri.StatusTimeout,
					Message:    "account worker timed out",
					DurationMS: time.Since(started).Milliseconds(),
				},
				Timestamp: time.Now(),
			}
		}
		if ctx.Err() != nil {
			return Result{
				Result: atri.Result{
					Email:      account.Email,
					Status:     atri.StatusTimeout,
					Message:    "run canceled",
					DurationMS: time.Since(started).Milliseconds(),
				},
				Timestamp: time.Now(),
			}
		}
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return failedResult(account.Email, started, errors.New(detail))
	}

	var result atri.Result
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &result); err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return failedResult(account.Email, started, fmt.Errorf("invalid worker output: %s", detail))
	}
	if result.Email == "" {
		result.Email = account.Email
	}
	if result.DurationMS == 0 {
		result.DurationMS = time.Since(started).Milliseconds()
	}
	return Result{Result: result, Timestamp: time.Now()}
}

func failedResult(email string, started time.Time, err error) Result {
	return Result{
		Result: atri.Result{
			Email:      email,
			Status:     atri.StatusFailed,
			Message:    err.Error(),
			DurationMS: time.Since(started).Milliseconds(),
		},
		Timestamp: time.Now(),
	}
}
