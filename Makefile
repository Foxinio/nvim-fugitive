DEPS    ?= .deps
NVIM    ?= nvim
PLENARY := $(DEPS)/plenary.nvim
INIT    := tests/minimal_init.lua
BUSTED   = $(NVIM) --headless --noplugin -u $(INIT) -c "PlenaryBustedDirectory $(1) {minimal_init = '$(INIT)', sequential = true, timeout = 60000}"

.PHONY: test unit integration parity lint format deps clean

test: unit integration

unit: deps
	$(call BUSTED,tests/unit)

integration: deps
	$(call BUSTED,tests/integration)

# Upstream parity harness (M0/M1 only): needs a checkout of tpope/vim-fugitive.
UPSTREAM ?= ../vim-fugitive
parity: deps
	UPSTREAM=$(abspath $(UPSTREAM)) $(call BUSTED,tests/parity)

lint:
	stylua --check lua plugin tests
	selene lua plugin
	lua-language-server --check . --checklevel=Warning

format:
	stylua lua plugin tests

deps: $(PLENARY)

$(PLENARY):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

clean:
	rm -rf $(DEPS) .tests
