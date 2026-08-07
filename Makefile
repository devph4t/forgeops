#!/usr/bin/env make
# Convenience wrapper around the local dev scripts in ./_scripts. See
# _scripts/README.md for what each script does; config is read from ./.env
# (see .env.example).

.PHONY: help check start test down restart clean admin-password prereqs-manual

# wrapper to the docker/cli-tools/repo/Makefile but runs the command in a container for portability
%:
	@docker run --rm \
		-v $(shell pwd):/opt/workspace \
			us-docker.pkg.dev/engineering-devops/images/repo:latest \
				make -f docker/cli-tools/repo/Makefile $@

help:
	@echo "Targets:"
	@echo "  check           verify tools/dependencies are installed and healthy"
	@echo "  start           first-time setup: venv, minikube, prereqs, deploy"
	@echo "  test            smoke-test the running platform"
	@echo "  down            pause: stop minikube + host proxy, keep all data"
	@echo "  restart         resume after 'make down' or a reboot"
	@echo "  clean           tear down namespace + prereqs (ARGS=--full to also delete the minikube profile)"
	@echo "  admin-password  print the amAdmin password"
	@echo "  prereqs-manual  install cert-manager/ingress/secret-agent one at a time (for restricted"
	@echo "                  networks; ARGS=--pull to only cache charts for an offline install)"

check:
	@./_scripts/check.sh

start:
	@./_scripts/startup.sh

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
