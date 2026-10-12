" Autoload-style entry points of upstream vim-fugitive that statusline
" plugins call directly. Backed by lua/nvim-fugitive/api.lua.

function! fugitive#Head(...) abort
  return v:lua.require'nvim-fugitive.api'.head(get(a:, 1, 0), get(a:, 2, v:null))
endfunction

function! fugitive#Statusline(...) abort
  return v:lua.require'nvim-fugitive.api'.statusline()
endfunction

function! fugitive#statusline(...) abort
  return v:lua.require'nvim-fugitive.api'.statusline()
endfunction

function! fugitive#Find(object, ...) abort
  return v:lua.require'nvim-fugitive.api'.find(a:object, get(a:, 1, v:null))
endfunction

function! fugitive#Real(...) abort
  return v:lua.require'nvim-fugitive.api'.real(get(a:, 1, bufname('')))
endfunction
