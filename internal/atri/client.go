package atri

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultBaseURL   = "https://shop.atrishop.work"
	DefaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"

	StatusSuccess       = "success"
	StatusAlreadySigned = "already_signed"
	StatusBadCredential = "bad_credentials"
	StatusFailed        = "failed"
	StatusTimeout       = "timeout"
)

type Result struct {
	Email      string `json:"email"`
	Status     string `json:"status"`
	Message    string `json:"message"`
	DurationMS int64  `json:"duration_ms"`
}

type Client struct {
	baseURL   string
	userAgent string
	http      *http.Client
}

type apiResponse struct {
	Code    any    `json:"code"`
	Msg     string `json:"msg"`
	Message string `json:"message"`
}

func (r apiResponse) code() int {
	switch value := r.Code.(type) {
	case json.Number:
		n, _ := value.Int64()
		return int(n)
	case float64:
		return int(value)
	case string:
		n, _ := strconv.Atoi(value)
		return n
	default:
		return -1
	}
}

func (r apiResponse) text() string {
	if r.Message != "" {
		return r.Message
	}
	return r.Msg
}

func NewClient(baseURL string, timeout time.Duration) (*Client, error) {
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, err
	}
	if u.Scheme != "https" && u.Scheme != "http" {
		return nil, fmt.Errorf("unsupported base URL scheme %q", u.Scheme)
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	return &Client{
		baseURL:   strings.TrimRight(baseURL, "/"),
		userAgent: DefaultUserAgent,
		http: &http.Client{
			Jar:     jar,
			Timeout: timeout,
		},
	}, nil
}

func (c *Client) CheckIn(ctx context.Context, email, password string) Result {
	started := time.Now()
	finish := func(status, message string) Result {
		return Result{
			Email:      email,
			Status:     status,
			Message:    message,
			DurationMS: time.Since(started).Milliseconds(),
		}
	}

	loginURL := c.baseURL + "/user/login"
	loginPage, err := c.doRequest(ctx, http.MethodGet, loginURL, nil, c.documentHeaders("", "none"))
	if err != nil {
		return finish(networkStatus(err), networkMessage(err))
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(loginPage.Body, 1<<20))
	loginPage.Body.Close()
	if err := SleepJitter(ctx, 800*time.Millisecond, 2500*time.Millisecond); err != nil {
		return finish(networkStatus(err), networkMessage(err))
	}

	login, err := c.postJSON(ctx, "/api/user/login", map[string]any{
		"email":    email,
		"password": password,
	}, loginURL)
	if err != nil {
		return finish(networkStatus(err), networkMessage(err))
	}
	if login.code() != http.StatusOK {
		status := StatusFailed
		if login.code() == http.StatusUnauthorized || login.code() == http.StatusForbidden || isCredentialMessage(login.text()) {
			status = StatusBadCredential
		}
		return finish(status, nonEmpty(login.text(), "login rejected"))
	}

	if err := SleepJitter(ctx, 800*time.Millisecond, 2*time.Second); err != nil {
		return finish(networkStatus(err), networkMessage(err))
	}

	centerURL := c.baseURL + "/user/center"
	center, err := c.doRequest(ctx, http.MethodGet, centerURL, nil, c.documentHeaders(loginURL, "same-origin"))
	if err != nil {
		return finish(networkStatus(err), networkMessage(err))
	}
	defer center.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(center.Body, 1<<20))
	if center.Request == nil || center.Request.URL.Path != "/user/center" {
		return finish(StatusFailed, "login session was not established")
	}

	if err := SleepJitter(ctx, 1500*time.Millisecond, 5*time.Second); err != nil {
		return finish(networkStatus(err), networkMessage(err))
	}

	checkin, err := c.postJSON(ctx, "/api/user/checkin", map[string]any{}, centerURL)
	if err != nil {
		return finish(networkStatus(err), networkMessage(err))
	}
	if checkin.code() == http.StatusOK {
		return finish(StatusSuccess, nonEmpty(checkin.text(), "check-in completed"))
	}
	if isAlreadySignedMessage(checkin.text()) {
		return finish(StatusAlreadySigned, nonEmpty(checkin.text(), "already checked in"))
	}
	return finish(StatusFailed, nonEmpty(checkin.text(), "check-in rejected"))
}

