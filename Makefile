DEPS    ?= .deps
NVIM    ?= nvim
PLENARY := $(DEPS)/plenary.nvim
# optional: telescope tests are pending without it
TELESCOPE := $(DEPS)/telescope.nvim
INIT    := tests/minimal_init.lua
BUSTED   = $(NVIM) --headless --noplugin -u $(INIT) -c "PlenaryBustedDirectory $(1) {minimal_init = '$(INIT)', sequential = true, timeout = 60000}"

.PHONY: test unit integration parity lint format deps clean

test: unit integration

unit: deps
	$(call BUSTED,tests/unit)

integration: deps
	$(call BUSTED,tests/integration)

# Upstream parity harness (M0/M1 only): needs a checkout of tpope/vim-fugitive.
# UPDATE_FIXTURES=1 rewrites tests/fixtures/browse_upstream.json.
UPSTREAM ?= ../vim-fugitive
parity: deps
	UPSTREAM=$(abspath $(UPSTREAM)) FIXTURES=$(abspath tests/fixtures) $(call BUSTED,tests/parity)

lint:
	stylua --check lua plugin tests
	selene lua plugin
	lua-language-server --check . --checklevel=Warning

format:
	stylua lua plugin tests

deps: $(PLENARY) $(TELESCOPE)

$(PLENARY):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

$(TELESCOPE):
	git clone --depth 1 https://github.com/nvim-telescope/telescope.nvim $(TELESCOPE)

clean:
	rm -rf $(DEPS) .tests
