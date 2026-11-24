# CheesePad vault contracts

Solidity source of the CheesePad vault and token contracts, for developers who build custom vaults
on CheesePad. How vaults work, the launch checks, and the factory addresses are in the
[Vaults](https://docs.cheesepad.ai/docs/developers/launchpad/vaults) and
[Building a custom vault](https://docs.cheesepad.ai/docs/developers/launchpad/custom-vault) docs.

## Build

Requires Node.js 18 or later.

```bash
npm install
npm run build
```

Solidity `0.8.28`, optimizer on, 200 runs, with OpenZeppelin Contracts `5.3.0` and Contracts
Upgradeable `5.6.1`.

## What is here

| Path | Contents |
| --- | --- |
| `contracts/launchpad/vaults/` | The vault base contracts and interfaces (`VaultBase`, `VaultFactoryBase`, `IVault`, `IVaultFactory`, `IVaultSchema`, `LibLaunchData`), and `SplitterVault` and `GiftVault` with their factories |
| `contracts/examples/` | `SingleRecipientVault`, the example vault and factory from the docs |
| `contracts/token/` | The tokens the launchpad mints: `CheeseToken`, `CheeseTaxToken`, and `CheeseTaxTokenV2` with its tax processor, dividend tracker, and swap router |
| `contracts/interfaces/`, `contracts/launchpad/libraries/` | Interfaces and libraries the files above import |

## License

MIT. See [LICENSE](LICENSE).
