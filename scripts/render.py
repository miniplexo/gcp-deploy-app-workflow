#!/usr/bin/env python3
"""Render one app of an instance repo into a text bundle (see "Bundle format" below).

Standard library only. The rules are documented in README.md.

  render.py --instance DIR --app NAME --out FILE     render one app
  render.py --instance DIR --all --dry-run           check every app (no secrets needed)
  render.py --instance DIR --list-apps               print the app names
  render.py --instance DIR --app NAME --get NAME     print one resolved, validated value (VM_NAME, GCP_ZONE, APPS_ROOT)

Inputs
  instance/common.env                  values shared by all apps of the instance repo
  instance/apps/NAME/app.env           values of one app (override common.env)
  instance/apps/NAME/app.yaml          optional; "profile: PROFILE" selects shared files
  instance/apps/NAME/files/**          optional extra files; same relative path as a profile file replaces it
  shared/profiles/PROFILE/files/**     the profile's files (the folder tree mirrors the output tree)
  shared/profiles/PROFILE/defaults.env lowest-precedence values
  shared/profiles/PROFILE/modes        "<glob> <mode>" lines, first match wins (600/640/644)
  shared/profiles/PROFILE/value-rules  "<glob> <regex>" lines: substituted values in matching files must match

Value precedence: profile defaults.env < common.env < app.env.

Placeholders in files
  ${NAME}            value of NAME
  ${secrets.NAME}    value of the GitHub secret NAME
  ${sq.NAME}         value of NAME as ONE single-quoted shell word (for shell scripts)
  $${                a literal ${ as seen by the final consumer
  %include F A=v     inline the fragment file F (name starts with "_") with fragment variables A=v
  %% text            source-only comment, not written to the output
Files and folders whose name starts with "_" are fragments and are never written out. Full-line
comments (first non-blank character '#') are copied verbatim, never expanded. Output files whose
name starts with ".env" are env files: substituted values get '$' -> '$$' (Docker Compose escaping)
and unsafe values are rejected.

Bundle format (plain text; the VM side needs only bash and base64):
  config-bundle v2
  app <name>
  <mode> <output path> <base64 of the content>        one line per file
"""
import argparse
import base64
import fnmatch
import json
import os
import re
import sys
from pathlib import Path

TOKEN = re.compile(r"\$\$\{|\$\{([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\}")
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
INCLUDE_RE = re.compile(r"%include\s+([A-Za-z0-9_.-]+)((?:\s+\S+)*)")
APP_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,60}$")
SEGMENT_RE = re.compile(r"^[A-Za-z0-9._-]+$")
FILL_ME = "__FILL_ME__"
ALLOWED_MODES = {"600", "640", "644"}
RESERVED = {".owner", ".files", ".disabled"}
MAX_FILES = 200
MAX_FILE_BYTES = 256 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024

# values that other tooling reads before a bundle exists: validated by --get
GET_VALIDATORS = {
    "VM_NAME": (re.compile(r"^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$"), "a GCP instance name"),
    "GCP_ZONE": (re.compile(r"^[a-z]+-[a-z]+[0-9]+-[a-z]$"), "a GCP zone such as europe-west1-b"),
    "APPS_ROOT": (re.compile(r"^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+){0,11}$"), "an absolute path of up to 12 simple segments"),
}


def env_problem(value):
    """Why a substituted value cannot be written safely into an env file (None if fine)."""
    if "\n" in value or "\r" in value:
        return "contains a newline (not allowed in an env file; use a non-env output file)"
    if value != value.strip():
        return "has leading or trailing whitespace"
    if value[:1] in ('"', "'"):
        return "starts with a quote character"
    if " #" in value:
        return "contains ' #', which starts a comment in env files"
    return None


def path_problem(path):
    """Why an output path is not acceptable (None if fine). apply-config.sh enforces the same rules."""
    if len(path) > 200:
        return "is longer than 200 characters"
    parts = path.split("/")
    if len(parts) > 8:
        return "is nested deeper than 8 levels"
    for part in parts:
        if part in ("", ".", "..") or not SEGMENT_RE.match(part):
            return "must be a relative path of segments made of letters, digits, '.', '_' and '-'"
    if path in RESERVED or parts[-1].startswith(".apply."):
        return "uses a reserved name"
    return None


