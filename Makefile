.PHONY: help install-precommit setup-dev lint lint-actions lint-devspace test test-install test-e2e smoke clean verify

help: ## Display this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

install-precommit: ## Install pre-commit hooks
	@echo "Installing pre-commit..."
	@if ! command -v pre-commit &> /dev/null; then \
		echo "pre-commit not found. Installing via pip..."; \
		pip install pre-commit; \
	fi
	pre-commit install

setup-dev: install-precommit ## Set up development environment
	@echo "Setting up development environment..."
	@if ! command -v helm &> /dev/null; then \
		echo "⚠️  Helm not found. Please install Helm first."; \
		echo "   brew install helm"; \
		exit 1; \
	fi
	@if ! command -v yamllint &> /dev/null; then \
		echo "Installing yamllint..."; \
		pip install yamllint; \
	fi
	@if ! helm plugin list | grep -q unittest; then \
		echo "Installing helm-unittest plugin..."; \
		helm plugin install https://github.com/helm-unittest/helm-unittest; \
	fi
	@echo "✅ Development environment ready!"

lint: ## Run all linting checks
	@echo "Running pre-commit on all files..."
	pre-commit run --all-files

lint-actions: ## Lint GitHub Actions workflows
	@echo "Running actionlint..."
	go run github.com/rhysd/actionlint/cmd/actionlint@latest

lint-devspace: ## Validate DevSpace config syntax and substitution
	@echo "Validating DevSpace config..."
	devspace print --skip-info --disable-profile-activation >/tmp/devspace-starter-pack-devspace.yaml

lint-yaml: ## Run YAML linting only
	@echo "Running yamllint..."
	yamllint .

lint-helm: ## Run Helm linting only
	@echo "Running helm lint on all charts..."
	@find charts -name "Chart.yaml" -exec dirname {} \; | while read chart; do \
		echo "Linting $$chart..."; \
		helm lint "$$chart" --strict; \
	done

test: ## Run all tests
	@echo "Running helm unittest..."
	@find charts -name "Chart.yaml" -exec dirname {} \; | while read chart; do \
		if [ -d "$$chart/tests" ]; then \
			echo "Testing $$chart..."; \
			cd "$$chart" && helm unittest . && cd - > /dev/null; \
		fi \
	done

test-install: ## Run live DevSpace install diagnostics
	CGO_ENABLED=1 go test -count=1 -v -timeout 5m ./tests/install

test-e2e: ## Run full ephemeral-cluster DevSpace e2e validation
	go run ./tests/e2e/cmd/smoke

smoke: test-e2e ## Run expensive smoke validation

clean: ## Clean up generated files
	@echo "Cleaning up..."
	rm -rf charts/*/charts/
	rm -f charts/*/Chart.lock
	rm -f charts/*.tgz
	pre-commit clean

format: ## Auto-format files where possible
	@echo "Auto-formatting files..."
	pre-commit run --all-files || true

verify: lint lint-actions lint-devspace test ## Run CI-equivalent local validation without a cluster

check: verify ## Run all checks

.DEFAULT_GOAL := help
