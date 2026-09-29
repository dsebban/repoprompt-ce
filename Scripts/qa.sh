#!/usr/bin/env bash
# Fork QA driver: build signed QA DMGs in GitHub Actions and install them.
#
#   Scripts/qa.sh pr <fork-pr>...        build one DMG per fork PR head
#   Scripts/qa.sh tip <fork-pr>...       merge the PRs onto upstream main, push
#                                        tip-<date>-v<n>-f<pr>-... and my-tip,
#                                        then build the all-features DMG
#   Scripts/qa.sh install [run-id]       download a QA DMG (default: latest
#                                        successful run) and install it into
#                                        /Applications
#   Scripts/qa.sh runs                   list recent QA DMG runs
#
# Environment: QA_REPO (default dsebban/repoprompt-ce), QA_UPSTREAM_REMOTE
# (default upstream), QA_FORK_REMOTE (default origin).
set -euo pipefail

REPO="${QA_REPO:-dsebban/repoprompt-ce}"
UPSTREAM_REMOTE="${QA_UPSTREAM_REMOTE:-upstream}"
FORK_REMOTE="${QA_FORK_REMOTE:-origin}"
WORKFLOW="qa-dmg.yml"
export GH_HOST="${GH_HOST:-github.com}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

dispatch() {
    local ref="$1" label="$2"
    gh workflow run "$WORKFLOW" -R "$REPO" -f ref="$ref" -f label="$label" >/dev/null
    printf 'dispatched %s (%s)\n' "$label" "$ref"
}

pr_head() {
    gh pr view "$1" -R "$REPO" --json headRefName,headRepository \
        --jq 'if .headRepository.name == null then error("no head repo") else .headRefName end'
}

cmd_pr() {
    (( $# )) || usage
    local n
    for n in "$@"; do
        dispatch "$(pr_head "$n")" "pr$n"
    done
    printf 'watch: gh run list -R %s --workflow %s\n' "$REPO" "$WORKFLOW"
}

cmd_tip() {
    (( $# )) || usage
    local root date version name worktree n head
    root="$(git rev-parse --show-toplevel)"
    date="$(date +%Y-%m-%d)"
    git -C "$root" fetch -q "$UPSTREAM_REMOTE" main
    git -C "$root" fetch -q --prune "$FORK_REMOTE"
    version="$(git -C "$root" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$FORK_REMOTE/tip-$date-v*" |
        sed -E "s/^tip-$date-v([0-9]+).*/\\1/" | sort -n | tail -1)"
    version=$(( ${version:-0} + 1 ))
    name="tip-$date-v$version$(printf -- '-f%s' "$@")"

    worktree="$(mktemp -d "${TMPDIR:-/tmp}/qa-tip.XXXXXX")"
    git -C "$root" worktree add -q --detach "$worktree" "$UPSTREAM_REMOTE/main"
    for n in "$@"; do
        head="$(pr_head "$n")"
        # rerere replays conflict resolutions recorded in earlier tip builds.
        if ! git -C "$worktree" -c rerere.enabled=true -c rerere.autoUpdate=true \
            merge -q --no-ff -m "Merge fork #$n ($head) into $name" "$FORK_REMOTE/$head"; then
            if [[ -n "$(git -C "$worktree" diff --name-only --diff-filter=U)" ]]; then
                fail "fork #$n conflicts in $worktree. Resolve, commit, then run:
  Scripts/qa.sh tip-publish $worktree $name"
            fi
            git -C "$worktree" commit -q --no-edit
        fi
    done
    cmd_tip_publish "$worktree" "$name"
}

cmd_tip_publish() {
    (( $# == 2 )) || usage
    local worktree="$1" name="$2" root
    root="$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)/.."
    git -C "$worktree" push -q --force "$FORK_REMOTE" "HEAD:refs/heads/$name" "HEAD:refs/heads/my-tip"
    printf 'pushed %s and my-tip at %s\n' "$name" "$(git -C "$worktree" rev-parse --short HEAD)"
    git -C "$root" worktree remove --force "$worktree"
    dispatch "$name" "$name"
}

cmd_runs() {
    gh run list -R "$REPO" --workflow "$WORKFLOW" --limit 15 \
        --json databaseId,displayTitle,status,conclusion,createdAt \
        --jq '.[]|"\(.databaseId)\t\(.status)/\(.conclusion // "-")\t\(.createdAt[0:16])\t\(.displayTitle)"'
}

cmd_install() {
    local run="${1:-}" dir dmg mount app
    if [[ -z "$run" ]]; then
        run="$(gh run list -R "$REPO" --workflow "$WORKFLOW" --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
        [[ -n "$run" ]] || fail "no successful QA DMG runs"
    fi
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' RETURN
    gh run download "$run" -R "$REPO" -D "$dir"
    dmg="$(find "$dir" -name '*.dmg' -print -quit)"
    [[ -n "$dmg" ]] || fail "run $run has no DMG artifact"
    mount="$(mktemp -d)"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
    app="$(find "$mount" -maxdepth 1 -name '*.app' -print -quit)"
    [[ -n "$app" ]] || { hdiutil detach -quiet "$mount"; fail "no app inside $dmg"; }
    osascript -e "tell application id \"com.pvncher.repoprompt.ce\" to quit" >/dev/null 2>&1 || true
    rm -rf "/Applications/$(basename "$app")"
    ditto "$app" "/Applications/$(basename "$app")"
    hdiutil detach -quiet "$mount"
    codesign --verify --deep --strict "/Applications/$(basename "$app")"
    printf 'installed %s from %s\n' "/Applications/$(basename "$app")" "$(basename "$dmg")"
}

(( $# )) || usage
cmd="$1"
shift
case "$cmd" in
pr) cmd_pr "$@" ;;
tip) cmd_tip "$@" ;;
tip-publish) cmd_tip_publish "$@" ;;
install) cmd_install "$@" ;;
runs) cmd_runs ;;
*) usage ;;
esac
