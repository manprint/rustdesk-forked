# Builds every image of this repository. `make` or `make help` lists the targets.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# Tag of the built images; the compose files read the same value from RD_TAG in .env.
TAG      ?= local
# Target platform, e.g. PLATFORM=linux/arm64 (needs QEMU/binfmt on the build host).
PLATFORM ?=
# Registry prefix for `make push`, with the trailing slash: REGISTRY=registry.example.com/infra/
REGISTRY ?=
# Output directory of `make save`.
DIST     ?= dist
# Variants for `make e2e` (default: all six), e.g. V="nginx-ssl allinone-ssl"
V        ?=
# Upstream ref for `make sync`.
REF      ?= master

IMAGES   := rustdesk-server-ws rustdesk-allinone
VERSION  := $(shell sed -n 's/^version = "\(.*\)"/\1/p' server/Cargo.toml | head -1)
UPSTREAM := $(shell sed -n 's/^UPSTREAM_COMMIT=//p' server/UPSTREAM)
FORK     := $(shell sed -n 's/^FORK_COMMIT=//p' server/UPSTREAM)
BUILD    := docker build $(if $(PLATFORM),--platform $(PLATFORM)) \
            --label org.opencontainers.image.version=$(VERSION) \
            --label rustdesk.upstream.commit=$(UPSTREAM) \
            --label rustdesk.fork.commit=$(FORK)

.PHONY: help images server allinone smoke save need-registry push test e2e audit sync clean

help: ## list the targets
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'
	@echo "  variables: TAG=$(TAG) PLATFORM=$(PLATFORM) REGISTRY=$(REGISTRY) DIST=$(DIST) V=$(V) REF=$(REF)"

images: server allinone ## build every image

server: ## rustdesk-server-ws:TAG, hbbs + hbbr on scratch (docker-compose.yml)
	$(BUILD) -t rustdesk-server-ws:$(TAG) -f Dockerfile .

allinone: ## rustdesk-allinone:TAG, hbbs + hbbr + nginx, ssl and plain modes (compose.allinone.yml)
	$(BUILD) -t rustdesk-allinone:$(TAG) -f Dockerfile.allinone .

smoke: allinone ## quick check of rustdesk-allinone:TAG (healthy, WebSocket upgrade), the one the CI runs
	scripts/smoke-allinone.sh rustdesk-allinone:$(TAG)

save: images ## export the images to DIST/*.tar.gz for `docker load` on another host
	mkdir -p $(DIST)
	for i in $(IMAGES); do docker save $$i:$(TAG) | gzip > $(DIST)/$$i-$(TAG).tar.gz; done
	cd $(DIST) && sha256sum $(addsuffix -$(TAG).tar.gz,$(IMAGES)) > SHA256SUMS-$(TAG)

need-registry:
	@test -n "$(REGISTRY)" || { echo "set REGISTRY=registry.example.com/path/"; exit 2; }

push: need-registry images ## tag and push the images to REGISTRY
	for i in $(IMAGES); do docker tag $$i:$(TAG) $(REGISTRY)$$i:$(TAG); docker push $(REGISTRY)$$i:$(TAG); done

test: ## unit tests of server/ in the pinned Rust image
	scripts/cargo.sh test --locked

e2e: ## end-to-end and stability suite (builds what it needs), V="variant ..."
	test/e2e/run.sh $(V)

audit: ## known vulnerabilities in server/Cargo.lock
	scripts/cargo.sh audit

sync: ## merge upstream rustdesk-server REF into server/
	scripts/sync-upstream.sh $(REF)

clean: ## remove the built images, the e2e leftovers, the cargo cache volumes and DIST
	-docker compose -f test/e2e/docker-compose.test.yml down -v --remove-orphans 2>/dev/null
	-docker image rm $(addsuffix :$(TAG),$(IMAGES)) rd-e2e-tester:local rd-e2e-client:local 2>/dev/null
	-docker volume rm rustdesk-cargo-home rustdesk-cargo-bin rustdesk-cargo-target 2>/dev/null
	rm -rf $(DIST)
