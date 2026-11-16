#!/bin/zsh

set -euo pipefail

source "${0:A:h}/local-bundle-transaction.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/sentencealong-install-check.XXXXXX")
trap '/bin/rm -rf "$root"' EXIT
mkdir -p "$root/source/SentenceAlong.app" "$root/target"
source_bundle="$root/source/SentenceAlong.app"
destination="$root/target/SentenceAlong.app"
print new > "$source_bundle/marker"

verify_staged_bundle() { [[ "$failure" != validation ]] }
prepare_for_swap() { : }
activate_bundle() { [[ "$failure" != activation && "$failure" != restoration ]]; }
undo_new_activation() { print undone >> "$root/log"; }
restore_registration() { print restored >> "$root/log"; }
mv() {
  if [[ "$failure" == move && "$1" == */.sentencealong-install.*/SentenceAlong.app ]]; then return 65; fi
  if [[ "$failure" == restoration && "$1" == */Previous.app ]]; then return 65; fi
  command mv "$@"
}

for failure in validation move activation; do
  mkdir -p "$destination"
  print old > "$destination/marker"
  if ( set -e; replace_local_bundle "$source_bundle" "$destination" ); then
    echo "Unexpected success: $failure" >&2
    exit 1
  fi
  [[ "$(cat "$destination/marker")" == old ]]
done
[[ "$(grep -c restored "$root/log")" == 2 ]]
[[ "$(grep -c undone "$root/log")" == 1 ]]

/bin/rm -rf "$destination"
failure=activation
if ( set -e; replace_local_bundle "$source_bundle" "$destination" ); then
  echo "Unexpected success for failed first install" >&2
  exit 1
fi
[[ ! -e "$destination" ]]
failure=none
replace_local_bundle "$source_bundle" "$destination"
[[ "$(cat "$destination/marker")" == new ]]
failure=restoration
if replace_local_bundle "$source_bundle" "$destination"; then
  echo "Unexpected success after restoration was prevented" >&2
  exit 1
fi
backups=("$root/target"/.sentencealong-install.*/Previous.app/marker(N))
[[ ${#backups} -eq 1 && "$(cat "$backups[1]")" == new ]]
echo "Local installation transaction checks passed"