func (c *Client) postJSON(ctx context.Context, path string, params map[string]any, referer string) (apiResponse, error) {
	secret, err := randomSecret()
	if err != nil {
		return apiResponse{}, err
	}
	body, err := encryptParams(params, secret)
	if err != nil {
		return apiResponse{}, err
	}
	headers := c.apiHeaders(secret, signature(params, secret), referer)
	response, err := c.doRequest(ctx, http.MethodPost, c.baseURL+path, []byte(body), headers)
	if err != nil {
		return apiResponse{}, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if err != nil {
		return apiResponse{}, err
	}
	if responseSecret := response.Header.Get("Secret"); responseSecret != "" && len(raw) > 0 {
		raw, err = decryptPayload(strings.TrimSpace(string(raw)), responseSecret)
		if err != nil {
			return apiResponse{}, fmt.Errorf("decrypt response: %w", err)
		}
	}
	var decoded apiResponse
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		preview := strings.TrimSpace(string(raw))
		if len(preview) > 180 {
			preview = preview[:180]
		}
		return apiResponse{}, fmt.Errorf("invalid API response: %w (%s)", err, preview)
	}
	return decoded, nil
}

func (c *Client) doRequest(ctx context.Context, method, target string, body []byte, headers http.Header) (*http.Response, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		var reader io.Reader
		if body != nil {
			reader = bytes.NewReader(body)
		}
		request, err := http.NewRequestWithContext(ctx, method, target, reader)
		if err != nil {
			return nil, err
		}
		request.Header = headers.Clone()

		response, err := c.http.Do(request)
		if err != nil {
			lastErr = err
			if attempt < 2 && ctx.Err() == nil {
				if sleepErr := sleepWithBackoff(ctx, attempt); sleepErr != nil {
					return nil, sleepErr
				}
				continue
			}
			return nil, err
		}
		if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
			if attempt < 2 {
				_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20))
				response.Body.Close()
				if sleepErr := sleepWithBackoff(ctx, attempt); sleepErr != nil {
					return nil, sleepErr
				}
				continue
			}
		}
		return response, nil
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, errors.New("request failed")
}

func (c *Client) documentHeaders(referer, site string) http.Header {
	headers := make(http.Header)
	headers.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8")
	headers.Set("Accept-Language", "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7")
	headers.Set("Cache-Control", "no-cache")
	headers.Set("Pragma", "no-cache")
	headers.Set("Sec-Fetch-Dest", "document")
	headers.Set("Sec-Fetch-Mode", "navigate")
	headers.Set("Sec-Fetch-Site", site)
	headers.Set("Sec-Fetch-User", "?1")
	headers.Set("Upgrade-Insecure-Requests", "1")
	headers.Set("User-Agent", c.userAgent)
	if referer != "" {
		headers.Set("Referer", referer)
	}
	return headers
}

func (c *Client) apiHeaders(secret, sig, referer string) http.Header {
	headers := make(http.Header)
	headers.Set("Accept", "*/*")
	headers.Set("Accept-Language", "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7")
	headers.Set("Content-Type", "text/plain")
	headers.Set("Origin", c.baseURL)
	headers.Set("Priority", "u=1, i")
	headers.Set("Referer", referer)
	headers.Set("Sec-Ch-Ua", `"Chromium";v="153", "Not:A-Brand";v="24", "Google Chrome";v="153"`)
	headers.Set("Sec-Ch-Ua-Mobile", "?0")
	headers.Set("Sec-Ch-Ua-Platform", `"macOS"`)
	headers.Set("Sec-Fetch-Dest", "empty")
	headers.Set("Sec-Fetch-Mode", "cors")
	headers.Set("Sec-Fetch-Site", "same-origin")
	headers.Set("Secret", secret)
	headers.Set("Signature", sig)
	headers.Set("User-Agent", c.userAgent)
	return headers
}

func SleepJitter(ctx context.Context, min, max time.Duration) error {
	delay, err := randomDuration(min, max)
	if err != nil {
		return err
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func sleepWithBackoff(ctx context.Context, attempt int) error {
	base := time.Duration(1<<attempt) * 2 * time.Second
	extra, err := randomDuration(0, 750*time.Millisecond)
	if err != nil {
		return err
	}
	timer := time.NewTimer(base + extra)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func randomDuration(min, max time.Duration) (time.Duration, error) {
	if max <= min {
		return min, nil
	}
	span := int64(max - min)
	n, err := rand.Int(rand.Reader, big.NewInt(span))
	if err != nil {
		return 0, err
	}
	return min + time.Duration(n.Int64()), nil
}

func networkStatus(err error) string {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return StatusTimeout
	}
	return StatusFailed
}

func networkMessage(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "request timed out"
	}
	if errors.Is(err, context.Canceled) {
		return "request canceled"
	}
	return err.Error()
}

func isCredentialMessage(message string) bool {
	message = strings.ToLower(message)
	return strings.Contains(message, "邮箱或密码错误") ||
		strings.Contains(message, "密码错误") ||
		strings.Contains(message, "账号或密码错误")
}

func isAlreadySignedMessage(message string) bool {
	return strings.Contains(message, "已签到") ||
		strings.Contains(message, "已经签到") ||
		strings.Contains(message, "重复签到") ||
		strings.Contains(message, "明天再来")
}

func nonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}
