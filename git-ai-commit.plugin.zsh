#!/usr/bin/env zsh
# git-ai-commit: root plugin loader.
#
# This is the file most Zsh plugin managers (oh-my-zsh custom plugins,
# zgen/zgenom, antigen, zim, zplug) source when you clone this repo and
# enable it by NAME — they look for `git-ai-commit.plugin.zsh` at the
# repository root.
#
# It does two things:
#   1. Resolves and sources the real implementation in zsh/.
#   2. Puts bin/ (worker.py, llama-server.sh) on PATH so the plugin's
#      helpers and the bundled scripts work regardless of how the repo
#      was cloned or where the manager placed it.
#
# Manager-independent: this file only uses ${0:A:h} to find its own
# directory, so it works whether the repo is cloned into
# ~/.oh-my-zsh/custom/plugins/git-ai-commit, a zgen/antigen/zim bundle
# dir, or anywhere else.

# Root of the repo (this file's directory).
_ai_ROOT="${0:A:h}"

# Make bundled scripts (worker.py, llama-server.sh) discoverable.
if [[ -d "$_ai_ROOT/bin" && ":$PATH:" != *":$_ai_ROOT/bin:"* ]]; then
  export PATH="$_ai_ROOT/bin:$PATH"
fi

# Source the real plugin implementation.
_ai_PLUGIN="$_ai_ROOT/zsh/git-ai-commit.plugin.zsh"
if [[ -f "$_ai_PLUGIN" ]]; then
  source "$_ai_PLUGIN"
else
  print -u2 "git-ai-commit: implementation not found at $_ai_PLUGIN"
  return 1
fi

unset _ai_PLUGIN
