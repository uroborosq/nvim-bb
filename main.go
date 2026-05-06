package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"text/tabwriter"
	"time"
)

const configPath = "config.json"

type Config struct {
	BaseURL string `json:"base_url"`
	Project string `json:"project"`
	Repo    string `json:"repo"`

	Auth     string `json:"auth"` // bearer | basic | none
	Token    string `json:"token"`
	User     string `json:"user"`
	Password string `json:"password"`

	State string `json:"state"` // OPEN | MERGED | DECLINED | ALL
	At    string `json:"at"`    // optional branch/ref filter

	Limit       int    `json:"limit"`
	Timeout     string `json:"timeout"`
	InsecureTLS bool   `json:"insecure_tls"`
	JSONOutput  bool   `json:"json_output"`
}

type RuntimeConfig struct {
	Config
	TimeoutDuration time.Duration
}

type Client struct {
	baseURL    *url.URL
	httpClient *http.Client
	cfg        RuntimeConfig
}

type PRPage struct {
	Size          int           `json:"size"`
	Limit         int           `json:"limit"`
	IsLastPage    bool          `json:"isLastPage"`
	Start         int           `json:"start"`
	NextPageStart int           `json:"nextPageStart"`
	Values        []PullRequest `json:"values"`
}

type PullRequest struct {
	ID          int64  `json:"id"`
	Title       string `json:"title"`
	State       string `json:"state"`
	CommentCount int   `json:"commentCount"`
	CreatedDate int64  `json:"createdDate"`
	UpdatedDate int64  `json:"updatedDate"`

	Author struct {
		User User `json:"user"`
	} `json:"author"`

	Reviewers []Reviewer `json:"reviewers"`

	FromRef Ref `json:"fromRef"`
	ToRef   Ref `json:"toRef"`

	Links struct {
		Self []struct {
			Href string `json:"href"`
		} `json:"self"`
	} `json:"links"`
}

type Reviewer struct {
	User     User   `json:"user"`
	Role     string `json:"role"`
	Approved bool   `json:"approved"`
	Status   string `json:"status"`
}

type Ref struct {
	ID         string     `json:"id"`
	DisplayID  string     `json:"displayId"`
	Repository Repository `json:"repository"`
}

type Repository struct {
	Slug    string `json:"slug"`
	Name    string `json:"name"`
	Project struct {
		Key  string `json:"key"`
		Name string `json:"name"`
	} `json:"project"`
}

type User struct {
	Name         string `json:"name"`
	Slug         string `json:"slug"`
	DisplayName  string `json:"displayName"`
	EmailAddress string `json:"emailAddress"`
}

func main() {
	cfg, err := LoadConfig(configPath)
	if err != nil {
		fatal(err)
	}

	client, err := NewClient(cfg)
	if err != nil {
		fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.TimeoutDuration)
	defer cancel()

	prs, err := client.GetRepoPullRequests(ctx)
	if err != nil {
		fatal(err)
	}

	sort.Slice(prs, func(i, j int) bool {
		return prs[i].CreatedDate > prs[j].CreatedDate
	})

	if cfg.JSONOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")

		if err := enc.Encode(prs); err != nil {
			fatal(err)
		}

		return
	}

	printTable(prs)
}

func LoadConfig(path string) (RuntimeConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return RuntimeConfig{}, fmt.Errorf("read config %q: %w", path, err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return RuntimeConfig{}, fmt.Errorf("parse config %q: %w", path, err)
	}

	cfg.normalize()
	cfg.applyDefaults()

	timeout, err := time.ParseDuration(cfg.Timeout)
	if err != nil {
		return RuntimeConfig{}, fmt.Errorf("bad timeout %q: %w", cfg.Timeout, err)
	}

	rt := RuntimeConfig{
		Config:          cfg,
		TimeoutDuration: timeout,
	}

	if err := validateConfig(rt); err != nil {
		return RuntimeConfig{}, err
	}

	return rt, nil
}

