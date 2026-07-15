# shellcheck shell=bash
#
# claudeview-lib.sh — shared identity helpers for ClaudeView.
#
# Sourced by hooks/claudeview-push and bin/claudeview-session so the hook and the
# manual-write helper derive the *same* session key and can never drift apart.
# Functions only; sourcing has no side effects.

# Replace every character outside the tab-name charset with "_". Applied to each
# component separately, so the reserved "~" delimiter can only ever be a joiner —
# never part of a repo, branch or topic name.
cv_clean() {
  printf '%s' "${1//[^A-Za-z0-9_.-]/_}"
}

# The human name of a session's project. In a normal checkout that is the repo
# directory; in a bare-repo + worktree layout basename(cwd) would be the branch
# ("master"), so we ask git for the shared repo dir and name it from there:
#   <repo>/.git      -> <repo>        (ordinary repo or its linked worktrees)
#   <repo>.git       -> <repo>        (bare repo, and worktrees checked out of it)
#   <project>/.bare  -> <project>     (the ".bare" worktree layout)
# Outside any git repo, fall back to basename(cwd).
cv_project_name() {
  local dir="${1:-$PWD}" common base
  [ -n "$dir" ] || dir="$PWD"
  if common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    base="$(basename "$common")"
    case "$base" in
      .git | .bare) basename "$(dirname "$common")" ;;
      *.git) basename "$base" .git ;;
      *) printf '%s\n' "$base" ;;
    esac
  else
    basename "${dir:-claude}"
  fi
}

# The checked-out branch, or "detached" when HEAD is not on a branch. Returns
# non-zero (and prints nothing) when the directory is not a git repo at all, so
# callers can distinguish "git, detached" from "not git".
cv_branch() {
  local dir="${1:-$PWD}" branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
  case "$branch" in
    HEAD | "") printf 'detached' ;;
    *) printf '%s' "$branch" ;;
  esac
}

# The session key that groups a session's documents in the viewer:
#   <repo>~<branch>   inside a git repo   (branch identifies the line of work)
#   <topic>~<sid>     outside git, sid given (keeps same-dir sessions apart)
#   <topic>           outside git, no sid   (a bare shell has no session id)
# Each component is cleaned individually so "~" stays an unambiguous delimiter.
cv_session_key() {
  local dir="${1:-$PWD}" sid="${2:-}" branch
  if branch="$(cv_branch "$dir")"; then
    printf '%s~%s' "$(cv_clean "$(cv_project_name "$dir")")" "$(cv_clean "$branch")"
  elif [ -n "$sid" ]; then
    printf '%s~%s' "$(cv_clean "$(cv_project_name "$dir")")" "$(cv_clean "$sid")"
  else
    cv_clean "$(cv_project_name "$dir")"
  fi
}
