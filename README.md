# TinyDiamond: Minimal Selector Proxy for Smart Contracts

TinyDiamond is a minimalistic implementation of the Diamond Pattern (EIP-2535). It provides selector-based routing with access control in a lightweight package.

Author: Martin Monperrus - mab.xyz

## Overview

The [Diamond Pattern (EIP-2535)](https://eips.ethereum.org/EIPS/eip-2535) uses a mapping to route function calls to different implementation contracts (called facets) based on their 4-byte function selectors. This allows you to:

- Split functionality across multiple specialized contracts
- Maintain a single entry point with a stable address
- Upgrade individual functions independently
- Bypass the 24KB contract size limit

### How It Works

1. When a function is called on the proxy, the `fallback()` function intercepts it
2. It extracts the function selector (first 4 bytes of calldata)
3. Looks up the target contract address for that selector
4. Optionally checks access restrictions
5. Delegates the call to the target contract using `delegatecall`

TinyDiamond implements the core Diamond principle—the essence, nothing more.

## Installation

```bash
# Using Foundry (forge-std is a git submodule)
git submodule update --init

# Run tests
forge test
```

## Core Interface

```solidity
interface ITinyDiamond {
    /**
     * @notice Set or update the target contract for a specific selector
     * To remove a selector, set the target address to address(0)
     * @param selector The function selector (4 bytes)
     * @param target The target contract address
     */
    function sharpCut(bytes4 selector, address target) external;

    /**
     * @notice Restrict access to a function to a specific authorized address
     * Set to address(0) to remove the restriction
     * @param selector The function selector (4 bytes)
     * @param target The address allowed to call this selector
     */
    function restrict(bytes4 selector, address target) external;
}
```

### Built-in (immutable) functions

`sharpCut`, `restrict`, `admin`, `getTarget`, `selectorToFacet` and `selectorRestriction` are compiled into
the diamond and always win over the fallback. `sharpCut` and `restrict` revert with
`TinyDiamond: immutable function` for these selectors.

### Events

Every selector change emits the standard EIP-2535 `DiamondCut` event, with one `FacetCut` holding the
selector: `Add` (unset → facet), `Replace` (facet → other facet) or `Remove` (facet → unset, facet address 0).
A cut that changes nothing emits nothing. The constructor emits the built-in selectors as `Add` with the
diamond's own address as facet.

```solidity
event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
```

## Usage

### Basic Setup

```solidity
// Deploy TinyDiamond
TinyDiamond diamond = new TinyDiamond();

// Deploy your facet contracts
MyFacet facet1 = new MyFacet();
AnotherFacet facet2 = new AnotherFacet();

// Map function selectors to facets
diamond.sharpCut(MyFacet.myFunction.selector, address(facet1));
diamond.sharpCut(AnotherFacet.anotherFunction.selector, address(facet2));

// Call functions through the diamond
MyFacet(address(diamond)).myFunction();
AnotherFacet(address(diamond)).anotherFunction();
```

### Updating Functions

```solidity
// Deploy new implementation
MyFacetV2 facetV2 = new MyFacetV2();

// Update the selector mapping
diamond.sharpCut(MyFacet.myFunction.selector, address(facetV2));

// Calls now go to the new implementation
MyFacet(address(diamond)).myFunction(); // Uses facetV2
```

### Removing Functions

```solidity
// Remove a function by setting target to address(0)
diamond.sharpCut(MyFacet.myFunction.selector, address(0));

// Calls to this function will now revert
```

### Optional Loupe (Introspection)

`DiamondLoupeFacet` implements EIP-2535 `IDiamondLoupe` and ERC-165 `supportsInterface`. It is optional:
deploy it once and route its five selectors.

```solidity
DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
diamond.sharpCut(IDiamondLoupe.facets.selector, address(loupeFacet));
diamond.sharpCut(IDiamondLoupe.facetFunctionSelectors.selector, address(loupeFacet));
diamond.sharpCut(IDiamondLoupe.facetAddresses.selector, address(loupeFacet));
diamond.sharpCut(IDiamondLoupe.facetAddress.selector, address(loupeFacet));
diamond.sharpCut(IERC165.supportsInterface.selector, address(loupeFacet));

IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
// all[0] is the diamond itself with its built-in selectors
```

The diamond keeps the routed selectors in an array (swap-and-pop on removal, position packed in the
same slot as the facet address), so the loupe can enumerate them whether or not it is installed;
the `fallback` path still reads a single routing slot.

### Optional Batch Upgrades (`diamondCut`)

`DiamondCutFacet` implements EIP-2535 `IDiamondCut`. It is optional: deploy it once and route its selector.

```solidity
DiamondCutFacet cutFacet = new DiamondCutFacet();
diamond.sharpCut(IDiamondCut.diamondCut.selector, address(cutFacet));

IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](2);
cut[0] = IDiamond.FacetCut(address(facet1), IDiamond.FacetCutAction.Add, facet1Selectors);
cut[1] = IDiamond.FacetCut(address(0), IDiamond.FacetCutAction.Remove, oldSelectors);
IDiamondCut(address(diamond)).diamondCut(cut, address(init), abi.encodeCall(MyInit.init, ()));
```

- The batch is atomic and recorded in a single `DiamondCut` event; then `_calldata` runs with `delegatecall`
  on `_init` (skipped when `_init` is `address(0)`), and a revert there undoes the whole batch.
- EIP-2535 checks: `Add` reverts if the selector is mapped, `Replace` if it is unset or already on that facet,
  `Remove` if it is unset; `Add`/`Replace` need a non-zero facet, `Remove` needs `address(0)`.
  Built-in selectors revert as with `sharpCut`.
- Only the admin (or the diamond itself) may call it, like `sharpCut`; `restrict` can narrow it further.
- While it is routed, the loupe's `supportsInterface` also reports `IDiamondCut` (`0x1f931c1c`).

## Storage Layout

Routing state lives in an [ERC-7201](https://eips.ethereum.org/EIPS/eip-7201) namespaced struct
(`LibTinyDiamond.Layout`, namespace `tinydiamond.storage`, slot
`0x0abc81caac83e1656ee495fd84f3fd0c2020c41999d182a4a81694a75a694700`), shared by the core and the optional facets.
Facets with ordinary state variables (slots 0, 1, 2, ...) therefore cannot corrupt the routing table.
The admin stays in the EIP-1967 admin slot.

## Access Control

The contract deployer is automatically set as admin using the EIP-1967 admin slot. Only the admin can call `sharpCut()`, `restrict()` and, if installed, `diamondCut()`.

### Function-Level Restrictions

Restrict specific functions to authorized addresses:

- **Admin functions**: Create more admin functions than `sharpCut` and `restrict`
- **Integration control**: Restrict certain functions to authorized contracts

```solidity
// Restrict a function to a specific user
diamond.restrict(MyFacet.sensitiveFunction.selector, authorizedUser);

// Restrict a function to internal calls
diamond.restrict(MyFacet.sensitiveFunction.selector, address(diamond));

// Remove restriction, now anyone can call again
diamond.restrict(MyFacet.sensitiveFunction.selector, address(0));


```


## Security Considerations

### Critical: Facet Trust

**Facets have complete control over the diamond's storage via `delegatecall`.** A malicious facet can:

- Modify the admin address
- Change selector mappings and restrictions
- Access and modify all storage

**Always audit facets thoroughly before adding them to your diamond.**

### Admin Key Security

The admin has complete control over the diamond:

- Can add, update, or remove any function
- Can set or remove restrictions
- Admin address is stored in EIP-1967 slot for tooling compatibility

Protect the admin key with appropriate security measures (multisig, timelock, etc.).

### Selector Collisions

Be aware of potential selector collisions:

- Different function signatures can produce the same 4-byte selector (rare but possible)
- Always verify selectors before adding them
- Use `getTarget()` (or the loupe's `facetAddress()`) to check current mappings

## Comparison with EIP-2535

TinyDiamond implements the core concept of EIP-2535 and keeps the rest in optional facets:

| Feature | TinyDiamond | Full EIP-2535 |
|---------|-------------|---------------|
| Selector routing | ✅ | ✅ |
| `delegatecall` to facets | ✅ | ✅ |
| Simple API | ✅ | ❌ |
| Batch updates (`diamondCut`) | Optional facet | ✅ |
| Introspection (`IDiamondLoupe`) | Optional facet | ✅ |
| `DiamondCut` event | ✅ | ✅ |
| Per-selector access control | ✅ | ❌ |

With `DiamondLoupeFacet` and `DiamondCutFacet` installed, TinyDiamond provides every interface EIP-2535 asks for.

When to Use TinyDiamond:

- You want per-function access control
- You prefer simplicity
- You're prototyping or learning the pattern

When to Use a Full EIP-2535 Implementation:

- You want the reference implementation's conventions and ecosystem rather than TinyDiamond's
- You're building a complex system with many facets

## Future Enhancements

Possible sophistications that could be added:

- **Immutability**: Support sealing to prevent further modifications
- **Gas Limits**: Per-selector gas budgets
- **Storage Isolation**: Patterns to prevent collisions between facets' own state (the routing state is already isolated)

## License

MIT

