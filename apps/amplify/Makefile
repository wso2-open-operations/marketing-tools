# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
# Local stack (plan M8a). Run from apps/amplify.
#   make up       build images, generate local/.env + dev JWT keys on first run, start the stack
#   make seed     rebuild and rerun Amplify DB Migrate (migrations + seeds, idempotent)
#   make e2e      end-to-end smoke test against the running stack (scripts/e2e-local.sh)
#   make down     stop and remove containers AND volumes
#   make check    descriptor drift + log hygiene + Chat transport (no http client for the webhook) (no PII/tokens/commentary in log calls) + transaction gate (R-13)
#   make test-all unit + IT (postgres:18, mock LinkedIn, DB down) + scheduler IT + e2e; cleans up after
#   make load-test k6 against the running stack: 1k employees / 50k ledger rows, p95 < 50 ms target
#   make up PROFILE=apim   also start WSO2 API Manager (pending the non-prod Asgardeo org)

COMPOSE := scripts/compose.sh $(if $(PROFILE),--profile $(PROFILE))

.PHONY: env up down seed e2e logs ps check test-all load-test

local/.env:
	@cp local/.env.example local/.env
	@for k in POSTGRES_PASSWORD AMPLIFY_API_DB_PASSWORD AMPLIFY_JOBS_DB_PASSWORD AMPLIFY_READONLY_DB_PASSWORD \
	          SCHEDULER_DB_PASSWORD LINKEDIN_CLIENT_SECRET; do \
	  v=$$(openssl rand -hex 16); sed -i.bak "s|^$$k=$$|$$k=$$v|" local/.env; done
	@v=$$(openssl rand -hex 24); sed -i.bak "s|^AMPLIFY_INTERNAL_API_KEY=$$|AMPLIFY_INTERNAL_API_KEY=$$v|" local/.env
	@v=$$(openssl rand -hex 24); sed -i.bak "s|^AMPLIFY_SCHEDULER_API_KEY=$$|AMPLIFY_SCHEDULER_API_KEY=$$v|" local/.env
	@v=$$(openssl rand -hex 24); sed -i.bak "s|^MOCK_ADMIN_KEY=$$|MOCK_ADMIN_KEY=$$v|" local/.env
	@v=$$(openssl rand -base64 32); sed -i.bak "s|^TOKEN_ENCRYPTION_KEY=$$|TOKEN_ENCRYPTION_KEY=$$v|" local/.env
	@rm -f local/.env.bak && chmod 600 local/.env
	@echo "Wrote local/.env with random local-only secrets."

local/dev-jwt/jwks.json:
	@local/dev-jwt/mint-dev-jwt.sh init

# The people-stub mounts this file; if it is missing Docker creates an empty directory in its place and the stub
# answers 500. Gitignored (real names and emails), so a fresh clone starts from the example. Checked on every
# `make env` rather than as a plain file target: make counts an existing directory as an up-to-date target, so
# the leftover empty directory would never be repaired. An existing directory.json is left alone.
.PHONY: people-stub-directory
people-stub-directory:
	@set -e; if [ ! -f local/people-stub/directory.json ]; then \
	  if [ -d local/people-stub/directory.json ]; then \
	    rmdir local/people-stub/directory.json || { \
	      echo "local/people-stub/directory.json is a non-empty directory; move it aside first." >&2; exit 1; }; \
	  fi; \
	  cp local/people-stub/directory.json.example local/people-stub/directory.json; \
	  echo "Wrote local/people-stub/directory.json from the example."; \
	fi

# An existing local/.env predates the internal key: add one rather than failing `make up`.
.PHONY: env-internal-key
env-internal-key: local/.env
	@grep -q '^AMPLIFY_INTERNAL_API_KEY=.' local/.env || { \
	  sed -i.bak '/^AMPLIFY_INTERNAL_API_KEY=/d' local/.env; rm -f local/.env.bak; \
	  echo "AMPLIFY_INTERNAL_API_KEY=$$(openssl rand -hex 24)" >> local/.env; \
	  echo "Added AMPLIFY_INTERNAL_API_KEY to local/.env."; }

# Same for the scheduler-only key (ADR-039, 2026-11-01).
.PHONY: env-scheduler-key
env-scheduler-key: local/.env
	@grep -q '^AMPLIFY_SCHEDULER_API_KEY=.' local/.env || { \
	  sed -i.bak '/^AMPLIFY_SCHEDULER_API_KEY=/d' local/.env; rm -f local/.env.bak; \
	  echo "AMPLIFY_SCHEDULER_API_KEY=$$(openssl rand -hex 24)" >> local/.env; \
	  echo "Added AMPLIFY_SCHEDULER_API_KEY to local/.env."; }

env: local/.env env-internal-key env-scheduler-key env-mock-admin-key local/dev-jwt/jwks.json people-stub-directory

# The mock's admin endpoints are behind an internal key (ADR-039), and the local stack turns the flag on, so a
# .env written before the key existed would leave /mock/posts and /mock/reset answering 404.
.PHONY: env-mock-admin-key
env-mock-admin-key: local/.env
	@grep -q '^MOCK_ADMIN_KEY=.' local/.env || { \
	  sed -i.bak '/^MOCK_ADMIN_KEY=/d' local/.env; rm -f local/.env.bak; \
	  echo "MOCK_ADMIN_KEY=$$(openssl rand -hex 24)" >> local/.env; \
	  echo "Added MOCK_ADMIN_KEY to local/.env."; }

up: env
	$(COMPOSE) up -d --build --wait

seed: env
	$(COMPOSE) run --rm --build amplify-db-migrate

e2e:
	scripts/e2e-local.sh

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps -a

down:
	$(COMPOSE) --profile apim down -v --remove-orphans

check:
	scripts/check-descriptors.sh
	scripts/check-logs-pii.sh
	scripts/check-transaction-gate.sh --self-test
	scripts/check-transaction-gate.sh
	scripts/check-chat-transport.sh

test-all:
	scripts/test-all.sh

load-test:
	scripts/load-test.sh
