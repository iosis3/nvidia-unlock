# nvidia-patched's updateScript, run from the repository root:
#
#   nix run .#nvidia-patched.updateScript
#
# Adds every release that a checked nixpkgs branch (legacy_580, production,
# beta, new_feature) ships but the P2P patch table in pkgs/nvidia-p2p lacks,
# ported from the nearest older release of the same driver series, or else
# the newest (.#nvidia-patched.portSources): that release's patches re-created
# on the new one's source (.#nvidia-patched.portedPatches.<release>), or copied
# unchanged when they do not apply, so that the release's p2p-patches check
# fails and porting starts from them.  A new entry inherits mixedGeneration.
#
# Drops a release only when no checked nixpkgs branch ships it anymore and two
# newer releases of its driver series are in the table, so a host whose
# nixpkgs is a step behind on any branch still finds its release; never one
# marked `keep = true` (added by hand for a nixpkgs this flake does not follow).

dir=pkgs/nvidia-p2p

die() { echo "update.sh: $*" >&2; exit 1; }
[[ -f $dir/default.nix ]] || die "run from the repository root"

# release -> { mixedGeneration, keep?, patches: file names in order }
table=$(nix eval --json --file "$dir" --apply \
  'builtins.mapAttrs (_: r: r // { patches = map (p: baseNameOf (toString p)) r.patches; })')
checked=$(nix eval --json .#nvidia-patched.passthru.checkedReleases)
sources=$(nix eval --json .#nvidia-patched.passthru.portSources)

mapfile -t missing < <(jq -r 'keys[]' <<<"$sources" | sort -V)
[[ ${#missing[@]} -gt 0 ]] || echo "nvidia-p2p: every checked release is in the table"

for release in "${missing[@]}"; do
  from=$(jq -r --arg r "$release" '.[$r]' <<<"$sources")
  mapfile -t names < <(jq -r --arg r "$from" '.[$r].patches[]' <<<"$table")
  log=$(mktemp)
  if ported=$(nix build --no-link --print-out-paths ".#nvidia-patched.portedPatches.\"$release\"" 2>"$log"); then
    for name in "${names[@]}"; do
      install -m644 "$ported/${name%-"$from".patch}-$release.patch" "$dir/"
    done
    echo "nvidia-p2p: added $release, patches re-created from $from"
  else
    cat "$log" >&2
    # refresh-patches.nix's line for a patch that does not apply; any other
    # failure (network, evaluation) says nothing about the patches, so stop
    # rather than commit them unported
    grep -qF "does not apply to $release" "$log" ||
      die "porting $release from $from failed, but not because a patch does not apply (see above)"
    for name in "${names[@]}"; do
      install -m644 "$dir/$name" "$dir/${name%-"$from".patch}-$release.patch"
    done
    echo "nvidia-p2p: added $release with the $from patches unchanged: they do not apply, port them by hand" >&2
  fi
  rm -f "$log"
  table=$(jq --arg r "$release" --arg n "$from" '
    .[$r] = (.[$n] | del(.keep) | .patches |= map(sub("-" + ($n | gsub("\\."; "\\.")) + "\\.patch$"; "-" + $r + ".patch")))
  ' <<<"$table")
done

mapfile -t releases < <(jq -r 'keys[]' <<<"$table" | sort -V)
kept=()
for release in "${releases[@]}"; do
  newer=0
  for other in "${releases[@]}"; do
    if [[ ${other%%.*} == "${release%%.*}" && $other != "$release" &&
      $(printf '%s\n%s\n' "$release" "$other" | sort -V | tail -n1) == "$other" ]]; then
      newer=$((newer + 1))
    fi
  done
  if ((newer < 2)) || jq -e --arg r "$release" '.[$r].keep // false' <<<"$table" >/dev/null ||
    jq -e --arg r "$release" 'index($r) != null' <<<"$checked" >/dev/null; then
    kept+=("$release")
  else
    jq -r --arg r "$release" '.[$r].patches[]' <<<"$table" | while read -r name; do rm -f "$dir/$name"; done
    table=$(jq --arg r "$release" 'del(.[$r])' <<<"$table")
    echo "nvidia-p2p: dropped $release: no checked nixpkgs branch ships it, two newer ${release%%.*} releases are in the table"
  fi
done

{
  sed -n '1,/^{$/p' "$dir/default.nix" | sed '$d'
  echo '{'
  for release in "${kept[@]}"; do
    printf '  "%s" = {\n' "$release"
    printf '    mixedGeneration = %s;\n' "$(jq -r --arg r "$release" '.[$r].mixedGeneration' <<<"$table")"
    if jq -e --arg r "$release" '.[$r].keep // false' <<<"$table" >/dev/null; then
      echo '    keep = true;'
    fi
    echo '    patches = ['
    jq -r --arg r "$release" '.[$r].patches[] | "      ./" + .' <<<"$table"
    echo '    ];'
    echo '  };'
  done
  echo '}'
} >"$dir/default.nix.new"
mv "$dir/default.nix.new" "$dir/default.nix"
nixfmt "$dir/default.nix"