func (cfg *Config) normalize() {
	cfg.BaseURL = strings.TrimSpace(cfg.BaseURL)
	cfg.Project = strings.TrimSpace(cfg.Project)
	cfg.Repo = strings.TrimSpace(cfg.Repo)

	cfg.Auth = strings.ToLower(strings.TrimSpace(cfg.Auth))
	cfg.User = strings.TrimSpace(cfg.User)
	cfg.Password = strings.TrimSpace(cfg.Password)
	cfg.Token = strings.TrimSpace(cfg.Token)

	cfg.State = strings.ToUpper(strings.TrimSpace(cfg.State))
	cfg.At = strings.TrimSpace(cfg.At)
	cfg.Timeout = strings.TrimSpace(cfg.Timeout)
}

func (cfg *Config) applyDefaults() {
	if cfg.Auth == "" {
		cfg.Auth = "none"
	}

	if cfg.State == "" {
		cfg.State = "OPEN"
	}

	if cfg.Limit == 0 {
		cfg.Limit = 100
	}

	if cfg.Timeout == "" {
		cfg.Timeout = "60s"
	}
}

func validateConfig(cfg RuntimeConfig) error {
	if cfg.BaseURL == "" {
		return errors.New("config.base_url is required")
	}

	if cfg.Project == "" {
		return errors.New("config.project is required")
	}

	if cfg.Repo == "" {
		return errors.New("config.repo is required")
	}

	switch cfg.Auth {
	case "bearer":
		if cfg.Token == "" {
			return errors.New("config.token is required when auth=bearer")
		}
	case "basic":
		if cfg.User == "" {
			return errors.New("config.user is required when auth=basic")
		}
		if cfg.Password == "" && cfg.Token == "" {
			return errors.New("config.password or config.token is required when auth=basic")
		}
	case "none":
	default:
		return fmt.Errorf("bad config.auth %q; expected bearer|basic|none", cfg.Auth)
	}

	switch cfg.State {
	case "OPEN", "MERGED", "DECLINED", "ALL":
	default:
		return fmt.Errorf("bad config.state %q; expected OPEN|MERGED|DECLINED|ALL", cfg.State)
	}

	if cfg.Limit <= 0 || cfg.Limit > 1000 {
		return errors.New("config.limit must be in range 1..1000")
	}

	if cfg.TimeoutDuration <= 0 {
		return errors.New("config.timeout must be positive")
	}

	return nil
}

func NewClient(cfg RuntimeConfig) (*Client, error) {
	baseURL, err := url.Parse(cfg.BaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse base_url: %w", err)
	}

	if baseURL.Scheme == "" || baseURL.Host == "" {
		return nil, fmt.Errorf("bad base_url: %q", cfg.BaseURL)
	}

	tr := http.DefaultTransport.(*http.Transport).Clone()

	if cfg.InsecureTLS {
		tr.TLSClientConfig = &tls.Config{
			InsecureSkipVerify: true, //nolint:gosec
		}
	}

	return &Client{
		baseURL: baseURL,
		httpClient: &http.Client{
			Transport: tr,
			Timeout:   cfg.TimeoutDuration,
		},
		cfg: cfg,
	}, nil
}

func (c *Client) GetRepoPullRequests(ctx context.Context) ([]PullRequest, error) {
	var all []PullRequest
	start := 0

	for {
		page, err := c.fetchRepoPRPage(ctx, start)
		if err != nil {
			return nil, err
		}

		all = append(all, page.Values...)

		if page.IsLastPage {
			break
		}

		next := page.NextPageStart
		if next <= start {
			if page.Size > 0 {
				next = start + page.Size
			} else {
				return nil, fmt.Errorf(
					"pagination stuck: start=%d nextPageStart=%d size=%d",
					start,
					page.NextPageStart,
					page.Size,
				)
			}
		}

		start = next
	}

	return all, nil
}

func (c *Client) fetchRepoPRPage(ctx context.Context, start int) (*PRPage, error) {
	u := *c.baseURL

	u.Path = joinURLPath(
		c.baseURL.Path,
		fmt.Sprintf(
			"/rest/api/latest/projects/%s/repos/%s/pull-requests",
			url.PathEscape(c.cfg.Project),
			url.PathEscape(c.cfg.Repo),
		),
	)

	q := u.Query()
	q.Set("state", c.cfg.State)
	q.Set("order", "NEWEST")
	q.Set("limit", fmt.Sprintf("%d", c.cfg.Limit))
	q.Set("start", fmt.Sprintf("%d", start))

	if c.cfg.At != "" {
		q.Set("at", c.cfg.At)
	}

	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Accept", "application/json")
	c.setAuth(req)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", u.Redacted(), err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))

		return nil, fmt.Errorf(
			"Bitbucket returned %s: %s",
			resp.Status,
			strings.TrimSpace(string(body)),
		)
	}

	var page PRPage
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		return nil, fmt.Errorf("decode Bitbucket response: %w", err)
	}

	return &page, nil
}

