// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SimpleTokenTest is Test {
    SimpleToken public token;

    address public owner;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant INITIAL_SUPPLY = 1000 * 1e18;

    function setUp() public {
        owner = address(this); // Test contract itself is the deployer → owner
        token = new SimpleToken();
        // owner now has 1000 STK
    }

    // 测试更新合并改动，我再改动了测试文件，先提交一下测试文件的改动，再继续改动合约文件
    // ═══════════════════════════════════════════
    // 维度 1：功能测试 — 正常路径 (1–5)
    // ═══════════════════════════════════════════

    /// @dev 1. owner mint(500) 给 alice → alice +500, totalSupply +500
    function test_MintToAlice() public {
        uint256 mintAmount = 500 * 1e18;
        uint256 supplyBefore = token.totalSupply();

        // OZ _mint emits Transfer(address(0), to, amount)
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, mintAmount);

        token.mint(alice, mintAmount);

        assertEq(token.balanceOf(alice), mintAmount, "alice balance");
        assertEq(token.totalSupply(), supplyBefore + mintAmount, "totalSupply");
    }

    /// @dev 2. alice transfer(200) 给 bob → alice -200, bob +200
    function test_Transfer() public {
        uint256 amount = 200 * 1e18;
        token.mint(alice, amount);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, bob, amount);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice), 0, "alice after transfer");
        assertEq(token.balanceOf(bob), amount, "bob after transfer");
    }

    /// @dev 3. alice approve(bob, 300) → bob allowance = 300
    function test_Approve() public {
        uint256 amount = 300 * 1e18;
        token.mint(alice, amount);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(alice, bob, amount);

        vm.prank(alice);
        token.approve(bob, amount);

        assertEq(token.allowance(alice, bob), amount, "allowance");
    }

    /// @dev 4. bob transferFrom(alice, charlie, 100) → alice -100, charlie +100, allowance -100
    function test_TransferFrom() public {
        uint256 approveAmt = 300 * 1e18;
        uint256 transferAmt = 100 * 1e18;
        token.mint(alice, approveAmt);

        vm.prank(alice);
        token.approve(bob, approveAmt);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, charlie, transferAmt);

        vm.prank(bob);
        token.transferFrom(alice, charlie, transferAmt);

        assertEq(token.balanceOf(alice), approveAmt - transferAmt, "alice");
        assertEq(token.balanceOf(charlie), transferAmt, "charlie");
        assertEq(token.allowance(alice, bob), approveAmt - transferAmt, "remaining allowance");
    }

    /// @dev 5. owner burnFrom(alice, 50) → alice -50, totalSupply -50
    function test_BurnFrom() public {
        uint256 mintAmt = 200 * 1e18;
        uint256 burnAmt = 50 * 1e18;
        token.mint(alice, mintAmt);
        uint256 supplyBefore = token.totalSupply();

        // OZ _burn emits Transfer(from, address(0), amount)
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), burnAmt);

        token.burnFrom(alice, burnAmt);

        assertEq(token.balanceOf(alice), mintAmt - burnAmt, "alice after burn");
        assertEq(token.totalSupply(), supplyBefore - burnAmt, "totalSupply");
    }

    // ═══════════════════════════════════════════
    // 维度 2：边界值测试 (6–14)
    // ═══════════════════════════════════════════

    /// @dev 6. mint(0) → 成功但不改变余额
    function test_MintZero() public {
        uint256 supplyBefore = token.totalSupply();
        token.mint(alice, 0);
        assertEq(token.balanceOf(alice), 0, "alice balance still 0");
        assertEq(token.totalSupply(), supplyBefore, "totalSupply unchanged");
    }

    /// @dev 7. mint(1) → 成功，最小有效值
    function test_MintOneWei() public {
        token.mint(alice, 1);
        assertEq(token.balanceOf(alice), 1, "alice got 1 wei");
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 1, "totalSupply +1");
    }

    /// @dev 8. transfer(0) → 成功，余额不变
    function test_TransferZero() public {
        vm.prank(owner);
        token.transfer(alice, 0);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY, "owner unchanged");
        assertEq(token.balanceOf(alice), 0, "alice unchanged");
    }

    /// @dev 9. alice transfer(全部余额) → alice 归零
    function test_TransferFullBalance() public {
        uint256 amt = 300 * 1e18;
        token.mint(alice, amt);

        vm.prank(alice);
        token.transfer(bob, amt);

        assertEq(token.balanceOf(alice), 0, "alice zero");
        assertEq(token.balanceOf(bob), amt, "bob got all");
    }

    /// @dev 10. approve max → 最大授权
    function test_ApproveMax() public {
        vm.prank(owner);
        token.approve(alice, type(uint256).max);
        assertEq(token.allowance(owner, alice), type(uint256).max, "max allowance");
    }

    /// @dev 11. approve → 0 取消授权
    function test_ApproveZeroToCancel() public {
        vm.prank(owner);
        token.approve(alice, 500 * 1e18);
        vm.prank(owner);
        token.approve(alice, 0);
        assertEq(token.allowance(owner, alice), 0, "allowance cancelled");
    }

    /// @dev 12. transferFrom 恰好等于 allowance → 成功，allowance 归零
    function test_TransferFromExactAllowance() public {
        uint256 amt = 100 * 1e18;
        token.mint(alice, amt);

        vm.prank(alice);
        token.approve(bob, amt);

        vm.prank(bob);
        token.transferFrom(alice, charlie, amt);

        assertEq(token.allowance(alice, bob), 0, "allowance => 0");
    }

    /// @dev 13. burn(0) → 成功但不改变余额
    function test_BurnZero() public {
        token.mint(alice, 100 * 1e18);
        uint256 supplyBefore = token.totalSupply();

        token.burnFrom(alice, 0);

        assertEq(token.balanceOf(alice), 100 * 1e18, "balance unchanged");
        assertEq(token.totalSupply(), supplyBefore, "totalSupply unchanged");
    }

    /// @dev 14. burn(全部余额) → 余额归零
    function test_BurnFullBalance() public {
        uint256 amt = 200 * 1e18;
        token.mint(alice, amt);

        token.burnFrom(alice, amt);

        assertEq(token.balanceOf(alice), 0, "alice zero");
    }

    // ═══════════════════════════════════════════
    // 维度 3：状态一致性 (15–22)
    // ═══════════════════════════════════════════

    /// @dev 15. transfer 前后 totalSupply 不变
    function test_TransferTotalSupplyInvariant() public {
        token.mint(alice, 200 * 1e18);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, 100 * 1e18);

        assertEq(token.totalSupply(), supplyBefore, "totalSupply unchanged after transfer");
    }

    /// @dev 16. mint 后 totalSupply += mint 的量
    function test_MintTotalSupplyIncreases() public {
        uint256 supplyBefore = token.totalSupply();
        token.mint(alice, 500 * 1e18);
        assertEq(token.totalSupply(), supplyBefore + 500 * 1e18);
    }

    /// @dev 17. burn 后 totalSupply -= burn 的量
    function test_BurnTotalSupplyDecreases() public {
        token.mint(alice, 200 * 1e18);
        uint256 supplyBefore = token.totalSupply();
        token.burnFrom(alice, 100 * 1e18);
        assertEq(token.totalSupply(), supplyBefore - 100 * 1e18);
    }

    /// @dev 18. approve 不改变 owner 余额
    function test_ApproveDoesNotChangeBalance() public {
        uint256 balBefore = token.balanceOf(owner);
        vm.prank(owner);
        token.approve(alice, 500 * 1e18);
        assertEq(token.balanceOf(owner), balBefore, "balance unchanged");
    }

    /// @dev 19. approve 不改变 spender 余额
    function test_ApproveDoesNotChangeSpenderBalance() public {
        uint256 balBefore = token.balanceOf(alice);
        vm.prank(owner);
        token.approve(alice, 500 * 1e18);
        assertEq(token.balanceOf(alice), balBefore, "spender balance unchanged");
    }

    /// @dev 20. approve 不改变 totalSupply
    function test_ApproveDoesNotChangeTotalSupply() public {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(owner);
        token.approve(alice, 500 * 1e18);
        assertEq(token.totalSupply(), supplyBefore);
    }

    /// @dev 21. transferFrom 后发送者余额减少、接收者增加、中间人不变
    function test_TransferFromBalances() public {
        token.mint(alice, 200 * 1e18);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        token.approve(bob, 100 * 1e18);

        vm.prank(bob);
        token.transferFrom(alice, charlie, 100 * 1e18);

        assertEq(token.balanceOf(alice), 100 * 1e18, "alice -100");
        assertEq(token.balanceOf(charlie), 100 * 1e18, "charlie +100");
        assertEq(token.balanceOf(bob), bobBefore, "bob unchanged (middleman)");
    }

    /// @dev 22. 所有账户余额之和 = totalSupply
    function test_SumOfBalancesEqualsTotalSupply() public {
        token.mint(alice, 300 * 1e18);
        token.mint(bob, 200 * 1e18);
        token.mint(charlie, 100 * 1e18);

        uint256 sum = token.balanceOf(owner) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(charlie);

        assertEq(sum, token.totalSupply(), "sum of balances = totalSupply");
    }

    // ═══════════════════════════════════════════
    // 维度 4：权限测试 (23–25)
    // ═══════════════════════════════════════════

    /// @dev 23. 非 owner 调 mint → revert
    function test_MintOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(bob, 100 * 1e18);
    }

    /// @dev 24. 非 owner 调 burnFrom → revert
    function test_BurnFromOnlyOwner() public {
        token.mint(alice, 100 * 1e18);

        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 50 * 1e18);
    }

    /// @dev 25. 无 approve 者调 transferFrom → revert
    function test_TransferFromWithoutApproval() public {
        token.mint(alice, 200 * 1e18);

        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, charlie, 50 * 1e18);
    }

    // ═══════════════════════════════════════════
    // 维度 5：异常 / 回滚测试 (26–32)
    // ═══════════════════════════════════════════

    /// @dev 26. transfer 给 address(0) → revert
    function test_TransferToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert();
        token.transfer(address(0), 100 * 1e18);
    }

    /// @dev 27. transfer 超过余额 → revert
    function test_TransferExceedsBalance() public {
        vm.prank(owner);
        vm.expectRevert();
        token.transfer(alice, INITIAL_SUPPLY + 1);
    }

    /// @dev 28. approve(address(0)) → revert
    function test_ApproveZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert();
        token.approve(address(0), 500 * 1e18);
    }

    /// @dev 29. transferFrom 给 address(0) → revert
    function test_TransferFromToZeroAddress() public {
        token.mint(alice, 200 * 1e18);
        vm.prank(alice);
        token.approve(bob, 100 * 1e18);

        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, address(0), 100 * 1e18);
    }

    /// @dev 30. transferFrom 超过 allowance → revert
    function test_TransferFromExceedsAllowance() public {
        token.mint(alice, 500 * 1e18);
        vm.prank(alice);
        token.approve(bob, 100 * 1e18);

        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, charlie, 200 * 1e18);
    }

    /// @dev 31. burnFrom 超过余额 → revert
    function test_BurnExceedsBalance() public {
        token.mint(alice, 50 * 1e18);

        vm.expectRevert();
        token.burnFrom(alice, 100 * 1e18);
    }

    /// @dev 32. transferFrom(address(0)) → revert
    function test_TransferFromZeroSender() public {
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(address(0), charlie, 100 * 1e18);
    }
}
