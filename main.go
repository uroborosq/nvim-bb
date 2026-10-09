package main

import (
	"bytes"
	"cmp"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"text/tabwriter"
	"time"
	"unicode/utf8"
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

	Repos       map[string]string `json:"repos"`
	TerminalCmd []string          `json:"terminal_cmd"`

	JiraBaseURL  string `json:"jira_base_url"`
	JiraAuth     string `json:"jira_auth"` // bearer | basic | none
	JiraToken    string `json:"jira_token"`
	JiraUser     string `json:"jira_user"`
	JiraPassword string `json:"jira_password"`
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

// Page is one page of a Bitbucket paged collection.
type Page[T any] struct {
	Size          int  `json:"size"`
	Limit         int  `json:"limit"`
	IsLastPage    bool `json:"isLastPage"`
	Start         int  `json:"start"`
	NextPageStart int  `json:"nextPageStart"`
	Values        []T  `json:"values"`
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
	ClosedDate   int64  `json:"closedDate"`

	Author struct {
		User User `json:"user"`
	} `json:"author"`

	Reviewers      []Reviewer `json:"reviewers"`
	MyReviewStatus string     `json:"my_review_status,omitempty"`
	MyApproved     bool       `json:"my_approved,omitempty"`
	BuildStatus    string     `json:"build_status,omitempty"` // SUCCESSFUL | FAILED | INPROGRESS | NONE

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
	ID           string     `json:"id"`
	DisplayID    string     `json:"displayId"`
	LatestCommit string     `json:"latestCommit"`
	Repository   Repository `json:"repository"`
}

type BuildStatus struct {
	State       string `json:"state"` // SUCCESSFUL | FAILED | INPROGRESS | UNKNOWN | CANCELLED
	Key         string `json:"key"`
	Name        string `json:"name"`
	URL         string `json:"url"`
	Description string `json:"description"`
	DateAdded   int64  `json:"dateAdded"`
}

// BuildSummary is the aggregated build status of a PR's latest commit.
type BuildSummary struct {
	Commit  string         `json:"commit"`
	Summary string         `json:"summary"` // SUCCESSFUL | FAILED | INPROGRESS | NONE
	Counts  map[string]int `json:"counts"`
	Builds  []BuildStatus  `json:"builds"`
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

type PRComment struct {
	ID             int64       `json:"id"`
	Text           string      `json:"text"`
	CreatedDate    int64       `json:"createdDate"`
	UpdatedDate    int64       `json:"updatedDate"`
	Version        int         `json:"version"`
	Anchor         *Anchor     `json:"anchor,omitempty"`
	CommentAnchor  *Anchor     `json:"commentAnchor,omitempty"`
	Comments       []PRComment `json:"comments,omitempty"`
	Properties     Properties  `json:"properties,omitempty"`
	Severity       string      `json:"severity,omitempty"`
	State          string      `json:"state,omitempty"`
	ThreadResolved bool        `json:"threadResolved,omitempty"`
	ResolvedDate   int64       `json:"resolvedDate,omitempty"`
	Author         User        `json:"author"`
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
		// Every field is set, so none of the fallbacks below could apply (and
		// data is a valid object, so the raw decode could not fail either).
		if a.Path != "" && a.Line != 0 && a.LineType != "" && a.FileType != "" && a.DiffType != "" {
			return nil
		}
	}

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	if a.Path == "" {
		a.Path = cmp.Or(
			pickString(raw, "path", "srcPath", "file", "filePath"),
			pickNestedString(raw, "path", "toString"),
		)
	}
	if a.Line == 0 {
		a.Line = pickInt(raw, "line", "lineNumber", "line_num", "fromLine", "toLine")
	}
	a.LineType = cmp.Or(a.LineType, pickString(raw, "lineType"))
	a.FileType = cmp.Or(a.FileType, pickString(raw, "fileType"))
	a.DiffType = cmp.Or(a.DiffType, pickString(raw, "diffType"))

	return nil
}

func pickString(raw map[string]any, keys ...string) string {
	for _, k := range keys {
		if s, ok := raw[k].(string); ok && s != "" {
			return s
		}
	}
	return ""
}

func pickNestedString(raw map[string]any, k1, k2 string) string {
	m, _ := raw[k1].(map[string]any)
	s, _ := m[k2].(string)
	return s
}

func pickInt(raw map[string]any, keys ...string) int {
	for _, k := range keys {
		if n, ok := raw[k].(float64); ok && int(n) != 0 {
			return int(n)
		}
	}
	return 0
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
	State   string `json:"state"`
	Version int    `json:"version"`
}

type selfUser struct {
	Name string `json:"name"`
	Slug string `json:"slug"`
}

type PRCommentView struct {
	ID            int64               `json:"id"`
	ParentID      int64               `json:"parent_id,omitempty"`
	Depth         int                 `json:"depth,omitempty"`
	Text          string              `json:"text"`
	Author        string              `json:"author"`
	CreatedDate   int64               `json:"created_date_ms"`
	CreatedAt     string              `json:"created_at"`
	UpdatedDate   int64               `json:"updated_date_ms"`
	UpdatedAt     string              `json:"updated_at"`
	IsFileComment bool                `json:"is_file_comment"`
	Path          string              `json:"path,omitempty"`
	Line          int                 `json:"line,omitempty"`
	LineType      string              `json:"line_type,omitempty"`
	FileType      string              `json:"file_type,omitempty"`
	DiffType      string              `json:"diff_type,omitempty"`
	Reactions     map[string]int      `json:"reactions,omitempty"`
	MyReactions   map[string]bool     `json:"my_reactions,omitempty"`
	ReactionUsers map[string][]string `json:"reaction_users,omitempty"`
	IsTask        bool                `json:"is_task,omitempty"`
	TaskStatus    string              `json:"task_status,omitempty"`
	IsResolved    bool                `json:"is_resolved,omitempty"`
	IsOutdated    bool                `json:"is_outdated,omitempty"`
	Version       int                 `json:"version"`
}

type PullRequestComments struct {
	PRID             int64           `json:"pr_id"`
	FetchedAt        string          `json:"fetched_at"`
	OverviewComments []PRCommentView `json:"overview_comments"`
	FileComments     []PRCommentView `json:"file_comments"`
}

type FlatComment struct {
	Comment    PRComment
	ParentID   int64
	Depth      int
	IsOutdated bool
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

type PullRequestMergeability struct {
	CanMerge bool `json:"canMerge"`
	Vetoes   []struct {
		Summary  string `json:"summaryMessage"`
		Detailed string `json:"detailedMessage"`
	} `json:"vetoes"`
}

type JiraIssue struct {
	Key         string        `json:"key"`
	Summary     string        `json:"summary"`
	URL         string        `json:"url"`
	Description string        `json:"description"`
	Type        string        `json:"type"`
	Status      string        `json:"status"`
	Priority    string        `json:"priority"`
	Assignee    string        `json:"assignee"`
	Reporter    string        `json:"reporter"`
	FixVersions []string      `json:"fix_versions"`
	EpicLink    string        `json:"epic_link"`
	Comments    []JiraComment `json:"comments"`
}

type JiraComment struct {
	Author  string `json:"author"`
	Body    string `json:"body"`
	Created string `json:"created"`
}

// padRight pads s with spaces to the given display width, measured in runes so
// multi-byte names (e.g. Cyrillic) align correctly.
func padRight(s string, width int) string {
	return s + strings.Repeat(" ", max(0, width-utf8.RuneCountInString(s)))
}

// buildMarker renders an aggregated build state as a single short glyph.
func buildMarker(status string) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case "SUCCESSFUL":
		return "✓"
	case "FAILED":
		return "✗"
	case "INPROGRESS":
		return "●"
	case "NONE":
		return "○"
	default:
		return " "
	}
}

