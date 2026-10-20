# Optional fixup patches

`build.sh` applies every `*.patch` in this directory **after** the main SUSFS
patch, in filename order. Use this when a LineageOS kernel merge changes the
context of the upstream SUSFS patch.

Create them from a patched kernel tree:

```bash
cd ~/.cache/baka-cupid/work/kernel
git diff > /path/to/builder/patches/10-lineage-24.0-fixup.patch
```

Keep fixups small and specific. If the upstream SUSFS branch already supports
the new kernel, delete the fixup instead of keeping it forever.
