# NOTICE

This repository contains a derivative of **Aave v3.2**.

## Lineage

1. **Aave v3.x** — original protocol by Aave DAO / BGD Labs, licensed BUSL 1.1 with an Additional Use Grant. See `LICENSE`.
2. **HyperLend** — a [friendly fork](https://governance.aave.com/t/arfc-recognize-hyperlend-as-a-friendly-fork/) of Aave v3.2. Some identifiers in git history and deployed token names still use that brand.
3. **Lumina** — current product name. New listings and documentation should say Lumina, not HyperLend. Lending contracts run on a public EVM (Base Sepolia `84532` in development). Lighter is a separate REST/WebSocket trading domain.

## Additional Use Grant

Production use of the Licensed Work is limited by the Additional Use Grant in `LICENSE`, including (non-exhaustively):

- do not use this code to migrate users or funds out of the Aave ecosystem;
- do not omit attribution to Aave;
- do not use the work in a way that harms the Aave ecosystem or brand.

Operators must confirm they satisfy those terms (and any Aave DAO authorization records on `v31.aavelicense.eth`) before a public mainnet launch. This NOTICE is documentation, not legal advice or a waiver.

## What this file does not change

- SPDX `BUSL-1.1` headers stay on protocol source.
- Already-deployed aToken / debt-token names on Base Sepolia are not renamed by this commit.
- Isolated pair contracts are a FraxLend V3 derivative; see `lumina-isolated` NOTICE.
