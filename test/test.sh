#!/usr/bin/env bash
#
# Smoke tests. Run from anywhere:  ./test/test.sh
#
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BIN="$REPO/git-livedemo"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }
ESC=$(printf '\033')

grep_ok(){ printf '%s' "$2" | grep -q "$3" && ok "$1" || bad "$1" "missing [$3] in [$2]"; }

# A repo with three steps committed on main, plus an ignored build dir.
repo() { local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 1
         git init -qb main; git config user.email t@t; git config user.name t; }

# Everything in the current directory bar the ignored build dir.
visible() { local f n=0; for f in *; do [ "$f" = target ] || [ ! -e "$f" ] || n=$((n + 1)); done; echo "$n"; }

fixture() {
  repo "$1"
  printf 'target/\n' > .gitignore
  mkdir -p target && echo junk > target/out.jar
  echo a > a.txt;                     git add -A; git commit -qm "Step one"
  echo b > b.txt; echo a2 >> a.txt;   git add -A; git commit -qm "Step two"
  mkdir -p sub; echo c > sub/c.txt; rm b.txt; git add -A; git commit -qm "Step three"
  "$BIN" use main >/dev/null
}

echo "git-livedemo tests"

fixture basic
check "lists every step"        "$("$BIN" list | wc -l | tr -d ' ')" "3"
"$BIN" reset >/dev/null
check "reset empties the tree"  "$(visible)" "0"
check "piped output carries no colour" "$("$BIN" list | grep -c "$ESC" || true)" "0"
check "reset keeps ignored dir" "$([ -f target/out.jar ] && echo yes)" "yes"

"$BIN" next >/dev/null
check "step 1 file present"     "$(cat a.txt)" "a"
grep_ok "step 1 is staged as an addition" "$(git status --short)" "^A  a.txt"
check "HEAD is the empty root"  "$(git log -1 --format=%s)" "Start of the demo"

"$BIN" next >/dev/null
grep_ok "step 2 shows a modification" "$(git status --short)" "^M  a.txt"
grep_ok "step 2 shows an addition"    "$(git status --short)" "^A  b.txt"
check "HEAD moved to step 1"    "$(git log -1 --format=%s)" "Step one"

"$BIN" next >/dev/null
grep_ok "step 3 shows a deletion" "$(git status --short)" "^D  b.txt"
grep_ok "step 3 shows a nested add" "$(git status --short)" "^A  sub/c.txt"

grep_ok "next past the end refuses" "$("$BIN" next 2>&1)" "Already at the last step"
"$BIN" prev >/dev/null
check "prev goes back"          "$("$BIN" status)" "Step 2/3 - Step two"
"$BIN" goto 1 >/dev/null
check "goto jumps"              "$(git status --short | grep -c '^A  a.txt')" "1"
a=$(git status --short); "$BIN" goto 1 >/dev/null; b=$(git status --short)
check "goto is idempotent"      "$a" "$b"
grep_ok "goto rejects nonsense" "$("$BIN" goto xyz 2>&1)" "must be a number"
grep_ok "goto rejects overflow" "$("$BIN" goto 99 2>&1)" "only 3 steps"

# A step number is decimal, whatever leading zeros it was typed with.
"$BIN" goto 02 >/dev/null
check "a leading zero stays decimal" "$("$BIN" status)" "Step 2/3 - Step two"
grep_ok "09 is nine, not a bad octal" "$("$BIN" goto 09 2>&1)" "only 3 steps"
"$BIN" goto 01 >/dev/null
check "01 is step one"          "$("$BIN" status)" "Step 1/3 - Step one"

check "play branch is used"     "$(git branch --show-current)" "livedemo"
check "source branch untouched" "$(git log --oneline main | wc -l | tr -d ' ')" "3"
grep_ok "plain checkout is refused mid-step" "$(git checkout main 2>&1)" "would be overwritten"
"$BIN" exit >/dev/null
check "exit returns to the source branch" "$(git branch --show-current)" "main"
check "exit restores the work"  "$(cat a.txt)" "$(printf 'a\na2')"

# Guards
fixture guard_dirty
echo "unsaved" >> a.txt
grep_ok "refuses on uncommitted tracked edits" "$("$BIN" goto 1 2>&1)" "Uncommitted changes"
check "the edit survived"       "$(tail -1 a.txt)" "unsaved"

fixture guard_clash
git checkout -q main; rm -f a.txt; git rm -q --cached a.txt; git commit -qm "drop a.txt"
echo "MINE" > a.txt
grep_ok "refuses to clobber an untracked clash" "$("$BIN" goto 1 2>&1)" "would be overwritten"
check "the untracked file survived" "$(cat a.txt)" "MINE"

fixture guard_noclash
echo scratch > scratch.txt
"$BIN" goto 2 >/dev/null 2>&1
check "keeps a non-clashing untracked file" "$(cat scratch.txt 2>/dev/null)" "scratch"

# An untracked file the step would write byte for byte is not a clash, and saying so
# must not abort the run.
fixture guard_identical
rm -f a.txt; git rm -q --cached a.txt; git commit -qm "drop a.txt"
printf 'a\n' > a.txt
"$BIN" goto 1 >/dev/null 2>&1
check "an identical untracked file plays through" "$?" "0"
check "and the step really played" "$(git status --short | grep -c '^A  a.txt')" "1"

