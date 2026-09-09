#!/usr/bin/env python3
"""
Record docs/demo.gif.

Builds a throwaway demo repository, drives git-livedemo through it for real, reads
the resulting state out of git after every command, and draws the whole thing as an
editor: a Changes view on the left, the step's diff on the right, and the terminal
underneath. Nothing is staged for the picture -- every file, badge, line count and
line of output below comes from the commands actually running.

    uv run --with pillow python docs/demo/record.py     (or: docs/demo/record.sh)

Nothing here is needed to use git-livedemo; it only regenerates the recording.
"""
import os, re, shutil, subprocess, sys, tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(ROOT, "git-livedemo")
OUT = os.path.join(ROOT, "docs", "demo.gif")

# ------------------------------------------------------------------- the repo

SERVER_V1 = '''import { createServer } from "node:http";

const PORT = process.env.PORT ?? 3000;

const server = createServer((req, res) => {
  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: "not found" }));
});

server.listen(PORT, () => {
  console.log(`orders-api on :${PORT}`);
});
'''

SERVER_V2 = '''import { createServer } from "node:http";
import { all } from "./src/store.js";

const PORT = process.env.PORT ?? 3000;

const server = createServer((req, res) => {
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify(all()));
});

server.listen(PORT, () => {
  console.log(`orders-api on :${PORT}`);
});
'''

STORE = '''const orders = new Map();
let nextId = 1;

export function all() {
  return [...orders.values()];
}

export function add({ item, qty }) {
  const order = { id: nextId++, item, qty };
  orders.set(order.id, order);
  return order;
}
'''

ROUTES = '''import { all, add } from "./store.js";

export function route(req, res, body) {
  if (req.method === "GET") {
    return res.end(JSON.stringify(all()));
  }
  const order = add(JSON.parse(body));
  res.writeHead(201);
  res.end(JSON.stringify(order));
}
'''

TESTS = '''import { test } from "node:test";
import assert from "node:assert/strict";
import { add, all } from "../src/store.js";

test("an order comes back from the store", () => {
  const order = add({ item: "cable", qty: 2 });
  assert.equal(order.id, 1);
  assert.deepEqual(all(), [order]);
});
'''

STEPS = [
    ("Add the HTTP skeleton", {
        ".gitignore": "node_modules/\n.idea/\n",
        "package.json": '{\n  "name": "orders-api",\n  "type": "module",\n'
                        '  "version": "0.1.0"\n}\n',
        "server.js": SERVER_V1,
    }),
    ("Add the in-memory order store", {
        "src/store.js": STORE,
        "server.js": SERVER_V2,
    }),
    ("Route requests to the store", {"src/routes.js": ROUTES}),
    ("Add the store tests", {"test/store.test.js": TESTS}),
]

CMDS = ["use main", "list", "next", "next", "prev", "next", "exit"]

CAPTIONS = {
    "use main": ("git livedemo use main", "step 0 is the empty working tree: the before shot"),
    "list":     ("git livedemo list", "every step of the demo, and where you are in it"),
    "next":     ("git livedemo next", "the step lands as pending changes, ready to walk through"),
    "prev":     ("git livedemo prev", "one step back, and the diff comes with it"),
    "exit":     ("git livedemo exit", "back on your branch, with nothing left behind"),
}


def git(repo, *args, **kw):
    return subprocess.run(["git", "-C", repo, *args], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, **kw).stdout


def build_repo(path):
    os.makedirs(path)
    git(path, "init", "-qb", "main")
    git(path, "config", "user.email", "dev@example.com")
    git(path, "config", "user.name", "Dev")
    for subject, files in STEPS:
        for name, body in files.items():
            full = os.path.join(path, name)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            open(full, "w").write(body)
        git(path, "add", "-A")
        git(path, "commit", "-qm", subject)
    os.makedirs(os.path.join(path, "node_modules", "left-pad"))
    open(os.path.join(path, "node_modules", "left-pad", "index.js"), "w").write("//\n")