func runDashboardCommand(args []string) error {
	fs := flag.NewFlagSet("dashboard", flag.ContinueOnError)
	configPath := fs.String("config", defaultConfigPath(), "path to config")
	stateFilter := fs.String("state", "OPEN", "PR state: OPEN|MERGED|DECLINED|ALL")
	limitFlag := fs.Int("limit", 50, "max PRs to fetch")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		return err
	}

	client, err := NewClient(cfg)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.TimeoutDuration)
	defer cancel()

	path := fmt.Sprintf("/rest/api/latest/dashboard/pull-requests?role=REVIEWER&state=%s&limit=%d",
		url.QueryEscape(*stateFilter), *limitFlag)
	b, err := client.doJSON(ctx, http.MethodGet, path, nil)
	page, err := decodeJSON[Page[PullRequest]](b, err, "dashboard response")
	if err != nil {
		return fmt.Errorf("fetch dashboard PRs: %w", err)
	}
	if len(page.Values) == 0 {
		fmt.Fprintln(os.Stderr, "no reviewer PRs found")
		return nil
	}

	enrichPullRequests(page.Values, cfg)
	enrichPullRequestBuilds(ctx, client, page.Values)

	now := time.Now()

	headers := []string{"B", "AGE", "LCOM", "CMTS", "NW", "APPR", "MINE", "REPO", "AUTHOR", "TITLE"}
	type dashRow struct {
		url   string
		cells []string
	}
	rows := make([]dashRow, 0, len(page.Values))
	for _, pr := range page.Values {
		prURL := ""
		if len(pr.Links.Self) > 0 {
			prURL = pr.Links.Self[0].Href
		}
		repo := pr.ToRef.Repository
		cells := []string{buildMarker(pr.BuildStatus)}
		cells = append(cells, prStatusCells(pr, now)...)
		cells = append(cells, repo.Project.Key+"/"+repo.Slug, displayUser(pr.Author.User), sanitizeCell(pr.Title))
		rows = append(rows, dashRow{url: prURL, cells: cells})
	}

	// column widths (rune-aware); the last column (TITLE) is never padded
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = utf8.RuneCountInString(h)
	}
	for _, r := range rows {
		for i, c := range r.cells {
			widths[i] = max(widths[i], utf8.RuneCountInString(c))
		}
	}

	formatCells := func(cells []string) string {
		parts := make([]string, len(cells))
		for i, c := range cells {
			if i == len(cells)-1 {
				parts[i] = c
			} else {
				parts[i] = padRight(c, widths[i])
			}
		}
		return strings.Join(parts, "  ")
	}

	var sb strings.Builder
	// header line (url field is empty so fzf skips it with --with-nth=2..)
	sb.WriteString("\t" + formatCells(headers) + "\n")
	for _, r := range rows {
		sb.WriteString(r.url + "\t" + formatCells(r.cells) + "\n")
	}

	fzf := exec.Command("fzf",
		"--ansi",
		"--with-nth=2..",
		"--delimiter=\t",
		"--header-lines=1",
		"--prompt=Reviewer PRs> ",
		"--height=60%",
		"--reverse",
	)
	fzf.Stdin = strings.NewReader(sb.String())
	fzf.Stderr = os.Stderr
	out, err := fzf.Output()
	if err != nil {
		// fzf exits 130 on ESC/q — not an error worth reporting
		return nil
	}

	selected := strings.TrimSpace(string(out))
	if selected == "" {
		return nil
	}
	prURL, _, _ := strings.Cut(selected, "\t")
	prURL = strings.TrimSpace(prURL)
	if prURL == "" {
		return fmt.Errorf("could not extract PR URL from selection")
	}
	return openPRURL(cfg, prURL)
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "open" {
		if err := runOpenCommand(os.Args[2:]); err != nil {
			fatal(err)
		}
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "dashboard" {
		if err := runDashboardCommand(os.Args[2:]); err != nil {
			fatal(err)
		}
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "stats" {
		if err := runStatsCommand(os.Args[2:]); err != nil {
			fatal(err)
		}
		return
	}

	// Reviewer columns are always shown; -reviewers is still accepted because
	// the Neovim plugin passes it.
	_ = flag.Bool("reviewers", false, "no-op, kept for compatibility (reviewer columns are always shown)")
	buildsEnabled := flag.Bool("builds", false, "enrich PR list with aggregated build status (Jenkins)")
	jsonEnabled := flag.Bool("json", false, "print pull requests as JSON")
	noDraft := flag.Bool("no-draft", false, "hide draft pull requests (title contains [DRAFT])")
	prCommentsID := flag.Int64("pr-comments", 0, "print PR comments (overview + file comments) as JSON for the given PR id")
	prCommentID := flag.Int64("pr-comment", 0, "create PR comment/task for the given PR id")
	prDeleteCommentID := flag.Int64("pr-delete-comment", 0, "delete PR comment by id for the given PR id")
	prUpdateCommentID := flag.Int64("pr-update-comment", 0, "update PR comment text by id for the given PR id")
	updateCommentID := flag.Int64("update-comment-id", 0, "comment id for -pr-update-comment")
	updateCommentVersion := flag.Int("update-comment-version", -1, "comment version for -pr-update-comment (optimistic lock)")
	prConvertCommentID := flag.Int64("pr-convert-comment", 0, "convert PR comment to task or back for the given PR id")
	convertCommentID := flag.Int64("convert-comment-id", 0, "comment id for -pr-convert-comment")
	convertCommentVersion := flag.Int("convert-comment-version", -1, "comment version for -pr-convert-comment (optimistic lock)")
	convertTo := flag.String("convert-to", "", "convert target: task|comment")
	prReviewID := flag.Int64("pr-review", 0, "set your review state for the given PR id")
	reviewAction := flag.String("review-action", "", "review action: approve|disapprove|needs-work")
	prTaskStatusID := flag.Int64("pr-task-status", 0, "change state of PR task/comment by id for the given PR id")
	prReactionID := flag.Int64("pr-reaction", 0, "set reaction on PR comment for the given PR id")
	prCreate := flag.Bool("pr-create", false, "create pull request")
	prUpdateID := flag.Int64("pr-update", 0, "update pull request title/description by id")
	prUpdateVersion := flag.Int("pr-update-version", -1, "current pull request version for -pr-update (optimistic lock)")
	prMergeID := flag.Int64("pr-merge", 0, "merge pull request by id")
	prCommitsID := flag.Int64("pr-commits", 0, "print pull request commits as JSON for the given PR id")
	prBuildsID := flag.Int64("pr-builds", 0, "print aggregated build status (Jenkins) as JSON for the given PR id")
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
	prResolveCommentID := flag.Int64("pr-resolve-comment", 0, "resolve or unresolve a comment thread for the given PR id")
	resolveCommentID := flag.Int64("resolve-comment-id", 0, "comment id for -pr-resolve-comment")
	resolveCommentVersion := flag.Int("resolve-comment-version", -1, "comment version for -pr-resolve-comment (optimistic lock)")
	resolveAction := flag.String("resolve-action", "resolve", "resolve action: resolve|unresolve")
	commentText := flag.String("text", "", "comment/task text")
	commentTask := flag.Bool("task", false, "create task (BLOCKER severity)")
	replyTo := flag.Int64("reply-to", 0, "reply to existing comment id")
	commentPath := flag.String("path", "", "repo-relative path for file comment")
	commentLine := flag.Int("line", 0, "line number for file comment")
	commentLineType := flag.String("line-type", "CONTEXT", "line type: ADDED|REMOVED|CONTEXT")
	commentFileType := flag.String("file-type", "TO", "file side: TO|FROM")
	jiraTicket := flag.String("jira-ticket", "", "fetch Jira issue by key and print as JSON")
	fetchURL := flag.String("fetch-url", "", "fetch URL with Bitbucket auth and write binary body to stdout")
	configPath := flag.String("config", defaultConfigPath(), "path to config")
	projectOverride := flag.String("project", "", "override project key (auto-detected from git remote when omitted)")
	repoOverride := flag.String("repo", "", "override repo slug (auto-detected from git remote when omitted)")
	forceAutodetectRepo := flag.Bool("force-autodetect-repo", false, "force auto-detection of project/repo from git remote (ignores config.project/config.repo unless -project/-repo are passed)")
	flag.Parse()

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		fatal(err)
	}
	cfg = applyRepoSelection(cfg, strings.TrimSpace(*projectOverride), strings.TrimSpace(*repoOverride), *forceAutodetectRepo)

	client, err := NewClient(cfg)
	if err != nil {
		fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.TimeoutDuration)
	defer cancel()

	if *fetchURL != "" {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSpace(*fetchURL), nil)
		if err != nil {
			fatal(err)
		}
		client.setAuth(req)
		resp, err := client.httpClient.Do(req)
		if err != nil {
			fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 400 {
			b, _ := io.ReadAll(resp.Body)
			fatal(fmt.Errorf("fetch %s: %s: %s", *fetchURL, resp.Status, strings.TrimSpace(string(b))))
		}
		if _, err := io.Copy(os.Stdout, resp.Body); err != nil {
			fatal(err)
		}
		return
	}

	if err := validateRepoSelection(cfg); err != nil {
		fatal(err)
	}

	if *jiraTicket != "" {
		printJSON(GetJiraIssue(ctx, cfg, strings.TrimSpace(*jiraTicket)))
		return
	}

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

		printJSON(client.CreatePullRequestComment(ctx, *prCommentID, req))
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

	if *prUpdateCommentID > 0 {
		commentID := *updateCommentID
		if commentID <= 0 {
			fatal(errors.New("-update-comment-id is required with -pr-update-comment"))
		}
		if *updateCommentVersion < 0 {
			fatal(errors.New("-update-comment-version is required with -pr-update-comment"))
		}
		printJSON(client.UpdatePullRequestComment(ctx, *prUpdateCommentID, commentID, *updateCommentVersion, *commentText))
		return
	}

	if *prConvertCommentID > 0 {
		commentID := *convertCommentID
		if commentID <= 0 {
			fatal(errors.New("-convert-comment-id is required with -pr-convert-comment"))
		}
		if *convertCommentVersion < 0 {
			fatal(errors.New("-convert-comment-version is required with -pr-convert-comment"))
		}
		to := strings.TrimSpace(*convertTo)
		if to == "" {
			fatal(errors.New("-convert-to is required with -pr-convert-comment (task|comment)"))
		}
		printJSON(client.SetPullRequestCommentSeverity(ctx, *prConvertCommentID, commentID, *convertCommentVersion, to))
		return
	}

	if *targetBranches {
		printJSON(client.GetRepoBranches(ctx))
		return
	}

	if *prCreate {
		title := strings.TrimSpace(*prTitle)
		source := strings.TrimSpace(*prSource)
		target := strings.TrimSpace(*prTarget)
		if title == "" || source == "" || target == "" {
			fatal(errors.New("-pr-title, -pr-source and -pr-target are required with -pr-create"))
		}
		printJSON(client.CreatePullRequest(ctx, title, strings.TrimSpace(*prBody), source, target))
		return
	}

	if *prUpdateID > 0 {
		version := *prUpdateVersion
		if version < 0 {
			cur, err := client.GetPullRequest(ctx, *prUpdateID)
			if err != nil {
				fatal(err)
			}
			version = cur.Version
		}
		printJSON(client.UpdatePullRequest(ctx, *prUpdateID, version, strings.TrimSpace(*prTitle), strings.TrimSpace(*prBody)))
		return
	}

	if *prCommitsID > 0 {
		printJSON(client.GetPullRequestCommits(ctx, *prCommitsID))
		return
	}

	if *prBuildsID > 0 {
		printJSON(client.GetPullRequestBuildSummary(ctx, *prBuildsID))
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

	if *prResolveCommentID > 0 {
		commentID := *resolveCommentID
		if commentID <= 0 {
			fatal(errors.New("-resolve-comment-id is required with -pr-resolve-comment"))
		}
		if *resolveCommentVersion < 0 {
			fatal(errors.New("-resolve-comment-version is required with -pr-resolve-comment"))
		}
		action := cmp.Or(strings.ToLower(strings.TrimSpace(*resolveAction)), "resolve")
		if err := client.ResolveComment(ctx, *prResolveCommentID, commentID, *resolveCommentVersion, action); err != nil {
			fatal(err)
		}
		_, _ = fmt.Fprintf(os.Stdout, "{\"pr_id\":%d,\"comment_id\":%d,\"resolve_action\":%q,\"ok\":true}\n", *prResolveCommentID, commentID, action)
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
		printJSON(client.GetPullRequestComments(ctx, *prCommentsID))
		return
	}

	prs, err := client.GetRepoPullRequests(ctx)
	if err != nil {
		fatal(err)
	}

	if *noDraft {
		prs = slices.DeleteFunc(prs, isDraftPR)
	}

	enrichPullRequests(prs, cfg)
	if *buildsEnabled {
		enrichPullRequestBuilds(ctx, client, prs)
	}

	if cfg.JSONOutput || *jsonEnabled {
		// Keep the bucket-based ordering for JSON consumers: the Neovim plugin's
		// PR picker and selection rely on this order.
		sortPullRequests(prs, cfg)
		printJSON(prs, nil)
		return
	}

	// Plain `bb` table: list every PR ordered purely by how long it has been
	// open ("hanging time", longest first), independent of author/review buckets.
	sortPullRequestsByOpenAge(prs)
	printTable(prs)
}

var (
	prURLPathRe = regexp.MustCompile(`/projects/([^/]+)/repos/([^/]+)/pull-requests/(\d+)`)
	gitRemoteRe = regexp.MustCompile(`(?:/|:)(?:scm/)?([^/]+)/([^/]+)$`)
)

type openTarget struct {
	Project   string
	Repo      string
	PRID      int64
	CommentID int64
}

func runOpenCommand(args []string) error {
	fs := flag.NewFlagSet("open", flag.ContinueOnError)
	configPath := fs.String("config", defaultConfigPath(), "path to config")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) < 1 {
		return errors.New("usage: bb open <url> [-config path]")
	}
	cfg, err := LoadConfig(*configPath)
	if err != nil {
		return err
	}
	return openPRURL(cfg, rest[0])
}

