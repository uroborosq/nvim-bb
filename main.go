package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

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
	CurrentUser string `json:"current_user"`
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
	ID           int64  `json:"id"`
	Version      int    `json:"version"`
	Title        string `json:"title"`
	Description  string `json:"description"`
	State        string `json:"state"`
	CommentCount int    `json:"commentCount"`
	CreatedDate  int64  `json:"createdDate"`
	UpdatedDate  int64  `json:"updatedDate"`

	Author struct {
		User User `json:"user"`
	} `json:"author"`

	Reviewers      []Reviewer `json:"reviewers"`
	MyReviewStatus string     `json:"my_review_status,omitempty"`
	MyApproved     bool       `json:"my_approved,omitempty"`

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

type Emoticon struct {
	Shortcut string `json:"shortcut"`
	URL      string `json:"url"`
}

type Reaction struct {
	Emoticon Emoticon `json:"emoticon"`
	Users    []User   `json:"users"`
}

type CommentPage struct {
	Size          int         `json:"size"`
	Limit         int         `json:"limit"`
	IsLastPage    bool        `json:"isLastPage"`
	Start         int         `json:"start"`
	NextPageStart int         `json:"nextPageStart"`
	Values        []PRComment `json:"values"`
}

type PRComment struct {
	ID            int64       `json:"id"`
	Text          string      `json:"text"`
	CreatedDate   int64       `json:"createdDate"`
	UpdatedDate   int64       `json:"updatedDate"`
	Version       int         `json:"version"`
	Anchor        *Anchor     `json:"anchor,omitempty"`
	CommentAnchor *Anchor     `json:"commentAnchor,omitempty"`
	Comments      []PRComment `json:"comments,omitempty"`
	Properties    Properties  `json:"properties,omitempty"`
	Severity      string      `json:"severity,omitempty"`
	State         string      `json:"state,omitempty"`
	Author        User        `json:"author"`
}

type Anchor struct {
	Path     string `json:"path"`
	Line     int    `json:"line"`
	LineType string `json:"lineType"`
	FileType string `json:"fileType"`
	DiffType string `json:"diffType"`
}

func (a *Anchor) UnmarshalJSON(data []byte) error {
	type alias Anchor
	var direct alias
	if err := json.Unmarshal(data, &direct); err == nil {
		*a = Anchor(direct)
	}

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	if a.Path == "" {
		a.Path = pickString(raw, "path", "srcPath", "file", "filePath")
		if a.Path == "" {
			if p := pickNestedString(raw, "path", "toString"); p != "" {
				a.Path = p
			}
		}
	}
	if a.Line == 0 {
		a.Line = pickInt(raw, "line", "lineNumber", "line_num", "fromLine", "toLine")
	}
	if a.LineType == "" {
		a.LineType = pickString(raw, "lineType")
	}
	if a.FileType == "" {
		a.FileType = pickString(raw, "fileType")
	}
	if a.DiffType == "" {
		a.DiffType = pickString(raw, "diffType")
	}

	return nil
}

