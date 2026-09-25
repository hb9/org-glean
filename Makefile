EMACS ?= emacs
MODULES = org-glean-core.el org-glean-embed.el org-glean-chunk.el org-glean-store.el org-glean-project.el \
          org-glean-semantic.el org-glean-index.el org-glean-search.el org-glean-ui.el org-glean.el

PYTHON ?= python3

.PHONY: test test-py compile clean test-model

test:
	$(EMACS) --batch -Q -L . -L test -l test/org-glean-test.el \
		-f ert-run-tests-batch-and-exit

# Fake-embedder protocol tests: spawn the real org_glean_embed.py subprocess
# with ORG_GLEAN_FAKE_EMBED=1, so this needs only the stdlib and pytest, no
# onnxruntime/tokenizers/numpy install.
test-py:
	$(PYTHON) -m pytest -q test/test_embed_backend.py

# Byte-compiles each module in isolation so cross-module require cycles and
# missing requires surface immediately. org-glean-mcp.el is intentionally
# excluded: it requires the optional, not-vendored mcp-server-tools package.
compile:
	@for module in $(MODULES); do \
		echo "=== $$module ==="; \
		$(EMACS) --batch -Q -L . --eval "(byte-compile-file \"$$module\")" || exit 1; \
	done
	@$(MAKE) clean

# Opt-in suite exercising a real installed embedding model (no
# ORG_GLEAN_FAKE_EMBED). Requires `org-glean-install` to have run first; see
# ROADMAP.md phase 1, C4.
test-model:
	@echo "test-model: org-glean-install (C4) not implemented yet; nothing to test against"
	@exit 1

clean:
	rm -f *.elc semantic/*.elc
	find . -name "__pycache__" -type d -exec rm -rf {} +