// openPRURL opens the PR behind a Bitbucket URL in the nvim instance already
// running in the repo's folder, or in a new terminal when there is none.
func openPRURL(cfg RuntimeConfig, rawURL string) error {
	target, err := parseBitbucketPRURL(rawURL)
	if err != nil {
		return err
	}

	folder, err := lookupRepoFolder(cfg.Repos, target.Project, target.Repo)
	if err != nil {
		return err
	}

	gitCheck := exec.Command("git", "diff", "--quiet", "HEAD")
	gitCheck.Dir = folder
	if err := gitCheck.Run(); err != nil {
		return fmt.Errorf("cannot open PR: repo %s has staged or uncommitted changes (stash or commit them first)", folder)
	}

	luaCode := fmt.Sprintf(`require("bb_pr").open_pr(%d, %s)`, target.PRID, luaOpenOpts(target.CommentID))

	sock := findNvimSocketForFolder(folder)
	if sock != "" {
		expr := fmt.Sprintf("luaeval(%s)", vimSingleQuote(luaCode))
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, "nvim", "--server", sock, "--remote-expr", expr).CombinedOutput()
		if err != nil {
			return fmt.Errorf("send to nvim %s: %w (%s)", sock, err, strings.TrimSpace(string(out)))
		}
		fmt.Fprintf(os.Stderr, "bb: opened PR #%d in nvim at %s\n", target.PRID, folder)
		return nil
	}

	if len(cfg.TerminalCmd) == 0 {
		return fmt.Errorf("no nvim instance found for %s and terminal_cmd is not set in config", folder)
	}
	termArgs := append(append([]string{}, cfg.TerminalCmd[1:]...), "nvim", "+lua "+luaCode)
	cmd := exec.Command(cfg.TerminalCmd[0], termArgs...)
	cmd.Dir = folder
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("launch terminal: %w", err)
	}
	fmt.Fprintf(os.Stderr, "bb: opening PR #%d in new terminal at %s\n", target.PRID, folder)
	return nil
}

func parseBitbucketPRURL(raw string) (*openTarget, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return nil, fmt.Errorf("parse url: %w", err)
	}
	m := prURLPathRe.FindStringSubmatch(u.Path)
	if m == nil {
		return nil, fmt.Errorf("not a Bitbucket PR URL: %s", raw)
	}
	prID, err := strconv.ParseInt(m[3], 10, 64)
	if err != nil {
		return nil, fmt.Errorf("parse pr id %q: %w", m[3], err)
	}
	out := &openTarget{
		Project: m[1],
		Repo:    m[2],
		PRID:    prID,
	}
	if c := u.Query().Get("commentId"); c != "" {
		if id, err := strconv.ParseInt(c, 10, 64); err == nil {
			out.CommentID = id
		}
	}
	return out, nil
}

func lookupRepoFolder(repos map[string]string, project, repo string) (string, error) {
	if len(repos) == 0 {
		return "", fmt.Errorf("config.repos is empty; add %q -> /path/to/folder", project+"/"+repo)
	}
	want := project + "/" + repo
	for k, v := range repos {
		if strings.EqualFold(k, want) {
			return expandHome(strings.TrimSpace(v)), nil
		}
	}
	return "", fmt.Errorf("no folder mapping for %s in config.repos", want)
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") || p == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			if p == "~" {
				return home
			}
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

func luaOpenOpts(commentID int64) string {
	if commentID > 0 {
		return fmt.Sprintf("{comment_id=%d}", commentID)
	}
	return "{}"
}

func vimSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func findNvimSocketForFolder(folder string) string {
	target, err := filepath.EvalSymlinks(folder)
	if err != nil {
		target = folder
	}
	target = filepath.Clean(target)

	var roots []string
	if rd := strings.TrimSpace(os.Getenv("XDG_RUNTIME_DIR")); rd != "" {
		roots = append(roots, rd)
	}
	roots = append(roots, "/tmp")

	seen := map[string]bool{}
	var sockets []string
	for _, root := range roots {
		matches, _ := filepath.Glob(filepath.Join(root, "nvim.*"))
		for _, m := range matches {
			fi, err := os.Stat(m)
			if err != nil {
				continue
			}
			if fi.Mode()&os.ModeSocket != 0 {
				if !seen[m] {
					seen[m] = true
					sockets = append(sockets, m)
				}
				continue
			}
			if fi.IsDir() {
				entries, _ := os.ReadDir(m)
				for _, e := range entries {
					p := filepath.Join(m, e.Name())
					st, err := os.Stat(p)
					if err == nil && st.Mode()&os.ModeSocket != 0 && !seen[p] {
						seen[p] = true
						sockets = append(sockets, p)
					}
				}
			}
		}
	}

	// Probe all sockets at once (each probe may take up to its timeout) but
	// still prefer the first matching socket in discovery order.
	matches := make([]bool, len(sockets))
	var wg sync.WaitGroup
	for i, sock := range sockets {
		wg.Go(func() { matches[i] = nvimCwdIs(sock, target) })
	}
	wg.Wait()
	if i := slices.Index(matches, true); i >= 0 {
		return sockets[i]
	}
	return ""
}

// nvimCwdIs reports whether the nvim listening on sock has dir as its cwd.
func nvimCwdIs(sock, dir string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "nvim", "--server", sock, "--remote-expr", "getcwd()").Output()
	if err != nil {
		return false
	}
	cwd := strings.TrimSpace(string(out))
	if cwd == "" {
		return false
	}
	if resolved, err := filepath.EvalSymlinks(cwd); err == nil {
		cwd = resolved
	}
	return filepath.Clean(cwd) == dir
}

func applyRepoSelection(cfg RuntimeConfig, projectOverride, repoOverride string, forceAutodetect bool) RuntimeConfig {
	if forceAutodetect {
		cfg.Project, cfg.Repo = "", ""
	}
	cfg.Project = cmp.Or(projectOverride, cfg.Project)
	cfg.Repo = cmp.Or(repoOverride, cfg.Repo)
	if cfg.Project != "" && cfg.Repo != "" {
		return cfg
	}
	project, repo, err := detectProjectRepoFromGitRemote()
	if err != nil {
		return cfg
	}
	cfg.Project = cmp.Or(cfg.Project, project)
	cfg.Repo = cmp.Or(cfg.Repo, repo)
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
	for _, name := range []string{"origin", "upstream"} {
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
	match := gitRemoteRe.FindStringSubmatch(clean)
	if len(match) != 3 {
		return "", ""
	}
	return strings.ToUpper(match[1]), match[2]
}

func defaultConfigPath() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "/etc/bb/config.json"
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "bb", "config.json")
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
	cfg.Auth = cmp.Or(cfg.Auth, "none")
	cfg.State = cmp.Or(cfg.State, "OPEN")
	cfg.Limit = cmp.Or(cfg.Limit, 100)
	cfg.Timeout = cmp.Or(cfg.Timeout, "60s")
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

