// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HookTestBase} from "./helpers/HookTestBase.sol";

contract ArtifactTest is HookTestBase {
    function test_runtimeHasNoEscapeOpcodesAndFitsEip170() public view {
        inspect(address(token).code);
        inspect(address(hook).code);
    }

    function inspect(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden opcode");
        }
    }
}
