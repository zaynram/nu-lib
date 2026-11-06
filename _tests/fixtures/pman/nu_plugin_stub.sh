#!/bin/sh
# A stub Nushell plugin for the pman `bump-nu` tests. It speaks just enough of the JSON plugin protocol for
# `plugin add` (Hello, Metadata, an empty Signature) and claims to be built for nushell @VERSION@: the engine refuses
# it when that version is incompatible with its own.
[ "$1" = --stdio ] || exit 2
printf '\004json'
printf '{"Hello":{"protocol":"nu-plugin","version":"@VERSION@","features":[]}}\n'
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"Call":\[\([0-9]*\),.*/\1/p')
  case "$line" in
    *'"Metadata"'*) printf '{"CallResponse":[%s,{"Metadata":{"version":"0.1.0"}}]}\n' "$id" ;;
    *'"Signature"'*) printf '{"CallResponse":[%s,{"Signature":[]}]}\n' "$id" ;;
    *Goodbye*) exit 0 ;;
  esac
done