const (
	restAPIPrefix      = "/rest/api/latest"
	commentLikesPrefix = "/rest/comment-likes/1.0"
)

// projectRepoPath returns prefix + "/projects/{project}/repos/{repo}" with
// both keys path-escaped, followed by the formatted suffix.
func projectRepoPath(prefix, project, repo, format string, args ...any) string {
	return prefix + "/projects/" + url.PathEscape(project) + "/repos/" + url.PathEscape(repo) + fmt.Sprintf(format, args...)
}

// repoPath returns a REST API path under the configured project/repo.
func (c *Client) repoPath(format string, args ...any) string {
	return projectRepoPath(restAPIPrefix, c.cfg.Project, c.cfg.Repo, format, args...)
}

// likesPath returns a comment-likes plugin path under the configured project/repo.
func (c *Client) likesPath(format string, args ...any) string {
	return projectRepoPath(commentLikesPrefix, c.cfg.Project, c.cfg.Repo, format, args...)
}

// decodeJSON decodes a doJSON response body; it passes a request error through.
func decodeJSON[T any](b []byte, err error, what string) (*T, error) {
	if err != nil {
		return nil, err
	}
	var out T
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, fmt.Errorf("decode %s: %w", what, err)
	}
	return &out, nil
}

var errPaginationStuck = errors.New("pagination stuck")

// paginate GETs every page of the paged collection at path (query holds the
// fixed parameters; start is managed here) and calls visit for each value in
// order until visit returns false or the last page is reached. It fails with
// errPaginationStuck when the server reports no way to advance.
func paginate[T any](ctx context.Context, c *Client, path string, query url.Values, visit func(T) bool) error {
	start := 0
	for {
		query.Set("start", strconv.Itoa(start))
		b, err := c.doJSON(ctx, http.MethodGet, path+"?"+query.Encode(), nil)
		page, err := decodeJSON[Page[T]](b, err, path+" page")
		if err != nil {
			return err
		}
		for _, v := range page.Values {
			if !visit(v) {
				return nil
			}
		}
		if page.IsLastPage {
			return nil
		}
		next := page.NextPageStart
		if next <= start {
			if page.Size <= 0 {
				return fmt.Errorf("%w: %s start=%d nextPageStart=%d size=%d", errPaginationStuck, path, start, page.NextPageStart, page.Size)
			}
			next = start + page.Size
		}
		start = next
	}
}

// collectPages returns every value of a paged collection (see paginate).
func collectPages[T any](ctx context.Context, c *Client, path string, query url.Values) ([]T, error) {
	var all []T
	err := paginate(ctx, c, path, query, func(v T) bool {
		all = append(all, v)
		return true
	})
	return all, err
}

func (c *Client) GetRepoPullRequests(ctx context.Context) ([]PullRequest, error) {
	query := url.Values{
		"state": {c.cfg.State},
		"order": {"NEWEST"},
		"limit": {strconv.Itoa(c.cfg.Limit)},
	}
	if c.cfg.At != "" {
		query.Set("at", c.cfg.At)
	}
	all, err := collectPages[PullRequest](ctx, c, c.repoPath("/pull-requests"), query)
	if err != nil {
		return nil, err
	}
	return all, nil
}

