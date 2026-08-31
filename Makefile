# cra-evidence — pinned tooling. This Makefile is the SINGLE pin location for
# tool versions (mirrors the source-of-truth toolkit; keep in sync at release).
SYFT_VERSION   := v1.46.0
GRYPE_VERSION  := v0.115.0
COSIGN_VERSION := v3.1.1

# `make tools` installs here (never silently in CI).
TOOLS_DIR := $(CURDIR)/.tools/bin
export PATH := $(TOOLS_DIR):$(PATH)

.PHONY: tools clean

# Installs the pinned versions into .tools/bin. Idempotent: skips a tool
# whose installed version already matches the pin.
tools:
	@mkdir -p $(TOOLS_DIR)
	@if [ "$$($(TOOLS_DIR)/syft version -o json 2>/dev/null | jq -r .version)" = "$(SYFT_VERSION:v%=%)" ]; then \
		echo "syft $(SYFT_VERSION) already installed"; \
	else \
		curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
			| sh -s -- -b $(TOOLS_DIR) $(SYFT_VERSION); \
	fi
	@if [ "$$($(TOOLS_DIR)/grype version -o json 2>/dev/null | jq -r .version)" = "$(GRYPE_VERSION:v%=%)" ]; then \
		echo "grype $(GRYPE_VERSION) already installed"; \
	else \
		curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
			| sh -s -- -b $(TOOLS_DIR) $(GRYPE_VERSION); \
	fi
	@if $(TOOLS_DIR)/cosign version 2>/dev/null | grep -q "$(COSIGN_VERSION:v%=%)"; then \
		echo "cosign $(COSIGN_VERSION) already installed"; \
	else \
		os=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		arch=$$(uname -m); [ "$$arch" = "x86_64" ] && arch=amd64; [ "$$arch" = "aarch64" ] && arch=arm64; \
		curl -sSfL -o $(TOOLS_DIR)/cosign \
			https://github.com/sigstore/cosign/releases/download/$(COSIGN_VERSION)/cosign-$$os-$$arch; \
		chmod +x $(TOOLS_DIR)/cosign; \
	fi
	@echo "tools ready in $(TOOLS_DIR)"

clean:
	rm -rf .tools dist
