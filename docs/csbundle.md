# csbundle

Bundles the `.cs` files of a source tree into one text file per folder, named by the folder's relative path.

```bash
csbundle [-p prefix] [-o outdir] [-d depth] [-n] [srcdir]
```

Concatenates the `.cs` files of each directory under `srcdir` into one `.txt` per directory, named by relative path (`Root.txt`, `Root_Drivers.txt`, `Root_Settings_SubSettings.txt`, ...). Output defaults to `~/cs_bundles/<srcdir name>/`. Each file is preceded by a `// ===== path =====` header unless `-n` is given.

With `-d N`, directories at depth N (srcdir is 0) also absorb everything beneath them, which caps the number of bundles. `-d 0` produces a single file.