func pickString(raw map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := raw[k]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

func pickNestedString(raw map[string]any, k1, k2 string) string {
	v, ok := raw[k1]
	if !ok {
		return ""
	}
	m, ok := v.(map[string]any)
	if !ok {
		return ""
	}
	s, _ := m[k2].(string)
	return s
}

func pickInt(raw map[string]any, keys ...string) int {
	for _, k := range keys {
		if v, ok := raw[k]; ok {
			switch n := v.(type) {
			case float64:
				if int(n) != 0 {
					return int(n)
				}
			case int:
				if n != 0 {
					return n
				}
			}
		}
	}
	return 0
}

type ActivityPage struct {
	Size          int        `json:"size"`
	Limit         int        `json:"limit"`
	IsLastPage    bool       `json:"isLastPage"`
	Start         int        `json:"start"`
	NextPageStart int        `json:"nextPageStart"`
	Values        []Activity `json:"values"`
}

type Properties struct {
	Reactions []Reaction `json:"reactions"`
}

type Activity struct {
	Action        string     `json:"action"`
	Anchor        *Anchor    `json:"anchor,omitempty"`
	CommentAnchor *Anchor    `json:"commentAnchor,omitempty"`
	CommentAction string     `json:"commentAction,omitempty"`
	Comment       *PRComment `json:"comment"`
	User          User       `json:"user"`
}

type reviewStatusUpdateRequest struct {
	Status string `json:"status"`
}

type taskStateUpdateRequest struct {
	State string `json:"state"`
}

type selfUser struct {
	Name string `json:"name"`
	Slug string `json:"slug"`
}

type PRCommentView struct {
	ID            int64           `json:"id"`
	ParentID      int64           `json:"parent_id,omitempty"`
	Depth         int             `json:"depth,omitempty"`
	Text          string          `json:"text"`
	Author        string          `json:"author"`
	CreatedDate   int64           `json:"created_date_ms"`
	CreatedAt     string          `json:"created_at"`
	UpdatedDate   int64           `json:"updated_date_ms"`
	UpdatedAt     string          `json:"updated_at"`
	IsFileComment bool            `json:"is_file_comment"`
	Path          string          `json:"path,omitempty"`
	Line          int             `json:"line,omitempty"`
	LineType      string          `json:"line_type,omitempty"`
	FileType      string          `json:"file_type,omitempty"`
	DiffType      string          `json:"diff_type,omitempty"`
	Reactions     map[string]int  `json:"reactions,omitempty"`
	MyReactions   map[string]bool `json:"my_reactions,omitempty"`
	IsTask        bool            `json:"is_task,omitempty"`
	TaskStatus    string          `json:"task_status,omitempty"`
	Version       int             `json:"version"`
}

type PullRequestComments struct {
	PRID             int64           `json:"pr_id"`
	FetchedAt        string          `json:"fetched_at"`
	OverviewComments []PRCommentView `json:"overview_comments"`
	FileComments     []PRCommentView `json:"file_comments"`
}

type FlatComment struct {
	Comment  PRComment
	ParentID int64
	Depth    int
}

type CommentParent struct {
	ID int64 `json:"id"`
}

type CreateCommentRequest struct {
	Text     string         `json:"text"`
	Severity string         `json:"severity,omitempty"`
	Parent   *CommentParent `json:"parent,omitempty"`
	Anchor   *Anchor        `json:"anchor,omitempty"`
}

type BranchRef struct {
	ID        string `json:"id"`
	DisplayID string `json:"displayId"`
}

type BranchPage struct {
	Values        []BranchRef `json:"values"`
	IsLastPage    bool        `json:"isLastPage"`
	NextPageStart int         `json:"nextPageStart"`
	Size          int         `json:"size"`
}

type CreatePullRequestRequest struct {
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
	FromRef     struct {
		ID string `json:"id"`
	} `json:"fromRef"`
	ToRef struct {
		ID string `json:"id"`
	} `json:"toRef"`
}

type MergePullRequestRequest struct {
	Version            int    `json:"version"`
	Message            string `json:"message,omitempty"`
	CommitMessage      string `json:"commitMessage,omitempty"`
	AutoSubject        bool   `json:"autoSubject"`
	AutoMerge          bool   `json:"autoMerge"`
	AutoMergeBranch    bool   `json:"autoMergeBranch"`
	StrategyID         string `json:"strategyId,omitempty"`
	TransitionToMerged bool   `json:"transitionToMerged"`
}

type PRCommit struct {
	ID         string `json:"id"`
	DisplayID  string `json:"displayId"`
	Message    string `json:"message"`
	Author     User   `json:"author"`
	AuthorTime int64  `json:"authorTimestamp"`
}

type PRCommitPage struct {
	Values        []PRCommit `json:"values"`
	IsLastPage    bool       `json:"isLastPage"`
	NextPageStart int        `json:"nextPageStart"`
}

type PullRequestMergeability struct {
	CanMerge bool `json:"canMerge"`
	Vetoes   []struct {
		Summary  string `json:"summaryMessage"`
		Detailed string `json:"detailedMessage"`
	} `json:"vetoes"`
}

func main() {
	reviewersEnabled := flag.Bool("reviewers", false, "enable reviewer-derived columns (NW/APPR)")
	jsonEnabled := flag.Bool("json", false, "print pull requests as JSON")
	prCommentsID := flag.Int64("pr-comments", 0, "print PR comments (overview + file comments) as JSON for the given PR id")
	prCommentID := flag.Int64("pr-comment", 0, "create PR comment/task for the given PR id")
	prDeleteCommentID := flag.Int64("pr-delete-comment", 0, "delete PR comment by id for the given PR id")
	prReviewID := flag.Int64("pr-review", 0, "set your review state for the given PR id")
	reviewAction := flag.String("review-action", "", "review action: approve|disapprove|needs-work")
	prTaskStatusID := flag.Int64("pr-task-status", 0, "change state of PR task/comment by id for the given PR id")
	prReactionID := flag.Int64("pr-reaction", 0, "set reaction on PR comment for the given PR id")
	prCreate := flag.Bool("pr-create", false, "create pull request")
	prMergeID := flag.Int64("pr-merge", 0, "merge pull request by id")
	prCommitsID := flag.Int64("pr-commits", 0, "print pull request commits as JSON for the given PR id")
	targetBranches := flag.Bool("target-branches", false, "list target branches for PR creation")
	prTitle := flag.String("pr-title", "", "pull request title for -pr-create")
	prBody := flag.String("pr-body", "", "pull request description for -pr-create")
	prSource := flag.String("pr-source", "", "source branch for -pr-create, e.g. feature/my-branch")
	prTarget := flag.String("pr-target", "", "target branch for -pr-create, e.g. main")
	mergeTitle := flag.String("merge-title", "", "merge commit title for -pr-merge")
	mergeBody := flag.String("merge-body", "", "merge commit body for -pr-merge")
	reactionCommentID := flag.Int64("comment-id", 0, "comment id for -pr-reaction")
	reactionShortcut := flag.String("reaction", "", "reaction shortcut for -pr-reaction (e.g. THUMBS_UP, HEART)")
	reactionAction := flag.String("reaction-action", "add", "reaction action: add|remove")
	deleteCommentID := flag.Int64("delete-comment-id", 0, "comment id for -pr-delete-comment")
	deleteCommentVersion := flag.Int("delete-comment-version", -1, "comment version for -pr-delete-comment (optimistic lock)")
	taskID := flag.Int64("task-id", 0, "task/comment id to update with -pr-task-status")
	taskState := flag.String("task-state", "", "task state: open|done")
	taskVersion := flag.Int("task-version", 0, "comment version for task update (optimistic lock)")
	commentText := flag.String("text", "", "comment/task text")
	commentTask := flag.Bool("task", false, "create task (BLOCKER severity)")
	replyTo := flag.Int64("reply-to", 0, "reply to existing comment id")
	commentPath := flag.String("path", "", "repo-relative path for file comment")
	commentLine := flag.Int("line", 0, "line number for file comment")
	commentLineType := flag.String("line-type", "CONTEXT", "line type: ADDED|REMOVED|CONTEXT")
	commentFileType := flag.String("file-type", "TO", "file side: TO|FROM")
	configPath := flag.String("config", "/etc/bb/config.json", "path to config")
	projectOverride := flag.String("project", "", "override project key (auto-detected from git remote when omitted)")
	repoOverride := flag.String("repo", "", "override repo slug (auto-detected from git remote when omitted)")
	forceAutodetectRepo := flag.Bool("force-autodetect-repo", false, "force auto-detection of project/repo from git remote (ignores config.project/config.repo unless -project/-repo are passed)")
	flag.Parse()

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		fatal(err)
	}
	cfg = applyRepoSelection(cfg, strings.TrimSpace(*projectOverride), strings.TrimSpace(*repoOverride), *forceAutodetectRepo)
	if err := validateRepoSelection(cfg); err != nil {
		fatal(err)
	}

	client, err := NewClient(cfg)
	if err != nil {
		fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.TimeoutDuration)
	defer cancel()

	if *prCommentID > 0 {
		text := strings.TrimSpace(*commentText)
		if text == "" {
			fatal(errors.New("-text is required with -pr-comment"))
		}

		req := CreateCommentRequest{Text: text}
		if *commentTask {
			req.Severity = "BLOCKER"
		}
		if *replyTo > 0 {
			req.Parent = &CommentParent{ID: *replyTo}
		}
		if strings.TrimSpace(*commentPath) != "" || *commentLine > 0 {
			req.Anchor = &Anchor{
				Path:     strings.TrimSpace(*commentPath),
				Line:     *commentLine,
				LineType: strings.ToUpper(strings.TrimSpace(*commentLineType)),
				FileType: strings.ToUpper(strings.TrimSpace(*commentFileType)),
				DiffType: "EFFECTIVE",
			}
		}

		created, err := client.CreatePullRequestComment(ctx, *prCommentID, req)
		if err != nil {
			fatal(err)
		}

		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(created); err != nil {
			fatal(err)
		}
		return
	}

	if *prDeleteCommentID > 0 {
		commentID := *deleteCommentID
		if commentID <= 0 {
			fatal(errors.New("-delete-comment-id is required with -pr-delete-comment"))
		}
		if *deleteCommentVersion < 0 {
			fatal(errors.New("-delete-comment-version is required with -pr-delete-comment"))
		}
		if err := client.DeletePullRequestComment(ctx, *prDeleteCommentID, commentID, *deleteCommentVersion); err != nil {
			fatal(err)
		}
		_, _ = fmt.Fprintf(os.Stdout, "{\"pr_id\":%d,\"comment_id\":%d,\"action\":\"delete\",\"ok\":true}\n", *prDeleteCommentID, commentID)
		return
	}

	if *targetBranches {
		branches, err := client.GetRepoBranches(ctx)
		if err != nil {
			fatal(err)
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(branches); err != nil {
			fatal(err)
		}
		return
	}

	if *prCreate {
		title := strings.TrimSpace(*prTitle)
		source := strings.TrimSpace(*prSource)
		target := strings.TrimSpace(*prTarget)
		if title == "" || source == "" || target == "" {
			fatal(errors.New("-pr-title, -pr-source and -pr-target are required with -pr-create"))
		}
		created, err := client.CreatePullRequest(ctx, title, strings.TrimSpace(*prBody), source, target)
		if err != nil {
			fatal(err)
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(created); err != nil {
			fatal(err)
		}
		return
	}
	if *prCommitsID > 0 {
		commits, err := client.GetPullRequestCommits(ctx, *prCommitsID)
		if err != nil {
			fatal(err)
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(commits); err != nil {
			fatal(err)
		}
		return
	}

	if *prMergeID > 0 {
		title := strings.TrimSpace(*mergeTitle)
		if title == "" {
			fatal(errors.New("-merge-title is required with -pr-merge"))
		}
		if err := client.MergePullRequest(ctx, *prMergeID, title, strings.TrimSpace(*mergeBody)); err != nil {
			fatal(err)
		}
		_, _ = fmt.Fprintf(os.Stdout, "{\"pr_id\":%d,\"action\":\"merge\",\"ok\":true}\n", *prMergeID)
		return
	}

	if *prReactionID > 0 {
		commentID := *reactionCommentID
		if commentID <= 0 {
			fatal(errors.New("-comment-id is required with -pr-reaction"))
		}
		shortcut := strings.TrimSpace(*reactionShortcut)
		if shortcut == "" {
			fatal(errors.New("-reaction is required with -pr-reaction"))
		}
		action := strings.ToLower(strings.TrimSpace(*reactionAction))
		if err := client.SetPullRequestCommentReaction(ctx, *prReactionID, commentID, shortcut, action); err != nil {
			fatal(err)
		}
		_, _ = fmt.Fprintf(os.Stdout, "{\"pr_id\":%d,\"comment_id\":%d,\"reaction\":%q,\"reaction_action\":%q,\"ok\":true}\n", *prReactionID, commentID, strings.ToUpper(shortcut), action)
		return
	}
	if *prTaskStatusID > 0 {
		id := *taskID
		if id <= 0 {
			fatal(errors.New("-task-id is required with -pr-task-status"))
		}
		state := strings.ToLower(strings.TrimSpace(*taskState))
		if state == "" {
			fatal(errors.New("-task-state is required with -pr-task-status"))
		}
		if err := client.SetPullRequestTaskState(ctx, *prTaskStatusID, id, state, *taskVersion); err != nil {
			fatal(err)
		}
		_, _ = fmt.Fprintf(os.Stdout, "{\"pr_id\":%d,\"task_id\":%d,\"task_state\":%q,\"ok\":true}\n", *prTaskStatusID, id, state)
		return
	}

	if *prReviewID > 0 {
		action := strings.ToLower(strings.TrimSpace(*reviewAction))
		if action == "" {
			fatal(errors.New("-review-action is required with -pr-review"))
		}
		if err := client.SetPullRequestReview(ctx, *prReviewID, action); err != nil {
			fatal(err)
		}
		_, _ = fmt.Fprintf(os.Stdout, "{\"pr_id\":%d,\"review_action\":%q,\"ok\":true}\n", *prReviewID, action)
		return
	}

	if *prCommentsID > 0 {
		comments, err := client.GetPullRequestComments(ctx, *prCommentsID)
		if err != nil {
			fatal(err)
		}

		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")

		if err := enc.Encode(comments); err != nil {
			fatal(err)
		}

		return
	}

	prs, err := client.GetRepoPullRequests(ctx)
	if err != nil {
		fatal(err)
	}

	sortPullRequests(prs, cfg)
	enrichPullRequests(prs, cfg)

	if cfg.JSONOutput || *jsonEnabled {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")

		if err := enc.Encode(prs); err != nil {
			fatal(err)
		}

		return
	}

	printTable(prs, cfg, *reviewersEnabled)
}

func applyRepoSelection(cfg RuntimeConfig, projectOverride, repoOverride string, forceAutodetect bool) RuntimeConfig {
	if projectOverride != "" {
		cfg.Project = projectOverride
	}
	if repoOverride != "" {
		cfg.Repo = repoOverride
	}
	if forceAutodetect {
		cfg.Project = ""
		cfg.Repo = ""
		if projectOverride != "" {
			cfg.Project = projectOverride
		}
		if repoOverride != "" {
			cfg.Repo = repoOverride
		}
	}
	if cfg.Project != "" && cfg.Repo != "" {
		return cfg
	}
	project, repo, err := detectProjectRepoFromGitRemote()
	if err != nil {
		return cfg
	}
	if cfg.Project == "" {
		cfg.Project = project
	}
	if cfg.Repo == "" {
		cfg.Repo = repo
	}
	return cfg
}

func validateRepoSelection(cfg RuntimeConfig) error {
	if strings.TrimSpace(cfg.Project) == "" {
		return errors.New("project is required: set config.project, pass -project, or run inside a git repo with a Bitbucket remote")
	}
	if strings.TrimSpace(cfg.Repo) == "" {
		return errors.New("repo is required: set config.repo, pass -repo, or run inside a git repo with a Bitbucket remote")
	}
	return nil
}

func detectProjectRepoFromGitRemote() (project, repo string, err error) {
	remote, err := gitRemoteURL()
	if err != nil {
		return "", "", err
	}
	project, repo = parseProjectRepoFromRemote(remote)
	if project == "" || repo == "" {
		return "", "", fmt.Errorf("cannot parse project/repo from git remote %q", remote)
	}
	return project, repo, nil
}

func gitRemoteURL() (string, error) {
	candidates := []string{"origin", "upstream"}
	for _, name := range candidates {
		out, err := exec.Command("git", "remote", "get-url", name).Output()
		if err != nil {
			continue
		}
		remote := strings.TrimSpace(string(out))
		if remote != "" {
			return remote, nil
		}
	}
	return "", errors.New("git remote origin/upstream not found")
}

func parseProjectRepoFromRemote(remote string) (string, string) {
	clean := strings.TrimSpace(remote)
	clean = strings.TrimSuffix(clean, ".git")
	clean = strings.ReplaceAll(clean, "\\", "/")
	re := regexp.MustCompile(`(?:/|:)(?:scm/)?([^/]+)/([^/]+)$`)
	match := re.FindStringSubmatch(clean)
	if len(match) != 3 {
		return "", ""
	}
	return strings.ToUpper(match[1]), match[2]
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
	cfg.CurrentUser = strings.TrimSpace(cfg.CurrentUser)
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

func (c *Client) GetPullRequestComments(ctx context.Context, prID int64) (*PullRequestComments, error) {
	var all []FlatComment
	var activities []Activity
	start := 0
	self, _ := c.getCurrentUser(ctx)

	for {
		page, err := c.fetchPullRequestActivityPage(ctx, prID, start)
		if err != nil {
			return nil, err
		}

		activities = append(activities, page.Values...)
		for _, activity := range page.Values {
			root := extractActivityComment(activity)
			if root != nil {
				if root.Anchor == nil {
					root.Anchor = root.CommentAnchor
				}
				if root.Anchor == nil {
					root.Anchor = activity.Anchor
				}
				if root.Anchor == nil {
					root.Anchor = activity.CommentAnchor
				}
				all = append(all, flattenCommentTree(*root, 0, 0)...)
			}
		}

		if page.IsLastPage {
			break
		}

		next := page.NextPageStart
		if next <= start {
			if page.Size > 0 {
				next = start + page.Size
			} else {
				return nil, fmt.Errorf("comment pagination stuck: pr=%d start=%d next=%d size=%d", prID, start, page.NextPageStart, page.Size)
			}
		}
		start = next
	}

	out := &PullRequestComments{PRID: prID, FetchedAt: time.Now().Format(time.RFC3339)}
	for _, item := range all {
		cmt := item.Comment
		anchor := cmt.Anchor
		if anchor == nil {
			anchor = cmt.CommentAnchor
		}

		commentReactions := extractReactionCounts(cmt.Properties.Reactions)
		myReactions := extractMyReactions(cmt.Properties.Reactions, self)

		view := PRCommentView{
			ID:          cmt.ID,
			ParentID:    item.ParentID,
			Depth:       item.Depth,
			Text:        cmt.Text,
			Author:      displayUser(cmt.Author),
			CreatedDate: cmt.CreatedDate,
			CreatedAt:   msToTime(cmt.CreatedDate).Format(time.RFC3339),
			UpdatedDate: cmt.UpdatedDate,
			UpdatedAt:   msToTime(cmt.UpdatedDate).Format(time.RFC3339),
			Reactions:   commentReactions,
			MyReactions: myReactions,
			Version:     cmt.Version,
		}
		severity := strings.ToUpper(strings.TrimSpace(cmt.Severity))
		if severity == "BLOCKER" {
			view.IsTask = true
			if strings.EqualFold(strings.TrimSpace(cmt.State), "RESOLVED") {
				view.TaskStatus = "DONE"
			} else {
				view.TaskStatus = "OPEN"
			}
		}

		if anchor != nil {
			view.IsFileComment = true
			view.Path = anchor.Path
			view.Line = anchor.Line
			view.LineType = anchor.LineType
			view.FileType = anchor.FileType
			view.DiffType = anchor.DiffType
			out.FileComments = append(out.FileComments, view)
			continue
		}

		out.OverviewComments = append(out.OverviewComments, view)
	}

	return out, nil
}

func extractReactionCounts(reactions []Reaction) map[string]int {
	result := map[string]int{}
	for _, reaction := range reactions {
		key := strings.ToUpper(strings.TrimSpace(reaction.Emoticon.Shortcut))
		if key == "" {
			continue
		}
		count := len(reaction.Users)
		result[key] += count
	}

	return result
}

func extractMyReactions(reactions []Reaction, self selfUser) map[string]bool {
	result := map[string]bool{}
	selfName := strings.TrimSpace(self.Name)
	selfSlug := strings.TrimSpace(self.Slug)
	for _, reaction := range reactions {
		key := strings.ToUpper(strings.TrimSpace(reaction.Emoticon.Shortcut))
		if key == "" {
			continue
		}
		for _, u := range reaction.Users {
			if (selfName != "" && strings.EqualFold(strings.TrimSpace(u.Name), selfName)) || (selfSlug != "" && strings.EqualFold(strings.TrimSpace(u.Slug), selfSlug)) {
				result[key] = true
				break
			}
		}
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

func mergeReactionCounts(dst map[string]int, src map[string]int) map[string]int {
	if dst == nil {
		dst = map[string]int{}
	}
	for k, v := range src {
		if v > 0 {
			dst[k] += v
		}
	}
	if len(dst) == 0 {
		return nil
	}
	return dst
}

func extractActivityReaction(activity Activity) (int64, string) {
	if activity.Comment == nil || activity.Comment.ID <= 0 {
		return 0, ""
	}
	reactions := extractReactionCounts(activity.Comment.Properties.Reactions)
	for key := range reactions {
		return activity.Comment.ID, key
	}
	return 0, ""
}

func flattenCommentTree(root PRComment, parentID int64, depth int) []FlatComment {
	out := []FlatComment{{Comment: root, ParentID: parentID, Depth: depth}}
	for _, child := range root.Comments {
		if child.Anchor == nil && child.CommentAnchor == nil {
			child.Anchor = root.Anchor
			child.CommentAnchor = root.CommentAnchor
		}
		out = append(out, flattenCommentTree(child, root.ID, depth+1)...)
	}
	return out
}

func extractActivityComment(activity Activity) *PRComment {
	if activity.Comment != nil {
		return activity.Comment
	}
	return nil
}

func (c *Client) CreatePullRequestComment(ctx context.Context, prID int64, payload CreateCommentRequest) (*PRComment, error) {
	u := *c.baseURL
	u.Path = joinURLPath(c.baseURL.Path, fmt.Sprintf(
		"/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/comments",
		url.PathEscape(c.cfg.Project),
		url.PathEscape(c.cfg.Repo),
		prID,
	))

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal create comment payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	c.setAuth(req)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("POST %s: %w", u.Redacted(), err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		rb, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
		return nil, fmt.Errorf("BitBucket returned %s: %s", resp.Status, strings.TrimSpace(string(rb)))
	}

	var out PRComment
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("decode Bitbucket create comment response: %w", err)
	}
	return &out, nil
}

func (c *Client) DeletePullRequestComment(ctx context.Context, prID int64, commentID int64, version int) error {
	u := *c.baseURL
	u.Path = joinURLPath(c.baseURL.Path, fmt.Sprintf(
		"/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/comments/%d",
		url.PathEscape(c.cfg.Project),
		url.PathEscape(c.cfg.Repo),
		prID,
		commentID,
	))
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, u.String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	q := req.URL.Query()
	q.Set("version", strconv.Itoa(version))
	req.URL.RawQuery = q.Encode()
	c.setAuth(req)
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("DELETE %s: %w", u.Redacted(), err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
		return fmt.Errorf("BitBucket returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	return nil
}

func (c *Client) fetchPullRequestActivityPage(ctx context.Context, prID int64, start int) (*ActivityPage, error) {
	u := *c.baseURL
	u.Path = joinURLPath(c.baseURL.Path, fmt.Sprintf(
		"/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/activities",
		url.PathEscape(c.cfg.Project),
		url.PathEscape(c.cfg.Repo),
		prID,
	))

	q := u.Query()
	q.Set("limit", fmt.Sprintf("%d", c.cfg.Limit))
	q.Set("start", fmt.Sprintf("%d", start))
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
			"BitBucket returned %s: %s",
			resp.Status,
			strings.TrimSpace(string(body)),
		)
	}

	var page ActivityPage
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
		return nil, fmt.Errorf("decode Bitbucket activities response: %w", err)
	}

	return &page, nil
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
			"BitBucket returned %s: %s",
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

func (c *Client) SetPullRequestCommentReaction(ctx context.Context, prID int64, commentID int64, shortcut, action string) error {
	shortcut = strings.ToLower(strings.TrimSpace(shortcut))
	if shortcut == "" {
		return errors.New("reaction shortcut is required")
	}
	if shortcut == "+1" {
		shortcut = "THUMBS_UP"
	}
	reactionPath := fmt.Sprintf("/rest/comment-likes/1.0/projects/%s/repos/%s/pull-requests/%d/comments/%d/reactions/%s",
		url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo), prID, commentID, url.PathEscape(shortcut))
	likesPath := fmt.Sprintf("/rest/comment-likes/1.0/projects/%s/repos/%s/pull-requests/%d/comments/%d/likes",
		url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo), prID, commentID)

	try := func(method, path string) error {
		_, err := c.doJSON(ctx, method, path, nil)
		return err
	}
	switch action {
	case "", "add":
		if err := try(http.MethodPut, reactionPath); err == nil {
			return nil
		}
		if shortcut == "THUMBS_UP" || shortcut == "LIKE" {
			return try(http.MethodPost, likesPath)
		}
		return try(http.MethodPut, reactionPath)
	case "remove", "delete":
		if err := try(http.MethodDelete, reactionPath); err == nil {
			return nil
		}
		if shortcut == "THUMBS_UP" || shortcut == "LIKE" {
			return try(http.MethodDelete, likesPath)
		}
		return try(http.MethodDelete, reactionPath)
	default:
		return fmt.Errorf("bad -reaction-action %q; expected add|remove", action)
	}
}

func (c *Client) GetRepoBranches(ctx context.Context) ([]BranchRef, error) {
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/branches?limit=1000", url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo))
	b, err := c.doJSON(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	var page BranchPage
	if err := json.Unmarshal(b, &page); err != nil {
		return nil, fmt.Errorf("decode branches response: %w", err)
	}
	return page.Values, nil
}

func (c *Client) CreatePullRequest(ctx context.Context, title, description, sourceBranch, targetBranch string) (*PullRequest, error) {
	var req CreatePullRequestRequest
	req.Title = title
	req.Description = description
	req.FromRef.ID = "refs/heads/" + strings.TrimPrefix(sourceBranch, "refs/heads/")
	req.ToRef.ID = "refs/heads/" + strings.TrimPrefix(targetBranch, "refs/heads/")
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests", url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo))
	b, err := c.doJSON(ctx, http.MethodPost, path, req)
	if err != nil {
		return nil, err
	}
	var out PullRequest
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, fmt.Errorf("decode create PR response: %w", err)
	}
	return &out, nil
}

func (c *Client) GetPullRequestCommits(ctx context.Context, prID int64) ([]PRCommit, error) {
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/commits?limit=1000", url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo), prID)
	b, err := c.doJSON(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	var page PRCommitPage
	if err := json.Unmarshal(b, &page); err != nil {
		return nil, fmt.Errorf("decode PR commits response: %w", err)
	}
	return page.Values, nil
}

func (c *Client) GetPullRequest(ctx context.Context, prID int64) (*PullRequest, error) {
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests/%d", url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo), prID)
	b, err := c.doJSON(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	var out PullRequest
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, fmt.Errorf("decode PR response: %w", err)
	}
	return &out, nil
}

func (c *Client) MergePullRequest(ctx context.Context, prID int64, title, body string) error {
	mergeability, err := c.GetPullRequestMergeability(ctx, prID)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "401") || strings.Contains(strings.ToLower(err.Error()), "not permitted") {
			return fmt.Errorf("merge precheck failed: no permission to merge this PR in Bitbucket (need REPO_WRITE and merge rights): %w", err)
		}
		return err
	}
	if !mergeability.CanMerge {
		var reasons []string
		for _, veto := range mergeability.Vetoes {
			msg := strings.TrimSpace(veto.Summary)
			if msg == "" {
				msg = strings.TrimSpace(veto.Detailed)
			}
			if msg != "" {
				reasons = append(reasons, msg)
			}
		}
		if len(reasons) == 0 {
			return errors.New("pull request is not mergeable according to Bitbucket checks")
		}
		return fmt.Errorf("pull request is not mergeable: %s", strings.Join(reasons, "; "))
	}

	pr, err := c.GetPullRequest(ctx, prID)
	if err != nil {
		return err
	}
	message := strings.TrimSpace(title)
	body = strings.TrimSpace(body)
	if body != "" {
		message += "\n\n" + body
	}
	req := MergePullRequestRequest{
		Version:            pr.Version,
		Message:            message,
		CommitMessage:      message,
		AutoSubject:        false,
		AutoMerge:          false,
		AutoMergeBranch:    false,
		TransitionToMerged: true,
	}
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/merge", url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo), prID)
	_, err = c.doJSON(ctx, http.MethodPost, path, req)
	if err != nil && (strings.Contains(strings.ToLower(err.Error()), "401") || strings.Contains(strings.ToLower(err.Error()), "not permitted")) {
		return fmt.Errorf("merge denied by Bitbucket permissions (need REPO_WRITE + merge rights for target branch): %w", err)
	}
	return err
}

func (c *Client) GetPullRequestMergeability(ctx context.Context, prID int64) (*PullRequestMergeability, error) {
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/merge", url.PathEscape(c.cfg.Project), url.PathEscape(c.cfg.Repo), prID)
	b, err := c.doJSON(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	var out PullRequestMergeability
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, fmt.Errorf("decode mergeability response: %w", err)
	}
	return &out, nil
}

func (c *Client) SetPullRequestTaskState(ctx context.Context, prID int64, taskID int64, state string, version int) error {
	var normalized string
	switch strings.ToLower(strings.TrimSpace(state)) {
	case "open":
		normalized = "OPEN"
	case "done", "resolved":
		normalized = "RESOLVED"
	default:
		return fmt.Errorf("bad -task-state %q; expected open|done", state)
	}

	path := fmt.Sprintf("/rest/api/1.0/projects/%s/repos/%s/pull-requests/%d/comments/%d", c.cfg.Project, c.cfg.Repo, prID, taskID)
	body := struct {
		State   string `json:"state"`
		Version int    `json:"version"`
	}{State: normalized, Version: version}
	_, err := c.doJSON(ctx, http.MethodPut, path, body)
	return err
}

func (c *Client) SetPullRequestReview(ctx context.Context, prID int64, action string) error {
	switch action {
	case "approve":
		return c.approvePullRequest(ctx, prID)
	case "disapprove":
		return c.disapprovePullRequest(ctx, prID)
	case "needs-work":
		return c.setNeedsWork(ctx, prID)
	default:
		return fmt.Errorf("bad -review-action %q; expected approve|disapprove|needs-work", action)
	}
}

func (c *Client) approvePullRequest(ctx context.Context, prID int64) error {
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/approve", c.cfg.Project, c.cfg.Repo, prID)
	_, err := c.doJSON(ctx, http.MethodPost, path, nil)
	return err
}

func (c *Client) disapprovePullRequest(ctx context.Context, prID int64) error {
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/approve", c.cfg.Project, c.cfg.Repo, prID)
	_, err := c.doJSON(ctx, http.MethodDelete, path, nil)
	return err
}

func (c *Client) setNeedsWork(ctx context.Context, prID int64) error {
	user, err := c.getCurrentUser(ctx)
	if err != nil {
		return err
	}
	if user.Slug == "" {
		return errors.New("failed to detect current user slug for needs-work")
	}
	path := fmt.Sprintf("/rest/api/latest/projects/%s/repos/%s/pull-requests/%d/participants/%s", c.cfg.Project, c.cfg.Repo, prID, url.PathEscape(user.Slug))
	body := reviewStatusUpdateRequest{Status: "NEEDS_WORK"}
	_, err = c.doJSON(ctx, http.MethodPut, path, body)
	return err
}

func (c *Client) getCurrentUser(ctx context.Context) (selfUser, error) {
	var out selfUser

	// Bitbucket Server/Data Center instances may not support /users/~self.
	// Resolve current user via configured username when available.
	if strings.TrimSpace(c.cfg.User) != "" {
		path := "/rest/api/latest/users/" + url.PathEscape(strings.TrimSpace(c.cfg.User))
		b, err := c.doJSON(ctx, http.MethodGet, path, nil)
		if err != nil {
			return out, err
		}
		if err := json.Unmarshal(b, &out); err != nil {
			return out, fmt.Errorf("decode user %q: %w", c.cfg.User, err)
		}
		if out.Slug == "" {
			out.Slug = out.Name
		}
		return out, nil
	}

	return out, errors.New("cannot resolve current user: set config.user for needs-work action")
}

func (c *Client) doJSON(ctx context.Context, method, path string, payload any) ([]byte, error) {
	endpoint, err := c.baseURL.Parse(path)
	if err != nil {
		return nil, fmt.Errorf("parse endpoint %q: %w", path, err)
	}

	var body io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("encode request JSON: %w", err)
		}
		body = strings.NewReader(string(data))
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), body)
	if err != nil {
		return nil, fmt.Errorf("new request %s %s: %w", method, endpoint.String(), err)
	}
	c.setAuth(req)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Atlassian-Token", "no-check")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w", method, endpoint.String(), err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read %s response: %w", endpoint.String(), err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s %s: %s: %s", method, endpoint.String(), resp.Status, strings.TrimSpace(string(respBody)))
	}

	return respBody, nil
}

