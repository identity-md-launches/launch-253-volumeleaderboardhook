// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {VOLM} from "../src/VOLM.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VOLMTest is Test {
    VOLM token;

    function setUp() public {
        token = new VOLM();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Volume");
        assertEq(token.symbol(), "VOLM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transfersAndAllowance(uint256 raw) public {
        uint256 amount = bound(raw, 0, token.totalSupply());
        token.approve(address(123), amount);
        vm.prank(address(123));
        assertTrue(token.transferFrom(address(this), address(456), amount));
        assertEq(token.balanceOf(address(456)), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.allowance(address(this), address(123)), 0);
        vm.prank(address(456));
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_failuresAndInfiniteApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        uint256 excessive = token.totalSupply() + 1;
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        token.transfer(address(1), excessive);
        vm.prank(address(2));
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        token.transferFrom(address(this), address(1), 1);
        token.approve(address(2), type(uint256).max);
        vm.prank(address(2));
        token.transferFrom(address(this), address(1), 1);
        assertEq(token.allowance(address(this), address(2)), type(uint256).max);
    }

    function test_noAdministrativeOrMintPaths() public {
        string[10] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) =
                address(token).call(abi.encodeWithSignature(selectors[i], address(this), 1 ether));
            assertFalse(success);
            vm.prank(address(123));
            (success,) = address(token).call(abi.encodeWithSignature(selectors[i], address(123), 1 ether));
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