func (c *Client) GetPullRequestComments(ctx context.Context, prID int64) (*PullRequestComments, error) {
	// Resolve the current user (for my_reactions) while the activities page in.
	// Buffered so the goroutine never blocks if we return early on error.
	selfCh := make(chan selfUser, 1)
	go func() {
		self, _ := c.getCurrentUser(ctx)
		selfCh <- self
	}()

	// The same comment can appear in several activities (COMMENTED, RESOLVED,
	// UNRESOLVED). Keep one entry per id, in first-seen order, holding the most
	// recently updated copy so threadResolved reflects the current state.
	var all []FlatComment
	indexByID := map[int64]int{}
	query := url.Values{"limit": {strconv.Itoa(c.cfg.Limit)}}
	err := paginate(ctx, c, c.repoPath("/pull-requests/%d/activities", prID), query, func(activity Activity) bool {
		root := activity.Comment
		if root == nil {
			return true
		}
		root.Anchor = cmp.Or(root.Anchor, root.CommentAnchor, activity.Anchor, activity.CommentAnchor)
		outdated := root.Anchor != nil && root.Anchor.DiffType != "" && root.Anchor.DiffType != "EFFECTIVE"
		for _, item := range flattenCommentTree(*root, 0, 0) {
			item.IsOutdated = outdated
			cid := item.Comment.ID
			if cid <= 0 {
				all = append(all, item)
				continue
			}
			if idx, ok := indexByID[cid]; ok {
				if item.Comment.UpdatedDate > all[idx].Comment.UpdatedDate {
					all[idx] = item
				}
				continue
			}
			indexByID[cid] = len(all)
			all = append(all, item)
		}
		return true
	})
	if err != nil {
		return nil, err
	}
	self := <-selfCh

	out := &PullRequestComments{PRID: prID, FetchedAt: time.Now().Format(time.RFC3339)}
	for _, item := range all {
		cmt := item.Comment
		reactions, reactionUsers, myReactions := summarizeReactions(cmt.Properties.Reactions, self)

		view := PRCommentView{
			ID:            cmt.ID,
			ParentID:      item.ParentID,
			Depth:         item.Depth,
			Text:          cmt.Text,
			Author:        displayUser(cmt.Author),
			CreatedDate:   cmt.CreatedDate,
			CreatedAt:     msToTime(cmt.CreatedDate).Format(time.RFC3339),
			UpdatedDate:   cmt.UpdatedDate,
			UpdatedAt:     msToTime(cmt.UpdatedDate).Format(time.RFC3339),
			Reactions:     reactions,
			MyReactions:   myReactions,
			ReactionUsers: reactionUsers,
			IsResolved:    cmt.ThreadResolved,
			IsOutdated:    item.IsOutdated,
			Version:       cmt.Version,
		}
		if strings.ToUpper(strings.TrimSpace(cmt.Severity)) == "BLOCKER" {
			view.IsTask = true
			view.TaskStatus = "OPEN"
			if strings.EqualFold(strings.TrimSpace(cmt.State), "RESOLVED") {
				view.TaskStatus = "DONE"
			}
		}

		if anchor := cmp.Or(cmt.Anchor, cmt.CommentAnchor); anchor != nil {
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

// summarizeReactions groups reactions by upper-cased shortcut: the number of
// users per reaction, the de-duplicated display names that reacted, and which
// reactions are self's. The name and self maps are nil when empty.
func summarizeReactions(reactions []Reaction, self selfUser) (counts map[string]int, users map[string][]string, mine map[string]bool) {
	counts = map[string]int{}
	selfName := strings.TrimSpace(self.Name)
	selfSlug := strings.TrimSpace(self.Slug)
	for _, reaction := range reactions {
		key := strings.ToUpper(strings.TrimSpace(reaction.Emoticon.Shortcut))
		if key == "" {
			continue
		}
		counts[key] += len(reaction.Users)
		for _, u := range reaction.Users {
			if (selfName != "" && strings.EqualFold(strings.TrimSpace(u.Name), selfName)) ||
				(selfSlug != "" && strings.EqualFold(strings.TrimSpace(u.Slug), selfSlug)) {
				if mine == nil {
					mine = map[string]bool{}
				}
				mine[key] = true
			}
			if name := displayUser(u); name != "" && !slices.Contains(users[key], name) {
				if users == nil {
					users = map[string][]string{}
				}
				users[key] = append(users[key], name)
			}
		}
	}
	return counts, users, mine
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

func (c *Client) CreatePullRequestComment(ctx context.Context, prID int64, payload CreateCommentRequest) (*PRComment, error) {
	b, err := c.doJSON(ctx, http.MethodPost, c.repoPath("/pull-requests/%d/comments", prID), payload)
	return decodeJSON[PRComment](b, err, "create comment response")
}

func (c *Client) DeletePullRequestComment(ctx context.Context, prID int64, commentID int64, version int) error {
	_, err := c.doJSON(ctx, http.MethodDelete, c.repoPath("/pull-requests/%d/comments/%d?version=%d", prID, commentID, version), nil)
	return err
}

func (c *Client) setAuth(req *http.Request) {
	switch c.cfg.Auth {
	case "bearer":
		req.Header.Set("Authorization", "Bearer "+c.cfg.Token)
	case "basic":
		req.SetBasicAuth(c.cfg.User, cmp.Or(c.cfg.Password, c.cfg.Token))
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

	var method, likesMethod string
	switch action {
	case "", "add":
		method, likesMethod = http.MethodPut, http.MethodPost
	case "remove", "delete":
		method, likesMethod = http.MethodDelete, http.MethodDelete
	default:
		return fmt.Errorf("bad -reaction-action %q; expected add|remove", action)
	}

	_, err := c.doJSON(ctx, method, c.likesPath("/pull-requests/%d/comments/%d/reactions/%s", prID, commentID, url.PathEscape(shortcut)), nil)
	// Older servers only know likes; fall back for the thumbs-up shortcut.
	// (shortcut is lower-cased above, so only "+1" can reach THUMBS_UP here.)
	if err == nil || (shortcut != "THUMBS_UP" && shortcut != "LIKE") {
		return err
	}
	_, err = c.doJSON(ctx, likesMethod, c.likesPath("/pull-requests/%d/comments/%d/likes", prID, commentID), nil)
	return err
}

func (c *Client) GetRepoBranches(ctx context.Context) ([]BranchRef, error) {
	b, err := c.doJSON(ctx, http.MethodGet, c.repoPath("/branches?limit=1000"), nil)
	page, err := decodeJSON[Page[BranchRef]](b, err, "branches response")
	if err != nil {
		return nil, err
	}
	return page.Values, nil
}

func (c *Client) UpdatePullRequest(ctx context.Context, prID int64, version int, title, description string) (*PullRequest, error) {
	req := struct {
		Version     int    `json:"version"`
		Title       string `json:"title,omitempty"`
		Description string `json:"description"`
	}{Version: version, Title: title, Description: description}
	b, err := c.doJSON(ctx, http.MethodPut, c.repoPath("/pull-requests/%d", prID), req)
	return decodeJSON[PullRequest](b, err, "update PR response")
}

func (c *Client) CreatePullRequest(ctx context.Context, title, description, sourceBranch, targetBranch string) (*PullRequest, error) {
	var req CreatePullRequestRequest
	req.Title = title
	req.Description = description
	req.FromRef.ID = "refs/heads/" + strings.TrimPrefix(sourceBranch, "refs/heads/")
	req.ToRef.ID = "refs/heads/" + strings.TrimPrefix(targetBranch, "refs/heads/")
	b, err := c.doJSON(ctx, http.MethodPost, c.repoPath("/pull-requests"), req)
	return decodeJSON[PullRequest](b, err, "create PR response")
}

func (c *Client) GetPullRequestCommits(ctx context.Context, prID int64) ([]PRCommit, error) {
	b, err := c.doJSON(ctx, http.MethodGet, c.repoPath("/pull-requests/%d/commits?limit=1000", prID), nil)
	page, err := decodeJSON[Page[PRCommit]](b, err, "PR commits response")
	if err != nil {
		return nil, err
	}
	return page.Values, nil
}

func (c *Client) GetPullRequest(ctx context.Context, prID int64) (*PullRequest, error) {
	b, err := c.doJSON(ctx, http.MethodGet, c.repoPath("/pull-requests/%d", prID), nil)
	return decodeJSON[PullRequest](b, err, "PR response")
}

// GetCommitBuildStatuses returns the build statuses (e.g. Jenkins) attached to a
// commit via Bitbucket's build-status API.
func (c *Client) GetCommitBuildStatuses(ctx context.Context, commitID string) ([]BuildStatus, error) {
	b, err := c.doJSON(ctx, http.MethodGet, "/rest/build-status/1.0/commits/"+url.PathEscape(commitID), nil)
	page, err := decodeJSON[Page[BuildStatus]](b, err, "build statuses")
	if err != nil {
		return nil, err
	}
	return page.Values, nil
}

// GetPullRequestBuildSummary fetches the latest commit of a PR and aggregates its
// build statuses into a single summary.
func (c *Client) GetPullRequestBuildSummary(ctx context.Context, prID int64) (*BuildSummary, error) {
	pr, err := c.GetPullRequest(ctx, prID)
	if err != nil {
		return nil, err
	}
	commit := strings.TrimSpace(pr.FromRef.LatestCommit)
	summary := &BuildSummary{
		Commit:  commit,
		Summary: "NONE",
		Counts:  map[string]int{},
		Builds:  []BuildStatus{},
	}
	if commit == "" {
		return summary, nil
	}

	builds, err := c.GetCommitBuildStatuses(ctx, commit)
	if err != nil {
		return nil, err
	}
	summary.Builds = builds
	summary.Summary = aggregateBuildState(builds)
	for _, b := range builds {
		summary.Counts[strings.ToUpper(strings.TrimSpace(b.State))]++
	}
	return summary, nil
}

// aggregateBuildState collapses multiple build statuses into one overall state:
// any FAILED wins, then any INPROGRESS, then SUCCESSFUL, else NONE.
func aggregateBuildState(builds []BuildStatus) string {
	if len(builds) == 0 {
		return "NONE"
	}
	var hasFailed, hasInProgress, hasSuccess bool
	for _, b := range builds {
		switch strings.ToUpper(strings.TrimSpace(b.State)) {
		case "FAILED":
			hasFailed = true
		case "INPROGRESS":
			hasInProgress = true
		case "SUCCESSFUL":
			hasSuccess = true
		}
	}
	switch {
	case hasFailed:
		return "FAILED"
	case hasInProgress:
		return "INPROGRESS"
	case hasSuccess:
		return "SUCCESSFUL"
	default:
		return "NONE"
	}
}

// isPermissionErr reports whether a Bitbucket error looks like missing rights.
func isPermissionErr(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "401") || strings.Contains(msg, "not permitted")
}

func (c *Client) MergePullRequest(ctx context.Context, prID int64, title, body string) error {
	var (
		mergeability *PullRequestMergeability
		pr           *PullRequest
		mergeErr     error
		prErr        error
		wg           sync.WaitGroup
	)
	wg.Go(func() { mergeability, mergeErr = c.GetPullRequestMergeability(ctx, prID) })
	wg.Go(func() { pr, prErr = c.GetPullRequest(ctx, prID) })
	wg.Wait()

	if mergeErr != nil {
		if isPermissionErr(mergeErr) {
			return fmt.Errorf("merge precheck failed: no permission to merge this PR in Bitbucket (need REPO_WRITE and merge rights): %w", mergeErr)
		}
		return mergeErr
	}
	if !mergeability.CanMerge {
		var reasons []string
		for _, veto := range mergeability.Vetoes {
			if msg := cmp.Or(strings.TrimSpace(veto.Summary), strings.TrimSpace(veto.Detailed)); msg != "" {
				reasons = append(reasons, msg)
			}
		}
		if len(reasons) == 0 {
			return errors.New("pull request is not mergeable according to Bitbucket checks")
		}
		return fmt.Errorf("pull request is not mergeable: %s", strings.Join(reasons, "; "))
	}
	if prErr != nil {
		return prErr
	}

	message := strings.TrimSpace(title)
	if body = strings.TrimSpace(body); body != "" {
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
	_, err := c.doJSON(ctx, http.MethodPost, c.repoPath("/pull-requests/%d/merge", prID), req)
	if err != nil && isPermissionErr(err) {
		return fmt.Errorf("merge denied by Bitbucket permissions (need REPO_WRITE + merge rights for target branch): %w", err)
	}
	return err
}

func (c *Client) GetPullRequestMergeability(ctx context.Context, prID int64) (*PullRequestMergeability, error) {
	b, err := c.doJSON(ctx, http.MethodGet, c.repoPath("/pull-requests/%d/merge", prID), nil)
	return decodeJSON[PullRequestMergeability](b, err, "mergeability response")
}

// putComment PUTs a partial comment update (body must carry the version).
func (c *Client) putComment(ctx context.Context, prID, commentID int64, body any) ([]byte, error) {
	return c.doJSON(ctx, http.MethodPut, c.repoPath("/pull-requests/%d/comments/%d", prID, commentID), body)
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
	_, err := c.putComment(ctx, prID, taskID, taskStateUpdateRequest{State: normalized, Version: version})
	return err
}

// SetPullRequestCommentSeverity converts a comment to a task and back by
// flipping its severity: BLOCKER marks it a task, NORMAL a plain comment.
func (c *Client) SetPullRequestCommentSeverity(ctx context.Context, prID int64, commentID int64, version int, target string) (*PRComment, error) {
	var severity string
	switch strings.ToLower(strings.TrimSpace(target)) {
	case "task", "blocker":
		severity = "BLOCKER"
	case "comment", "normal":
		severity = "NORMAL"
	default:
		return nil, fmt.Errorf("bad -convert-to %q; expected task|comment", target)
	}
	body := struct {
		Version  int    `json:"version"`
		Severity string `json:"severity"`
	}{Version: version, Severity: severity}
	b, err := c.putComment(ctx, prID, commentID, body)
	return decodeJSON[PRComment](b, err, "convert comment response")
}

func (c *Client) UpdatePullRequestComment(ctx context.Context, prID int64, commentID int64, version int, text string) (*PRComment, error) {
	body := struct {
		Version int    `json:"version"`
		Text    string `json:"text"`
	}{Version: version, Text: text}
	b, err := c.putComment(ctx, prID, commentID, body)
	return decodeJSON[PRComment](b, err, "update comment response")
}

func (c *Client) ResolveComment(ctx context.Context, prID int64, commentID int64, version int, action string) error {
	var threadResolved bool
	switch strings.ToLower(strings.TrimSpace(action)) {
	case "", "resolve":
		threadResolved = true
	case "unresolve", "reopen":
		threadResolved = false
	default:
		return fmt.Errorf("bad -resolve-action %q; expected resolve|unresolve", action)
	}
	body := struct {
		ThreadResolved bool `json:"threadResolved"`
		Version        int  `json:"version"`
	}{ThreadResolved: threadResolved, Version: version}
	_, err := c.putComment(ctx, prID, commentID, body)
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
	_, err := c.doJSON(ctx, http.MethodPost, c.repoPath("/pull-requests/%d/approve", prID), nil)
	return err
}

func (c *Client) disapprovePullRequest(ctx context.Context, prID int64) error {
	_, err := c.doJSON(ctx, http.MethodDelete, c.repoPath("/pull-requests/%d/approve", prID), nil)
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
	path := c.repoPath("/pull-requests/%d/participants/%s", prID, url.PathEscape(user.Slug))
	_, err = c.doJSON(ctx, http.MethodPut, path, reviewStatusUpdateRequest{Status: "NEEDS_WORK"})
	return err
}

func (c *Client) getCurrentUser(ctx context.Context) (selfUser, error) {
	var out selfUser

	// Bitbucket Server/Data Center instances may not support /users/~self.
	// Resolve current user via configured username when available.
	if strings.TrimSpace(c.cfg.User) != "" {
		path := restAPIPrefix + "/users/" + url.PathEscape(strings.TrimSpace(c.cfg.User))
		b, err := c.doJSON(ctx, http.MethodGet, path, nil)
		if err != nil {
			return out, err
		}
		if err := json.Unmarshal(b, &out); err != nil {
			return out, fmt.Errorf("decode user %q: %w", c.cfg.User, err)
		}
		out.Slug = cmp.Or(out.Slug, out.Name)
		return out, nil
	}

	return out, errors.New("cannot resolve current user: set config.user for needs-work action")
}

// doJSON sends a request to path (relative to base_url, keeping any path
// prefix base_url has) and returns the body of a 2xx response.
func (c *Client) doJSON(ctx context.Context, method, path string, payload any) ([]byte, error) {
	rel, err := url.Parse(path)
	if err != nil {
		return nil, fmt.Errorf("parse endpoint %q: %w", path, err)
	}
	endpoint := *c.baseURL
	endpoint.Path = joinURLPath(c.baseURL.Path, rel.Path)
	endpoint.RawPath = joinURLPath(c.baseURL.EscapedPath(), rel.EscapedPath())
	endpoint.RawQuery = rel.RawQuery
	endpoint.Fragment, endpoint.RawFragment = "", ""

	var body io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("encode request JSON: %w", err)
		}
		body = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), body)
	if err != nil {
		return nil, fmt.Errorf("new request %s %s: %w", method, endpoint.Redacted(), err)
	}
	c.setAuth(req)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Atlassian-Token", "no-check")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w", method, endpoint.Redacted(), err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read %s response: %w", endpoint.Redacted(), err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s %s: %s: %s", method, endpoint.Redacted(), resp.Status, strings.TrimSpace(string(respBody)))
	}

	return respBody, nil
}

