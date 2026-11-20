" Optional errorformat for the standard clang-tidy text output.
if exists('current_compiler')
  finish
endif
let current_compiler = 'nvim-zh-clang-tidy'
let s:cpo_save = &cpo
set cpo&vim
CompilerSet errorformat=%f:%l:%c:\ %trror:\ %m,
      \%f:%l:%c:\ %tatal\ error:\ %m,
      \%f:%l:%c:\ %tarning:\ %m,
      \%f:%l:%c:\ %tote:\ %m,
      \%f:%l:%c:\ %temark:\ %m,
      \%f:%l:\ %trror:\ %m,
      \%f:%l:\ %tarning:\ %m,
      \%f:%l:\ %tote:\ %m,
      \%f:\ %trror:\ %m,
      \%f:\ %tarning:\ %m,
      \%f:\ %tote:\ %m,
      \%+G%.%#
let &cpo = s:cpo_save
unlet s:cpo_save
