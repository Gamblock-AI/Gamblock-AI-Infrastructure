.PHONY: help ping check check-mode lint verify-context deploy deploy-fresh app \
        vault-encrypt vault-decrypt vault-view vault-edit \
        github-secrets github-secrets-dry cloudflare cloudflare-dry \
        ci-init ssh

PLAYBOOK = playbooks/server-setup.yml
INVENTORY = inventory/hosts.ini
OPTS = -i $(INVENTORY)
VAULT_FILE = group_vars/all/vault.yml
LINT_ANSIBLE_CONFIG = $(CURDIR)/ansible-lint.cfg
LINT_VAULT_FILE = $(CURDIR)/group_vars/all/vault.yml.example

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ===== Connection & deploy =====

ping: ## Test connection to the server
	@ansible $(OPTS) all -m ping

check: ## Syntax check the playbook
	@ansible-playbook $(OPTS) $(PLAYBOOK) --syntax-check

check-mode: check ## Simulate the playbook on the configured host (no diff/secrets)
	@ansible-playbook $(OPTS) $(PLAYBOOK) --check

lint: ## Lint playbooks and roles
	@ANSIBLE_CONFIG=$(LINT_ANSIBLE_CONFIG) \
		GAMBLOCK_LINT_MODE=1 \
		GAMBLOCK_LINT_VAULT_FILE="$(LINT_VAULT_FILE)" ansible-lint

verify-context: ## Verify committed AI context files and portability
	@./scripts/verify-ai-context.sh

deploy: check ## Deploy all roles (idempotent)
	@ansible-playbook $(OPTS) $(PLAYBOOK)

deploy-fresh: check ## Fresh deploy (re-run migrations on backend)
	@ansible-playbook $(OPTS) $(PLAYBOOK) -e "run_fresh_migrate=true"

app: check ## Deploy a single app (APP=gamblock-ai-backend|gamblock-ai-website)
	@ansible-playbook $(OPTS) $(PLAYBOOK) --tags application -e "app=$(APP)"

ssh: ## SSH into the server
	@ssh -i ~/.ssh/server_ed25519 deployer@$$(grep -oP '^\d+\.\d+\.\d+\.\d+' $(INVENTORY))

# ===== Vault =====
# Secret file: group_vars/all/vault.yml (encrypted). Never commit the plaintext.
# The vault password lives in .vault_pass (gitignored).

vault-encrypt: ## Encrypt the secret file ($(VAULT_FILE))
	@test -f $(VAULT_FILE) || { echo "Run 'cp group_vars/all/vault.yml.example $(VAULT_FILE)' first"; exit 1; }
	@ansible-vault encrypt $(VAULT_FILE) && echo "Encrypted: $(VAULT_FILE)"

vault-decrypt: ## Decrypt the secret file ($(VAULT_FILE))
	@ansible-vault decrypt $(VAULT_FILE) && echo "Decrypted: $(VAULT_FILE)"

vault-view: ## View the secret file without decrypting on disk
	@ansible-vault view $(VAULT_FILE)

vault-edit: ## Edit the secret file (decrypts in-memory, re-encrypts on save)
	@ansible-vault edit $(VAULT_FILE)

# ===== CI/CD cloud configuration (run locally) =====
# These set GitHub repo secrets/variables + Cloudflare DNS from your group_vars.

ci-init: github-secrets cloudflare ## One-shot: set GitHub secrets + Cloudflare DNS

github-secrets: ## Set GitHub repo secrets + variables (from vault)
	@./scripts/github-secrets.sh

github-secrets-dry: ## Dry-run: show GitHub secrets/variables that would be set
	@./scripts/github-secrets.sh --dry-run

cloudflare: ## Create/update Cloudflare DNS records (from vault)
	@./scripts/cloudflare-dns.sh

cloudflare-dry: ## Dry-run: show Cloudflare records that would be set
	@./scripts/cloudflare-dns.sh --dry-run
