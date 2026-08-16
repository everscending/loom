#!/usr/bin/env bash
# Reconcile preserves failed dependency-installer diagnostics.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/test-lib.sh"

# Build 1 #136 reconciled cleanly, then pnpm failed while relinking the merged
# dependency set. `_run_install` discarded both streams, so the merge lane
# could report missing modules but not the actionable pnpm error that caused
# them. Exercise the production reconcile path with one marker on each stream.
RG="$T/reconcile-install-logging"; mkdir -p "$RG"
git -c init.defaultBranch=main init -q --bare "$RG/origin.git"
git clone -q "$RG/origin.git" "$RG/work" 2>/dev/null
git -C "$RG/work" config user.email t@t
git -C "$RG/work" config user.name t
seed_tracker_decl "$RG/work"
echo base > "$RG/work/base"
git -C "$RG/work" add base docs/agents/issue-tracker.md
git -C "$RG/work" commit -qm base
git -C "$RG/work" push -q origin main
git -C "$RG/work" checkout -qb ticket
echo ticket > "$RG/work/ticket"
git -C "$RG/work" add ticket
git -C "$RG/work" commit -qm ticket
git -C "$RG/work" checkout -q main
printf 'lockfileVersion: 9.0\n' > "$RG/work/pnpm-lock.yaml"
git -C "$RG/work" add pnpm-lock.yaml
git -C "$RG/work" commit -qm dependency
git -C "$RG/work" push -q origin main
git -C "$RG/work" checkout -q ticket

cat > "$RG/fail-install.sh" <<'EOF'
#!/usr/bin/env bash
echo "installer stdout detail"
echo "installer stderr detail" >&2
exit 23
EOF
chmod +x "$RG/fail-install.sh"

out=$(cd "$RG/work" && GLAB_CMD=/usr/bin/true \
  LANE_INSTALL_CMD="$RG/fail-install.sh" "$LANE" reconcile 2>&1)
rc=$?
if [ "$rc" = 0 ] \
  && printf '%s' "$out" | grep -q "FAILED" \
  && printf '%s' "$out" | grep -q "installer stdout detail" \
  && printf '%s' "$out" | grep -q "installer stderr detail"; then
  ok "reconcile: failed install preserves stdout and stderr but leaves verdict to gate"
else
  bad "reconcile: failed install gave rc=$rc or lost diagnostics ($(printf '%s' "$out" | tail -3 | tr '\n' ' '))"
fi

test_finish
