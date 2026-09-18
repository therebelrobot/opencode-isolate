REGISTRY := ghcr.io/therebelrobot
PLATFORMS := linux/amd64,linux/arm64

TAG ?= latest
OPENCODE_VERSION ?= latest

.PHONY: release build-local inspect verify

# make release VERSION=1.2.3
# The only thing that cuts a release: pushing the tag triggers
# .github/workflows/release.yml, which builds and publishes all three
# images in lockstep.
release:
	@if [ -z "$(VERSION)" ]; then echo "VERSION is required, e.g. make release VERSION=1.2.3" >&2; exit 1; fi
	git tag -a v$(VERSION) -m "v$(VERSION)"
	git push origin v$(VERSION)

# make build-local IMAGE=gateway|agent|poller
# Local multi-arch build for pre-tag sanity checking. Doesn't push.
build-local:
	@if [ -z "$(IMAGE)" ]; then echo "IMAGE is required: gateway, agent, or poller" >&2; exit 1; fi
	@case "$(IMAGE)" in \
	  gateway) context=./gateway; dockerfile=./gateway/Dockerfile; buildarg="" ;; \
	  agent)   context=.;         dockerfile=./Dockerfile;         buildarg="--build-arg OPENCODE_VERSION=$(OPENCODE_VERSION)" ;; \
	  poller)  context=./poller;  dockerfile=./poller/Dockerfile;  buildarg="" ;; \
	  *) echo "unknown IMAGE: $(IMAGE) (expected gateway, agent, or poller)" >&2; exit 1 ;; \
	esac; \
	docker buildx build --platform $(PLATFORMS) -f "$$dockerfile" $$buildarg "$$context"

# make inspect IMAGE=gateway [TAG=1.2.3]
# Confirm a published image's index has both arches.
inspect:
	@if [ -z "$(IMAGE)" ]; then echo "IMAGE is required: gateway, agent, or poller" >&2; exit 1; fi
	docker buildx imagetools inspect $(REGISTRY)/isolate-opencode-$(IMAGE):$(TAG)

# make verify IMAGE=gateway TAG=1.2.3
# Confirm signed provenance attestation for a published image.
verify:
	@if [ -z "$(IMAGE)" ]; then echo "IMAGE is required: gateway, agent, or poller" >&2; exit 1; fi
	gh attestation verify oci://$(REGISTRY)/isolate-opencode-$(IMAGE):$(TAG) --owner therebelrobot
