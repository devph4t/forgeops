#!/usr/bin/env make
# Convenience wrapper around the local dev scripts in ./_scripts. See
# _scripts/README.md for what each script does; config is read from ./.env
# (see .env.example).

.PHONY: help install-deps check start start-step start-manual test down restart clean admin-password prereqs-manual platform-images \
        compose-export compose-generate images-build-export images-import-start

# wrapper to the docker/cli-tools/repo/Makefile but runs the command in a container for portability
%:
	@docker run --rm \
		-v $(shell pwd):/opt/workspace \
			us-docker.pkg.dev/engineering-devops/images/repo:latest \
				make -f docker/cli-tools/repo/Makefile $@

help:
	@echo "Targets:"
	@echo "  install-deps    (Linux) install docker/kubectl/helm/minikube/python3 if missing"
	@echo "  check           verify tools/dependencies are installed and healthy"
	@echo "  start           first-time setup: venv, minikube, prereqs, deploy"
	@echo "  start-step      same as 'start', run step-by-step via _scripts/step-*.sh"
	@echo "  start-manual    same as 'start-step', but cert-manager/traefik/secret-agent are"
	@echo "                  fetched by curl (no Helm repo, no forgeops CLI) - see _scripts/step-manual-*.sh"
	@echo "  test            smoke-test the running platform"
	@echo "  down            pause: stop minikube + host proxy, keep all data"
	@echo "  restart         resume after 'make down' or a reboot"
	@echo "  clean           tear down namespace + prereqs (ARGS=--full to also delete the minikube profile)"
	@echo "  admin-password  print the amAdmin password"
	@echo "  prereqs-manual  install cert-manager/ingress/secret-agent one at a time (for restricted"
	@echo "                  networks; ARGS=--pull to only cache charts for an offline install)"
	@echo "  platform-images load am/idm/ds/ig/amster/UI images into minikube (for restricted networks;"
	@echo "                  ARGS=--pull to only cache images for an offline install)"
	@echo ""
	@echo "docker-compose (alternative to minikube - see _scripts/README.md):"
	@echo "  compose-export      export secrets/config from a working minikube deployment"
	@echo "  compose-generate    turn that export into docker-compose.yaml"
	@echo "  images-build-export build platform images from source, export as tar.gz"
	@echo "  images-import-start import tar.gz images + docker compose up"

install-deps:
	@./_scripts/install-deps.sh $(ARGS)

check:
	@./_scripts/check.sh

start:
	@./_scripts/startup.sh

start-step:
	@./_scripts/start-step.sh

start-manual:
	@./_scripts/start-manual.sh

test:
	@./_scripts/test.sh

down:
	@./_scripts/down.sh

restart:
	@./_scripts/restart.sh

clean:
	@./_scripts/clean.sh $(ARGS)

admin-password:
	@./_scripts/admin-password.sh

prereqs-manual:
	@./_scripts/prereqs-manual.sh $(ARGS)

platform-images:
	@./_scripts/platform-images.sh $(ARGS)

compose-export:
	@./_scripts/compose-export.sh

compose-generate:
	@./_scripts/compose-generate.sh

images-build-export:
	@./_scripts/images-build-export.sh $(ARGS)

images-import-start:
	@./_scripts/images-import-start.sh
