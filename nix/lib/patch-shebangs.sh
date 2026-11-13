# Bun binary lockfiles start with #! but their serialized offsets depend on
# the original header length. Patch executable scripts without rewriting them.
patchBunShebangs() {
    local script
    while IFS= read -r -d '' script; do
        patchShebangs --build "$script"
    done < <(find "$@" -type f -perm -0100 ! -name '*.lockb' -print0)
}
