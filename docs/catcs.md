# catcs

Prints every `.cs` file in a folder, without its subfolders, with any UTF-8 byte order mark stripped.

```bash
catcs [dir]     # contents of every .cs file in dir (non-recursive), BOMs stripped
```

`catcsc` does the same and copies the result to the clipboard.
