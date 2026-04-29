# Makefile for opencode-voxtral
# Installs wrapper scripts system-wide

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share/opencode-voxtral

SCRIPTS = opencode-voxtral.sh opencode-voxtral-status.sh

.PHONY: all install uninstall clean test

all:
	@echo "Available targets:"
	@echo "  install      - Install scripts to $(BINDIR) (requires sudo)"
	@echo "  uninstall    - Remove installed scripts and clean everything"
	@echo "  clean        - Remove local temporary files"
	@echo "  test         - Check if scripts are valid bash"

install:
	@echo "Installing opencode-voxtral to $(BINDIR)..."
	@mkdir -p $(BINDIR)
	@mkdir -p $(SHAREDIR)
	@# Copy scripts to share dir
	@cp opencode-voxtral.sh $(SHAREDIR)/
	@cp opencode-voxtral-status.sh $(SHAREDIR)/
	@chmod +x $(SHAREDIR)/*.sh
	@# Create symlinks in bin
	@ln -sf $(SHAREDIR)/opencode-voxtral.sh $(BINDIR)/opencode-voxtral
	@ln -sf $(SHAREDIR)/opencode-voxtral-status.sh $(BINDIR)/opencode-voxtral-status
	@echo "✅ Installed successfully!"
	@echo ""
	@echo "Usage:"
	@echo "  opencode-voxtral              # Launch OpenCode with Voxtral"
	@echo "  opencode-voxtral --install    # Install Python dependencies"
	@echo "  opencode-voxtral --status     # Check vLLM status"
	@echo "  opencode-voxtral --help       # Show all options"

uninstall:
	@echo "Uninstalling opencode-voxtral..."
	@echo "This will:"
	@echo "  1. Stop any running vLLM processes"
	@echo "  2. Delete virtual environment at ~/.opencode-voxtral"
	@echo "  3. Delete HuggingFace model cache"
	@echo "  4. Remove installed scripts"
	@echo ""
	@read -p "Are you sure? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		echo "Stopping vLLM..."; \
		pkill -f "vllm serve" 2>/dev/null || true; \
		sleep 2; \
		echo "Deleting virtual environment..."; \
		rm -rf $(HOME)/.opencode-voxtral; \
		echo "Deleting model cache..."; \
		rm -rf $(HOME)/.cache/huggingface/hub/models--mistralai--Voxtral*; \
		rm -rf $(HOME)/.cache/huggingface/hub/models--mlx-community--Voxtral*; \
		echo "Deleting temp files..."; \
		rm -rf /tmp/opencode-voxtral; \
		rm -rf /run/user/*/opencode-voxtral; \
		echo "Removing installed scripts..."; \
		rm -f $(BINDIR)/opencode-voxtral; \
		rm -f $(BINDIR)/opencode-voxtral-status; \
		rm -rf $(SHAREDIR); \
		echo "✅ Uninstalled completely!"; \
	else \
		echo "Uninstall cancelled."; \
	fi

clean:
	@echo "Cleaning local temporary files..."
	@rm -rf /tmp/opencode-voxtral
	@rm -rf /run/user/*/opencode-voxtral
	@echo "✅ Cleaned"

test:
	@echo "Checking script syntax..."
	@bash -n opencode-voxtral.sh && echo "✅ opencode-voxtral.sh: OK"
	@bash -n opencode-voxtral-status.sh && echo "✅ opencode-voxtral-status.sh: OK"

help:
	@echo "opencode-voxtral Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  install      Install system-wide (default: $(PREFIX))"
	@echo "  uninstall    Remove everything including caches"
	@echo "  clean        Clean local temp files"
	@echo "  test         Validate script syntax"
	@echo "  help         Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX       Installation prefix (default: /usr/local)"
	@echo ""
	@echo "Examples:"
	@echo "  sudo make install"
	@echo "  sudo make uninstall"
	@echo "  make test"
