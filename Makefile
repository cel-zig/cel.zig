# Convenience entrypoints. build.zig remains the source of truth.

.PHONY: test test-conformance test-conformance-suite fuzz bench coverage conformance-refresh conformance-sync

CONFORMANCE_TOOL_DIR := tools/conformance
CONFORMANCE_CACHE_DIR := .cache/conformance
CONFORMANCE_SPEC_DIR := .cache/cel-spec/tests/simple/testdata
CONFORMANCE_SUITES := basic bindings_ext encoders_ext conversions fields fp_math \
	integer_math lists logic macros macros2 namespace plumbing string \
	string_ext math_ext timestamps wrappers dynamic type_deduction optionals \
	comparisons parse network_ext enums block_ext proto2 proto3 proto2_ext

test:
	zig test src/cel.zig -lc

test-conformance:
	zig build test-conformance

test-conformance-suite:
	@test -n "$(SUITE)" || (echo "usage: make test-conformance-suite SUITE=parse" && exit 1)
	zig test test/conformance.zig -lc --test-filter "$(SUITE)"

fuzz:
	@test -n "$(TARGET)" || (echo "usage: make fuzz TARGET=lexer|parser|eval" && exit 1)
	zig test src/cel.zig -lc -ffuzz --test-filter "fuzz $(TARGET)"

bench:
	zig build
	./zig-out/bin/cel-perf

coverage:
	docker build -f Dockerfile.coverage -t cel-coverage . -q
	rm -rf coverage
	docker run --rm -v "$(PWD):/cel" cel-coverage bash -c '\
		set -e && \
		cd /cel && \
		echo "[1/6] Building unit test binary..." && \
		zig test src/cel.zig -lc --test-no-exec -femit-bin=bin_unit 2>/dev/null && \
		echo "[2/6] Running unit tests under kcov..." && \
		kcov --skip-solibs --include-pattern=/cel/src /cel/coverage bin_unit >/dev/null 2>&1; \
		if [ -d .cache/conformance ]; then \
			echo "[3/6] Building conformance binary..." && \
			zig test --dep cel -Mroot=test/conformance.zig -Mcel=src/cel.zig -lc --test-no-exec -femit-bin=bin_conf 2>/dev/null && \
			echo "[4/6] Running 2454 conformance tests under kcov..." && \
			kcov --skip-solibs --include-pattern=/cel/src /cel/coverage bin_conf >/dev/null 2>&1; \
		else \
			echo "[3/6] Skipping conformance (no .cache/conformance)" && \
			echo "[4/6] Skipping conformance"; \
		fi && \
		echo "[5/6] Building fuzz smoke binary..." && \
		zig test --dep cel -Mroot=test/fuzz.zig -Mcel=src/cel.zig -lc --test-no-exec -femit-bin=bin_fuzz 2>/dev/null && \
		echo "[6/6] Running fuzz smoke tests under kcov..." && \
		kcov --skip-solibs --include-pattern=/cel/src /cel/coverage bin_fuzz >/dev/null 2>&1; \
		rm -f bin_unit bin_conf bin_fuzz'
	@python3 -c "import json,glob; \
		f=glob.glob('coverage/kcov-merged/coverage.json'); \
		f=f[0] if f else glob.glob('coverage/*/coverage.json')[0]; \
		d=json.load(open(f)); \
		print(f'Coverage: {d[\"percent_covered\"]}%% ({d[\"covered_lines\"]}/{d[\"total_lines\"]} lines)')"
	@echo "HTML report: open coverage/index.html"

conformance-sync:
	@if [ -d $(CONFORMANCE_SPEC_DIR)/../../.. ]; then \
		echo "updating cel-spec..."; \
		cd .cache/cel-spec && git pull --ff-only; \
	else \
		echo "cloning cel-spec..."; \
		mkdir -p .cache; \
		git clone --depth 1 https://github.com/google/cel-spec.git .cache/cel-spec; \
	fi

conformance-refresh: conformance-sync
	cd $(CONFORMANCE_TOOL_DIR) && go run . --descriptors-output ../../$(CONFORMANCE_CACHE_DIR)/descriptors.json
	@set -e; \
	for suite in $(CONFORMANCE_SUITES); do \
		echo "refreshing $$suite"; \
		cd $(CONFORMANCE_TOOL_DIR) && go run . \
			--input ../../$(CONFORMANCE_SPEC_DIR)/$$suite.textproto \
			--output ../../$(CONFORMANCE_CACHE_DIR)/$$suite.json; \
	done
