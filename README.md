# Lumina Core (Aave v3.2 derivative)

Lumina's EVM lending pool is a derivative of [Aave v3.2](https://github.com/aave-dao/aave-v3-origin), previously branded as a [HyperLend friendly fork](https://governance.aave.com/t/arfc-recognize-hyperlend-as-a-friendly-fork/). Contracts in this repo target **Base Sepolia (`84532`)** for development. Do not treat Lighter REST as this chain.

See `NOTICE.md` and `LICENSE` (BUSL 1.1 / Additional Use Grant) before any public production deployment.

## Dependencies

- Foundry, [how-to install](https://book.getfoundry.sh/getting-started/installation) (we recommend also update to the last version with `foundryup`)
- Lcov
  - Optional, only needed for coverage testing
  - For Ubuntu, you can install via `apt install lcov`
  - For Mac, you can install via `brew install lcov`

<br>

## Setup

```sh
cp .env.example .env

forge install

# required for tests & linting
npm install
```

<br>

## Tests

- To run the full test suite: `make test`
- To re-generate the coverage report: `make coverage`

<br>

## Documentation

- [Aave v3 technical Paper](./docs/Aave_V3_Technical_Paper.pdf)
- [v3 to v3.0.2 production upgrade](https://github.com/bgd-labs/proposal-3.0.2-upgrade/blob/main/README.md)
- [Aave v3.1 features](./docs/Aave-v3.1-features.md)
- [Aave v3.2 features](./docs/3.2/Aave-v3.2-features.md)
- [v3.1 to v3.2.0 production upgrade](https://github.com/bgd-labs/protocol-3.2.0-upgrade/blob/main/README.md)
- [Set Ltv to 0 on Freeze Feature State diagram](./docs/freeze-ltv0-states.png)

<br>

## Security

Upstream Aave v3.x audit reports are listed below. They cover Aave's code, not Lumina-specific changes or this Base Sepolia deployment.

**Aave v3**

- [ABDK](./audits/27-01-2022_ABDK_AaveV3.pdf)
- [OpenZeppelin](./audits/01-11-2021_OpenZeppelin_AaveV3.pdf)
- [Trail of Bits](./audits/07-01-2022_TrailOfBits_AaveV3.pdf)
- [Peckshield](./audits/14-01-2022_PeckShield_AaveV3.pdf)
- [SigmaPrime](./audits/27-01-2022_SigmaPrime_AaveV3.pdf)
- [Certora](./certora/Aave_V3_Formal_Verification_Report_Jan2022.pdf)

**Aave v3.0.1 / 3.0.2 / 3.1 / 3.2** — see `./audits/` and the [Aave v3 origin README](https://github.com/aave-dao/aave-v3-origin).

This repository is not covered by the Aave Immunefi bounty until Lumina publishes its own program.

## License

See `LICENSE` (BUSL 1.1, Additional Use Grant) and `NOTICE.md`. Interfaces required for integrations remain MIT where marked.
