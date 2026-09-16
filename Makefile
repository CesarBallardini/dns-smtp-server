# dns-smtp-server -- canonical operator commands.
#
# Everything Ansible runs inside the dockerized controller (ansible/), so the
# same targets work on Windows (Git Bash), Linux, and macOS with only Docker
# and make installed. Config + secrets live in ~/.dns-smtp-server/, mounted
# read-only into the controller at /etc/dns-smtp-server.

.DEFAULT_GOAL := help

ANSIBLE := docker compose -f ansible/docker-compose.yml run --rm ansible
INVENTORY := /etc/dns-smtp-server/inventory.yml
ROLES := os_hardening bind9 opendkim postfix alpine
PLAYBOOKS := oci-vm-create oci-vm-start oci-vm-stop oci-vm-destroy discover host-prep verify dns-check info
SELECTOR ?= s1

.PHONY: help sync ansible-build ansible-selftest shell lint ascii syntax test-roles test-role \
        dkim-keygen smtp-password show-credentials require-deploy-env \
        vm-create vm-prep vm-verify vm-info dns-check vm-start vm-stop vm-destroy clean

help:
	@echo "dns-smtp-server -- common commands"
	@echo ""
	@echo "  Controller + quality:"
	@echo "  make ansible-build     Build the dockerized Ansible controller image"
	@echo "  make ansible-selftest  Run the controller image self-test (goss)"
	@echo "  make shell             Interactive shell in the controller"
	@echo "  make lint              ASCII check + yamllint + ansible-lint"
	@echo "  make syntax            ansible-playbook --syntax-check on every playbook"
	@echo "  make test-roles        molecule test for every role (Docker, ~minutes each)"
	@echo "  make test-role ROLE=bind9   molecule test for one role"
	@echo "  make sync              uv sync the deploy group locally (Linux/macOS editors)"
	@echo ""
	@echo "  Secrets (written to ~/.dns-smtp-server/, never to the repo):"
	@echo "  make dkim-keygen DOMAIN=example.com [SELECTOR=s1]   Generate a DKIM private key"
	@echo "  make smtp-password LOGIN=app@example.com            Generate a submission password"
	@echo "  make show-credentials   PRINTS the mail passwords in clear (local files)"
	@echo ""
	@echo "  Oracle Cloud VM (see README.md):"
	@echo "  make vm-create    Provision VCN + subnet + VM + reserved public IP"
	@echo "  make vm-prep      Configure the VM: hardening, OpenDKIM, Postfix, BIND9 (re-run after config changes)"
	@echo "  make vm-verify    Check the VM from inside (goss) and from the internet (dig, SMTP)"
	@echo "  make vm-info      Show the VM's IP, SSH, and the IMAP/SMTP settings for a mail client"
	@echo "  make dns-check    Query every configured DNS name, on the VM and via a public resolver"
	@echo "  make vm-stop      Stop the VM"
	@echo "  make vm-start     Start the VM"
	@echo "  make vm-destroy   Tear down VM + network (keeps the reserved public IP)"

# ----------------------------------------------------------- controller
ansible-build:
	docker compose -f ansible/docker-compose.yml build

ansible-selftest:
	$(ANSIBLE) goss --gossfile ansible/tests/container.goss.yaml validate

shell:
	$(ANSIBLE)

sync:
	uv sync --group deploy

# ------------------------------------------------------------- quality
# ascii: documentation, comments and code stay 7-bit. Non-ASCII punctuation
# (em dashes, arrows, box drawing) renders unpredictably across terminals,
# locales and editors, so it is rejected outright.
lint: ascii
	$(ANSIBLE) bash -c 'yamllint . && ansible-lint'

ascii:
	@bad=$$(grep -rlP --exclude-dir=.git --exclude-dir=.venv --exclude=uv.lock \
		'[^\x00-\x7F]' . 2>/dev/null); \
	if [ -n "$$bad" ]; then \
		echo "ERROR: non-ASCII characters found in:"; \
		for f in $$bad; do \
			echo "  $$f"; \
			grep -nP '[^\x00-\x7F]' "$$f" | head -3 | sed 's/^/      /'; \
		done; \
		echo "Replace them with ASCII (-- for em dash, -> for arrow, | + - for box drawing)."; \
		exit 1; \
	fi; \
	echo "ascii: all files are 7-bit clean"

syntax:
	MSYS_NO_PATHCONV=1 $(ANSIBLE) bash -c 'set -e; for p in $(PLAYBOOKS); do \
		ansible-playbook -i localhost, --syntax-check ansible/playbooks/$$p.yml; done'

test-roles:
	MSYS_NO_PATHCONV=1 $(ANSIBLE) bash -c 'set -e; for r in $(ROLES); do \
		echo "=== molecule test: $$r"; (cd ansible/roles/$$r && molecule test); done'

test-role:
	@test -n "$(ROLE)" || { echo "ERROR: set ROLE=<one of: $(ROLES)>"; exit 1; }
	MSYS_NO_PATHCONV=1 $(ANSIBLE) bash -c 'cd ansible/roles/$(ROLE) && molecule test'

