// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice EIP-2535 `IDiamond`: the standard event recording every function added, replaced or removed.
interface IDiamond {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }
    // Add=0, Replace=1, Remove=2

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}

/**
 * @title LibTinyDiamond
 * @notice Routing state of a TinyDiamond, stored at an ERC-7201 namespaced slot so that facets
 * (which run with `delegatecall` on the diamond's storage) can read it without colliding with
 * their own sequentially-allocated state variables. Its internal functions run inside the diamond,
 * so the events below are emitted by the diamond.
 */
library LibTinyDiamond {
    /// @dev Same signature as `IDiamond.DiamondCut` (solc 0.8.20 cannot emit an interface's event)
    event DiamondCut(IDiamond.FacetCut[] _diamondCut, address _init, bytes _calldata);

    struct FacetAndPosition {
        address facet;
        uint96 position; // index in `selectors` + 1; 0 means absent
    }

    /// @custom:storage-location erc7201:tinydiamond.storage
    struct Layout {
        mapping(bytes4 => FacetAndPosition) facetOf;
        bytes4[] selectors; // every selector routed by the fallback, in no particular order
        mapping(bytes4 => address) restriction;
    }

    // keccak256(abi.encode(uint256(keccak256("tinydiamond.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_SLOT = 0x0abc81caac83e1656ee495fd84f3fd0c2020c41999d182a4a81694a75a694700;

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Selectors of the functions compiled into TinyDiamond itself (EIP-2535 immutable functions).
    function builtinSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("sharpCut(bytes4,address)"));
        s[1] = bytes4(keccak256("restrict(bytes4,address)"));
        s[2] = bytes4(keccak256("admin()"));
        s[3] = bytes4(keccak256("getTarget(bytes4)"));
        s[4] = bytes4(keccak256("selectorToFacet(bytes4)"));
        s[5] = bytes4(keccak256("selectorRestriction(bytes4)"));
    }

    function isBuiltin(bytes4 selector) internal pure returns (bool) {
        bytes4[] memory s = builtinSelectors();
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == selector) return true;
        }
        return false;
    }

    /// @notice EIP-2535: immutable functions are emitted as added, with the diamond as facet
    function emitBuiltins() internal {
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut(address(this), IDiamond.FacetCutAction.Add, builtinSelectors());
        emit DiamondCut(cut, address(0), "");
    }

    /// @notice Routes `selector` to `target` (address(0) removes it) and emits `DiamondCut`; silent if unchanged
    function cut(bytes4 selector, address target) internal {
        require(!isBuiltin(selector), "TinyDiamond: immutable function");
        Layout storage l = layout();
        FacetAndPosition memory old = l.facetOf[selector];
        if (old.facet == target) return; // no change, no event

        IDiamond.FacetCutAction action;
        if (old.facet == address(0)) {
            // Add: append, position stored in the same slot as the facet
            l.selectors.push(selector);
            l.facetOf[selector] = FacetAndPosition(target, uint96(l.selectors.length));
            action = IDiamond.FacetCutAction.Add;
        } else if (target == address(0)) {
            // Remove: swap-and-pop keeps `selectors` dense
            uint256 index = old.position - 1;
            uint256 lastIndex = l.selectors.length - 1;
            if (index != lastIndex) {
                bytes4 last = l.selectors[lastIndex];
                l.selectors[index] = last;
                l.facetOf[last].position = uint96(index + 1);
            }
            l.selectors.pop();
            delete l.facetOf[selector];
            action = IDiamond.FacetCutAction.Remove;
        } else {
            l.facetOf[selector].facet = target;
            action = IDiamond.FacetCutAction.Replace;
        }

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        IDiamond.FacetCut[] memory c = new IDiamond.FacetCut[](1);
        c[0] = IDiamond.FacetCut(target, action, selectors);
        emit DiamondCut(c, address(0), "");
    }

    function restrict(bytes4 selector, address target) internal {
        require(!isBuiltin(selector), "TinyDiamond: immutable function");
        layout().restriction[selector] = target;
    }
}
