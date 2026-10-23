# Spark Prime Vault Deployment

Deployment of the Spark Prime Vault, its two PAUs and the PAS on Ethereum mainnet.

What gets deployed from one config file:

| Component | Notes |
| --- | --- |
| `SparkPrimeVault` implementation + ERC1967 proxy | Wraps spUSDC (Spark Savings Vault V2). |
| `spPrimePAU` (taker PAU) | AccessControls, ALMProxy, RateLimits, Controller from the existing Spark `PAUFactory`, hence bound to the existing Spark Beacon. Its ALMProxy holds `TAKER_ROLE` on the vault. |
| `flcPAU` (first-loss capital PAU) | Same stack. Transfers USDC to the taker PAU's ALMProxy. |
| PAS | BeamState, Configurator, Timelock. The Configurator is admin of both PAUs' AccessControls and RateLimits. |

Not deployed: the `AdministeredAgent`. Both PAUs grant `ALLOCATOR_ROLE` to the existing mainnet
agent given in the config.

## Layout

```
deploy/SparkPrimeVaultDeployer.sol   deployment logic: Config struct in, Instance struct out
script/Deploy.s.sol                  thin broadcast wrapper: fork, env, JSON in, JSON out
script/input/<chainId>/              deployment configs
test/TestBase.t.sol                  local stand-ins for every mainnet dependency
test/DeploymentAssertions.sol        exact-value checks of an Instance against its Config
test/Deployment.t.sol                configuration tests (no fork)
test/fork/DeployScript.t.sol         dry run of the real script on a mainnet fork
```

`SparkPrimeVaultDeployer` has no forge-std base contract and reads no files or env vars. The
script and the tests call the same `_deploy(deployer, config)`; the deployer address is the
broadcaster in the script and a pranked EOA in tests, so the sequence of calls, the resulting
state and even the CREATE addresses (given the same starting nonce) are identical.

The deployer is a temporary admin everywhere and holds no role after `_deploy` returns unless
it is explicitly listed as a final admin in the config.

## Config

`script/input/1/deploy-spark-prime-vault-production.json`. Rate limits are listed per PAU with
an `integrationId` discriminator. Destinations and Spark vaults may be a literal address or one
of the symbolic references `spPrime` and `spPrimePAUAlmProxy`, resolved after deployment. All
`slope` values are per day.

## Testing before deploying

```bash
forge test
```

The local suite deploys USDC, spUSDC, a Beacon with the three facets, a `PAUFactory` and an
`AdministeredAgent`, substitutes only those addresses into the production JSON and runs the full
deployment plus assertions. With `MAINNET_RPC_URL` set, `DeployScriptForkTest` additionally runs
the real script (with file output disabled) on a mainnet fork against the real factory, beacon,
agent and spUSDC, and applies the same assertions.

## Deploying

```bash
ENV=production CHAIN=mainnet forge script script/Deploy.s.sol:DeploySparkPrimeVault \
    --rpc-url $MAINNET_RPC_URL --sender <deployer> --broadcast --verify ...
```

Drop `--broadcast` for a simulation. Deployed addresses are written to `script/output/1/`.

## Using from another repository

Add this repository as a submodule and inherit the pieces you need:

```solidity
import { SparkPrimeVaultDeploymentTestBase }   from "spark-prime-vault-deployment/test/TestBase.t.sol";
import { SparkPrimeVaultDeploymentAssertions } from "spark-prime-vault-deployment/test/DeploymentAssertions.sol";

contract MyTests is SparkPrimeVaultDeploymentTestBase, SparkPrimeVaultDeploymentAssertions {
    // `instance` and `config` are populated by setUp(); override CONFIG_PATH handling or
    // _deployDependencies() as needed.
}
```

The consumer needs remappings for `forge-std/`, `dss-test/`, `pas/`, `diamond-pau/`,
`pau-administered-agent/`, `spark-prime-vault/` and `spark-vaults-v2/` pointing into this
submodule's `lib/` (see `remappings.txt` here for the context-scoped OpenZeppelin entries), and
`fs_permissions` read access to this submodule's `script/input/` directory.
