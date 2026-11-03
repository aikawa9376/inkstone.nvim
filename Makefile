NVIM ?= nvim

.PHONY: test unit upstream bench reference terminal raster raster-test

test:
	$(NVIM) --headless --clean -u NONE -l tests/run.lua

unit:
	NVIM="$(NVIM)" python3 scripts/test_upstream.py tests/unit

upstream:
	NVIM="$(NVIM)" python3 scripts/test_upstream.py tests

bench:
	$(NVIM) --headless --clean -u NONE -l benchmarks/run.lua

reference:
	$(NVIM) --headless --clean -u NONE -l tests/viewport_reference.lua

terminal:
	kitty +runpy 'import runpy; runpy.run_path("tests/terminal_compat.py", run_name="__main__")'

raster:
	cargo build --locked --release --manifest-path native/Cargo.toml

raster-test:
	cargo test --locked --manifest-path native/Cargo.toml