func (c *Client) setAuth(req *http.Request) {
	switch c.cfg.Auth {
	case "bearer":
		req.Header.Set("Authorization", "Bearer "+c.cfg.Token)

	case "basic":
		secret := c.cfg.Password
		if secret == "" {
			secret = c.cfg.Token
		}

		req.SetBasicAuth(c.cfg.User, secret)

	case "none":
		return
	}
}

func printTable(prs []PullRequest) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	fmt.Fprintln(w, "AGE\tLCOM\tCMTS\tNW\tAPPR\tAUTHOR\tTITLE")

	now := time.Now()

	for _, pr := range prs {
		opened := msToTime(pr.CreatedDate)
		ageStr := "-"
		lastCommentStr := "-"

		if !opened.IsZero() {
			ageStr = humanAge(now.Sub(opened))
		}
		updated := msToTime(pr.UpdatedDate)
		if !updated.IsZero() {
			lastCommentStr = humanAge(now.Sub(updated))
		}

		fmt.Fprintf(
			w,
			"%s\t%s\t%d\t%s\t%d\t%s\t%s\n",
			ageStr,
			lastCommentStr,
			pr.CommentCount,
			needsWorkStatus(pr.Reviewers),
			countApprovals(pr.Reviewers),
			displayUser(pr.Author.User),
			sanitizeCell(pr.Title),
		)
	}

	_ = w.Flush()
}

func countApprovals(reviewers []Reviewer) int {
	count := 0

	for _, reviewer := range reviewers {
		if reviewer.Approved || strings.EqualFold(reviewer.Status, "APPROVED") {
			count++
		}
	}

	return count
}

func needsWorkStatus(reviewers []Reviewer) string {
	for _, reviewer := range reviewers {
		if strings.EqualFold(reviewer.Status, "NEEDS_WORK") {
			return "yes"
		}
	}

	return "-"
}

func reviewersList(pr PullRequest) string {
	if len(pr.Reviewers) == 0 {
		return "-"
	}

	names := make([]string, 0, len(pr.Reviewers))

	for _, r := range pr.Reviewers {
		name := displayUser(r.User)

		if r.Status != "" {
			name += ":" + r.Status
		} else if r.Approved {
			name += ":APPROVED"
		}

		names = append(names, name)
	}

	return strings.Join(names, ", ")
}

func msToTime(ms int64) time.Time {
	if ms <= 0 {
		return time.Time{}
	}

	return time.Unix(0, ms*int64(time.Millisecond)).Local()
}

func humanAge(d time.Duration) string {
	if d < 0 {
		d = -d
	}

	days := int(d.Hours() / 24)

	switch {
	case days >= 365:
		return fmt.Sprintf("%dy%dd", days/365, days%365)

	case days >= 1:
		return fmt.Sprintf("%dd", days)

	default:
		hours := int(d.Hours())
		if hours > 0 {
			return fmt.Sprintf("%dh", hours)
		}

		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
}

func repoName(r Repository) string {
	if r.Slug != "" {
		return r.Slug
	}

	return r.Name
}

func displayUser(u User) string {
	if u.DisplayName != "" {
		return u.DisplayName
	}

	if u.Name != "" {
		return u.Name
	}

	if u.Slug != "" {
		return u.Slug
	}

	return u.EmailAddress
}

func selfURL(pr PullRequest) string {
	if len(pr.Links.Self) == 0 {
		return ""
	}

	return pr.Links.Self[0].Href
}

func sanitizeCell(s string) string {
	s = strings.ReplaceAll(s, "\t", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")

	return s
}

func joinURLPath(basePath, suffix string) string {
	return strings.TrimRight(basePath, "/") + "/" + strings.TrimLeft(suffix, "/")
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