def run_pty(repo, argv):
    """Run one command under a pty, so what it prints is what a terminal would get."""
    pid, fd = os.forkpty()
    if pid == 0:
        os.chdir(repo)
        os.environ.update(TERM="xterm-256color", COLUMNS="96")
        try:
            os.execv(argv[0], argv)
        finally:
            os._exit(127)
    chunks = []
    while True:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    os.waitpid(pid, 0)
    os.close(fd)
    return b"".join(chunks).decode("utf-8", "replace")


def diff_lines(repo, path):
    """The file as the step leaves it: [(marker, text)], marker in ' +-'."""
    out = git(repo, "diff", "--cached", "-U2000", "--", path)
    body, seen = [], False
    for line in out.split("\n"):
        if line.startswith("@@"):
            seen = True
            continue
        if not seen or line.startswith("\\"):
            continue
        if line[:1] in (" ", "+", "-"):
            body.append((line[0], line[1:]))
    return body


def read_state(repo, step, total):
    """Everything the picture shows, read back out of the repository."""
    changes = []
    for line in git(repo, "status", "--porcelain").rstrip("\n").split("\n"):
        # Unversioned files are their own node in an IDE, not a change: at step 0 the
        # only one is the .gitignore the step keeps so build output stays ignored.
        if line and not line.startswith("??"):
            changes.append((line[:2].strip(), line[3:]))
    stats = {}
    for line in git(repo, "diff", "--cached", "--numstat").rstrip("\n").split("\n"):
        if line:
            add, rem, path = line.split("\t")
            stats[path] = (int(add or 0), int(rem or 0))

    focus = max(stats, key=lambda p: stats[p][0], default=None)
    if focus:
        content = diff_lines(repo, focus)
    else:
        focus = "server.js" if os.path.exists(os.path.join(repo, "server.js")) else None
        content = [(" ", l) for l in
                   open(os.path.join(repo, focus)).read().rstrip("\n").split("\n")] if focus else []

    head = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD").strip()
    return {"changes": [(s, p, stats.get(p, (0, 0))) for s, p in changes],
            "focus": focus, "content": content, "branch": head or "detached",
            "step": step, "total": total}


def drive(repo):
    """Run the commands and photograph the repository after each one."""
    total = len(git(repo, "log", "--oneline", "main").rstrip("\n").split("\n"))
    states = [("", "", read_state(repo, None, total))]
    step = None
    for cmd in CMDS:
        out = run_pty(repo, [BIN] + cmd.split())
        if cmd.startswith("use"):
            step = 0
        elif cmd == "next":
            step += 1
        elif cmd == "prev":
            step -= 1
        elif cmd == "exit":
            step = None
        states.append((cmd, out, read_state(repo, step, total)))
    return states


# ------------------------------------------------------------------ the paint

SCALE = 2
W, H = 900, 558
TITLE_H, HEAD_H = 30, 26
MAIN_TOP, MAIN_BOT = 30, 400
PANEL_W = 268
STRIP_BOT = 512

TITLE_BG, PANEL_BG = (49, 53, 61), (40, 44, 52)
EDITOR_BG, STRIP_BG, CAPTION_BG = (33, 37, 43), (28, 31, 37), (22, 24, 29)
SELECT_BG, BORDER = (55, 61, 73), (58, 63, 72)
ADD_BG, DEL_BG = (44, 64, 48), (72, 42, 45)
FG, MUTED, WHITE = (171, 178, 191), (108, 116, 130), (229, 233, 240)
BLUE, GREEN, RED = (97, 175, 239), (152, 195, 121), (224, 108, 117)
PURPLE, ORANGE, CYAN = (198, 120, 221), (209, 154, 102), (86, 182, 194)
DOTS = [(255, 95, 87), (254, 188, 46), (40, 200, 64)]
BADGE = {"A": GREEN, "M": BLUE, "D": RED, "?": MUTED}

S = lambda v: int(v * SCALE)
_mono, _ui = {}, {}


