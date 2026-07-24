.PHONY: build test clean

IMAGE   := soundcloud-sync-local
TESTDIR := /tmp/soundcloud-sync-test

# Override on the command line:
#   make test TEST_URL="https://youtu.be/XXXX" TITLE_FILTER="Group Therapy"
TEST_URL      ?=
TITLE_FILTER  ?=
DATE_AFTER    ?=
SPLIT_CHAPTERS ?= true

build:
	docker build -t $(IMAGE) .

test: build
	@[ -n "$(TEST_URL)" ] || { echo "Usage: make test TEST_URL=\"https://youtu.be/VIDEO_ID\""; exit 1; }
	@mkdir -p $(TESTDIR)/music $(TESTDIR)/state
	@rm -f $(TESTDIR)/state/downloaded.txt $(TESTDIR)/state/sync.log
	@echo "=== Syncing $(TEST_URL) ==="
	docker run --rm \
		--user "$(shell id -u):$(shell id -g)" \
		--entrypoint bash \
		-e SOUNDCLOUD_URL="$(TEST_URL)" \
		-e MUSIC_DIR=/music \
		-e STATE_DIR=/state \
		-e AUDIOBOOKSHELF_URL=http://localhost:1 \
		-e AUDIOBOOKSHELF_TOKEN="" \
		-e AUDIOBOOKSHELF_LIBRARY_ID="" \
		-e SPLIT_CHAPTERS="$(SPLIT_CHAPTERS)" \
		-e TITLE_FILTER="$(TITLE_FILTER)" \
		-e DATE_AFTER="$(DATE_AFTER)" \
		-e PLAYLIST_REVERSE="" \
		-v $(TESTDIR)/music:/music \
		-v $(TESTDIR)/state:/state \
		$(IMAGE) \
		/usr/local/bin/soundcloud-sync.sh || true
	@echo ""
	@echo "=== Files ==="
	@find $(TESTDIR)/music -type f | sort || echo "(none)"
	@echo ""
	@echo "=== Metadata ==="
	@docker run --rm \
		--entrypoint bash \
		-v $(TESTDIR)/music:/music \
		$(IMAGE) \
		-c 'find /music -type f \( -name "*.webm" -o -name "*.opus" -o -name "*.m4a" \) \
			| grep -v "\.tmp\." | sort | while read f; do \
			printf "\n  %s\n" "$$(basename "$$f")"; \
			ffprobe -v quiet -print_format json -show_format "$$f" \
			| python3 -c "import json,sys; t=json.load(sys.stdin).get(\"format\",{}).get(\"tags\",{}); print(\"    title:\", t.get(\"title\",\"?\")); print(\"    track:\", t.get(\"track\",t.get(\"TRACKNUMBER\",\"?\")))"; \
		done' || true
	@echo ""
	@echo "=== Sync log ==="
	@cat $(TESTDIR)/state/sync.log || echo "(no log)"

clean:
	docker run --rm -v /tmp:/tmp alpine rm -rf $(TESTDIR) 2>/dev/null; rm -rf $(TESTDIR) 2>/dev/null; true
