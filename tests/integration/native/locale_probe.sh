#!/usr/bin/env bash
set -euo pipefail
NVIM=${NVIM_BIN:-nvim}
printf 'E1_ENV LANG=%s LC_ALL=%s LC_MESSAGES=%s\n' "${LANG-}" "${LC_ALL-}" "${LC_MESSAGES-}"
printf 'E1_LOCALES\n'
locale -a | sed 's/^/E1_LOCALE /'
exe=$(command -v "$NVIM")
prefix=$(dirname -- "$(dirname -- "$(readlink -f "$exe")")")
mo="$prefix/share/locale/zh_CN.UTF-8/LC_MESSAGES/nvim.mo"
if [[ -f "$mo" ]]; then
  printf 'E1_MO=%s\n' "$mo"
  msgunfmt "$mo" >"$NVIM_ZH_TMP/nvim-mo.po"
  if grep -q 'msgstr "当前的 %s语言' "$NVIM_ZH_TMP/nvim-mo.po"; then
    printf 'E1_MO_READABLE=yes known_translation=present
'
  else
    printf 'E1_MO_READABLE=FAIL known translation absent
' >&2
    exit 1
  fi
else
  printf 'E1_MO=missing:%s\n' "$mo"
fi
current=$("$NVIM" --headless -u NONE '+language messages' +qa 2>&1)
printf 'E1_CURRENT=%s\n' "$current"
attempt=$("$NVIM" --headless -u NONE '+language messages zh_CN.UTF-8' '+language messages' +qa 2>&1 || true)
printf 'E1_DIRECT=%s\n' "$attempt"
if [[ "$attempt" == *E197* ]]; then
  printf 'E1_DIRECT_STATUS=UNAVAILABLE (locale not installed)\n'
elif [[ "$attempt" == *当前的* ]]; then
  printf 'E1_DIRECT_STATUS=AVAILABLE\n'
else
  printf 'E1_DIRECT_STATUS=UNKNOWN\n'
fi
# Positive control without changing the host: generate a temporary glibc locale
# and ask glibc to use it through LOCPATH.
if command -v localedef >/dev/null && [[ -r /usr/share/i18n/locales/zh_CN && -f "$mo" ]]; then
  mkdir -p "$NVIM_ZH_TMP/locale"
  if localedef -i zh_CN -f UTF-8 "$NVIM_ZH_TMP/locale/zh_CN.UTF-8" >"$NVIM_ZH_TMP/localedef.log" 2>&1; then
    positive=$(LOCPATH="$NVIM_ZH_TMP/locale" LC_ALL=zh_CN.UTF-8 "$NVIM" --headless -u NONE '+language messages' +qa 2>&1)
    printf 'E1_TEMP_LOCALE=%s\n' "$positive"
    if [[ "$positive" != *当前的* ]]; then
      printf 'E1_TEMP_STATUS=FAIL (native Chinese probe did not translate)\n' >&2
      exit 1
    fi
    printf 'E1_TEMP_STATUS=PASS\n'
  else
    printf 'E1_TEMP_STATUS=UNAVAILABLE (localedef failed; see temporary log during debugging)\n'
  fi
else
  printf 'E1_TEMP_STATUS=SKIP (localedef, locale source, or MO unavailable)\n'
fi