// printTable writes the plain `bb` PR table. PRs must be enriched first
// (enrichPullRequests) so the MINE column is filled.
func printTable(prs []PullRequest) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	_, _ = fmt.Fprintln(w, "AGE\tLCOM\tCMTS\tNW\tAPPR\tMINE\tAUTHOR\tTITLE")

	now := time.Now()
	for _, pr := range prs {
		cells := append(prStatusCells(pr, now), displayUser(pr.Author.User), sanitizeCell(pr.Title))
		_, _ = fmt.Fprintln(w, strings.Join(cells, "\t"))
	}

	_ = w.Flush()
}

// prStatusCells returns the AGE, LCOM, CMTS, NW, APPR and MINE cells shared by
// the table and dashboard views.
func prStatusCells(pr PullRequest, now time.Time) []string {
	return []string{
		ageSince(pr.CreatedDate, now),
		ageSince(pr.UpdatedDate, now),
		strconv.Itoa(pr.CommentCount),
		needsWorkStatus(pr.Reviewers),
		strconv.Itoa(countApprovals(pr.Reviewers)),
		myApprovalMarker(pr),
	}
}

// ageSince renders the time elapsed since a Bitbucket millisecond timestamp,
// or "-" when it is unset.
func ageSince(ms int64, now time.Time) string {
	t := msToTime(ms)
	if t.IsZero() {
		return "-"
	}
	return humanAge(now.Sub(t))
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

	return time.UnixMilli(ms).Local()
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
	return cmp.Or(u.DisplayName, u.Name, u.Slug, u.EmailAddress)
}

func normalizeIdentity(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

// userCandidates returns the normalized, de-duplicated identities that denote
// the current user (config.current_user, then config.user).
func userCandidates(cfg RuntimeConfig) []string {
	var candidates []string
	for _, raw := range []string{cfg.CurrentUser, cfg.User} {
		if norm := normalizeIdentity(raw); norm != "" && !slices.Contains(candidates, norm) {
			candidates = append(candidates, norm)
		}
	}
	return candidates
}

func isCurrentUser(u User, candidates []string) bool {
	for _, t := range []string{normalizeIdentity(u.Slug), normalizeIdentity(u.Name), normalizeIdentity(u.DisplayName)} {
		if t != "" && slices.Contains(candidates, t) {
			return true
		}
	}
	return false
}

func isDraftPR(pr PullRequest) bool {
	return strings.Contains(pr.Title, "[DRAFT]")
}

// prSortBucket orders the JSON PR list: PRs to review, then ones I marked
// needs-work, then ones I approved, then drafts, then my own. It reads the
// fields set by enrichPullRequests.
func prSortBucket(pr PullRequest, candidates []string) int {
	switch {
	case isCurrentUser(pr.Author.User, candidates):
		return 5
	case isDraftPR(pr):
		return 4
	case pr.MyApproved:
		return 3
	case pr.MyReviewStatus == "NEEDS_WORK":
		return 2
	default:
		return 1
	}
}

func reviewStatusForCurrentUser(pr PullRequest, candidates []string) (status string, approved bool) {
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
		return cmp.Or(st, "PENDING"), false
	}
	return "NOT_REVIEWER", false
}

func enrichPullRequests(prs []PullRequest, cfg RuntimeConfig) {
	candidates := userCandidates(cfg)
	for i := range prs {
		prs[i].MyReviewStatus, prs[i].MyApproved = reviewStatusForCurrentUser(prs[i], candidates)
	}
}

