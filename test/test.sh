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

fixture guard_foreign
"$BIN" goto 1 >/dev/null 2>&1
echo stray > stray.txt; git add -A; git commit -qm "committed mid-demo"
git checkout -q main
grep_ok "refuses to rewind a foreign commit" "$("$BIN" goto 2 2>&1)" "not demo steps"

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
