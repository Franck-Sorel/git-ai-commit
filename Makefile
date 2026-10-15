PYTHON ?= .venv/bin/python
PIP ?= .venv/bin/pip
VENV := .venv

.PHONY: setup install test doctor lint daemon demo clean

setup:           ## create a venv and install deps (incl. dev)
	python3 -m venv $(VENV)
	$(PIP) install -e ".[dev]"

install:         ## install just the runtime deps into the venv
	$(PIP) install -e .

test:            ## run all tests: daemon+pytest, plugin smoke, interactive, e2e, integration
	$(PYTHON) -m pytest -q
	zsh -f tests/smoke.zsh
	zsh tests/interactive.zsh
	bash tests/e2e-workflow.sh
	bash tests/integration.sh

doctor:          ## one-command setup self-check (why is it not working?)
	bash scripts/doctor.sh

lint:
	$(PYTHON) -m ruff check src tests bin/worker.py

daemon:          ## run the daemon (needs llama-server reachable)
	$(PYTHON) -m git_ai_commit.daemon

demo:            ## end-to-end demo vs the mock LLM (no llama-server needed)
	bash tests/integration.sh

clean:
	rm -rf $(VENV) .pytest_cache .ruff_cache *.egg-info