// enrichPullRequestBuilds fills BuildStatus for each PR by fetching build
// statuses of its latest commit concurrently.
func enrichPullRequestBuilds(ctx context.Context, c *Client, prs []PullRequest) {
	const workers = 10
	jobs := make(chan int)
	var wg sync.WaitGroup

	for range workers {
		wg.Go(func() {
			for i := range jobs {
				commit := strings.TrimSpace(prs[i].FromRef.LatestCommit)
				if commit == "" {
					prs[i].BuildStatus = "NONE"
					continue
				}
				builds, err := c.GetCommitBuildStatuses(ctx, commit)
				if err != nil {
					prs[i].BuildStatus = ""
					continue
				}
				prs[i].BuildStatus = aggregateBuildState(builds)
			}
		})
	}

	for i := range prs {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
}

// myApprovalMarker renders the MINE column from the fields set by
// enrichPullRequests.
func myApprovalMarker(pr PullRequest) string {
	switch {
	case pr.MyApproved:
		return "yes"
	case pr.MyReviewStatus == "NOT_REVIEWER" || pr.MyReviewStatus == "UNKNOWN":
		return "-"
	default:
		return "no"
	}
}

// sortPullRequests orders PRs by prSortBucket, most recently updated first
// within a bucket. PRs must be enriched first (enrichPullRequests).
func sortPullRequests(prs []PullRequest, cfg RuntimeConfig) {
	candidates := userCandidates(cfg)
	slices.SortFunc(prs, func(a, b PullRequest) int {
		return cmp.Or(
			cmp.Compare(prSortBucket(a, candidates), prSortBucket(b, candidates)),
			cmp.Compare(b.UpdatedDate, a.UpdatedDate),
		)
	})
}

// sortPullRequestsByOpenAge orders PRs purely by how long they have been open
// ("hanging time"): the oldest CreatedDate (longest open) comes first, matching a
// descending AGE column. PRs with an unknown/zero CreatedDate sort last. Used only
// for the plain table output; JSON consumers keep sortPullRequests' ordering.
func sortPullRequestsByOpenAge(prs []PullRequest) {
	slices.SortStableFunc(prs, func(a, b PullRequest) int {
		ca, cb := a.CreatedDate, b.CreatedDate
		if (ca <= 0) != (cb <= 0) {
			if ca > 0 {
				return -1 // known dates before unknown ones
			}
			return 1
		}
		return cmp.Compare(ca, cb) // older (longer open) first
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

func GetJiraIssue(ctx context.Context, cfg RuntimeConfig, issueKey string) (*JiraIssue, error) {
	if cfg.JiraBaseURL == "" {
		return nil, errors.New("jira_base_url is not configured")
	}
	baseURL, err := url.Parse(strings.TrimRight(cfg.JiraBaseURL, "/"))
	if err != nil {
		return nil, fmt.Errorf("parse jira_base_url: %w", err)
	}

	tlsCfg := &tls.Config{InsecureSkipVerify: cfg.InsecureTLS} //nolint:gosec
	httpClient := &http.Client{
		Transport: &http.Transport{TLSClientConfig: tlsCfg},
	}

	doReq := func(path string) ([]byte, error) {
		endpoint, _ := baseURL.Parse(path)
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Accept", "application/json")
		switch cmp.Or(cfg.JiraAuth, cfg.Auth) {
		case "bearer":
			req.Header.Set("Authorization", "Bearer "+cmp.Or(cfg.JiraToken, cfg.Token))
		case "basic":
			req.SetBasicAuth(cmp.Or(cfg.JiraUser, cfg.User), cmp.Or(cfg.JiraPassword, cfg.Password))
		}
		resp, err := httpClient.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode >= 400 {
			return nil, fmt.Errorf("jira API %s: %s", resp.Status, strings.TrimSpace(string(b)))
		}
		return b, nil
	}

	const fields = "summary,description,comment,issuetype,status,priority,assignee,reporter,fixVersions,customfield_10014"
	b, err := doReq("/rest/api/2/issue/" + url.PathEscape(issueKey) + "?fields=" + fields)
	if err != nil {
		return nil, err
	}

	type namedField struct {
		Name        string `json:"name"`
		DisplayName string `json:"displayName"`
	}
	var raw struct {
		Key    string `json:"key"`
		Fields struct {
			Summary     string       `json:"summary"`
			Description string       `json:"description"`
			IssueType   namedField   `json:"issuetype"`
			Status      namedField   `json:"status"`
			Priority    namedField   `json:"priority"`
			Assignee    namedField   `json:"assignee"`
			Reporter    namedField   `json:"reporter"`
			FixVersions []namedField `json:"fixVersions"`
			EpicLink    string       `json:"customfield_10014"`
			Comment     struct {
				Comments []struct {
					Author  namedField `json:"author"`
					Body    string     `json:"body"`
					Created string     `json:"created"`
				} `json:"comments"`
			} `json:"comment"`
		} `json:"fields"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, fmt.Errorf("decode jira issue: %w", err)
	}

	issue := &JiraIssue{
		Key:         raw.Key,
		Summary:     raw.Fields.Summary,
		Description: raw.Fields.Description,
		URL:         strings.TrimRight(cfg.JiraBaseURL, "/") + "/browse/" + raw.Key,
		Type:        raw.Fields.IssueType.Name,
		Status:      raw.Fields.Status.Name,
		Priority:    raw.Fields.Priority.Name,
		Assignee:    raw.Fields.Assignee.DisplayName,
		Reporter:    raw.Fields.Reporter.DisplayName,
		EpicLink:    raw.Fields.EpicLink,
	}
	for _, v := range raw.Fields.FixVersions {
		issue.FixVersions = append(issue.FixVersions, v.Name)
	}
	for _, c := range raw.Fields.Comment.Comments {
		issue.Comments = append(issue.Comments, JiraComment{
			Author:  c.Author.DisplayName,
			Body:    c.Body,
			Created: c.Created,
		})
	}
	return issue, nil
}

// ── stats subcommand ─────────────────────────────────────────────────────────

const defaultIgnoredUsers = "bitbucket.system-user,Code Owners for Bitbucket,Code Owners for BitBucket,tb-service-acc-1,Bitbucket,AI Code Assistant"

type prStatEntry struct {
	pr   PullRequest
	repo string
}

type StatsResult struct {
	Summary             StatsSummary      `json:"summary"`
	UserComments        []UserCount       `json:"user_comments"`
	UserApprovals       []UserCount       `json:"user_approvals"`
	UserCommits         []UserCount       `json:"user_commits"`
	PROpenDuration      DistributionStats `json:"pr_open_duration"`
	OpenToFirstComment  DistributionStats `json:"open_to_first_comment"`
	FirstCommentToMerge DistributionStats `json:"first_comment_to_merge"`
	CommentDistribution DistributionStats `json:"comment_distribution"`
	TopLongestPRs       []LongestPR       `json:"top_longest_prs"`
	TopAuthorPRCount    []UserCount       `json:"top_author_pr_count"`
	TopAuthorDuration   []UserCount       `json:"top_author_duration"`
	TopAuthorLongRatio  []UserCount       `json:"top_author_long_ratio"`
	Warnings            []string          `json:"warnings,omitempty"`
}

type StatsSummary struct {
	Project    string   `json:"project"`
	Repos      []string `json:"repos"`
	TotalPRs   int      `json:"total_prs"`
	SinceDays  int      `json:"since_days"`
	SinceDate  string   `json:"since_date,omitempty"`
	AnalyzedAt string   `json:"analyzed_at"`
}

type UserCount struct {
	User  string `json:"user"`
	Count int    `json:"count"`
}

type HistogramBucket struct {
	Label string  `json:"label"`
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Count int     `json:"count"`
}

type DistributionStats struct {
	Count     int               `json:"count"`
	Mean      float64           `json:"mean"`
	Median    float64           `json:"median"`
	Min       float64           `json:"min"`
	Max       float64           `json:"max"`
	Std       float64           `json:"std"`
	P25       float64           `json:"p25"`
	P75       float64           `json:"p75"`
	P90       float64           `json:"p90"`
	P95       float64           `json:"p95"`
	Histogram []HistogramBucket `json:"histogram"`
}

type LongestPR struct {
	ID            int64   `json:"id"`
	Title         string  `json:"title"`
	Repo          string  `json:"repo"`
	Author        string  `json:"author"`
	DurationHours float64 `json:"duration_hours"`
}

func runStatsCommand(args []string) error {
	fs := flag.NewFlagSet("stats", flag.ContinueOnError)
	configPath := fs.String("config", defaultConfigPath(), "path to config")
	projectFlag := fs.String("project", "", "project key (defaults to config.project)")
	reposFlag := fs.String("repos", "", "comma-separated repo slugs (required)")
	sinceDays := fs.Int("since-days", 90, "days to look back (0 = all time)")
	stateFlag := fs.String("state", "MERGED", "PR state: OPEN|MERGED|DECLINED|ALL")
	concurrency := fs.Int("concurrency", 10, "max parallel activity requests")
	topN := fs.Int("top", 20, "number of longest PRs to include")
	ignoreUsersFlag := fs.String("ignore-users", defaultIgnoredUsers, "comma-separated display names to ignore")
	timeoutFlag := fs.String("timeout", "5m", "overall timeout")
	numBuckets := fs.Int("buckets", 8, "histogram bucket count")
	if err := fs.Parse(args); err != nil {
		return err
	}

	reposRaw := strings.TrimSpace(*reposFlag)
	if reposRaw == "" {
		return errors.New("-repos is required: comma-separated list of repo slugs")
	}
	repos := splitTrimmed(reposRaw, ",")

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		return err
	}

	project := cmp.Or(strings.TrimSpace(*projectFlag), cfg.Project)
	if project == "" {
		return errors.New("-project is required (or set config.project)")
	}

	dur, err := time.ParseDuration(*timeoutFlag)
	if err != nil {
		return fmt.Errorf("bad -timeout: %w", err)
	}
	cfg.TimeoutDuration = dur

	var cutoff time.Time
	if *sinceDays > 0 {
		cutoff = time.Now().UTC().Add(-time.Duration(*sinceDays) * 24 * time.Hour)
	}

	ignoredMap := map[string]bool{}
	for _, u := range splitTrimmed(*ignoreUsersFlag, ",") {
		ignoredMap[u] = true
	}

	client, err := NewClient(cfg)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.TimeoutDuration)
	defer cancel()

	// Stage 1: fetch PR lists and repo commits from all repos in parallel.
	type repoResult struct {
		repo string
		prs  []PullRequest
		err  error
	}
	type commitResult struct {
		repo    string
		commits []PRCommit
		err     error
	}
	repoCh := make(chan repoResult, len(repos))
	commitCh := make(chan commitResult, len(repos))
	for _, repo := range repos {
		go func() {
			prs, err := statsAllPRs(ctx, client, project, repo, *stateFlag, cutoff)
			repoCh <- repoResult{repo: repo, prs: prs, err: err}
		}()
		go func() {
			commits, err := statsRepoCommits(ctx, client, project, repo, cutoff)
			commitCh <- commitResult{repo: repo, commits: commits, err: err}
		}()
	}

	var allPRs []prStatEntry
	var allCommits []PRCommit
	var warnings []string
	for range repos {
		r := <-repoCh
		if r.err != nil {
			warnings = append(warnings, fmt.Sprintf("repo %s: fetch PRs: %v", r.repo, r.err))
			continue
		}
		for _, pr := range r.prs {
			allPRs = append(allPRs, prStatEntry{pr: pr, repo: r.repo})
		}
	}
	for range repos {
		r := <-commitCh
		if r.err != nil {
			warnings = append(warnings, fmt.Sprintf("repo %s: fetch commits: %v", r.repo, r.err))
			continue
		}
		allCommits = append(allCommits, r.commits...)
	}

	// Stage 2: fetch activities for every PR, bounded by semaphore.
	// activities[i] belongs to allPRs[i]; it stays nil when the fetch failed.
	sem := make(chan struct{}, *concurrency)
	activities := make([][]Activity, len(allPRs))
	var wg sync.WaitGroup
	var mu sync.Mutex

	for i, pe := range allPRs {
		wg.Go(func() {
			sem <- struct{}{}
			defer func() { <-sem }()

			acts, err := statsAllActivities(ctx, client, project, pe.repo, pe.pr.ID)
			if err != nil {
				mu.Lock()
				warnings = append(warnings, fmt.Sprintf("PR #%d in %s: %v", pe.pr.ID, pe.repo, err))
				mu.Unlock()
				return
			}
			activities[i] = acts
		})
	}
	wg.Wait()

	result := computePRStats(allPRs, activities, ignoredMap, project, repos, *sinceDays, cutoff, *topN, *numBuckets)

	commitCounts := map[string]int{}
	for _, c := range allCommits {
		author := cmp.Or(c.Author.Name, c.Author.DisplayName)
		if author == "" || ignoredMap[author] {
			continue
		}
		commitCounts[author]++
	}
	result.UserCommits = sortedUserCounts(commitCounts)
	result.Warnings = warnings

	printJSON(result, nil)
	return nil
}

// statsCollect gathers a paged collection, stopping at the first value keep
// rejects. Stuck pagination just ends the collection.
func statsCollect[T any](ctx context.Context, c *Client, path string, query url.Values, keep func(T) bool) ([]T, error) {
	var all []T
	err := paginate(ctx, c, path, query, func(v T) bool {
		if !keep(v) {
			return false
		}
		all = append(all, v)
		return true
	})
	if err != nil && !errors.Is(err, errPaginationStuck) {
		return nil, err
	}
	return all, nil
}

// statsAllPRs returns the repo's PRs, newest first, down to the cutoff.
func statsAllPRs(ctx context.Context, c *Client, project, repo, state string, cutoff time.Time) ([]PullRequest, error) {
	cutoffMs := cutoff.UnixMilli()
	query := url.Values{"state": {state}, "order": {"NEWEST"}, "limit": {"100"}}
	return statsCollect(ctx, c, projectRepoPath(restAPIPrefix, project, repo, "/pull-requests"), query, func(pr PullRequest) bool {
		return cutoffMs <= 0 || pr.CreatedDate >= cutoffMs
	})
}

// statsRepoCommits returns the repo's commits, newest first, down to the cutoff.
func statsRepoCommits(ctx context.Context, c *Client, project, repo string, cutoff time.Time) ([]PRCommit, error) {
	cutoffMs := cutoff.UnixMilli()
	query := url.Values{"limit": {"100"}}
	return statsCollect(ctx, c, projectRepoPath(restAPIPrefix, project, repo, "/commits"), query, func(commit PRCommit) bool {
		return cutoffMs <= 0 || commit.AuthorTime >= cutoffMs
	})
}

func statsAllActivities(ctx context.Context, c *Client, project, repo string, prID int64) ([]Activity, error) {
	query := url.Values{"limit": {"100"}}
	return statsCollect(ctx, c, projectRepoPath(restAPIPrefix, project, repo, "/pull-requests/%d/activities", prID), query, func(Activity) bool {
		return true
	})
}

// computePRStats aggregates the stats report. activities[i] holds the
// activities of prEntries[i] (nil when they could not be fetched).
func computePRStats(
	prEntries []prStatEntry,
	activities [][]Activity,
	ignored map[string]bool,
	project string,
	repos []string,
	sinceDays int,
	cutoff time.Time,
	topN int,
	numBuckets int,
) StatsResult {
	commentCounts := map[string]int{}
	approvalCounts := map[string]int{}
	authorPRCount := map[string]int{} // merged PRs per author (denominator for the long ratio)
	authorHours := map[string][]float64{}
	var openDurations, openToFirst, firstToMerge, commentDist []float64

	type durEntry struct {
		id     int64
		repo   string
		title  string
		author string
		hours  float64
	}
	var durEntries []durEntry
	hoursBetween := func(fromMs, toMs int64) float64 { return float64(toMs-fromMs) / (3600 * 1000) }

	for i, pe := range prEntries {
		pr := pe.pr
		author := pr.Author.User.DisplayName

		var firstCommentMs int64
		reviewComments := 0 // comments by anyone but the author
		for _, act := range activities[i] {
			user := cmp.Or(act.User.DisplayName, act.User.Name)
			if ignored[user] {
				continue
			}
			switch {
			case act.Action == "COMMENTED" && act.Comment != nil:
				if user != author {
					commentCounts[user]++
					reviewComments++
				}
				if t := act.Comment.CreatedDate; t > 0 && (firstCommentMs == 0 || t < firstCommentMs) {
					firstCommentMs = t
				}
			case act.Action == "APPROVED":
				approvalCounts[user]++
			}
		}

		merged := pr.State == "MERGED"
		if merged && author != "" && !ignored[author] {
			authorPRCount[author]++
		}
		if merged && pr.CreatedDate > 0 && pr.ClosedDate > 0 {
			if h := hoursBetween(pr.CreatedDate, pr.ClosedDate); h >= 0 {
				openDurations = append(openDurations, h)
				durEntries = append(durEntries, durEntry{id: pr.ID, repo: pe.repo, title: pr.Title, author: author, hours: h})
				if author != "" && !ignored[author] {
					authorHours[author] = append(authorHours[author], h)
				}
			}
		}
		if firstCommentMs > 0 && pr.CreatedDate > 0 {
			if h := hoursBetween(pr.CreatedDate, firstCommentMs); h >= 0 {
				openToFirst = append(openToFirst, h)
			}
			if merged && pr.ClosedDate > 0 {
				if h := hoursBetween(firstCommentMs, pr.ClosedDate); h >= 0 {
					firstToMerge = append(firstToMerge, h)
				}
			}
		}
		if reviewComments > 0 {
			commentDist = append(commentDist, float64(reviewComments))
		}
	}

	// The longest-open 10% of merged PRs (at least one), and how many of each
	// author's PRs landed in that list.
	slices.SortFunc(durEntries, func(a, b durEntry) int { return cmp.Compare(b.hours, a.hours) })
	ratioN := min(len(durEntries), max(1, len(durEntries)/10))
	top := make([]LongestPR, 0, ratioN)
	topAuthorHits := map[string]int{}
	for _, d := range durEntries[:ratioN] {
		top = append(top, LongestPR{ID: d.id, Title: d.title, Repo: d.repo, Author: d.author, DurationHours: round2(d.hours)})
		if d.author != "" {
			topAuthorHits[d.author]++
		}
	}

	authorAvg := make([]UserCount, 0, len(authorHours))
	for author, hours := range authorHours {
		sum := 0.0
		for _, h := range hours {
			sum += h
		}
		authorAvg = append(authorAvg, UserCount{User: author, Count: int(math.Round(sum / float64(len(hours))))})
	}

	longRatio := make([]UserCount, 0, len(topAuthorHits))
	for author, hits := range topAuthorHits {
		if total := authorPRCount[author]; total > 0 {
			pct := int(math.Round(float64(hits) / float64(total) * 100))
			longRatio = append(longRatio, UserCount{User: author, Count: pct})
		}
	}

	sinceStr := ""
	if !cutoff.IsZero() {
		sinceStr = cutoff.UTC().Format(time.RFC3339)
	}

	return StatsResult{
		Summary: StatsSummary{
			Project:    project,
			Repos:      repos,
			TotalPRs:   len(prEntries),
			SinceDays:  sinceDays,
			SinceDate:  sinceStr,
			AnalyzedAt: time.Now().UTC().Format(time.RFC3339),
		},
		UserComments:        sortedUserCounts(commentCounts),
		UserApprovals:       sortedUserCounts(approvalCounts),
		PROpenDuration:      computeDistribution(openDurations, numBuckets, "h"),
		OpenToFirstComment:  computeDistribution(openToFirst, numBuckets, "h"),
		FirstCommentToMerge: computeDistribution(firstToMerge, numBuckets, "h"),
		CommentDistribution: computeDistribution(commentDist, numBuckets, ""),
		TopLongestPRs:       top,
		TopAuthorPRCount:    topUserCounts(userCounts(topAuthorHits), topN),
		TopAuthorDuration:   topUserCounts(authorAvg, topN),
		TopAuthorLongRatio:  topUserCounts(longRatio, topN),
	}
}

// userCounts returns m's entries in no particular order.
func userCounts(m map[string]int) []UserCount {
	out := make([]UserCount, 0, len(m))
	for u, c := range m {
		out = append(out, UserCount{User: u, Count: c})
	}
	return out
}

// topUserCounts sorts counts highest first and keeps at most n of them.
func topUserCounts(counts []UserCount, n int) []UserCount {
	slices.SortFunc(counts, func(a, b UserCount) int { return cmp.Compare(b.Count, a.Count) })
	return counts[:min(n, len(counts))]
}

func sortedUserCounts(m map[string]int) []UserCount {
	return topUserCounts(userCounts(m), len(m))
}

func computeDistribution(values []float64, numBuckets int, unit string) DistributionStats {
	if len(values) == 0 {
		return DistributionStats{}
	}

	sorted := slices.Sorted(slices.Values(values))

	n := len(sorted)
	sum := 0.0
	for _, v := range sorted {
		sum += v
	}
	mean := sum / float64(n)

	variance := 0.0
	for _, v := range sorted {
		d := v - mean
		variance += d * d
	}
	variance /= float64(n)
	std := math.Sqrt(variance)

	pct := func(p float64) float64 {
		idx := p / 100.0 * float64(n-1)
		lo := int(idx)
		hi := lo + 1
		if hi >= n {
			return sorted[n-1]
		}
		frac := idx - float64(lo)
		return sorted[lo]*(1-frac) + sorted[hi]*frac
	}

	minV, maxV := sorted[0], sorted[n-1]
	if numBuckets <= 0 {
		numBuckets = 8
	}

	bucketWidth := (maxV - minV) / float64(numBuckets)
	if bucketWidth <= 0 {
		bucketWidth = 1
	}

	buckets := make([]HistogramBucket, numBuckets)
	for i := range buckets {
		start := minV + float64(i)*bucketWidth
		end := start + bucketWidth
		if i == numBuckets-1 {
			end = maxV
		}
		label := fmt.Sprintf("%.0f-%.0f%s", start, end, unit)
		buckets[i] = HistogramBucket{Label: label, Start: round2(start), End: round2(end)}
	}

	for _, v := range sorted {
		idx := min(max(int((v-minV)/bucketWidth), 0), numBuckets-1)
		buckets[idx].Count++
	}

	return DistributionStats{
		Count:     n,
		Mean:      round2(mean),
		Median:    round2(pct(50)),
		Min:       round2(sorted[0]),
		Max:       round2(sorted[n-1]),
		Std:       round2(std),
		P25:       round2(pct(25)),
		P75:       round2(pct(75)),
		P90:       round2(pct(90)),
		P95:       round2(pct(95)),
		Histogram: buckets,
	}
}

func splitTrimmed(s, sep string) []string {
	parts := strings.Split(s, sep)
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}

func round2(v float64) float64 {
	return math.Round(v*100) / 100
}

// printJSON writes v to stdout as indented JSON, exiting on err or a write
// failure.
func printJSON(v any, err error) {
	if err != nil {
		fatal(err)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