# ------------------------------------------------------------- secrets
# Both run on the HOST (the controller mounts the config dir read-only) and
# refuse to overwrite: a new DKIM key must be published before it signs, and
# a new password must be given to the client that uses it.
dkim-keygen:
	@test -n "$(DOMAIN)" || { echo "ERROR: set DOMAIN=<domain> [SELECTOR=s1]"; exit 1; }
	@key="$$HOME/.dns-smtp-server/dkim/$(DOMAIN).$(SELECTOR).key"; \
	if [ -e "$$key" ]; then echo "ERROR: $$key already exists (use a new SELECTOR to rotate)"; exit 1; fi; \
	mkdir -p "$$HOME/.dns-smtp-server/dkim" && \
	(umask 077 && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$$key") && \
	chmod 600 "$$key" && echo "Wrote $$key -- back it up with the rest of ~/.dns-smtp-server/"

smtp-password:
	@test -n "$(LOGIN)" || { echo "ERROR: set LOGIN=<login address, e.g. noreply@example.com>"; exit 1; }
	@file="$$HOME/.dns-smtp-server/smtp-users/$(LOGIN)"; \
	if [ -e "$$file" ]; then echo "ERROR: $$file already exists"; exit 1; fi; \
	mkdir -p "$$HOME/.dns-smtp-server/smtp-users" && \
	(umask 077 && openssl rand -base64 30 | tr -d '\r\n' > "$$file") && \
	chmod 600 "$$file" && echo "Wrote $$file -- add the user to postfix_submission_users, then make vm-prep"

# Print the mail logins with their passwords IN CLEAR, straight from the
# local files (nothing is read from the VM, which only stores hashes). Handy
# when setting up a mail client; mind who can see the terminal.
show-credentials:
	@dir="$$HOME/.dns-smtp-server/smtp-users"; \
	if [ ! -d "$$dir" ] || [ -z "$$(ls -A "$$dir" 2>/dev/null)" ]; then \
		echo "No accounts yet. Create one with: make smtp-password LOGIN=<address>"; exit 1; \
	fi; \
	conf="$$HOME/.dns-smtp-server/group_vars/all.yml"; \
	host=$$(sed -n 's/^dnssmtp_mail_hostname: *"\([^"]*\)".*/\1/p' "$$conf"); \
	primary=$$(awk '/^dnssmtp_domains:/ { f = 1 } f && /^[[:space:]]*- name:/ { gsub(/[",]/, "", $$3); print $$3; exit }' "$$conf"); \
	host=$$(printf '%s' "$$host" | sed "s|{{ *dnssmtp_primary_domain *}}|$$primary|"); \
	host=$${host:-<dnssmtp_mail_hostname>}; \
	echo ""; \
	echo "Mail accounts -- IMAP $$host:993 (SSL/TLS) or :143 (STARTTLS)"; \
	echo "                 SMTP $$host:587 (STARTTLS), auth = normal password"; \
	echo ""; \
	printf "%-32s %s\n" "USERNAME" "PASSWORD"; \
	for f in "$$dir"/*; do printf "%-32s %s\n" "$$(basename "$$f")" "$$(cat "$$f")"; done; \
	echo ""; \
	echo "A mailbox (IMAP) is one listed in postfix_mailboxes; the others are send-only."; \
	echo ""

# ------------------------------------------------------------- deploy
# The controller reads inventory + group_vars + secrets from
# ~/.dns-smtp-server/. Without the inventory Ansible silently falls back to
# implicit localhost and does nothing useful, so fail fast instead.
require-deploy-env:
	@if [ ! -f "$$HOME/.dns-smtp-server/inventory.yml" ] || [ ! -f "$$HOME/.dns-smtp-server/group_vars/all.yml" ]; then \
		echo ""; \
		echo "ERROR: ~/.dns-smtp-server/inventory.yml or group_vars/all.yml is missing."; \
		echo ""; \
		echo "  mkdir -p ~/.dns-smtp-server/group_vars"; \
		echo "  cp ansible/inventory.yml.example      ~/.dns-smtp-server/inventory.yml"; \
		echo "  cp ansible/group_vars/all.yml.example ~/.dns-smtp-server/group_vars/all.yml"; \
		echo ""; \
		echo "Then fill it in (docs/config.md explains every setting) -- README.md Phase 0."; \
		echo ""; \
		exit 1; \
	fi

# MSYS_NO_PATHCONV=1 stops Git Bash from rewriting /etc/dns-smtp-server/...
# into a Windows path before docker compose sees it. Harmless elsewhere.
vm-create: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) ansible/playbooks/oci-vm-create.yml

vm-prep: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) ansible/playbooks/host-prep.yml

vm-verify: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) ansible/playbooks/verify.yml

# Read-only diagnostics: they never touch the VM, so they skip the wait for
# SSH -- you run these exactly when something is not answering.
vm-info: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) \
		-e dnssmtp_wait_for_ssh=false ansible/playbooks/info.yml

dns-check: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) \
		-e dnssmtp_wait_for_ssh=false ansible/playbooks/dns-check.yml

vm-stop: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) ansible/playbooks/oci-vm-stop.yml

vm-start: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) ansible/playbooks/oci-vm-start.yml

vm-destroy: require-deploy-env
	MSYS_NO_PATHCONV=1 $(ANSIBLE) ansible-playbook -i $(INVENTORY) ansible/playbooks/oci-vm-destroy.yml

clean:
	rm -rf .venv .cache .ansible
	find . -type d -name .molecule -prune -exec rm -rf {} +
