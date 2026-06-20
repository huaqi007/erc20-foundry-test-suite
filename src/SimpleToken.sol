// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SimpleToken is ERC20, Ownable {
    constructor() ERC20("SimpleToken", "STK") Ownable(msg.sender) {
          _mint(msg.sender, 1000 * 10 ** decimals());
      }

    function mint(address to, uint256 amount) external onlyOwner {
          _mint(to, amount);
      }

    function burnFrom(address from, uint256 amount) external onlyOwner {
          _burn(from, amount);
      }
}
