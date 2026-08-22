#!/usr/bin/env zsh
# Interactive plugin-load test. Run:  zsh tests/interactive.zsh
#
# Drives a real interactive Zsh under a pty, sources the plugin, and
# confirms it loads cleanly:
#   - zpty self-test passes -> AI_ENABLED=1
#   - the accept-suggestion widget is registered
#   - self-insert is wrapped by ai-self-insert
#
# Results are written to a temp file (read after the child exits) so the
# test is immune to interactive-prompt redraw/escape noise on the pty.
set -u

zmodload zsh/zpty 2>/dev/null || { print "zpty unavailable; can't test"; exit 1; }
SCRIPT_DIR="${0:A:h}"
PLUGIN="${SCRIPT_DIR}/../zsh/git-ai-commit.plugin.zsh"
PTY="gai_it"
RESULT="$(mktemp)"

zpty "$PTY" zsh -f -i
sleep 0.4

send() { zpty -w "$PTY" "$1"$'\n'; }

send "source $PLUGIN"
send "{ echo \"AI_READY:\$AI_ENABLED\"; zle -l | grep -E 'accept-suggestion|self-insert'; } > $RESULT"
send "exit"
sleep 1

# drain whatever remains so the pty doesn't linger
for i in {1..20}; do zpty -r "$PTY" line 2>/dev/null || break; done
zpty -d "$PTY" 2>/dev/null

RESULT_TEXT="$(< "$RESULT")"
rm -f "$RESULT"

FAIL=0
if echo "$RESULT_TEXT" | grep -q 'AI_READY:1'; then
  print "ok: zpty self-test passed; plugin enabled"
else
  print "FAIL: plugin should be enabled (AI_READY:1)"
  FAIL=1
fi

if echo "$RESULT_TEXT" | grep -q 'ai-accept-suggestion'; then
  print "ok: ai-accept-suggestion widget registered"
else
  print "FAIL: ai-accept-suggestion not registered"
  FAIL=1
fi

if echo "$RESULT_TEXT" | grep -qE 'self-insert.*ai-self-insert|ai-self-insert.*self-insert'; then
  print "ok: self-insert wrapped by ai-self-insert"
else
  print "FAIL: self-insert wrapper not installed"
  FAIL=1
fi

print
if (( FAIL )); then print "INTERACTIVE FAILED"; exit 1; fi
print "INTERACTIVE OK"