def parse_env(path, err):
    """KEY=VALUE lines -> {key: value}; reports problems through err()."""
    out = {}
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or not KEY_RE.match(key):
            err(f"{path.name}:{n}: expected KEY=VALUE")
            continue
        if key in out:
            err(f"{path.name}:{n}: duplicate key {key}")
            continue
        out[key] = value
    return out


def parse_pairs(path, err, what):
    """'<glob> <value>' lines -> [(glob, value)]. The value is the rest of the line."""
    pairs = []
    if not path.is_file():
        return pairs
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            err(f"{path.parent.name}/{path.name}:{n}: expected '<glob> {what}'")
            continue
        pairs.append((parts[0], parts[1].strip()))
    return pairs


class Renderer:
    def __init__(self, instance, shared, app, secrets, dry_run):
        self.instance = Path(instance)
        self.shared = Path(shared)
        self.app = app
        self.app_dir = self.instance / "apps" / app
        self.dry_run = dry_run
        self.errors = []
        self.warnings = []
        self.raw = {}  # key -> (value, label of the file it came from)
        self.cache = {}
        self.stack = []
        self.used_secret_values = set()
        self.sources = {}  # relative path -> Path (app files replace profile files)
        self.own_keys = set()
        self.rules = []  # [(glob, compiled regex)]
        self.modes = []  # [(glob, mode)]
        self.cur_out = ""
        self.secrets = {}
        for name, value in secrets.items():
            upper = name.upper()  # GitHub treats secret names case-insensitively
            if upper in self.secrets:
                self.err(f"GitHub secrets {name!r} and another secret differ only by case")
            self.secrets[upper] = value

    def err(self, msg):  # never include secret values
        if msg not in self.errors:
            self.errors.append(msg)

    # ---- inputs ----
    def load(self):
        if not APP_RE.match(self.app):
            self.err(f"app name {self.app!r} must match {APP_RE.pattern}")
            return
        if not self.app_dir.is_dir():
            self.err(f"{self.app_dir} not found")
            return
        profile = None
        yaml_path = self.app_dir / "app.yaml"
        if yaml_path.is_file():
            for n, line in enumerate(yaml_path.read_text(encoding="utf-8").splitlines(), 1):
                text = line.split("#", 1)[0].strip()
                if not text:
                    continue
                key, sep, value = text.partition(":")
                if not sep or key.strip() != "profile":
                    self.err(f"apps/{self.app}/app.yaml:{n}: only 'profile: NAME' is supported")
                    continue
                profile = value.strip()
                if not PROFILE_RE.match(profile):
                    self.err(f"apps/{self.app}/app.yaml:{n}: invalid profile name")
                    profile = None
        files_dirs = []
        label_defaults = None
        if profile:
            pdir = self.shared / "profiles" / profile
            if not pdir.is_dir():
                self.err(f"profile {profile} not found in {self.shared / 'profiles'}")
                return
            if (pdir / "defaults.env").is_file():
                label_defaults = f"profile {profile}: defaults.env"
                for k, v in parse_env(pdir / "defaults.env", self.err).items():
                    self.raw[k] = (v, label_defaults)
            self.rules = []
            for glob, rx in parse_pairs(pdir / "value-rules", self.err, "<regex>"):
                try:
                    self.rules.append((glob, re.compile(rx)))
                except re.error as exc:
                    self.err(f"profile {profile}: value-rules: bad regex for {glob} ({exc})")
            for glob, mode in parse_pairs(pdir / "modes", self.err, "<mode>"):
                if mode not in ALLOWED_MODES:
                    self.err(f"profile {profile}: modes: {mode} is not one of {sorted(ALLOWED_MODES)}")
                else:
                    self.modes.append((glob, mode))
            files_dirs.append(pdir / "files")
        common = self.instance / "common.env"
        if common.is_file():
            for k, v in parse_env(common, self.err).items():
                self.raw[k] = (v, "common.env")
        app_env = self.app_dir / "app.env"
        if app_env.is_file():
            for k, v in parse_env(app_env, self.err).items():
                self.raw[k] = (v, f"apps/{self.app}/app.env")
                self.own_keys.add(k)
        files_dirs.append(self.app_dir / "files")
        for fdir in files_dirs:  # later directories (the app's own) replace earlier ones
            if not fdir.is_dir():
                continue
            for path in sorted(fdir.rglob("*")):
                if path.is_symlink():
                    self.err(f"{path} is a symbolic link; links are not supported")
                elif path.is_file():
                    self.sources[path.relative_to(fdir).as_posix()] = path

    # ---- values ----
    def get_value(self, key):
        if key in self.cache:
            return self.cache[key]
        if key in self.stack:
            self.err("reference cycle: " + " -> ".join(self.stack + [key]))
            return "", set()
        raw, label = self.raw[key]
        sink = set()
        if FILL_ME in raw:
            self.err(f"{label}: {key} is still {FILL_ME}; fill it in (or leave it empty on purpose)")
            value = ""
        else:
            self.stack.append(key)
            value = self.expand(raw, {}, f"{label}:{key}", False, sink, rules=False)
            self.stack.pop()
        sink.add(key)
        self.cache[key] = (value, sink)
        return value, sink

    def value_of(self, name, local, where, sink):
        if "." in name:
            ns, key = name.split(".", 1)
            if ns != "secrets":
                self.err(f"{where}: unknown namespace in ${{{name}}} (supported: 'secrets.' and 'sq.')")
                return None
            sink.add(name)
            value = self.secrets.get(key.upper())
            if value:
                self.used_secret_values.add(value)
                return value
            if self.dry_run:
                return f"<secret:{key}>"
            self.err(f"{where}: GitHub secret {key} is missing or empty")
            return None
        if name in local:
            value, deps = local[name]
            sink |= deps
            return value
        if name in self.raw:
            value, deps = self.get_value(name)
            sink |= deps
            return value
        self.err(f"{where}: ${{{name}}} is not defined (profile defaults.env, common.env or apps/{self.app}/app.env)")
        return None

    def rule_problem(self, value):
        if self.dry_run and value.startswith("<secret:"):
            return None
        for glob, rx in self.rules:
            if fnmatch.fnmatchcase(self.cur_out, glob) and not rx.fullmatch(value):
                return f"contains characters that value-rules does not allow in {self.cur_out}"
        return None

    def expand(self, text, local, where, env_mode, sink, rules=True):
        def repl(match):
            name = match.group(1)
            if name is None:  # $${
                return "$${" if env_mode else "${"
            quote = name.startswith("sq.")
            value = self.value_of(name[3:] if quote else name, local, where, sink)
            if value is None:
                return ""
            if rules:
                problem = self.rule_problem(value)
                if problem:
                    self.err(f"{where}: value of ${{{name}}} {problem}")
                    return ""
            if quote:
                if env_mode:
                    self.err(f"{where}: ${{{name}}} cannot be used in an env file")
                    return ""
                if re.search(r"[\x00-\x1f\x7f]", value):
                    self.err(f"{where}: value of ${{{name}}} contains control characters")
                    return ""
                return "'" + value.replace("'", "'\\''") + "'"
            if env_mode:
                problem = env_problem(value)
                if problem:
                    self.err(f"{where}: value of ${{{name}}} {problem}")
                    return ""
                value = value.replace("$", "$$")
            return value

        return TOKEN.sub(repl, text)

    # ---- files ----
    def render_source(self, rel, local, env_mode, sink, stack):
        out = []
        src = self.sources[rel]
        for n, line in enumerate(src.read_text(encoding="utf-8").splitlines(), 1):
            where = f"{rel}:{n}"  # full relative path: names repeat across folders
            stripped = line.strip()
            if stripped.startswith("%%"):  # source-only comment, not emitted
                continue
            if stripped.startswith("%include"):
                m = INCLUDE_RE.fullmatch(stripped)
                if not m:
                    self.err(f"{where}: expected '%include FRAGMENT [NAME=value ...]'")
                    continue
                name = m.group(1)
                if name not in self.sources:
                    self.err(f"{where}: fragment {name} not found (profile files or apps/{self.app}/files)")
                    continue
                if name in stack:
                    self.err(f"{where}: %include cycle through {name}")
                    continue
                new_local = {}
                for token in m.group(2).split():
                    key, sep, raw = token.partition("=")
                    if not sep or not KEY_RE.match(key):
                        self.err(f"{where}: bad %include argument (expected NAME=value)")
                        continue
                    arg_sink = set()
                    new_local[key] = (self.expand(raw, local, where, False, arg_sink), arg_sink)
                out.extend(self.render_source(name, new_local, env_mode, sink, stack + [name]))
                continue
            if stripped.startswith("#"):
                out.append(line)
                continue
            out.append(self.expand(line, local, where, env_mode, sink))
        return out

    def mode_for(self, path):
        for glob, mode in self.modes:
            if fnmatch.fnmatchcase(path, glob):
                return mode
        return "600" if os.path.basename(path).startswith(".env") else "644"

    def run(self):
        self.load()
        files, usage = {}, {}
        if self.errors and not self.sources:
            return files, usage
        outputs = sorted(p for p in self.sources if not any(part.startswith("_") for part in p.split("/")))
        if len(outputs) > MAX_FILES:
            self.err(f"{len(outputs)} output files; at most {MAX_FILES} are allowed")
        for p in outputs:
            problem = path_problem(p)
            if problem:
                self.err(f"output path {p!r} {problem}")
        for p in outputs:
            if any(q.startswith(p + "/") for q in outputs):
                self.err(f"{p} is both a file and a folder")
        for rel in outputs:
            if path_problem(rel):
                continue
            sink = set()
            self.cur_out = rel
            env_mode = os.path.basename(rel).startswith(".env")
            lines = self.render_source(rel, {}, env_mode, sink, [])
            content = "\n".join(lines) + "\n"
            if len(content.encode()) > MAX_FILE_BYTES:
                self.err(f"{rel} is larger than {MAX_FILE_BYTES} bytes")
            files[rel] = content
            usage[rel] = sink
        self.cur_out = ""
        used = set().union(*usage.values()) if usage else set()
        for key in sorted(self.own_keys - used):
            self.warnings.append(f"apps/{self.app}/app.env: {key} is not used by any file of this app")
        return files, usage

    def get(self, name):
        """Resolved value of one key for --get; secrets are never printed."""
        self.load()
        if name not in GET_VALIDATORS:
            self.err(f"--get supports only {', '.join(sorted(GET_VALIDATORS))}")
            return None
        if name not in self.raw:
            self.err(f"{name} is not defined (common.env or apps/{self.app}/app.env)")
            return None
        self.cur_out = ""
        value, deps = self.get_value(name)
        if any(d.startswith("secrets.") for d in deps):
            self.err(f"{name} depends on a secret; it cannot be printed")
            return None
        rx, what = GET_VALIDATORS[name]
        if not rx.fullmatch(value):
            self.err(f"{name} must be {what}")
            return None
        if name == "APPS_ROOT" and ".." in value.split("/"):
            self.err("APPS_ROOT must not contain '..'")
            return None
        return None if self.errors else value


