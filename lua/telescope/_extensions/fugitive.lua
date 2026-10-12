-- :Telescope fugitive {log,refs,stash}
return require("telescope").register_extension({
  exports = {
    log = function(opts)
      return require("nvim-fugitive.integrations.telescope.pickers").log(opts)
    end,
    refs = function(opts)
      return require("nvim-fugitive.integrations.telescope.pickers").refs(opts)
    end,
    stash = function(opts)
      return require("nvim-fugitive.integrations.telescope.pickers").stash(opts)
    end,
    file_history = function(opts)
      return require("nvim-fugitive.integrations.telescope.pickers").file_history(opts)
    end,
    line_history = function(opts)
      return require("nvim-fugitive.integrations.telescope.pickers").line_history(opts)
    end,
    blame_line = function(opts)
      return require("nvim-fugitive.integrations.telescope.pickers").blame_line(opts)
    end,
    fugitive = function(opts)
      return require("nvim-fugitive.integrations.telescope.pickers").log(opts)
    end,
  },
})
