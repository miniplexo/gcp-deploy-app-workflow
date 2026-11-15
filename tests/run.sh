#!/usr/bin/env bash
# Self-test of render.py and apply-config.sh against tests/fixture (fake values only).
# Usage: tests/run.sh          (needs bash, python3, git; run from anywhere)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$(dirname "$HERE")"
FIX="$HERE/fixture/instance"
RENDER=(python3 -I "$SHARED/scripts/render.py")
APPLY="$SHARED/scripts/apply-config.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1 HOME="$T/home"; mkdir -p "$HOME"
export ALL_SECRETS; ALL_SECRETS="$(cat "$HERE/secrets.json")"
pass=0 failn=0
ok()   { pass=$((pass + 1)); }
bad()  { failn=$((failn + 1)); printf 'FAIL: %s\n' "$*"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }
refuse() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name (should have been refused)"; else ok; fi; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
tree() { (cd "$1" 2>/dev/null && find . -mindepth 1 | sort | tr '\n' ' '); }

# ---------------- render.py ----------------
check "list apps"        test "$("${RENDER[@]}" --instance "$FIX" --list-apps | tr '\n' ' ')" = "vaultwarden whoami "
check "get VM_NAME"      test "$("${RENDER[@]}" --instance "$FIX" --app vaultwarden --get VM_NAME)" = "vault-1"
check "get GCP_ZONE"     test "$("${RENDER[@]}" --instance "$FIX" --app vaultwarden --get GCP_ZONE)" = "europe-west1-b"
check "get APPS_ROOT"    test "$("${RENDER[@]}" --instance "$FIX" --app vaultwarden --get APPS_ROOT)" = "/mnt/disks/vault-1-data/apps"
refuse "get other names" "${RENDER[@]}" --instance "$FIX" --app vaultwarden --get SMTP_PASSWORD
check "dry-run all apps" env -u ALL_SECRETS "${RENDER[@]}" --instance "$FIX" --all --dry-run

C="$T/inst"; cp -r "$FIX" "$C"
sed -i 's/^VM_NAME=.*/VM_NAME=__FILL_ME__/' "$C/common.env"
refuse "FILL_ME is refused" "${RENDER[@]}" --instance "$C" --app vaultwarden --get VM_NAME
cp -r "$FIX/common.env" "$C/common.env"
sed -i 's/^VM_NAME=.*/VM_NAME=Bad_Name/' "$C/common.env"
refuse "invalid VM_NAME" "${RENDER[@]}" --instance "$C" --app vaultwarden --get VM_NAME
cp "$FIX/common.env" "$C/common.env"
sed -i 's#^APPS_ROOT=.*#APPS_ROOT=/mnt/../etc#' "$C/common.env"
refuse "APPS_ROOT with .." "${RENDER[@]}" --instance "$C" --app vaultwarden --get APPS_ROOT
cp "$FIX/common.env" "$C/common.env"

SEC='{"SMTP_PASSWORD":"p@ss/w$rd\"q","ACTUAL_OPENID_CLIENT_SECRET":"a","CLOUDFLARED_TUNNEL_CRED":"c","CFTOKEN":"t"}'
refuse "value-rules reject an unsafe SMTP password" env ALL_SECRETS="$SEC" "${RENDER[@]}" --instance "$FIX" --app vaultwarden --out "$T/x"
refuse "missing secret"  env ALL_SECRETS='{}' "${RENDER[@]}" --instance "$FIX" --app vaultwarden --out "$T/x"
refuse "unknown profile" bash -c "printf 'profile: nope\n' > '$C/apps/vaultwarden/app.yaml' && ${RENDER[*]} --instance '$C' --app vaultwarden --out '$T/x'"
printf 'profile: vaultwarden-stack\n' > "$C/apps/vaultwarden/app.yaml"
printf 'x=${UNDEFINED_NAME}\n' > "$C/apps/whoami/files/bad.env"
refuse "undefined name"  "${RENDER[@]}" --instance "$C" --app whoami --out "$T/x"
rm "$C/apps/whoami/files/bad.env"
printf 'x=1\n' > "$C/apps/whoami/files/has space.txt"
refuse "output path with a space" "${RENDER[@]}" --instance "$C" --app whoami --out "$T/x"
rm "$C/apps/whoami/files/has space.txt"
printf 'x\n' > "$C/apps/whoami/files/.owner"
refuse "reserved output name" "${RENDER[@]}" --instance "$C" --app whoami --out "$T/x"
rm "$C/apps/whoami/files/.owner"

