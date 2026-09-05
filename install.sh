#!/usr/bin/env sh
#
# git-livedemo installer.
#
#   curl -fsSL https://raw.githubusercontent.com/vspiewak/git-livedemo/main/install.sh | sh
#
# Installs a single script into the first writable directory of:
#   $GIT_LIVEDEMO_PREFIX, ~/.local/bin, /usr/local/bin
#
set -eu

REPO=${GIT_LIVEDEMO_REPO:-vspiewak/git-livedemo}
REF=${GIT_LIVEDEMO_REF:-main}
SRC="https://raw.githubusercontent.com/$REPO/$REF/git-livedemo"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
cyan() { printf '\033[36m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

command -v git >/dev/null 2>&1 || { red "git is required."; exit 1; }

if [ -n "${GIT_LIVEDEMO_PREFIX:-}" ]; then
  PREFIX=$GIT_LIVEDEMO_PREFIX
elif [ -w "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
  PREFIX="$HOME/.local/bin"
elif [ -w /usr/local/bin ]; then
  PREFIX=/usr/local/bin
else
  red "No writable install directory. Set GIT_LIVEDEMO_PREFIX=/somewhere/on/PATH."
  exit 1
fi

TARGET="$PREFIX/git-livedemo"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if [ -f "./git-livedemo" ]; then
  # Running from a clone.
  cp ./git-livedemo "$TMP"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "$SRC" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP" "$SRC"
else
  red "Need curl or wget to download $SRC"
  exit 1
fi

# Refuse to install something that is not the script we expect.
head -n 1 "$TMP" | grep -q '^#!' || { red "Downloaded file is not a script."; exit 1; }
grep -q 'git-livedemo' "$TMP" || { red "Downloaded file does not look like git-livedemo."; exit 1; }

mkdir -p "$PREFIX"
cp "$TMP" "$TARGET"
chmod +x "$TARGET"

cyan "Installed $("$TARGET" version) to $TARGET"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    dim ""
    dim "$PREFIX is not on your PATH. Add it:"
    dim "  echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.zshrc && exec zsh"
    ;;
esac

dim ""
dim "In any repo whose commits are your demo steps:"
dim "  git livedemo use main"
dim "  git livedemo next"
