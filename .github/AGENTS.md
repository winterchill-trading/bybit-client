# AGENTS.md (.github/)

`workflows/ci.yml` builds and tests this repository with the `ox-setup` action. Its `pins:` block
lists the sibling repositories in dependency order, including `bybit-sim` (test-only). Keep it in
sync with `dune-project`. The `obj-magic` job calls the shared reusable workflow from `infra`.