def build_report(app, usage, shared_keys):
    """Markdown matrix of where each secret and shared value ends up (names only, never values)."""
    by_name = {}
    for path, names in usage.items():
        for name in names:
            by_name.setdefault(name, []).append(path)
    lines = [f"## Config audit: {app}", "", "### Secrets", ""]
    secrets = sorted(n for n in by_name if n.startswith("secrets."))
    lines += [f"- `{n}` -> {', '.join(f'`{p}`' for p in sorted(by_name[n]))}" for n in secrets] or ["- none"]
    lines += ["", "### Values", ""]
    values = sorted(n for n in by_name if n in shared_keys)
    lines += [f"- `{n}` -> {', '.join(f'`{p}`' for p in sorted(by_name[n]))}" for n in values] or ["- none"]
    return "\n".join(lines) + "\n"


def list_apps(instance):
    apps_dir = Path(instance) / "apps"
    if not apps_dir.is_dir():
        return []
    return sorted(p.name for p in apps_dir.iterdir() if p.is_dir() and APP_RE.match(p.name))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--instance", default=".", help="instance repo directory (default: .)")
    ap.add_argument("--shared", default=str(Path(__file__).resolve().parent.parent),
                    help="shared deploy repo directory (default: the repo this script is in)")
    ap.add_argument("--app", help="app to render")
    ap.add_argument("--all", action="store_true", help="every app (needs --dry-run)")
    ap.add_argument("--list-apps", action="store_true", help="print the app names and exit")
    ap.add_argument("--get", metavar="NAME", help="print one resolved value (needs --app)")
    ap.add_argument("--out", help="write the text bundle here (mode 600)")
    ap.add_argument("--secrets-env", default="ALL_SECRETS",
                    help="environment variable holding a JSON object of secrets (default: ALL_SECRETS)")
    ap.add_argument("--dry-run", action="store_true",
                    help="structure check only: missing secrets are replaced by <secret:NAME>")
    ap.add_argument("--mask", action="store_true", help="print ::add-mask:: lines for used secrets (GitHub Actions)")
    args = ap.parse_args()

    if args.list_apps:
        print("\n".join(list_apps(args.instance)))
        return 0

    try:
        secrets = json.loads(os.environ.get(args.secrets_env) or "{}")
        if not isinstance(secrets, dict):
            raise ValueError("not an object")
        secrets = {str(k): str(v) for k, v in secrets.items()}
    except ValueError as exc:
        print(f"error: ${args.secrets_env} is not a JSON object ({exc})", file=sys.stderr)
        return 2

    gha = os.environ.get("GITHUB_ACTIONS") == "true"

    def show(r, stream=sys.stdout):
        for w in r.warnings:
            print(f"::warning::{w}" if gha else f"warning: {w}", file=stream)
        for e in r.errors:
            print(f"::error::{e}" if gha else f"error: {e}", file=stream)

    if args.get:
        if not args.app:
            print("error: --get needs --app", file=sys.stderr)
            return 2
        r = Renderer(args.instance, args.shared, args.app, {}, True)
        value = r.get(args.get)
        show(r, sys.stderr)  # stdout carries only the value
        if value is None:
            return 1
        print(value)
        return 0

    if args.all:
        if not args.dry_run or args.out:
            print("error: --all is only for --dry-run checks (no --out)", file=sys.stderr)
            return 2
        apps = list_apps(args.instance)
        if not apps:
            print("error: no apps found under apps/", file=sys.stderr)
            return 1
    elif args.app:
        apps = [args.app]
    else:
        print("error: give --app NAME, --all --dry-run, --list-apps or --get", file=sys.stderr)
        return 2

    failed = False
    for app in apps:
        r = Renderer(args.instance, args.shared, app, secrets, args.dry_run)
        files, usage = r.run()
        if args.mask:  # before anything else is printed
            for value in sorted(r.used_secret_values):
                for part in value.splitlines():
                    if part.strip():
                        print(f"::add-mask::{part}")
        lines = ["config-bundle v2", f"app {app}"]
        total = 0
        for path, content in sorted(files.items()):
            data = content.encode("utf-8")
            total += len(data)
            lines.append(f"{r.mode_for(path)} {path} {base64.b64encode(data).decode('ascii')}")
        if total > MAX_TOTAL_BYTES:
            r.err(f"files total {total} bytes; at most {MAX_TOTAL_BYTES} are allowed")
        payload = "\n".join(lines) + "\n"
        show(r)
        report = build_report(app, usage, set(r.raw))
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as fh:
                fh.write(report)
        else:
            print(report)
        if r.errors:
            failed = True
            continue
        if args.out:
            fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(payload)
        print(f"{app}: rendered {len(files)} files ({len(payload)} bytes).")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
