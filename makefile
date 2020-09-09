MAKEFLAGS += --warn-undefined-variables
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -euc
.DEFAULT_GOAL := build

.PHONY: clean test integration consul etcd run-consul run-etcd example example-consul example-etcd ship dockerfile docker cover lint

IMPORT_PATH := github.com/joyent/containerpilot
VERSION ?= dev-build-not-for-release
LDFLAGS := -X ${IMPORT_PATH}/core.GitHash='$(shell git rev-parse --short HEAD)' -X ${IMPORT_PATH}/core.Version='${VERSION}'

ROOT := $(shell pwd)

DOCKERRUN := docker run --rm \
	--link containerpilot_consul:consul \
	--link containerpilot_etcd:etcd \
	-v ${ROOT}/vendor:/go/src \
	-v ${ROOT}:/cp/src/${IMPORT_PATH} \
	-w /cp/src/${IMPORT_PATH} \
	containerpilot2_build

DOCKERBUILD_LINUX_ARM64 := docker run --rm \
	-e GOOS=linux \
	-e GOARCH=arm64 \
	-e LDFLAGS="${LDFLAGS}" \
	-v ${ROOT}/vendor:/go/src \
	-v ${ROOT}:/cp/src/${IMPORT_PATH} \
	-w /cp/src/${IMPORT_PATH} \
	containerpilot2_build

DOCKERBUILD_LINUX_AMD64 := docker run --rm \
	-e GOOS=linux \
	-e GOARCH=amd64 \
	-e LDFLAGS="${LDFLAGS}" \
	-v ${ROOT}/vendor:/go/src \
	-v ${ROOT}:/cp/src/${IMPORT_PATH} \
	-w /cp/src/${IMPORT_PATH} \
	containerpilot2_build


clean:
	rm -rf build release cover vendor
	docker rmi -f containerpilot2_build > /dev/null 2>&1 || true
	docker rm -f containerpilot_consul > /dev/null 2>&1 || true
	docker rm -f containerpilot_etcd > /dev/null 2>&1 || true
	./scripts/test.sh clean

# ----------------------------------------------
# docker build

# default top-level target
build: build/containerpilot

build/containerpilot:  build/containerpilot2_build */*.go vendor
	mkdir -p ${ROOT}/vendor/bitbucket.org/ww
	cp -pr ${ROOT}/vendor/github.com/adjust/goautoneg ${ROOT}/vendor/bitbucket.org/ww/
	${DOCKERBUILD_LINUX_AMD64} go build -o build/containerpilot_linux_amd64 -ldflags "$(LDFLAGS)"
	${DOCKERBUILD_LINUX_ARM64} go build -o build/containerpilot_linux_arm64 -ldflags "$(LDFLAGS)"
	@rm -rf src || true

# builds the builder container
build/containerpilot2_build:
	mkdir -p ${ROOT}/build
	docker rmi -f containerpilot2_build > /dev/null 2>&1 || true
	docker build -t containerpilot2_build ${ROOT}
	docker inspect -f "{{ .ID }}" containerpilot2_build > build/containerpilot2_build

# shortcut target for other targets: asserts a
# working test environment
docker: build/containerpilot2_build consul etcd

# top-level target for vendoring our packages: glide install requires
# being in the package directory so we have to run this for each package
vendor: build/containerpilot2_build
	${DOCKERBUILD_LINUX_AMD64} glide install

# fetch a dependency via go get, vendor it, and then save into the parent
# package's glide.yml
# usage DEP=github.com/owner/package make add-dep
add-dep: build/containerpilot2_build
	docker run --rm \
		-e LDFLAGS="${LDFLAGS}" \
		-v ${ROOT}:/cp/src/${IMPORT_PATH} \
		-w /cp/src/${IMPORT_PATH} \
		containerpilot2_build \
		bash -c "DEP=$(DEP) ./scripts/add_dep.sh"

# ----------------------------------------------
# develop and test

lint: vendor
	${DOCKERBUILD_LINUX_AMD64} bash ./scripts/lint.sh

# run unit tests and write out test coverage
test: docker vendor
	${DOCKERRUN} bash ./scripts/unit_test.sh

cover: docker
	mkdir -p cover
	${DOCKERRUN} bash ./scripts/cover.sh

# run integration tests
TEST ?= "all"
integration: build
	./scripts/test.sh test $(TEST)

# ------ Backends

# Consul Backend
consul:
	docker rm -f containerpilot_consul > /dev/null 2>&1 || true
	docker run -d -m 256m --name containerpilot_consul \
		consul:latest agent -dev -client 0.0.0.0 -bind=0.0.0.0

# Etcd Backend
etcd:
	docker rm -f containerpilot_etcd > /dev/null 2>&1 || true
	docker run -d -m 256m --name containerpilot_etcd -h etcd quay.io/coreos/etcd:v2.0.8 \
		-name etcd0 \
		-advertise-client-urls http://etcd:2379,http://etcd:4001 \
		-listen-client-urls http://0.0.0.0:2379,http://0.0.0.0:4001 \
		-initial-advertise-peer-urls http://etcd:2380 \
		-listen-peer-urls http://0.0.0.0:2380 \
		-initial-cluster-token etcd-cluster-1 \
		-initial-cluster etcd0=http://etcd:2380 \
		-initial-cluster-state new

release: build
	mkdir -p release
	git tag $(VERSION)
	git push joyent --tags
	cd build && tar -czf ../release/containerpilot-$(VERSION).tar.gz containerpilot
	@echo
	@cd release && sha1sum containerpilot-$(VERSION).tar.gz
	@cd release && sha1sum containerpilot-$(VERSION).tar.gz > containerpilot-$(VERSION).sha1.txt
	@echo Upload files in release/ directory to GitHub release.