def mono(size):
    if size not in _mono:
        _mono[size] = ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", S(size))
    return _mono[size]


def ui(size, weight="Regular"):
    key = (size, weight)
    if key not in _ui:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", S(size))
        f.set_variation_by_name(weight)
        _ui[key] = f
    return _ui[key]


KEYWORDS = {"import", "from", "export", "function", "return", "const", "let", "new",
            "if", "else", "class", "async", "await", "test", "of", "in", "default"}
GLOBALS = {"console", "process", "JSON", "Map", "assert", "req", "res", "server"}
TOKEN = re.compile(r'(`[^`]*`|"[^"]*"|\'[^\']*\'|//.*$|\b\d+\b|[A-Za-z_$][\w$]*|\s+|.)')


def highlight(text):
    """Rough JavaScript colouring: enough to read, not a parser."""
    runs = []
    for tok in TOKEN.findall(text):
        if tok.startswith("//"):
            colour = MUTED
        elif tok[:1] in "\"'`":
            colour = GREEN
        elif tok.isdigit():
            colour = ORANGE
        elif tok in KEYWORDS:
            colour = PURPLE
        elif tok in GLOBALS:
            colour = CYAN
        else:
            colour = FG
        runs.append((tok, colour))
    return runs


ANSI = {"2": MUTED, "31": RED, "32": GREEN, "33": ORANGE, "34": BLUE, "36": CYAN}


def ansi_runs(text):
    colour, runs, pos = FG, [], 0
    for m in re.finditer(r"\x1b\[([0-9;]*)m", text):
        if m.start() > pos:
            runs.append((text[pos:m.start()], colour))
        codes = [c for c in m.group(1).split(";") if c not in ("", "1")]
        colour = ANSI.get(codes[-1], FG) if codes else FG
        pos = m.end()
    if pos < len(text):
        runs.append((text[pos:], colour))
    return [r for r in runs if r[0]]


def text(d, xy, runs, font):
    x, y = xy
    for body, colour in runs:
        d.text((x, y), body, font=font, fill=colour)
        x += font.getlength(body)
    return x


