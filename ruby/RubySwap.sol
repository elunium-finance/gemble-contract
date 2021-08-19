pragma solidity ^0.6.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./token/RubyToken.sol";
import "./pancakeV2/IPancakeRouter02.sol";
import "./pancakeV2/IPancakeFactory.sol";
import "./pancakeV2/IPancakePair.sol";

contract RubySwap is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant MAX_FEE = 1e9; // 10%
    uint256 private constant FEE_DENOMINATOR = 1e10;
    uint256 private constant ONE = 1 ether;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Ruby
    RubyToken public ruby;

    // Gem
    address public gem;

    // Fee token
    address public elunium;
    // Fee percent
    uint256 public feePercent;

    // Router
    address public router;

    // WBNB
    address private WBNB;

    event UpdateSwapRouter(address indexed owner, address indexed router);
    event Mint(address indexed creator,  uint256 amount);
    event Burn(address indexed creator,  uint256 amount);

    constructor(        
        RubyToken _ruby,
        address _gem,
        address _elunium,
        uint256 _feePercent,
        address _router
    ) public {
        require(_feePercent <= MAX_FEE, "Over MAX_FEE");
				
        ruby = _ruby;
        gem = _gem;
        elunium = _elunium;
        feePercent = _feePercent;
        router = _router;

        WBNB = IPancakeRouter02(router).WETH();
    }

    /// @dev Return the gem price via pancake router;
    function _getGemPrice() internal view returns (uint256) {
        address[] memory path;
        path = new address[](2);
        path[0] = gem;
        path[1] = WBNB;
        uint256[] memory amounts = IPancakeRouter02(router).getAmountsOut(ONE, path);
        return amounts[amounts.length - 1];
    }

    /// @dev Return the elunium price via pancake router;
    function _getEluniumPrice() internal view returns (uint256) {
        address[] memory path;
        path = new address[](2);
        path[0] = gem;
        path[1] = WBNB;
        uint256[] memory amounts = IPancakeRouter02(router).getAmountsOut(ONE, path);
        return amounts[amounts.length - 1];
    }

    /// @dev Mint ruby token from gem.
    /// @param _amount The gem amount to mint.
    /// @param _maxFee The max elunium fee calculate from frontend.
    function mint(uint256 _amount, uint256 _maxFee) external nonReentrant returns (bool) {
        require(IERC20(gem).balanceOf(msg.sender) >= _amount, "Not enough gem");
        require(IERC20(elunium).balanceOf(msg.sender) >= _maxFee, "Not enough elunium");
        IERC20(gem).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 gemPrince = _getGemPrice();
        uint256 eluniumPrice = _getEluniumPrice();
        uint256 eluniumFee = _amount.mul(gemPrince).mul(feePercent).div(FEE_DENOMINATOR).div(eluniumPrice);
        require(eluniumFee <= _maxFee, "Elunium fee more than you thought");
        if(eluniumFee > 0) {
            IERC20(elunium).safeTransferFrom(msg.sender, BURN_ADDRESS, eluniumFee);
        }
        ruby.mint(msg.sender, _amount.div(100));
        emit Mint(msg.sender, _amount);
        return true;
    }

    /// @dev redeem ruby token for gem.
    /// @param _amount The ruby amount to redeem.
    function redeem(uint256 _amount) external nonReentrant returns (bool) {
        require(IERC20(address(ruby)).balanceOf(msg.sender) >= _amount, "Not enough ruby");
        ruby.burnFrom(msg.sender, _amount);
        IERC20(gem).safeTransfer(msg.sender, _amount.mul(100));
        emit Burn(msg.sender, _amount);
        return true;
    }

    /// @dev set fee of elunium percent.
    /// @param _feePercent The new fee percent to set.
    function setFeePercent(uint256 _feePercent) public onlyOwner {
        require(_feePercent <= MAX_FEE, "Over MAX_FEE");
        feePercent = _feePercent;
    }
}