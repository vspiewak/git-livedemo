<h1 align="center">git-livedemo</h1>

<p align="center">
  <em>Step through a live coding demo one commit at a time —<br>
  and let your IDE show every step as a reviewable diff.</em>
</p>

<p align="center">
  <a href="https://github.com/vspiewak/git-livedemo/actions/workflows/test.yml"><img alt="tests" src="https://github.com/vspiewak/git-livedemo/actions/workflows/test.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="shell" src="https://img.shields.io/badge/shell-bash%203.2%2B-lightgrey.svg">
  <img alt="dependencies" src="https://img.shields.io/badge/dependencies-git-brightgreen.svg">
</p>

---

<p align="center">
  <img src="docs/demo.gif" width="900"
       alt="an editor driven by git livedemo: each step lands in the Changes view as pending changes with its diff in the editor, and exit puts the branch back">
</p>

You are presenting. You built the project up as a clean chain of commits, and you want to
walk the room through it — one commit per slide, the diff on screen, the code running at
every stop.

So you `git checkout` the next commit. The files are right, and **the Changes view is
empty.** There is nothing to point at. You end up flipping to the git log and scrolling a
patch, which is not a demo.

`git-livedemo` fixes that. It puts step N into your working tree **and the index** while
`HEAD` stays on step N-1, so each step lands in the IDE as pending changes — added files,
added lines, deleted files, ready to walk through.

```console
$ git livedemo use main
Playing 'main' (7 steps). You were on main; 'git livedemo exit' takes you back.
Step 0/7 - empty working tree

$ git livedemo next
Step 1/7 - Add the project skeleton
  9 files changed, 598 insertions(+)

$ git livedemo next
Step 2/7 - Add the HTTP endpoint
  3 files changed, 87 insertions(+), 2 deletions(-)
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/vspiewak/git-livedemo/main/install.sh | sh
```

One file lands in `~/.local/bin/git-livedemo`, and git picks it up as a subcommand. No
runtime, no config file, no directory added to your project. To uninstall, delete it.

<details>
<summary><strong>Does this modify my git installation?</strong></summary>

No. Nothing is written into git, anywhere.

Git has no plugin registry. When it meets a subcommand it does not recognise, it scans
your `PATH` for an executable called `git-<name>` and runs it — that is the entire
mechanism, and it is how `git lfs` and `git absorb` work too. Your git install
(`git --exec-path`) is never touched.

So `git-livedemo` is one ordinary script in your own bin directory. Read it before you
run it; it is a single file. Deleting it is a complete uninstall, and git is exactly as
it was.
</details>

<details>
<summary>Other ways</summary>

```bash
# a specific directory
GIT_LIVEDEMO_PREFIX=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/vspiewak/git-livedemo/main/install.sh | sh

# from a clone
git clone https://github.com/vspiewak/git-livedemo && cd git-livedemo && ./install.sh

# or just copy the script anywhere on your PATH — that is the whole program
```
</details>

## Use it

Build your demo the way you always would: a branch, one commit per step, oldest first.
Then point at it and go.

```bash
git livedemo use main     # your commits are the steps; lands on step 0, an empty tree
git livedemo next         # step 1 appears in the IDE as pending changes
git livedemo next         # step 2 …
git livedemo exit         # back to the branch you came from
```

Presenting is smoother with a one-key alias:

```bash
alias next='git livedemo next'
```

## Commands

| command | what it does |
|---|---|
| `git livedemo use <branch>` | take the steps from a branch you committed yourself |
| `git livedemo next` / `prev` | move one step |
| `git livedemo goto <n>` | jump to a step; `0` is an empty working tree |
| `git livedemo reset` | back to step 0 |
| `git livedemo list` | every step, with `->` on the current one |
| `git livedemo status` | where you are |
| `git livedemo exit` | stop playing, back to your branch |

Nothing takes a commit hash. You move by step number, or just keep typing `next`.
`exit` takes an optional branch name for the rare case where it cannot work out where
you started.

## How it works

A step is an ordinary commit: every first-parent commit of the branch, oldest first.
Playing step N does four things:

1. points `HEAD` at step N-1, on a playback branch of its own;
2. `git read-tree -u --reset` step N's tree into the index and working tree;
3. puts the branch's `.gitignore` files back if the step does not have them;
4. `git clean` takes whatever else is in the tree, sparing ignored files and nested
   repositories.

The gap between `HEAD` and the index **is** the step, which is exactly what the IDE
renders. `git status` agrees:

```console
$ git livedemo goto 3 && git status --short
A  src/main/java/com/example/Controller.java
M  pom.xml
D  src/main/java/com/example/Placeholder.java
```

Step 1 has no previous step, so `HEAD` is left unborn and the whole tree reads as added.
Build tooling that insists on resolving `HEAD` (some versioning plugins) will not run at
step 1 for that reason; every later step has a real commit behind it.

