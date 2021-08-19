pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import "./EluniumToken.sol";
import "./Rock.sol";
import "./interfaces/IFairLaunch.sol";

// FairLaunch is a smart contract for distributing Elunium by asking user to stake the ERC20-based token.
contract FairLaunch is IFairLaunch, Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // Info of each user.
  struct UserInfo {
    uint256 amount; // How many Staking tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
    uint256 bonusDebt; // Last block that user exec something to the pool.
    uint256 lastDepositedTime; // Last time that user deposit token.
    address fundedBy; // Funded by who?
    //
    // We do some fancy math here. Basically, any point in time, the amount of Eluniums
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accEluniumPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws Staking tokens to a pool. Here's what happens:
    //   1. The pool's `accEluniumPerShare` (and `lastRewardBlock`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
  }

  // Info of each pool.
  struct PoolInfo {
    address stakeToken; // Address of Staking token contract.
    uint256 allocPoint; // How many allocation points assigned to this pool. Eluniums to distribute per block.
    uint256 lastRewardBlock; // Last block number that Eluniums distribution occurs.
    uint256 accEluniumPerShare; // Accumulated Eluniums per share, times 1e12. See below.
    uint256 accEluniumPerShareTilBonusEnd; // Accumated Eluniums per share until Bonus End.
    uint256 withdrawFeeBP; // Withdraw fee in basis points
    uint256 gemRewardPercent; // Reward gem percent per pool.
  }

  // The Gem Bank!
  IERC20 public gemBank;
  // The Gem TOKEN!
  IERC20 public gem;
  // The Elunium TOKEN!
  EluniumToken public elunium;
  // The Rock TOKEN!
  Rock public rock;
  // Dev address.
  address public devaddr;
  // Fee address.
  address public feeaddr;
  // Elunium tokens created per block.
  uint256 public eluniumPerBlock;
  // Bonus muliplier for early elunium makers.
  uint256 public bonusMultiplier;
  // Block number when bonus Elunium period ends.
  uint256 public bonusEndBlock;
  // Bonus lock-up in BPS
  uint256 public bonusLockUpBps;
  // 3 days
  uint256 public withdrawFeePeriod = 72 hours; 

  // Max fees
  uint256 public constant MAX_WITHDRAW_FEE = 100; // 1%
  // time to withdraw period
  uint256 public constant MAX_WITHDRAW_FEE_PERIOD = 72 hours; // 3 days

  // Info of each pool.
  PoolInfo[] public poolInfo;
  // Info of each user that stakes Staking tokens.
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;
  // Total allocation poitns. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint;
  // The block number when Elunium mining starts.
  uint256 public startBlock;

  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

  constructor(
    IERC20 _gem,
    EluniumToken _elunium,
    Rock _rock,
    address _devaddr,
    address _feeaddr,
    uint256 _eluniumPerBlock,
    uint256 _startBlock,
    uint256 _bonusLockupBps,
    uint256 _bonusEndBlock
  ) public {
    bonusMultiplier = 0;
    totalAllocPoint = 0;
    gem = _gem;
    elunium = _elunium;
    rock = _rock;
    devaddr = _devaddr;
    feeaddr = _feeaddr;
    eluniumPerBlock = _eluniumPerBlock;
    bonusLockUpBps = _bonusLockupBps;
    bonusEndBlock = _bonusEndBlock;
    startBlock = _startBlock;

    // staking pool
    poolInfo.push(PoolInfo({
      stakeToken: address(_elunium),
      allocPoint: 0,
      lastRewardBlock: _startBlock,
      accEluniumPerShare: 0,
      accEluniumPerShareTilBonusEnd: 0,
      withdrawFeeBP: 0,
      gemRewardPercent: 10
    }));
  }

  function setFeeAddr(address _feeaddr) external onlyOwner {
    feeaddr = _feeaddr;
  }

  function setGemBank(IERC20 _gemBank) external onlyOwner {
    gemBank = _gemBank;
  }

   function setWithdrawFeePeriod(uint256 _withdrawFeePeriod) external onlyOwner {
    require(
      _withdrawFeePeriod <= MAX_WITHDRAW_FEE_PERIOD,
      "withdrawFeePeriod cannot be more than MAX_WITHDRAW_FEE_PERIOD"
    );
    withdrawFeePeriod = _withdrawFeePeriod;
  }

  // Update dev address by the previous dev.
  function setDev(address _devaddr) public {
    require(msg.sender == devaddr, "dev: wut?");
    devaddr = _devaddr;
  }

  function setEluniumPerBlock(uint256 _eluniumPerBlock) external onlyOwner {
    eluniumPerBlock = _eluniumPerBlock;
  }

  // Set Bonus params. bonus will start to accu on the next block that this function executed
  // See the calculation and counting in test file.
  function setBonus(
    uint256 _bonusMultiplier,
    uint256 _bonusEndBlock,
    uint256 _bonusLockUpBps
  ) external onlyOwner {
    require(_bonusEndBlock > block.number, "setBonus: bad bonusEndBlock");
    require(_bonusMultiplier > 1, "setBonus: bad bonusMultiplier");
    bonusMultiplier = _bonusMultiplier;
    bonusEndBlock = _bonusEndBlock;
    bonusLockUpBps = _bonusLockUpBps;
  }

  // Add a new lp to the pool. Can only be called by the owner.
  function addPool(
    uint256 _allocPoint,
    address _stakeToken,
    uint256 _withdrawFeeBP,
    uint256 _gemRewardPercent,
    bool _withUpdate
  ) external override onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    require(_stakeToken != address(0), "add: not stakeToken addr");
    require(!isDuplicatedPool(_stakeToken), "add: stakeToken dup");
    require(_withdrawFeeBP <= MAX_WITHDRAW_FEE, "withdrawFee cannot be more than MAX_WITHDRAW_FEE");
    uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
    totalAllocPoint = totalAllocPoint.add(_allocPoint);
    poolInfo.push(
      PoolInfo({
        stakeToken: _stakeToken,
        allocPoint: _allocPoint,
        lastRewardBlock: lastRewardBlock,
        accEluniumPerShare: 0,
        accEluniumPerShareTilBonusEnd: 0,
        withdrawFeeBP: _withdrawFeeBP,
        gemRewardPercent: _gemRewardPercent
      })
    );
  }

  // Update the given pool's Elunium allocation point. Can only be called by the owner.
  function setPool(
    uint256 _pid,
    uint256 _allocPoint,
    uint256 _withdrawFeeBP,
    uint256 _gemRewardPercent,
    bool _withUpdate
  ) external override onlyOwner {
    require(_withdrawFeeBP <= MAX_WITHDRAW_FEE, "withdrawFee cannot be more than MAX_WITHDRAW_FEE");
    if (_withUpdate) {
      massUpdatePools();
    }
    totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
    poolInfo[_pid].allocPoint = _allocPoint;
    poolInfo[_pid].withdrawFeeBP = _withdrawFeeBP;
    poolInfo[_pid].gemRewardPercent = _gemRewardPercent;
  }

  function isDuplicatedPool(address _stakeToken) public view returns (bool) {
    uint256 length = poolInfo.length;
    for (uint256 _pid = 0; _pid < length; _pid++) {
      if(poolInfo[_pid].stakeToken == _stakeToken) return true;
    }
    return false;
  }

  function poolLength() external override view returns (uint256) {
    return poolInfo.length;
  }

  // Return reward multiplier over the given _from to _to block.
  function getMultiplier(uint256 _lastRewardBlock, uint256 _currentBlock) public view returns (uint256) {
    if (_currentBlock <= bonusEndBlock) {
      return _currentBlock.sub(_lastRewardBlock).mul(bonusMultiplier);
    }
    if (_lastRewardBlock >= bonusEndBlock) {
      return _currentBlock.sub(_lastRewardBlock);
    }
    // This is the case where bonusEndBlock is in the middle of _lastRewardBlock and _currentBlock block.
    return bonusEndBlock.sub(_lastRewardBlock).mul(bonusMultiplier).add(_currentBlock.sub(bonusEndBlock));
  }

  // View function to see pending Eluniums on frontend.
  function pendingElunium(uint256 _pid, address _user) external override view returns (uint256) {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_user];
    uint256 accEluniumPerShare = pool.accEluniumPerShare;
    uint256 lpSupply = IERC20(pool.stakeToken).balanceOf(address(this));
    if (block.number > pool.lastRewardBlock && lpSupply != 0) {
      uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
      uint256 eluniumReward = multiplier.mul(eluniumPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
      accEluniumPerShare = accEluniumPerShare.add(eluniumReward.mul(1e12).div(lpSupply));
    }
    return user.amount.mul(accEluniumPerShare).div(1e12).sub(user.rewardDebt);
  }

  // Update reward vairables for all pools. Be careful of gas spending!
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 pid = 0; pid < length; ++pid) {
      updatePool(pid);
    }
  }

  // Update reward variables of the given pool to be up-to-date.
  function updatePool(uint256 _pid) public override {
    PoolInfo storage pool = poolInfo[_pid];
    if (block.number <= pool.lastRewardBlock) {
      return;
    }
    uint256 lpSupply = IERC20(pool.stakeToken).balanceOf(address(this));
    if (lpSupply == 0) {
      pool.lastRewardBlock = block.number;
      return;
    }
    uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
    uint256 eluniumReward = multiplier.mul(eluniumPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
    elunium.mint(devaddr, eluniumReward.div(10));
    elunium.mint(address(rock), eluniumReward);
    pool.accEluniumPerShare = pool.accEluniumPerShare.add(eluniumReward.mul(1e12).div(lpSupply));
    // update accEluniumPerShareTilBonusEnd
    if (block.number <= bonusEndBlock) {
      elunium.lock(devaddr, eluniumReward.mul(bonusLockUpBps).div(100000));
      pool.accEluniumPerShareTilBonusEnd = pool.accEluniumPerShare;
    }
    if(block.number > bonusEndBlock && pool.lastRewardBlock < bonusEndBlock) {
      uint256 eluniumBonusPortion = bonusEndBlock.sub(pool.lastRewardBlock).mul(bonusMultiplier).mul(eluniumPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
      elunium.lock(devaddr, eluniumBonusPortion.mul(bonusLockUpBps).div(100000));
      pool.accEluniumPerShareTilBonusEnd = pool.accEluniumPerShareTilBonusEnd.add(eluniumBonusPortion.mul(1e12).div(lpSupply));
    }
    pool.lastRewardBlock = block.number;
  }

  // Deposit Staking tokens to FairLaunchToken for Elunium allocation.
  function deposit(address _for, uint256 _pid, uint256 _amount) external override nonReentrant {
    require (_pid != 0, 'deposit Elunium by staking');
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_for];
    if (user.fundedBy != address(0)) require(user.fundedBy == msg.sender, "bad sof");
    require(pool.stakeToken != address(0), "deposit: not accept deposit");
    updatePool(_pid);
    if (user.amount > 0) _harvest(_for, _pid);
    if (user.fundedBy == address(0)) user.fundedBy = msg.sender;
    IERC20(pool.stakeToken).safeTransferFrom(address(msg.sender), address(this), _amount);
    user.amount = user.amount.add(_amount);
    user.rewardDebt = user.amount.mul(pool.accEluniumPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accEluniumPerShareTilBonusEnd).div(1e12);
    if(pool.withdrawFeeBP > 0) {
      user.lastDepositedTime = block.timestamp;
    }
    emit Deposit(msg.sender, _pid, _amount);
  }

  // Withdraw Staking tokens from FairLaunchToken.
  function withdraw(address _for, uint256 _pid, uint256 _amount) external override nonReentrant {
    require (_pid != 0, 'withdraw Elunium by unstaking');
    _withdraw(_for, _pid, _amount);
  }

  function withdrawAll(address _for, uint256 _pid) external override nonReentrant {
    require (_pid != 0, 'withdraw Elunium by unstaking');
    _withdraw(_for, _pid, userInfo[_pid][_for].amount);
  }

  function _withdraw(address _for, uint256 _pid, uint256 _amount) internal {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_for];
    require(user.fundedBy == msg.sender, "only funder");
    require(user.amount >= _amount, "withdraw: not good");
    updatePool(_pid);
    _harvest(_for, _pid);
    user.amount = user.amount.sub(_amount);
    user.rewardDebt = user.amount.mul(pool.accEluniumPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accEluniumPerShareTilBonusEnd).div(1e12);
    if (user.amount == 0) user.fundedBy = address(0);
    if (pool.stakeToken != address(0)) {
      if(pool.withdrawFeeBP > 0 && block.timestamp <= user.lastDepositedTime.add(withdrawFeePeriod)) {
        uint256 withdrawFee = _amount.mul(pool.withdrawFeeBP).div(10000);
        IERC20(pool.stakeToken).safeTransfer(feeaddr, withdrawFee);
        IERC20(pool.stakeToken).safeTransfer(address(msg.sender), _amount.sub(withdrawFee));
      } else {
        IERC20(pool.stakeToken).safeTransfer(address(msg.sender), _amount);       
      }
    }
    emit Withdraw(msg.sender, _pid, user.amount);
  }

  // Harvest Eluniums earn from the pool.
  function harvest(uint256 _pid) external override nonReentrant {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    updatePool(_pid);
    _harvest(msg.sender, _pid);
    user.rewardDebt = user.amount.mul(pool.accEluniumPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accEluniumPerShareTilBonusEnd).div(1e12);
  }

  function _harvest(address _to, uint256 _pid) internal {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_to];
    require(user.amount > 0, "nothing to harvest");
    uint256 pending = user.amount.mul(pool.accEluniumPerShare).div(1e12).sub(user.rewardDebt);
    if (pending > 0) {
      uint256 gemPending = pending.mul(pool.gemRewardPercent).div(10000);
      uint256 gemBal = gem.balanceOf(address(gemBank));
      if (gemPending <= gemBal) {
        safeGemTransfer(_to, gemPending);
      }
    }
    require(pending <= elunium.balanceOf(address(rock)), "wtf not enough elunium");
    uint256 bonus = user.amount.mul(pool.accEluniumPerShareTilBonusEnd).div(1e12).sub(user.bonusDebt);
    safeEluniumTransfer(_to, pending);
    elunium.lock(_to, bonus.mul(bonusLockUpBps).div(10000));
  }

  // Stake Elunium tokens to MasterChef
  function enterStaking(uint256 _amount) public {
    PoolInfo storage pool = poolInfo[0];
    UserInfo storage user = userInfo[0][msg.sender];
    if (user.fundedBy != address(0)) require(user.fundedBy == msg.sender, "bad sof");
    require(pool.stakeToken != address(0), "deposit: not accept deposit");
    updatePool(0);
    if (user.amount > 0) _harvest(msg.sender, 0);
    if (user.fundedBy == address(0)) user.fundedBy = msg.sender;
    if (_amount > 0) {
        IERC20(pool.stakeToken).safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
    }
    user.rewardDebt = user.amount.mul(pool.accEluniumPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accEluniumPerShareTilBonusEnd).div(1e12);
    rock.mint(msg.sender, _amount);
    emit Deposit(msg.sender, 0, _amount);
  }

  // Withdraw Elunium tokens from STAKING.
  function leaveStaking(uint256 _amount) public {
    PoolInfo storage pool = poolInfo[0];
    UserInfo storage user = userInfo[0][msg.sender];
    require(user.amount >= _amount, "withdraw: not good");
    updatePool(0);
    _harvest(msg.sender, 0);
    if(_amount > 0) {
        user.amount = user.amount.sub(_amount);
        IERC20(pool.stakeToken).safeTransfer(address(msg.sender), _amount);
    }
    user.rewardDebt = user.amount.mul(pool.accEluniumPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accEluniumPerShareTilBonusEnd).div(1e12);
    rock.burn(msg.sender, _amount);
    emit Withdraw(msg.sender, 0, _amount);
  }

  // Withdraw without caring about rewards. EMERGENCY ONLY.
  function emergencyWithdraw(uint256 _pid) external nonReentrant {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    require(user.fundedBy == msg.sender, "only funder");
    if(pool.withdrawFeeBP > 0 && block.timestamp <= user.lastDepositedTime.add(withdrawFeePeriod)) {
      uint256 withdrawFee = user.amount.mul(pool.withdrawFeeBP).div(10000);
      IERC20(pool.stakeToken).safeTransfer(feeaddr, withdrawFee);
      IERC20(pool.stakeToken).safeTransfer(address(msg.sender), user.amount.sub(withdrawFee));
    } else {
      IERC20(pool.stakeToken).safeTransfer(address(msg.sender), user.amount);       
    }
    emit EmergencyWithdraw(msg.sender, _pid, user.amount);
    user.amount = 0;
    user.rewardDebt = 0;
    user.fundedBy = address(0);
    user.lastDepositedTime = 0;
  }

    // Safe elunium transfer function, just in case if rounding error causes pool to not have enough Eluniums.
  function safeEluniumTransfer(address _to, uint256 _amount) internal {
    rock.safeEluniumTransfer(_to, _amount);
  }

  function safeGemTransfer(address _to, uint256 _amount) internal {
    uint256 gemBal = gem.balanceOf(address(gemBank));
        if (_amount > gemBal) {
            gem.safeTransferFrom(address(gemBank), _to, gemBal);
        } else {
            gem.safeTransferFrom(address(gemBank), _to, _amount);
        }
  }
}