# override: an app file with the same relative path replaces the profile's file
cp -r "$FIX" "$T/ov"; mkdir -p "$T/ov/apps/vaultwarden/files/cloudflared"
printf 'tunnel: custom\n' > "$T/ov/apps/vaultwarden/files/cloudflared/config.yml"
"${RENDER[@]}" --instance "$T/ov" --app vaultwarden --out "$T/ov.bundle" >/dev/null 2>&1
line="$(grep ' cloudflared/config.yml ' "$T/ov.bundle" | cut -d' ' -f3 | base64 -d)"
check "app file overrides profile file" test "$line" = "tunnel: custom"

# ---------------- render + apply ----------------
"${RENDER[@]}" --instance "$FIX" --app vaultwarden --out "$T/vw.bundle" >/dev/null || bad "render vaultwarden"
"${RENDER[@]}" --instance "$FIX" --app whoami --out "$T/who.bundle" >/dev/null || bad "render whoami"
ROOT="$T/apps"; mkdir -p "$ROOT"
apply() { bash "$APPLY" "$1" --apps-root "$ROOT" --app "$2" --owner "${3:-org/a}" "${@:4}"; }
check "apply vaultwarden" apply "$T/vw.bundle" vaultwarden
check "apply generic app" apply "$T/who.bundle" whoami
d="$ROOT/vaultwarden"
check "mode .env is 600"        test "$(stat -c %a "$d/.env")" = 600
check "mode cloudflared is 644" test "$(stat -c %a "$d/cloudflared/vault-tunnel-cred.json")" = 644
check "folders are 755"         test "$(stat -c %a "$d/fail2ban/jail.d")" = 755
check "owner file"              test "$(cat "$d/.owner")" = "owner=org/a"
check "tunnel name default"     grep -qx 'tunnel: vault' "$d/cloudflared/config.yml"
check "secret reached env file" grep -q '^ACTUAL_OPENID_CLIENT_SECRET=actual-secret$' "$d/.env"
check "sq quoting"              grep -qxF "git config --global user.name 'Ann \"O'\\''Neil\" \$HOME'" "$d/gitconfig.sh"
check "gitconfig.sh runs"       bash -c "bash '$d/gitconfig.sh' && test \"\$(git config --global user.name)\" = 'Ann \"O'\\''Neil\" \$HOME'"
check "generic app: shared secret and value" grep -qx 'SMTP_PASSWORD=AbCd.1234-efgh_ij~k+' "$ROOT/whoami/.env"
check "dry-run writes nothing"  bash -c "before=\$(find '$ROOT' | wc -l); bash '$APPLY' '$T/vw.bundle' --apps-root '$ROOT' --app vaultwarden --owner org/a --dry-run >/dev/null && test \$before = \$(find '$ROOT' | wc -l)"

# ownership
refuse "another owner is refused" apply "$T/vw.bundle" vaultwarden org/b
mkdir -p "$ROOT/legacy"; echo hi > "$ROOT/legacy/old.txt"
sed 's/^app vaultwarden$/app legacy/' "$T/vw.bundle" > "$T/legacy.bundle"
refuse "non-empty folder without .owner" apply "$T/legacy.bundle" legacy
check "--adopt takes it over" apply "$T/legacy.bundle" legacy org/a --adopt
check "unrelated old file kept" test -f "$ROOT/legacy/old.txt"
refuse "wrong app in bundle" apply "$T/vw.bundle" whoami
refuse "missing apps root"   bash "$APPLY" "$T/vw.bundle" --apps-root "$T/nodisk" --app vaultwarden --owner org/a
ln -s "$ROOT/vaultwarden" "$ROOT/linked"
sed 's/^app vaultwarden$/app linked/' "$T/vw.bundle" > "$T/linked.bundle"
refuse "symlinked app folder" apply "$T/linked.bundle" linked
mkdir -p "$ROOT/sub/real"; echo x > "$ROOT/sub/real/f"; ln -s /tmp "$ROOT/sub/real2"
printf 'owner=org/a\n' > "$ROOT/sub/.owner"
printf 'config-bundle v2\napp sub\n644 real2/x %s\n' "$(b64 hi)" > "$T/sym.bundle"
refuse "symlink inside the app folder" apply "$T/sym.bundle" sub

