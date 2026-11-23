.DEFAULT_GOAL := test

.PHONY: test lint e2e mutants mutants-mac

# Host-only tests: no containers, no network; safe on any Mac (and Linux)
test:
	@zsh ./tests/unit_test.zsh

# Real-Mac end-to-end tests with Apple container (SECTIONS=run,egress to pick some)
e2e:
	@zsh ./tests/mac_e2e_test.zsh $(if $(SECTIONS),--only $(SECTIONS))

# Break the code on purpose and check the tests notice (unit: fast; mac: slow, needs a Mac)
mutants:
	@zsh ./tests/mutants.zsh --unit

mutants-mac:
	@zsh ./tests/mutants.zsh --mac

lint:
	@echo "Checking zsh syntax..."
	@zsh -n bin/agent-shadow
	@zsh -n install.sh
	@for f in lib/agent-shadow/*.zsh tests/*.zsh; do zsh -n "$$f" || exit 1; done
	@zsh -n completions/_agent-shadow
	@echo "All files passed syntax validation."