func printTable(prs []PullRequest, cfg RuntimeConfig, reviewersEnabled bool) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	_, _ = fmt.Fprintln(w, "AGE\tLCOM\tCMTS\tNW\tAPPR\tMINE\tAUTHOR\tTITLE")

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

		needsWork := needsWorkStatus(pr.Reviewers)
		approvals := countApprovals(pr.Reviewers)
		mine := myApprovalMarker(pr, cfg)

		_, _ = fmt.Fprintf(
			w,
			"%s\t%s\t%d\t%s\t%d\t%s\t%s\t%s\n",
			ageStr,
			lastCommentStr,
			pr.CommentCount,
			needsWork,
			approvals,
			mine,
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

func normalizeIdentity(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func userCandidates(cfg RuntimeConfig) []string {
	candidates := []string{}
	seen := map[string]struct{}{}
	for _, raw := range []string{cfg.CurrentUser, cfg.User} {
		norm := normalizeIdentity(raw)
		if norm == "" {
			continue
		}
		if _, ok := seen[norm]; ok {
			continue
		}
		seen[norm] = struct{}{}
		candidates = append(candidates, norm)
	}
	return candidates
}

func isCurrentUser(u User, candidates []string) bool {
	if len(candidates) == 0 {
		return false
	}
	targets := []string{normalizeIdentity(u.Slug), normalizeIdentity(u.Name), normalizeIdentity(u.DisplayName)}
	for _, c := range candidates {
		for _, t := range targets {
			if t != "" && c == t {
				return true
			}
		}
	}
	return false
}

func prSortBucket(pr PullRequest, candidates []string) int {
	if isCurrentUser(pr.Author.User, candidates) {
		return 4
	}
	for _, reviewer := range pr.Reviewers {
		if !isCurrentUser(reviewer.User, candidates) {
			continue
		}
		status := strings.ToUpper(strings.TrimSpace(reviewer.Status))
		if reviewer.Approved || status == "APPROVED" {
			return 3
		}
		if status == "NEEDS_WORK" {
			return 2
		}
	}
	return 1
}

func reviewStatusForCurrentUser(pr PullRequest, cfg RuntimeConfig) (status string, approved bool) {
	candidates := userCandidates(cfg)
	if len(candidates) == 0 {
		return "UNKNOWN", false
	}
	for _, reviewer := range pr.Reviewers {
		if !isCurrentUser(reviewer.User, candidates) {
			continue
		}
		st := strings.ToUpper(strings.TrimSpace(reviewer.Status))
		if reviewer.Approved || st == "APPROVED" {
			return "APPROVED", true
		}
		if st == "NEEDS_WORK" {
			return "NEEDS_WORK", false
		}
		if st == "UNAPPROVED" {
			return "UNAPPROVED", false
		}
		if st != "" {
			return st, false
		}
		return "PENDING", false
	}
	return "NOT_REVIEWER", false
}

func enrichPullRequests(prs []PullRequest, cfg RuntimeConfig) {
	for i := range prs {
		status, approved := reviewStatusForCurrentUser(prs[i], cfg)
		prs[i].MyReviewStatus = status
		prs[i].MyApproved = approved
	}
}

func myApprovalMarker(pr PullRequest, cfg RuntimeConfig) string {
	status, approved := reviewStatusForCurrentUser(pr, cfg)
	if approved {
		return "yes"
	}
	if status == "NOT_REVIEWER" || status == "UNKNOWN" {
		return "-"
	}
	return "no"
}

func sortPullRequests(prs []PullRequest, cfg RuntimeConfig) {
	candidates := userCandidates(cfg)
	sort.Slice(prs, func(i, j int) bool {
		bucketI := prSortBucket(prs[i], candidates)
		bucketJ := prSortBucket(prs[j], candidates)
		if bucketI != bucketJ {
			return bucketI < bucketJ
		}
		return prs[i].UpdatedDate > prs[j].UpdatedDate
	})
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
