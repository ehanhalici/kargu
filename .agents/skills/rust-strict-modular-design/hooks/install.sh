#!/usr/bin/env bash
# Install the rust-strict-modular-design gate as this repository's pre-commit hook.
# An existing, different pre-commit hook is kept and chained, never overwritten.
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
hooks=$(git rev-parse --git-path hooks)
gate=$(realpath --relative-to="$repo" "$(dirname "$(realpath "$0")")/pre-commit")
target="$hooks/pre-commit"
marker="# rust-strict-modular-design gate"

mkdir -p "$hooks"
if [[ -e $target ]] && grep -qF "$marker" "$target"; then
    echo "already installed: $target"; exit 0
fi
if [[ -e $target ]]; then
    mv "$target" "$target.chained"
    echo "kept existing hook as $target.chained (it runs first)"
fi
cat > "$target" <<HOOK
#!/usr/bin/env bash
$marker
set -euo pipefail
root=\$(git rev-parse --show-toplevel)
if [[ -x "\$(git rev-parse --git-path hooks)/pre-commit.chained" ]]; then
    "\$(git rev-parse --git-path hooks)/pre-commit.chained" "\$@"
fi
exec "\$root/$gate" "\$@"
HOOK
chmod +x "$target"
echo "installed: $target -> $gate"
