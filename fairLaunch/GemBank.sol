pragma solidity 0.6.6;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

contract GemBank is Ownable {

    using SafeERC20 for IERC20;

    IERC20 public gem;
    uint256 constant MAX_INT = uint256(-1);

    constructor(IERC20 _gem, address masterChef) public {
        gem = _gem;
        gem.safeApprove(masterChef, MAX_INT);
    }
    
}