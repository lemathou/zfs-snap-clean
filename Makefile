COMPLETION_DIR ?= /etc/bash_completion.d

install-completion:
	install -m 644 completion/zfs-snap-clean $(COMPLETION_DIR)/zfs-snap-clean
	@echo "Completion installed. Reload with: source $(COMPLETION_DIR)/zfs-snap-clean"

uninstall-completion:
	rm -f $(COMPLETION_DIR)/zfs-snap-clean

.PHONY: install-completion uninstall-completion