# The guard runs on every step, not only when switching onto the play branch.
fixture guard_midplay
"$BIN" goto 1 >/dev/null
echo "MY NOTES" > b.txt
grep_ok "refuses a clash created mid-demo" "$("$BIN" next 2>&1)" "would be overwritten"
check "the mid-demo file survived" "$(cat b.txt)" "MY NOTES"

# git quotes any path it cannot print raw, and a quoted path matches nothing.
fixture guard_quoted
printf 'orig\n' > 'quo"te.txt'; printf 'orig\n' > ' spaced.txt'
git add -A; git commit -qm "Step four: odd names"
git rm -q 'quo"te.txt' ' spaced.txt'; git commit -qm "Step five: drop them"
printf 'MINE\n' > 'quo"te.txt'; printf 'MINE\n' > ' spaced.txt'
clash=$("$BIN" goto 4 2>&1)
grep_ok "refuses to clobber a quoted path" "$clash" 'quo"te.txt'
grep_ok "refuses to clobber a spaced path" "$clash" ' spaced.txt'
check "the quoted file survived"  "$(cat 'quo"te.txt')" "MINE"
check "the spaced file survived"  "$(cat ' spaced.txt')" "MINE"

# A symlink stores its target, not the bytes behind it.
repo symlink
echo a > a.txt; ln -s a.txt link; git add -A; git commit -qm "Step one"
echo b > b.txt; git add -A; git commit -qm "Step two"
"$BIN" use main >/dev/null; "$BIN" reset >/dev/null
ln -s a.txt link
"$BIN" goto 1 >/dev/null 2>&1
check "a matching symlink is not a clash" "$?" "0"
check "the symlink is the step's" "$(readlink link)" "a.txt"

# Step 0 wipes the tree, but the ignore rules are the presenter's, not the demo's.
fixture ignored
"$BIN" reset >/dev/null
check "step 0 keeps the ignore file"   "$([ -f .gitignore ] && echo yes)" "yes"
check "step 0 keeps target/ ignored"   "$(git status --short | grep -c target || true)" "0"
"$BIN" next >/dev/null
grep_ok "the step takes .gitignore back" "$(git status --short)" "^A  .gitignore"

# Mid-playback the tree is a replayed step, so record must not append it.
fixture record_guard
"$BIN" goto 1 >/dev/null
grep_ok "record refuses mid-playback" "$("$BIN" record "nope" 2>&1)" "mid-playback"
check "the steps branch is untouched" "$(git log --oneline main | wc -l | tr -d ' ')" "3"

# use takes a branch: a tag would become refs/heads/<tag> the moment record ran.
fixture use_tag
git tag v1 main
grep_ok "use rejects a tag" "$("$BIN" use v1 2>&1)" "No such branch"
check "steps still come from main" "$("$BIN" status)" "Step 3/3 - Step three"

# A detached HEAD has no branch name, so exit must remember the commit.
fixture detached
git checkout -q --detach main~1
sha=$(git rev-parse --short HEAD)
grep_ok "names the detached HEAD" "$("$BIN" goto 1 2>&1)" "detached HEAD ($sha)"
"$BIN" exit >/dev/null
check "exit returns to the detached commit" "$(git rev-parse --short HEAD)" "$sha"

fixture guard_foreign
"$BIN" goto 1 >/dev/null 2>&1
echo stray > stray.txt; git add -A; git commit -qm "committed mid-demo"
git checkout -q main
grep_ok "refuses to rewind a foreign commit" "$("$BIN" goto 2 2>&1)" "not demo steps"

# Two steps can share a tree; the index alone cannot tell them apart.
repo revert
echo a > a.txt;          git add -A; git commit -qm "Step one"
echo b > b.txt;          git add -A; git commit -qm "Step two"
rm b.txt;                git add -A; git commit -qm "Step three"
echo c > c.txt;          git add -A; git commit -qm "Step four"
"$BIN" use main >/dev/null
"$BIN" goto 3 >/dev/null
check "a repeated tree keeps its place" "$("$BIN" status)" "Step 3/4 - Step three"
"$BIN" next >/dev/null
check "next moves past a repeated tree" "$("$BIN" status)" "Step 4/4 - Step four"

repo empty_first
git commit -q --allow-empty -m "Step one"
echo a > a.txt; git add -A; git commit -qm "Step two"
"$BIN" use main >/dev/null
"$BIN" goto 1 >/dev/null
check "an empty first step holds"  "$("$BIN" status)" "Step 1/2 - Step one"
"$BIN" next >/dev/null
check "and next moves past it"     "$("$BIN" status)" "Step 2/2 - Step two"

# A repo with no commits at all
d="$TMP/fresh"; mkdir -p "$d"; cd "$d"; git init -qb main
git config user.email t@t; git config user.name t
grep_ok "no steps explains both options" "$("$BIN" list 2>&1)" "git livedemo use"
echo x > x.txt; "$BIN" record "Recorded one" >/dev/null
echo y > y.txt; "$BIN" record "Recorded two" >/dev/null
"$BIN" reset >/dev/null; "$BIN" next >/dev/null; "$BIN" next >/dev/null
check "record works with zero commits" "$("$BIN" status)" "Step 2/2 - Recorded two"
check "state stays out of the tree"    "$(git ls-files | grep -c livedemo || true)" "0"
check "state lives under .git"         "$([ -f .git/livedemo/state ] && echo yes)" "yes"

# Outside a repo: the installer prints the version from wherever it ran.
cd "$TMP"
grep_ok "version works outside a repo" "$("$BIN" version 2>&1)" "^git-livedemo "
grep_ok "help works outside a repo"    "$("$BIN" help 2>&1)" "step through a demo"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