def draw_frame(state, typed, output_lines, caption):
    img = Image.new("RGB", (S(W), S(H)), EDITOR_BG)
    d = ImageDraw.Draw(img)

    # --- title bar
    d.rectangle([0, 0, S(W), S(TITLE_H)], fill=TITLE_BG)
    for n, colour in enumerate(DOTS):
        cx, r = S(14 + n * 14), S(5)
        d.ellipse([cx, S(TITLE_H / 2) - r, cx + 2 * r, S(TITLE_H / 2) + r], fill=colour)
    f = ui(12.5, "Semibold")
    x = S(62)
    d.text((x, S(9)), "orders-api", font=f, fill=WHITE)
    x += f.getlength("orders-api") + S(10)
    chip, chip_f = state["branch"], ui(11)
    cw = chip_f.getlength(chip) + S(14)
    playing = state["branch"] == "livedemo"
    d.rounded_rectangle([x, S(8), x + cw, S(23)], radius=S(7),
                        fill=(46, 63, 84) if playing else (58, 62, 71))
    d.text((x + S(7), S(10)), chip, font=chip_f, fill=BLUE if playing else MUTED)
    if state["step"] is not None:
        label = "Step %d / %d" % (state["step"], state["total"])
        fs = ui(12, "Medium")
        d.text((S(W - 14) - fs.getlength(label), S(9)), label, font=fs, fill=BLUE)

    # --- changes panel
    d.rectangle([0, S(MAIN_TOP), S(PANEL_W), S(MAIN_BOT)], fill=PANEL_BG)
    d.text((S(12), S(MAIN_TOP + 7)), "CHANGES", font=ui(10.5, "Bold"), fill=FG)
    changes = state["changes"]
    if changes:
        n = len(changes)
        d.text((S(74), S(MAIN_TOP + 7)), "%d file%s" % (n, "" if n == 1 else "s"),
               font=ui(10.5), fill=MUTED)
    y = S(MAIN_TOP + HEAD_H)
    for status, path, (add, rem) in changes:
        row_h = S(22)
        if path == state["focus"]:
            d.rectangle([0, y, S(PANEL_W), y + row_h], fill=SELECT_BG)
        colour = BADGE.get(status, MUTED)
        d.rounded_rectangle([S(10), y + S(4), S(24), y + S(18)], radius=S(3), fill=colour)
        fb = ui(9.5, "Bold")
        d.text((S(17) - fb.getlength(status) / 2, y + S(6)), status, font=fb, fill=(28, 31, 37))
        folder, _, name = path.rpartition("/")
        fp = mono(10.5)
        px = S(32)
        if folder:
            d.text((px, y + S(5)), folder + "/", font=fp, fill=MUTED)
            px += fp.getlength(folder + "/")
        d.text((px, y + S(5)), name, font=fp, fill=FG)
        counts = ("+%d" % add if add else "") + ("  -%d" % rem if rem else "")
        fc = mono(10)
        d.text((S(PANEL_W - 12) - fc.getlength(counts), y + S(5)), counts,
               font=fc, fill=GREEN if add and not rem else (RED if rem and not add else MUTED))
        y += row_h
    if not changes:
        empty = "Nothing to show."
        sub = "The working tree matches HEAD."
        fe, fsub = ui(12), ui(11)
        cy = S(MAIN_TOP) + (S(MAIN_BOT - MAIN_TOP)) // 2
        d.line([S(PANEL_W / 2 - 8), cy - S(40), S(PANEL_W / 2 + 8), cy - S(40)], fill=MUTED, width=S(1))
        d.text((S(PANEL_W / 2) - fe.getlength(empty) / 2, cy - S(24)), empty, font=fe, fill=MUTED)
        d.text((S(PANEL_W / 2) - fsub.getlength(sub) / 2, cy - S(6)), sub, font=fsub, fill=(84, 91, 104))

    # --- editor
    d.line([S(PANEL_W), S(MAIN_TOP), S(PANEL_W), S(MAIN_BOT)], fill=BORDER, width=S(1))
    if state["focus"]:
        tab_f = mono(11)
        tw = tab_f.getlength(state["focus"].rpartition("/")[2]) + S(28)
        d.rectangle([S(PANEL_W + 1), S(MAIN_TOP), S(PANEL_W + 1) + tw, S(MAIN_TOP + HEAD_H)],
                    fill=(44, 49, 58))
        d.text((S(PANEL_W + 15), S(MAIN_TOP + 7)), state["focus"].rpartition("/")[2],
               font=tab_f, fill=WHITE)
    d.line([S(PANEL_W), S(MAIN_TOP + HEAD_H), S(W), S(MAIN_TOP + HEAD_H)], fill=BORDER, width=S(1))

    code_f, num_f = mono(11.5), mono(10)
    y = S(MAIN_TOP + HEAD_H + 8)
    line_h = S(17)
    if state["content"]:
        for i, (marker, body) in enumerate(state["content"][:19], start=1):
            bg = ADD_BG if marker == "+" else DEL_BG if marker == "-" else None
            if bg:
                d.rectangle([S(PANEL_W + 1), y - S(2), S(W), y + line_h - S(2)], fill=bg)
            d.text((S(PANEL_W + 40) - num_f.getlength(str(i)), y + S(2)), str(i),
                   font=num_f, fill=(80, 87, 100))
            if marker != " ":
                d.text((S(PANEL_W + 48), y), marker, font=code_f,
                       fill=GREEN if marker == "+" else RED)
            text(d, (S(PANEL_W + 60), y), highlight(body), code_f)
            y += line_h
    else:
        msg, sub = "The working tree is empty.", "Nothing is checked out yet."
        fm, fs = ui(12), ui(11)
        cx = S(PANEL_W) + (S(W) - S(PANEL_W)) // 2
        cy = S(MAIN_TOP + HEAD_H) + (S(MAIN_BOT - MAIN_TOP - HEAD_H)) // 2
        d.text((cx - fm.getlength(msg) / 2, cy - S(14)), msg, font=fm, fill=MUTED)
        d.text((cx - fs.getlength(sub) / 2, cy + S(4)), sub, font=fs, fill=(84, 91, 104))

    # --- terminal strip
    d.rectangle([0, S(MAIN_BOT), S(W), S(STRIP_BOT)], fill=STRIP_BG)
    d.line([0, S(MAIN_BOT), S(W), S(MAIN_BOT)], fill=BORDER, width=S(1))
    tf = mono(11.5)
    y = S(MAIN_BOT + 10)
    x = text(d, (S(14), y), [("$ ", GREEN), (typed, WHITE)], tf)
    if typed is not None and output_lines is None:
        d.rectangle([x, y + S(1), x + tf.getlength("M") - 1, y + S(14)], fill=WHITE)
    y += S(16)
    for line in (output_lines or [])[:5]:
        text(d, (S(14), y), ansi_runs(line), tf)
        y += S(16)

    # --- caption
    d.rectangle([0, S(STRIP_BOT), S(W), S(H)], fill=CAPTION_BG)
    if caption:
        cmd, tail = caption
        cf, sf = mono(11), ui(12)
        cw = cf.getlength(cmd) + S(16)
        total = cw + S(8) + sf.getlength(tail)
        x = (S(W) - total) / 2
        d.rounded_rectangle([x, S(STRIP_BOT + 15), x + cw, S(STRIP_BOT + 34)],
                            radius=S(4), fill=(44, 64, 48))
        d.text((x + S(8), S(STRIP_BOT + 18)), cmd, font=cf, fill=GREEN)
        d.text((x + cw + S(8), S(STRIP_BOT + 18)), tail, font=sf, fill=(150, 158, 172))

    return img.resize((W, H), Image.LANCZOS)


