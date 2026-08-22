#!/usr/bin/env zsh
# Plugin smoke test. Run:  zsh tests/smoke.zsh
#
# Verifies the plugin loads in a clean shell and that its core helper
# logic (context detection) behaves correctly. The async transport and
# daemon are covered by `pytest -q` (tests/test_daemon.py).
#
# NOTE: run with `zsh -f` to avoid a user's ~/.zshrc interfering.
set -eu
SCRIPT_DIR="${0:A:h}"
PLUGIN="${SCRIPT_DIR}/../zsh/git-ai-commit.plugin.zsh"

[[ -f "$PLUGIN" ]] || { print "plugin not found: $PLUGIN" >&2; exit 1; }

fails=0
check() {
  local name="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then
    print "ok: $name"
  else
    print "FAIL: $name (expected '$expected', got '$got')"
    fails=$((fails + 1))
  fi
}

# ---- load ------------------------------------------------------------------
source "$PLUGIN"
if (( ${+functions[_ai_in_commit_context]} )); then
  print "ok: plugin defined helper functions"
else
  print "FAIL: helper functions missing after source"
  fails=$((fails + 1))
fi

# ---- context detection (docs/03 §3) ---------------------------------------
# LBUFFER/RBUFFER are plain vars outside ZLE; set them and call the helper.
_ctx() { LBUFFER="$1" RBUFFER="${2:-}"; _ai_in_commit_context; }

check "load zpty module"        "OK" "$(zmodload zsh/zpty && print OK)"
check "open -m space"           YES "$( _ctx 'git commit -m "add login ' && print YES || print NO)"
check "open -m no tail space"   YES "$( _ctx 'git commit -m "add login'   && print YES || print NO)"
check "open -m at quote"        YES "$( _ctx 'git commit -m "'            && print YES || print NO)"
check "open -am"                YES "$( _ctx 'git commit -am "fix bug '   && print YES || print NO)"
check "open -a -m"              YES "$( _ctx 'git commit -a -m "fix bug ' && print YES || print NO)"
check "open --message= "        YES "$( _ctx 'git commit --message="fix ' && print YES || print NO)"
check "open --message space"    YES "$( _ctx 'git commit --message "fix ' && print YES || print NO)"
check "closed quote rejected"   NO  "$( _ctx 'git commit -m "done"'      && print YES || print NO)"
check "not a commit"            NO  "$( _ctx 'ls -la'                     && print YES || print NO)"
check "git status (no -m)"      NO  "$( _ctx 'git status'                 && print YES || print NO)"
check "cursor not at end"       NO  "$( _ctx 'git commit -m "done' '}'    && print YES || print NO)"

# ---- suggestion helpers are safe to define -------------------------------
if (( ${+functions[_ai_apply_suggestion]} && ${+functions[_ai_clear_suggestion]} )); then
  print "ok: apply/clear helpers defined"
else
  print "FAIL: apply/clear helpers missing"
  fails=$((fails + 1))
fi

print
if (( fails )); then
  print "SMOKE FAILED: $fails"
  exit 1
fi
print "SMOKE OK"
