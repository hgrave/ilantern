# Thin wrappers around docker compose. `make help` lists targets.
.DEFAULT_GOAL := help
COMPOSE := docker compose

.PHONY: help install up down restart logs ps occ backup shell upgrade check

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## First-time setup: generate .env, start the stack, install Nextcloud
	./scripts/bootstrap.sh

up: ## Start the stack
	$(COMPOSE) up -d

down: ## Stop the stack (volumes are kept)
	$(COMPOSE) down

restart: ## Recreate the containers
	$(COMPOSE) up -d --force-recreate

logs: ## Follow the application log
	$(COMPOSE) logs -f app

ps: ## Show container status
	$(COMPOSE) ps

occ: ## Run an occ command: make occ ARGS="user:list"
	./scripts/occ $(ARGS)

shell: ## Open a shell in the app container as www-data
	$(COMPOSE) exec --user www-data app bash

backup: ## Snapshot the database and files into backups/
	./scripts/backup.sh

upgrade: ## Pull newer images and run the Nextcloud upgrade
	$(COMPOSE) pull
	$(COMPOSE) up -d
	./scripts/occ upgrade || true
	./scripts/occ db:add-missing-indices
	./scripts/occ maintenance:mimetype:update-db
	./scripts/occ status

check: ## Validate compose file and shell scripts
	$(COMPOSE) config -q
	shellcheck scripts/*.sh scripts/occ config/nextcloud/hooks/before-starting/*.sh
