# docker compose watch demo. `make help` lists targets.
COMPOSE ?= docker compose
PORT    ?= $(or $(GATEWAY_PORT),8090)

.DEFAULT_GOAL := help
.PHONY: help up start watch demo status logs open down clean

help: ## List targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

up: ## Build, start and watch in the foreground (Ctrl-C stops watching AND the containers)
	$(COMPOSE) up --build --watch

start: ## Build and start detached, no watching
	$(COMPOSE) up -d --build --wait

watch: ## Watch an already running stack (Ctrl-C leaves containers running)
	$(COMPOSE) watch --no-up

demo: ## Hands-free tour: edits every watched file, verifies the effect, restores
	./scripts/demo.sh

status: ## Containers and a quick check of each endpoint
	@$(COMPOSE) ps -a
	@echo; curl -fsS http://localhost:$(PORT)/ | grep -o '<p id="message">.*</p>' || true
	@curl -fsSI http://localhost:$(PORT)/ | grep -i x-demo-banner || true
	@curl -fsS http://localhost:$(PORT)/api/ | grep -E '"greeting"|"started"' || true
	@curl -fsS http://localhost:$(PORT)/notes/ | grep -o 'build #[0-9]*' || true

logs: ## Follow all logs
	$(COMPOSE) logs -f

down: ## Stop and remove containers (keeps volume and images)
	$(COMPOSE) down --remove-orphans

clean: ## Remove containers, the project's images and named volumes
	$(COMPOSE) down --volumes --rmi local --remove-orphans
