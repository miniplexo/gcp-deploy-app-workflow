# Shared deploy repo

Generic scripts, profiles and workflows that deploy apps from one or more **instance repos** to a VM.
This repo knows nothing about any particular instance: instances supply values and secrets only.

```
scripts/render.py          renders one app into a text bundle (Python 3, standard library only; runs on the runner)
scripts/apply-config.sh    validates a bundle and writes it into the app's folder on the VM (bash + base64 + mktemp)
profiles/<name>/           shared sources for a kind of app: files/, defaults.env, modes, value-rules
.github/workflows/         reusable workflows: deploy.yml (one app), validate.yml (all apps, no secrets)
tests/run.sh               self-test with a fake instance (tests/fixture); run it before releasing a new version
```

## Flow

1. An instance repo's workflow (push to `main`, or manual) calls `deploy.yml` once per app, one after the other.
2. The runner checks out the instance repo and this repo (at the pinned ref), reads `VM_NAME`, `GCP_ZONE` and
   `APPS_ROOT` (`render.py --get`, validated) and renders the app into a bundle. Only this step sees the secrets.
3. It signs in to Google Cloud with Workload Identity Federation and opens one IAP SSH session. `apply-config.sh`
   and the bundle travel on **stdin**, never on a command line, and are removed from the VM and the runner afterwards.
4. On the VM (under a lock, one deployment per VM at a time) `apply-config.sh` writes `APPS_ROOT/<app>/`, then
   `docker compose -p <app> up -d --remove-orphans` runs and the job fails unless every container is `running`.

## Conventions (instead of tables)

| | Rule |
|---|---|
| Output path | A file's path under `profiles/<p>/files/` (or the app's own `files/`) is its path under `APPS_ROOT/<app>/`. |
| Fragments | A name starting with `_` is never written; it can be pulled in with `%include _name A=value`. |
| Overrides | A file at the same relative path in the app's own `files/` replaces the profile's file. |
| Values | `defaults.env` (profile) < `common.env` (instance) < `apps/<app>/app.env`. One `KEY=value` per line. |
| Placeholders | `${NAME}`, `${secrets.NAME}` (GitHub secret, case-insensitive), `${sq.NAME}` (one single-quoted shell word), `$${` (literal `${`). |
| Required values | Every `${NAME}` must resolve, otherwise the render fails. `__FILL_ME__` fails if used. `KEY=` is blank on purpose. |
| Modes | `.env*` files 600, everything else 644, unless a profile's `modes` file says otherwise (600, 640 or 644 only). |
| Value rules | A profile's `value-rules` lists `<glob> <regex>`: every value substituted into a matching file must match. Use it where a value lands in a shell command, a parsed config or a sourced script. |
| Env files | In files named `.env*`, `$` in substituted values is doubled (Docker Compose escaping); values with newlines, edge spaces, a leading quote or ` #` are rejected. |
| Comments | Full-line `#` comments are copied as they are; `%% text` lines are source-only comments. |

`render.py --instance DIR --all --dry-run` checks every app without secrets (missing secrets show as `<secret:NAME>`).

## What an instance repo provides

```
common.env                    VM_NAME, GCP_ZONE, APPS_ROOT and values shared by its apps
apps/<app>/app.yaml           optional: "profile: <name>"
apps/<app>/app.env            values of that app
apps/<app>/files/...          optional: extra files, or replacements of profile files
.github/workflows/deploy.yml  the caller (see instance-repo/)
```
Variables in the instance repo's Environment (not secrets): `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT`.
Secrets: whatever the apps reference as `${secrets.NAME}`.

## What the VM must provide

- `APPS_ROOT` exists and is the mounted data disk (for example `/mnt/disks/<vm>-data/apps`). `apply-config.sh` never
  creates it, so a missing mount cannot silently fill the boot disk.
- Docker with the compose plugin, and passwordless `sudo` for the deploy identity (OS Login).
- Services in the compose files have `restart: unless-stopped`; all persistent state is bind-mounted below `APPS_ROOT`.
- The first-boot setup (cloud-config / Terraform) starts every app folder once, for example
  `for d in "$APPS_ROOT"/*/; do [ -e "$d/.disabled" ] || (cd "$d" && docker compose up -d); done`.

## Guard rails in apply-config.sh

Everything is validated before anything is written; a bad bundle changes nothing.

- Paths: relative, `[A-Za-z0-9._-]` segments, no `.` or `..`, at most 8 levels and 200 characters, no duplicates,
  no path that is both a file and a folder; `.owner`, `.files`, `.disabled` and `.apply.*` are reserved.
- Modes 600/640/644 only; at most 200 files, 256 KiB per file, 2 MiB in total.
- No symbolic link may be `APPS_ROOT`, the app folder or any folder below it.
- `.owner` records the repository that deployed the folder; another repository is refused. A non-empty folder
  without `.owner` is refused unless `--adopt` is given (use the `adopt` input once when migrating a folder such as
  `/var/vault`).
- Files written by the previous run (listed in `.files`) that are no longer part of the bundle are removed, nothing else.
- Folders are created with mode 755: containers run as other users and must be able to traverse them.

## Security notes

- Render and deploy now run in one job from one commit, so the code and the config share a trust domain. Protect the
  instance repo's `main` (reviews, no force-push) and the `production` Environment (branch rule, reviewers). Keep the
  secrets in the Environment, not at repository level.
- The shared repo is the supply chain for every instance: pin it by tag or commit in each instance, protect its tags,
  and bump pins through reviewed pull requests. Run `tests/run.sh` before tagging.
- Restrict the Workload Identity provider per instance, to the repository and to this workflow at an approved ref.
  For example (check the claim names in GitHub's OIDC documentation):
  `assertion.repository == 'my-org/inst-a' && assertion.job_workflow_ref.startsWith('my-org/deploy/.github/workflows/deploy.yml@refs/tags/v1')`.
  Use one service account per instance, allowed to SSH (IAP + OS Login) only to its own VM.
- All apps of one instance repo can reference all of its secrets. Keep sensitive apps in their own repo.
- Files for non-root containers (cloudflared, fail2ban) are 644, so their secrets are readable by every user on the VM.
  fail2ban logs the full command line when an action fails, including the SMTP password in `smtp-direct.conf`.

## Adding things

- **A new app that needs no shared files:** add `apps/<name>/` to an instance repo with its files and `app.env`.
  No change here.
- **A new kind of app:** add `profiles/<name>/` (files, optionally `defaults.env`, `modes`, `value-rules`) and tag a
  release. No script change.
- **New behaviour in the scripts:** change them, extend `tests/run.sh`, tag a release.

## Not tested yet

The workflows on GitHub, Workload Identity Federation, the IAP SSH session, `docker compose ... ps --format` on your
Compose version, and a running fail2ban or Compose reading the generated files. `tests/run.sh` covers the two scripts.