## It will not eat your work

Two rules, one on each side of the door.

**Getting in is all or nothing.** `use` refuses if the working tree holds anything of
yours — an edit, a staged file, an untracked file — and names it:

```console
$ git livedemo use main
The working tree is not clean, and playing would drop all of this:
 M src/main/java/com/example/App.java
?? notes.md
Commit it, or stash it with: git stash push -u
```

It refuses mid-merge or mid-rebase too, and it refuses when a `livedemo` branch already
exists: git-livedemo creates that branch itself and deletes it on the way out, so one
that is already there is yours, or a demo that ended badly. Playing would rewind it.

An uncommitted `.gitignore` is the one thing the gate lets through. It is what keeps
`target/` out of the list above, and stashing it would un-ignore everything it covers
and make the next attempt worse.

**Once you are in, every step starts from its own tree and nothing else.** Whatever else
is in the working tree is dropped without asking — an edit, a deletion, a file you typed
live, a file you staged. That is safe precisely because entry refused on anything of
yours: everything the demo drops, the demo put there. A mistyped live edit cannot derail
the rest of the talk, and step 6 looks the same whether or not step 5 went to plan. Each
step names what it took, five at a time, so nothing disappears silently:

```console
$ git livedemo next
Step 2/7 - Add the HTTP endpoint
  3 files changed, 87 insertions(+), 2 deletions(-)
  dropped scratch/
```

Three things are never dropped:

- **Ignored files**, at entry and at every step: `target/`, `.idea/`, `node_modules/` and
  the rest of your build output. To make sure of it, the `.gitignore` files of the branch
  are kept on disk at every step, including step 0 and the steps from before the commit
  that added them — they show as untracked there, and the step that owns them takes them
  back.
- **`.gitignore` files**, whoever wrote them. A step cannot tell one you typed during the
  demo from the rules protecting your build output, and dropping the wrong one would
  un-ignore it. Remove it by hand and the next step takes what it was shielding.
- **Nested repositories**, which includes every submodule. Their working directories are
  left exactly as they are, and steps do not check them out. A directory someone typed
  `git init` into on stage stays too; delete that one by hand.

`exit` drops the last step the same way, checks out the branch you came from — or the
commit, if you started from a detached `HEAD` — and deletes the playback branch. If the
state under `.git/` is ever lost, `git livedemo exit <branch>` still gets you out.

State lives in one file under `.git/`, so there is nothing to add to `.gitignore` and
nothing you can accidentally commit.

## Configuration

| variable | default | what it changes |
|---|---|---|
| `GIT_LIVEDEMO_PLAY_BRANCH` | `livedemo` | branch playback runs on |
| `GIT_LIVEDEMO_PREFIX` | `~/.local/bin` | install directory |
| `NO_COLOR` | unset | any value turns colour off; it is off anyway when output is not a terminal |

## Tests

```bash
./test/test.sh
```

151 assertions over real repositories: the entry gate in every shape, the diff of every
step, what a move drops and what it spares, submodules and nested repositories, ignore
files committed late, nested, deleted live or never committed at all, odd and non-ASCII
filenames, symlinks, a merge, an empty first commit, two steps sharing a tree, a
SHA-256 repository, and exit from a branch, from a detached `HEAD`, after a manual
checkout and with the state file deleted.

## Recording

`docs/demo.gif` at the top of this page is generated, not hand-made:

```bash
./docs/demo/record.sh
```

It builds a throwaway demo repository in a temporary directory, drives git-livedemo
through it for real, and reads the state back out of git after every command — the
file list, the badges, the line counts, the diff and the terminal output are all what
the commands actually produced, then drawn as an editor. It needs
[uv](https://docs.astral.sh/uv/) to supply Pillow for one run; nothing is installed
system-wide, and nothing here is needed to use git-livedemo.

## How it compares

Walking a talk through a chain of commits is not a new idea, and if the tools below fit
your demo better, use them.

| tool | what advancing a step does |
|---|---|
| [git-slides](https://github.com/gelisam/git-slides) | checks out each commit: the files are right, and the Changes view is empty |
| [gitlogue](https://github.com/unhappychoice/gitlogue) | replays commits as an animation in the terminal; your editor is not involved |
| [CodeTour](https://github.com/microsoft/codetour) | hand-authored waypoints in the editor, not the diffs your commits already contain |
| `git-livedemo` | leaves `HEAD` one step behind, so the step arrives as pending changes in the IDE |

The difference is the last row. Everything else here moves `HEAD` to the commit you want
to show, which is correct and leaves nothing to point at. If your demo lives in the
terminal, one of the others is the better tool.

## License

MIT © Vincent Spiewak
