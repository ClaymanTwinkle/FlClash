# SQLite amalgamation

The Android build compiles SQLite from this source instead of letting the
`sqlite3` package download its prebuilt `libsqlite3.so` from GitHub
(see `hooks.user_defines.sqlite3` in `pubspec.yaml`). Other platforms keep the
package default.

| | |
|---|---|
| Version | 3.54.1 |
| Source | https://sqlite.org/2026/sqlite-amalgamation-3540100.zip |
| Zip SHA3-256 (as published on https://sqlite.org/download.html) | `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` |
| `sqlite3.c` SHA-256 | `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52` |
| `sqlite3.h` SHA-256 | `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c` |

Only `sqlite3.c` and `sqlite3.h` are kept from the zip, unmodified.

## Updating

1. Take the `sqlite-amalgamation-*.zip` line from the product data at the bottom
   of https://sqlite.org/download.html and download that zip.
2. Check its SHA3-256 against the published one, for example
   `python3 -c "import hashlib,sys;print(hashlib.sha3_256(open(sys.argv[1],'rb').read()).hexdigest())" <zip>`.
3. Replace `sqlite3.c` and `sqlite3.h`, then update the table above.
