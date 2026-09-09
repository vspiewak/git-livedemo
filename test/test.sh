#!/usr/bin/env bash
#
# Smoke tests over real repositories. Run from anywhere:  ./test/test.sh
#
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BIN="$REPO/git-livedemo"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ESC=$(printf '\033')

ok()    { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
skip()  { printf '  \033[2mskip\033[0m %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }
grep_ok(){ printf '%s' "$2" | grep -q "$3" && ok "$1" || bad "$1" "missing [$3] in [$2]"; }
exists() { [ -e "$1" ] && echo yes || echo no; }

repo() { local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 1
         git init -qb main; git config user.email t@t; git config user.name t; }

# Everything in the current directory bar the ignored build dir.
visible() { local f n=0; for f in * .[!.]*; do [ "$f" = target ] || [ "$f" = .git ] || [ ! -e "$f" ] || n=$((n + 1)); done; echo "$n"; }
step()    { "$BIN" status 2>/dev/null | head -1; }

# A repo with three steps committed on main, plus an ignored build dir.
fixture() {
  repo "$1"
  printf 'target/\n' > .gitignore
  mkdir -p target && echo junk > target/out.jar
  echo a > a.txt;                            git add -A; git commit -qm "Step one"
  echo b > b.txt; echo a2 >> a.txt;          git add -A; git commit -qm "Step two"
  mkdir -p sub; echo c > sub/c.txt; rm b.txt; git add -A; git commit -qm "Step three"
}

echo "git-livedemo tests"

# ------------------------------------------------------------------ the gate
fixture gate_modified
echo unsaved >> a.txt
out=$("$BIN" use main 2>&1)
grep_ok "refuses a modified tracked file" "$out" "not clean"
grep_ok "and names it"                    "$out" "a.txt"
check "the edit survived"                 "$(tail -1 a.txt)" "unsaved"
check "and nothing started"               "$(git branch --show-current)" "main"
check "no state was written"              "$(exists .git/livedemo)" "no"

fixture gate_staged
echo s > staged.txt; git add staged.txt
grep_ok "refuses a staged file" "$("$BIN" use main 2>&1)" "staged.txt"

fixture gate_untracked
echo scratch > scratch.txt
grep_ok "refuses an untracked file"   "$("$BIN" use main 2>&1)" "scratch.txt"
check "the untracked file survived"   "$(cat scratch.txt)" "scratch"
git config status.showUntrackedFiles no
grep_ok "even when status hides untracked files" "$("$BIN" use main 2>&1)" "scratch.txt"
rm scratch.txt
check "enters once the tree is clean" "$("$BIN" use main >/dev/null 2>&1; echo $?)" "0"

fixture gate_ignored
echo more > target/more.jar
check "an ignored file does not block entry" "$("$BIN" use main >/dev/null 2>&1; echo $?)" "0"
check "and it is still there"                "$(exists target/more.jar)" "yes"

# An uncommitted .gitignore is what keeps target/ out of the list above, and the
# stash the refusal would ask for is exactly what un-ignores the build output.
repo gate_gitignore_untracked
printf 'target/\n' > .gitignore                       # never committed
mkdir -p target; echo junk > target/out.jar
echo a > a.txt; git add a.txt; git commit -qm "Step one"
echo b > b.txt; git add b.txt; git commit -qm "Step two"
check "an untracked .gitignore does not block entry" "$("$BIN" use main >/dev/null 2>&1; echo $?)" "0"
check "step 0 keeps it"               "$(exists .gitignore)" "yes"
check "so the build output stays"     "$(exists target/out.jar)" "yes"
"$BIN" next >/dev/null
check "and a step keeps both"         "$(exists target/out.jar)$(exists .gitignore)" "yesyes"

fixture gate_tag
git tag v1 main
grep_ok "rejects a tag"                 "$("$BIN" use v1 2>&1)" "No such branch"
grep_ok "rejects the play branch name"  "$("$BIN" use livedemo 2>&1)" "playback runs on"
grep_ok "rejects an unknown branch"     "$("$BIN" use nope 2>&1)" "No such branch"

fixture gate_on_play_branch
git checkout -q -b livedemo
out=$("$BIN" use main 2>&1)
grep_ok "refuses to start from a branch called livedemo" "$out" "no demo is open"
grep_ok "and says how to get out"       "$out" "git livedemo exit"

fixture gate_existing_play_branch
git branch livedemo main
out=$("$BIN" use main 2>&1)
grep_ok "refuses an existing play branch" "$out" "already exists"
check "and leaves it alone"           "$(git rev-parse --verify -q livedemo >/dev/null && echo yes || echo no)" "yes"
check "and never switched"            "$(git branch --show-current)" "main"

# The play branch is taken from the environment, so it can name a branch of yours.
fixture gate_play_branch_is_yours
git branch release main~1
was=$(git rev-parse release)
out=$(GIT_LIVEDEMO_PLAY_BRANCH=release "$BIN" use main 2>&1)
grep_ok "refuses to play over a branch of yours" "$out" "already exists"
check "and it still points where it did" "$(git rev-parse release)" "$was"
check "and the tree is untouched"     "$(git status --porcelain)" ""

fixture gate_worktree
git worktree add -q -b livedemo "$TMP/wt1" main 2>/dev/null
out=$("$BIN" use main 2>&1)
grep_ok "refuses a play branch held by another worktree" "$out" "livedemo"
check "the other worktree still has its branch" "$(git -C "$TMP/wt1" symbolic-ref --short HEAD)" "livedemo"
check "and its HEAD still resolves"   "$(git -C "$TMP/wt1" rev-parse -q --verify HEAD >/dev/null && echo yes || echo no)" "yes"
git worktree remove --force "$TMP/wt1" 2>/dev/null

fixture gate_rebase
git rebase -q --exec false HEAD~1 >/dev/null 2>&1 || true
grep_ok "refuses mid-rebase" "$("$BIN" use main 2>&1)" "in progress"
git rebase --abort 2>/dev/null

# git quotes any path it cannot print raw; the refusal has to name it anyway.
fixture gate_odd_names
printf 'MINE\n' > 'quo"te.txt'; printf 'MINE\n' > ' spaced.txt'; printf 'MINE\n' > 'café.txt'
out=$("$BIN" use main 2>&1)
grep_ok "names a quoted path"  "$out" 'quo"te.txt'
grep_ok "names a spaced path"  "$out" ' spaced.txt'
grep_ok "names a non-ASCII path unescaped" "$out" 'café.txt'
check "and the files survived"  "$(exists 'café.txt')" "yes"

# --------------------------------------------------------------------- entry
fixture enter
out=$("$BIN" use main 2>&1)
grep_ok "use announces the steps"    "$out" "3 steps"
grep_ok "and lands on step 0"        "$out" "Step 0/3"
check "step 0 is an empty tree"      "$(visible)" "1"
check "except the ignore rules"      "$(git status --short)" "?? .gitignore"
check "the build output survives"    "$(exists target/out.jar)" "yes"
check "playback is on its own branch" "$(git branch --show-current)" "livedemo"
check "state lives under .git"       "$(exists .git/livedemo)" "yes"
check "and not in the tree"          "$(git ls-files | grep -c livedemo || true)" "0"

# --------------------------------------------------------------------- moves
"$BIN" next >/dev/null
check "step 1 file present"          "$(cat a.txt)" "a"
grep_ok "step 1 is staged as an addition" "$(git status --short)" "^A  a.txt"
check "step 1 leaves HEAD unborn"    "$(git rev-parse -q --verify HEAD >/dev/null 2>&1 && echo born || echo unborn)" "unborn"

"$BIN" next >/dev/null
grep_ok "step 2 shows a modification" "$(git status --short)" "^M  a.txt"
grep_ok "step 2 shows an addition"    "$(git status --short)" "^A  b.txt"
check "HEAD moved to step 1"          "$(git log -1 --format=%s)" "Step one"

"$BIN" next >/dev/null
grep_ok "step 3 shows a deletion"     "$(git status --short)" "^D  b.txt"
grep_ok "step 3 shows a nested add"   "$(git status --short)" "^A  sub/c.txt"
check "the file is really gone"       "$(exists b.txt)" "no"

grep_ok "next past the end refuses"   "$("$BIN" next 2>&1)" "Already at the last step"
"$BIN" prev >/dev/null
check "prev goes back"                "$(step)" "Step 2/3 - Step two"
"$BIN" goto 1 >/dev/null
check "goto jumps"                    "$(step)" "Step 1/3 - Step one"
a=$(git status --short); "$BIN" goto 1 >/dev/null; b=$(git status --short)
check "goto is idempotent"            "$a" "$b"
grep_ok "goto rejects nonsense"       "$("$BIN" goto xyz 2>&1)" "must be a number"
grep_ok "goto rejects overflow"       "$("$BIN" goto 99 2>&1)" "only 3 steps"
grep_ok "goto wants a number"         "$("$BIN" goto 2>&1)" "usage"
"$BIN" goto 02 >/dev/null
check "a leading zero stays decimal"  "$(step)" "Step 2/3 - Step two"
grep_ok "09 is nine, not a bad octal" "$("$BIN" goto 09 2>&1)" "only 3 steps"
"$BIN" reset >/dev/null
check "reset goes back to 0"          "$(step)" "Step 0/3 - empty working tree"
check "and empties the tree"          "$(visible)" "1"
grep_ok "prev at 0 refuses"           "$("$BIN" prev 2>&1)" "Already at step 0"

"$BIN" goto 2 >/dev/null
list=$("$BIN" list)
check "list shows every step"         "$(printf '%s\n' "$list" | wc -l | tr -d ' ')" "4"
check "and marks exactly one"         "$(printf '%s\n' "$list" | grep -c -- '->')" "1"
grep_ok "the right one"               "$(printf '%s\n' "$list" | grep -- '->')" "2  Step two"
grep_ok "step 0 is listed"            "$list" "0  (empty working tree)"
check "piped output carries no colour" "$("$BIN" list | grep -c "$ESC" || true)" "0"
check "the source branch is untouched" "$(git log --oneline main | wc -l | tr -d ' ')" "3"

"$BIN" use main >/dev/null
check "use mid-demo starts over"      "$(step)" "Step 0/3 - empty working tree"

# ------------------------------------------------------- drops between steps
fixture drops
"$BIN" use main >/dev/null; "$BIN" goto 1 >/dev/null
echo "MY NOTES" > b.txt                       # step 2 writes b.txt too
rm -f a.txt                                   # a tracked file deleted live
mkdir -p scratch; echo x > scratch/x.txt      # no step ever writes this
printf 'MINE\n' > ' spaced.txt'
echo staged > staged.txt; git add staged.txt
out=$("$BIN" next 2>&1)
check "the step wins over a live file" "$(cat b.txt)" "b"
check "a live deletion is undone"     "$(cat a.txt)" "$(printf 'a\na2')"
check "a stray file is dropped"       "$(exists scratch/x.txt)" "no"
check "its directory goes too"        "$(exists scratch)" "no"
check "a spaced name is dropped"      "$(exists ' spaced.txt')" "no"
check "a staged file is dropped"      "$(exists staged.txt)" "no"
check "ignored build output stays"    "$(exists target/out.jar)" "yes"
grep_ok "and it names what it dropped" "$out" "dropped scratch/"
check "status is exactly the step"    "$(git status --short | tr '\n' '|')" "M  a.txt|A  b.txt|"

# One stray dependency directory would otherwise scroll the talk off the screen.
fixture drop_cap
"$BIN" use main >/dev/null; "$BIN" goto 1 >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo x > "junk$i.txt"; done
out=$("$BIN" next 2>&1)
check "the dropped list is capped"    "$(printf '%s\n' "$out" | grep -c 'dropped ')" "5"
grep_ok "and says how many more"      "$out" "and 7 more"

# A nested repository is a submodule as often as it is a prop, and a step that
# deletes one costs a re-clone.
fixture drops_nested
"$BIN" use main >/dev/null; "$BIN" goto 1 >/dev/null
mkdir -p demo2 && (cd demo2 && git init -q . && echo hi > hi.txt)
"$BIN" next >/dev/null
check "a nested repository is spared" "$(exists demo2/hi.txt)" "yes"

# ------------------------------------------------------------------ submodules
up="$TMP/upstream"; mkdir -p "$up"
(cd "$up" && git init -qb main && git config user.email t@t && git config user.name t &&
 echo lib > lib.txt && git add -A && git commit -qm "the submodule") >/dev/null 2>&1
fixture submodule
if git -c protocol.file.allow=always submodule add -q "$up" vendor >/dev/null 2>&1; then
  git commit -qm "Step four: add the submodule" >/dev/null
  "$BIN" use main >/dev/null 2>&1
  check "entering keeps the submodule's files" "$(exists vendor/lib.txt)" "yes"
  "$BIN" next >/dev/null 2>&1
  check "and so does a step"          "$(exists vendor/lib.txt)" "yes"
  "$BIN" exit >/dev/null 2>&1
  check "and so does leaving"         "$(exists vendor/lib.txt)" "yes"
else
  skip "submodules (git refused a file:// submodule)"
fi

# ---------------------------------------------------------------- ignore rules
# .gitignore first committed in step 2: steps before it still keep target/.
repo ignore_later
echo a > a.txt; git add -A; git commit -qm "Step one"
printf 'target/\n' > .gitignore; git add -A; git commit -qm "Step two: ignore target"
echo b > b.txt; git add -A; git commit -qm "Step three"
mkdir -p target; echo junk > target/out.jar
"$BIN" use main >/dev/null
check "step 0 borrows the tip's ignore rules" "$(git status --short)" "?? .gitignore"
"$BIN" goto 2 >/dev/null; "$BIN" prev >/dev/null
check "a step before the ignore commit keeps them" "$(exists .gitignore)" "yes"
grep_ok "as untracked"                "$(git status --short)" "?? .gitignore"
"$BIN" next >/dev/null
check "so target/ survives the move"  "$(exists target/out.jar)" "yes"
grep_ok "and the step takes the file back" "$(git status --short)" "^A  .gitignore"
rm .gitignore                                  # deleted live at step 2
"$BIN" next >/dev/null
check "a live-deleted .gitignore comes back"  "$(exists .gitignore)" "yes"
check "and target/ is still there"    "$(exists target/out.jar)" "yes"

fixture ignore_nested
mkdir -p lib; printf '*.log\n' > lib/.gitignore; git add -A; git commit -qm "Step four: nested ignore"
echo noise > lib/app.log
"$BIN" use main >/dev/null
check "a nested .gitignore is kept at step 0"  "$(exists lib/.gitignore)" "yes"
check "and what it shields"           "$(exists lib/app.log)" "yes"
"$BIN" goto 4 >/dev/null
check "and through a step"            "$(exists lib/app.log)" "yes"

# One typed during the demo is spared too: a step cannot tell it from the rules that
# keep your build output ignored. Remove it and the step takes what it shielded.
fixture ignore_live
"$BIN" use main >/dev/null; "$BIN" goto 1 >/dev/null
mkdir -p live; printf '*.log\n' > live/.gitignore; echo noise > live/app.log
"$BIN" next >/dev/null
check "a live .gitignore is kept"     "$(exists live/.gitignore)" "yes"
check "and so is what it shields"     "$(exists live/app.log)" "yes"
rm live/.gitignore
"$BIN" next >/dev/null
check "removing it lets the step take both" "$(exists live)" "no"

# A repo with no ignore rules anywhere still plays.
repo ignore_none
echo a > a.txt; git add -A; git commit -qm "Step one"
echo b > b.txt; git add -A; git commit -qm "Step two"
"$BIN" use main >/dev/null 2>&1
check "no .gitignore anywhere is fine" "$("$BIN" next >/dev/null 2>&1; echo $?)" "0"
check "and the step played"            "$(cat a.txt)" "a"

# ------------------------------------------------------------ the branch moves
fixture branch_gone
"$BIN" use main >/dev/null; "$BIN" goto 2 >/dev/null
git update-ref -d refs/heads/main
out=$("$BIN" reset 2>&1)
grep_ok "a deleted steps branch is reported" "$out" "is gone"
check "and the tree was not emptied"  "$(exists a.txt)" "yes"
check "and the state still stands"    "$(exists .git/livedemo)" "yes"

# ---------------------------------------------------------------------- exit
fixture leave
"$BIN" use main >/dev/null; "$BIN" goto 2 >/dev/null
echo live > live.txt
out=$("$BIN" exit 2>&1)
grep_ok "exit says where you landed"  "$out" "Back on main"
check "exit returns to the source branch" "$(git branch --show-current)" "main"
check "with a clean tree"             "$(git status --porcelain)" ""
check "the work is back"              "$(cat a.txt)" "$(printf 'a\na2')"
check "live edits are gone"           "$(exists live.txt)" "no"
check "build output is still there"   "$(exists target/out.jar)" "yes"
check "the play branch is gone"       "$(git show-ref --verify --quiet refs/heads/livedemo && echo yes || echo no)" "no"
check "and so is the state"           "$(exists .git/livedemo)" "no"
grep_ok "next after exit says so"     "$("$BIN" next 2>&1)" "Not playing"
grep_ok "exit twice says so"          "$("$BIN" exit 2>&1)" "Not playing"

fixture leave_from_step0
"$BIN" use main >/dev/null
"$BIN" exit >/dev/null
check "exit from step 0 restores the tree" "$(git status --porcelain)" ""
check "on the source branch"          "$(git branch --show-current)" "main"

fixture leave_detached
git checkout -q --detach main~1
was=$(git rev-parse HEAD)
grep_ok "use names a detached HEAD"   "$("$BIN" use main 2>&1)" "detached HEAD"
"$BIN" exit >/dev/null
check "exit returns to the detached commit" "$(git rev-parse HEAD)" "$was"
check "with its tree"                 "$(git status --porcelain)" ""

# HEAD left on its own, so there is nothing to check out -- only to say so.
fixture leave_stale
"$BIN" use main >/dev/null; "$BIN" goto 2 >/dev/null
git checkout -q -f main
grep_ok "a manual checkout ends the demo" "$("$BIN" next 2>&1)" "Not playing"
out=$("$BIN" exit 2>&1)
grep_ok "exit does not claim to have moved" "$out" "already left"
grep_ok "and names where you actually are"  "$out" "You are on main"
check "the leftover play branch is deleted" "$(git show-ref --verify --quiet refs/heads/livedemo && echo yes || echo no)" "no"
check "and the state is gone"         "$(exists .git/livedemo)" "no"

# The state file can be lost; HEAD is then stranded where a plain checkout refuses
# to go, so exit has to take a branch name and work anyway.
fixture leave_lost_state
"$BIN" use main >/dev/null; "$BIN" goto 1 >/dev/null
rm -f .git/livedemo
grep_ok "a lost state file stops the moves" "$("$BIN" next 2>&1)" "Not playing"
grep_ok "and exit asks where to go"   "$("$BIN" exit 2>&1)" "say where to go"
"$BIN" exit main >/dev/null 2>&1
check "exit <branch> gets you out"    "$(git branch --show-current)" "main"
check "with a clean tree"             "$(git status --porcelain)" ""
check "and the play branch cleared"   "$(git show-ref --verify --quiet refs/heads/livedemo && echo yes || echo no)" "no"

# An origin branch with no commits on it is a name, not a commit.
repo unborn_origin
echo a > a.txt; git add -A; git commit -qm "Step one"
echo b > b.txt; git add -A; git commit -qm "Step two"
git branch -m main steps
git symbolic-ref HEAD refs/heads/main    # unborn, index still holds steps' tree
git rm -rq --cached .; rm -f a.txt b.txt
err=$("$BIN" use steps 2>&1 >/dev/null)
check "an unborn origin prints no git fatal" "$(printf '%s' "$err" | grep -c fatal || true)" "0"
grep_ok "and is named as itself"      "$("$BIN" status 2>&1)" "you were on main"
"$BIN" exit >/dev/null 2>&1
check "exit lands back on it"         "$(git symbolic-ref --short HEAD)" "main"

fixture leave_play_branch_env
GIT_LIVEDEMO_PLAY_BRANCH=demo "$BIN" use main >/dev/null
check "the play branch can be renamed" "$(git branch --show-current)" "demo"
GIT_LIVEDEMO_PLAY_BRANCH=demo "$BIN" exit >/dev/null
check "and is deleted on the way out" "$(git show-ref --verify --quiet refs/heads/demo && echo yes || echo no)" "no"

# --------------------------------------------------------------- odd histories
# A symlink is the step's to play, like any other path.
repo symlink
echo a > a.txt; ln -s a.txt link; git add -A; git commit -qm "Step one"
echo b > b.txt; git add -A; git commit -qm "Step two"
"$BIN" use main >/dev/null; "$BIN" next >/dev/null
check "the symlink is the step's"     "$(readlink link)" "a.txt"

# Two steps can share a tree -- a revert, an empty commit -- so the step number is
# the only thing that can tell them apart.
repo repeated_tree
echo a > a.txt; git add -A; git commit -qm "Step one"
echo b > b.txt; git add -A; git commit -qm "Step two"
rm b.txt;       git add -A; git commit -qm "Step three"
echo c > c.txt; git add -A; git commit -qm "Step four"
"$BIN" use main >/dev/null; "$BIN" goto 3 >/dev/null
check "a repeated tree keeps its place" "$(step)" "Step 3/4 - Step three"
"$BIN" next >/dev/null
check "next moves past a repeated tree" "$(step)" "Step 4/4 - Step four"

repo empty_first
git commit -q --allow-empty -m "Step one"
echo a > a.txt; git add -A; git commit -qm "Step two"
"$BIN" use main >/dev/null; "$BIN" goto 1 >/dev/null
check "an empty first step holds"     "$(step)" "Step 1/2 - Step one"
"$BIN" next >/dev/null
check "and next moves past it"        "$(step)" "Step 2/2 - Step two"

# A merge on the branch is one step, not a fork.
repo merge_history
echo a > a.txt; git add -A; git commit -qm "Step one"
git checkout -qb side; echo s > s.txt; git add -A; git commit -qm "side work"
git checkout -q main; echo b > b.txt; git add -A; git commit -qm "Step two"
git merge -q --no-ff side -m "Step three: merge side" >/dev/null
"$BIN" use main >/dev/null
check "a merge counts as one step"    "$("$BIN" list | wc -l | tr -d ' ')" "4"
"$BIN" goto 3 >/dev/null
grep_ok "and plays what it merged in" "$(git status --short)" "^A  s.txt"

# Step 0's tree is asked for, not written out: a SHA-256 repository has its own.
if git init -q --object-format=sha256 "$TMP/probe" 2>/dev/null; then
  d="$TMP/sha256"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 1
  git init -q --object-format=sha256 -b main .
  git config user.email t@t; git config user.name t
  check "the fixture really is sha256" "$(git rev-parse --show-object-format)" "sha256"
  echo a > a.txt; git add -A; git commit -qm "Step one"
  echo b > b.txt; git add -A; git commit -qm "Step two"
  "$BIN" use main >/dev/null 2>&1
  check "step 0 works in a sha256 repo" "$(step)" "Step 0/2 - empty working tree"
  "$BIN" next >/dev/null 2>&1
  check "and so does a step"            "$(cat a.txt 2>/dev/null)" "a"
else
  skip "sha256 repositories (git too old)"
fi

# --------------------------------------------------------------- outside a repo
outside="$TMP/outside"; mkdir -p "$outside"; cd "$outside" || exit 1
grep_ok "version works outside a repo" "$("$BIN" version 2>&1)" "^git-livedemo "
grep_ok "help works outside a repo"    "$("$BIN" help 2>&1)" "step through a demo"
grep_ok "no command shows help"        "$("$BIN" 2>&1)" "step through a demo"
grep_ok "next outside a repo refuses"  "$("$BIN" next 2>&1)" "Not inside a git repository"

# ------------------------------------------------------------------- installer
noperm="$TMP/noperm"; mkdir -p "$noperm"; chmod 555 "$noperm"
if [ "$(id -u)" = 0 ]; then
  skip "install refuses a non-writable prefix (running as root)"
else
  out=$(cd "$REPO" && GIT_LIVEDEMO_PREFIX="$noperm" sh ./install.sh 2>&1)
  grep_ok "install refuses a non-writable prefix" "$out" "not writable"
fi
chmod 755 "$noperm"
bin="$TMP/bin"
out=$(cd "$REPO" && GIT_LIVEDEMO_PREFIX="$bin" sh ./install.sh 2>&1)
grep_ok "install from a clone reports the version" "$out" "Installed git-livedemo "
check "and the script runs"           "$("$bin/git-livedemo" version | cut -d' ' -f1)" "git-livedemo"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
