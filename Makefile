EMACS ?= emacs
MODULES = org-glean-core.el org-glean-chunk.el org-glean-store.el org-glean-project.el \
          org-glean-index.el org-glean-search.el org-glean-ui.el org-glean.el

.PHONY: test compile clean test-model

test:
	$(EMACS) --batch -Q -L . -L test -l test/org-glean-test.el \
		-f ert-run-tests-batch-and-exit

# Byte-compiles each module in isolation so cross-module require cycles and
# missing requires surface immediately. org-glean-mcp.el is intentionally
# excluded: it requires the optional, not-vendored mcp-server-tools package.
compile:
	@for module in $(MODULES); do \
		echo "=== $$module ==="; \
		$(EMACS) --batch -Q -L . --eval "(byte-compile-file \"$$module\")" || exit 1; \
	done
	@$(MAKE) clean

# Opt-in suite exercising a real installed embedding model. Not part of
# `test`; see ROADMAP.md phase 1.
test-model:
	@echo "test-model: no semantic backend implemented yet (see ROADMAP.md phase 1)"
	@exit 1

clean:
	rm -f *.elc semantic/*.elc
	find . -name "__pycache__" -type d -exec rm -rf {} +
