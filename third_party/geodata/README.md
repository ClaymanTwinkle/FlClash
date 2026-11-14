# Bundled geodata

`assets/data/` ships the GeoIP, GeoSite and ASN databases that decide which
traffic goes direct and which goes through a proxy. They come from
[MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat), pinned
to one commit of its `release` branch. `geodata.lock` records the commit and the
SHA-256 of every file.

- Update: `tool/update_geodata.sh` takes the current head of `release`, checks
  each file against the digest GitHub lists for it on the `latest` release, then
  rewrites `assets/data/` and `geodata.lock`.
- Verify a checkout: `tool/build_android.sh` refuses to build when a file in
  `assets/data/` no longer matches `geodata.lock`.