def main():
    tmp = tempfile.mkdtemp(prefix="livedemo-gif-")
    repo = os.path.join(tmp, "orders-api")
    try:
        build_repo(repo)
        states = drive(repo)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    frames = []
    previous = states[0][2]
    for cmd, out, state in states[1:]:
        full = "git livedemo " + cmd
        caption = CAPTIONS[cmd]
        for n in range(0, len(full) + 1, 3):        # type it, on the old state
            frames.append((draw_frame(previous, full[:n], None, None), 80))
        frames.append((draw_frame(previous, full, None, None), 360))
        lines = out.replace("\r", "").rstrip("\n").split("\n")
        hold = 2600 if cmd == "exit" else 2000 if cmd in ("list", "use main") else 1700
        frames.append((draw_frame(state, full, lines, caption), hold))
        previous = state

    imgs = [f for f, _ in frames]
    delays = [d for _, d in frames]

    # One palette for the whole recording, chosen over the colours that are actually
    # on screen rather than over how often each appears: a frequency-based quantiser
    # spends its buckets on the background and drops the green of an added line.
    seen = set()
    for img in imgs[::max(1, len(imgs) // 12)] + [imgs[-1]]:
        seen.update(c for _, c in img.getcolors(maxcolors=1 << 24))
    probe = Image.new("RGB", (len(seen), 1))
    probe.putdata(sorted(seen))
    pal = probe.quantize(colors=128, method=Image.MEDIANCUT)
    imgs = [im.quantize(palette=pal, dither=Image.NONE) for im in imgs]

    imgs[0].save(OUT, save_all=True, append_images=imgs[1:], duration=delays,
                 loop=0, optimize=True, disposal=1)
    print("%s  %d frames  %dx%d  %.0f KB  %.1fs"
          % (os.path.relpath(OUT, ROOT), len(imgs), W, H,
             os.path.getsize(OUT) / 1024, sum(delays) / 1000))


if __name__ == "__main__":
    sys.exit(main())
