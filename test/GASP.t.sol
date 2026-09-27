// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GASP} from "../src/GASP.sol";

contract GASPTest is Test {
    GASP internal token;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new GASP();
    }

    function test_metadataAndWholeSupplyToConstructorCaller() public {
        assertEq(token.name(), "Gas Tax");
        assertEq(token.symbol(), "GASP");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.prank(address(0x1234));
        GASP other = new GASP();
        assertEq(other.balanceOf(address(0x1234)), SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(address(0xBEEF), amount));
        assertEq(token.balanceOf(address(0xBEEF)), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowanceAndInfiniteApproval() public {
        token.approve(address(0xBEEF), 100);
        vm.prank(address(0xBEEF));
        assertTrue(token.transferFrom(address(this), address(0xCAFE), 60));
        assertEq(token.allowance(address(this), address(0xBEEF)), 40);
        assertEq(token.balanceOf(address(0xCAFE)), 60);
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(0xBEEF), 40, 41)
        );
        token.transferFrom(address(this), address(0xCAFE), 41);
        token.approve(address(0xBEEF), type(uint256).max);
        vm.prank(address(0xBEEF));
        token.transferFrom(address(this), address(0xCAFE), 1);
        assertEq(token.allowance(address(this), address(0xBEEF)), type(uint256).max);
    }

    function test_invalidTransfersRevertWithoutChangingSupply() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(0xBEEF), 0, 1));
        token.transfer(address(this), 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_noAdministrativeOrMintEntryPointsEvenForDeployer() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], address(0xBEEF), 1);
            (bool deployerOk,) = address(token).call(data);
            assertFalse(deployerOk);
            vm.prank(address(0xBEEF));
            (bool outsiderOk,) = address(token).call(data);
            assertFalse(outsiderOk);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }
}