# stale files are removed, nothing else
printf 'config-bundle v2\napp stale\n644 keep.txt %s\n644 old/dir/gone.txt %s\n' "$(b64 k)" "$(b64 g)" > "$T/s1.bundle"
printf 'config-bundle v2\napp stale\n644 keep.txt %s\n' "$(b64 k2)" > "$T/s2.bundle"
apply "$T/s1.bundle" stale >/dev/null; echo mine > "$ROOT/stale/unrelated.txt"
apply "$T/s2.bundle" stale >/dev/null
check "stale file and empty folders removed" test ! -e "$ROOT/stale/old"
check "unrelated file kept"                  test -f "$ROOT/stale/unrelated.txt"
check "kept file updated"                    test "$(cat "$ROOT/stale/keep.txt")" = k2

# hostile bundles: refused, nothing written
hostile() {  # hostile NAME 'bundle body lines...'
  local name="$1" body="$2"
  printf 'config-bundle v2\napp evil\n%b' "$body" > "$T/h.bundle"
  rm -rf "$ROOT/evil"
  if apply "$T/h.bundle" evil >/dev/null 2>&1; then bad "hostile: $name accepted"; else ok; fi
  [ ! -e "$ROOT/evil" ] || bad "hostile: $name left files behind"
}
H="$(b64 hi)"
hostile "parent traversal"   "644 ../x $H\n"
hostile "nested traversal"   "644 a/../../x $H\n"
hostile "absolute path"      "644 /etc/passwd $H\n"
hostile "dot segment"        "644 a/./b $H\n"
hostile "reserved .owner"    "644 .owner $H\n"
hostile "reserved .files"    "644 .files $H\n"
hostile "reserved temp name" "644 .apply.abc $H\n"
hostile "mode 777"           "777 f $H\n"
hostile "mode 4755"          "4755 f $H\n"
hostile "mode 600x"          "6000 f $H\n"
hostile "duplicate"          "644 f $H\n644 f $H\n"
hostile "file and folder"    "644 f $H\n644 f/g $H\n"
hostile "bad base64"         "644 f !!!\n"
hostile "space in path"      "644 a b $H\n"
hostile "quote in path"      "644 a\\\"b $H\n"
hostile "newline injection"  "644 f $H\n; touch $T/PWNED\n"
hostile "too deep"           "644 a/b/c/d/e/f/g/h/i $H\n"
hostile "long path"          "644 $(printf 'a%.0s' $(seq 1 201)) $H\n"
big="$(head -c 300000 /dev/zero | base64 | tr -d '\n')"
hostile "file too large"     "644 big $big\n"
many=""; for i in $(seq 1 201); do many+="644 f$i $H\n"; done
hostile "too many files"     "$many"
printf 'config-bundle v1\napp evil\n' > "$T/h.bundle";  refuse "wrong version" apply "$T/h.bundle" evil
printf 'config-bundle v2\n' > "$T/h.bundle";            refuse "no app line"   apply "$T/h.bundle" evil
: > "$T/h.bundle";                                       refuse "empty bundle"  apply "$T/h.bundle" evil
refuse "bad app name"  bash "$APPLY" "$T/vw.bundle" --apps-root "$ROOT" --app 'Bad;Name' --owner org/a
refuse "bad owner"     bash "$APPLY" "$T/vw.bundle" --apps-root "$ROOT" --app vaultwarden --owner 'x y'
refuse "bad apps root" bash "$APPLY" "$T/vw.bundle" --apps-root "/a/../b" --app vaultwarden --owner org/a
check "no injected file" test ! -e "$T/PWNED"
check "nothing outside apps root" test "$(tree "$T/home" | tr -d ' ')" = "./.gitconfig"

echo "passed: $pass   failed: $failn"
[ "$failn" = 0 ]
