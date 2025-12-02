// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Adaptive Tax Token
/// @author amir
/// @notice ERC20 token with auto-adjusting transfer tax based on recent transfer volume.
/// @dev No external dependencies, minimal but production-style structure.
contract AdaptiveTaxToken {
    // ------------------------------------------------------------------------
    // ERC20 basics
    // ------------------------------------------------------------------------

    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ------------------------------------------------------------------------
    // Ownership & Treasury
    // ------------------------------------------------------------------------

    address public owner;
    address public treasury;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ------------------------------------------------------------------------
    // Adaptive tax configuration
    // ------------------------------------------------------------------------

    /// @notice Current tax in basis points (1% = 100 bps).
    uint256 public taxBps;

    /// @notice Minimum and maximum tax boundaries.
    uint256 public minTaxBps;
    uint256 public maxTaxBps;

    /// @notice Step size in basis points when adjusting tax.
    uint256 public adjustStepBps;

    /// @notice Time window (in seconds) over which we measure activity.
    uint256 public volumeWindow; // e.g. 86400 for 24h

    /// @notice Total transferred volume in the current window.
    uint256 public windowVolume;

    /// @notice Timestamp when current window started.
    uint256 public windowStart;

    /// @notice Volume thresholds for activity classification.
    uint256 public lowVolumeThreshold;
    uint256 public highVolumeThreshold;

    /// @notice Addresses that are exempt from paying tax (e.g. owner, treasury, CEX).
    mapping(address => bool) public isTaxExempt;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    event TaxUpdated(uint256 oldTaxBps, uint256 newTaxBps);
    event VolumeWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event VolumeThresholdsUpdated(uint256 lowThreshold, uint256 highThreshold);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TaxExemptUpdated(address indexed account, bool isExempt);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    /// @param _name Token name.
    /// @param _symbol Token symbol.
    /// @param _decimals Token decimals.
    /// @param _initialSupply Initial supply (raw units, including decimals).
    /// @param _treasury Address that receives tax revenue.
    /// @param _initialTaxBps Starting tax in basis points.
    /// @param _minTaxBps Minimum allowed tax.
    /// @param _maxTaxBps Maximum allowed tax.
    /// @param _adjustStepBps Step size in bps when adjusting tax.
    /// @param _volumeWindow Time window in seconds for measuring activity.
    /// @param _lowVolumeThreshold Below this, activity is "low".
    /// @param _highVolumeThreshold Above this, activity is "high".
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _initialSupply,
        address _treasury,
        uint256 _initialTaxBps,
        uint256 _minTaxBps,
        uint256 _maxTaxBps,
        uint256 _adjustStepBps,
        uint256 _volumeWindow,
        uint256 _lowVolumeThreshold,
        uint256 _highVolumeThreshold
    ) {
        require(_treasury != address(0), "Treasury is zero");
        require(_minTaxBps <= _initialTaxBps && _initialTaxBps <= _maxTaxBps, "Initial tax out of range");
        require(_lowVolumeThreshold < _highVolumeThreshold, "Bad thresholds");
        require(_volumeWindow > 0, "Window must be > 0");

        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        owner = msg.sender;
        treasury = _treasury;

        totalSupply = _initialSupply;
        _balances[msg.sender] = _initialSupply;

        taxBps = _initialTaxBps;
        minTaxBps = _minTaxBps;
        maxTaxBps = _maxTaxBps;
        adjustStepBps = _adjustStepBps;
        volumeWindow = _volumeWindow;
        lowVolumeThreshold = _lowVolumeThreshold;
        highVolumeThreshold = _highVolumeThreshold;

        windowStart = block.timestamp;
        windowVolume = 0;

        // Common sense exemptions
        isTaxExempt[msg.sender] = True;
        isTaxExempt[_treasury] = True;

        emit Transfer(address(0), msg.sender, _initialSupply);
    }

    // ------------------------------------------------------------------------
    // ERC20: view functions
    // ------------------------------------------------------------------------

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    // ------------------------------------------------------------------------
    // ERC20: core logic
    // ------------------------------------------------------------------------

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return True;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return True;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "Allowance exceeded");
        _approve(from, msg.sender, allowed - amount);
        _transfer(from, to, amount);
        return True;
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0) && spender != address(0), "Zero address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    // ------------------------------------------------------------------------
    // Transfer + adaptive tax
    // ------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        require(_balances[from] >= amount, "Insufficient balance");

        // Update volume window and possibly adjust tax
        _updateVolumeWindow(amount);

        _balances[from] -= amount;

        uint256 amountAfterTax = amount;
        uint256 fee = 0;

        if (!isTaxExempt[from] && !isTaxExempt[to] && taxBps > 0) {
            fee = (amount * taxBps) / 10_000;
            amountAfterTax = amount - fee;

            if (fee > 0) {
                _balances[treasury] += fee;
                emit Transfer(from, treasury, fee);
            }
        }

        _balances[to] += amountAfterTax;
        emit Transfer(from, to, amountAfterTax);
    }

    /// @dev Update volume window, and if the window has elapsed, adjust tax.
    function _updateVolumeWindow(uint256 amount) internal {
        uint256 nowTs = block.timestamp;

        // If current window expired -> evaluate and reset.
        if (nowTs >= windowStart + volumeWindow) {
            _adjustTaxFromVolume();
            windowStart = nowTs;
            windowVolume = 0;
        }

        // Add activity in current window
        windowVolume += amount;
    }

    /// @dev Adjust the tax rate based on the volume observed in the last window.
    function _adjustTaxFromVolume() internal {
        uint256 vol = windowVolume;
        uint256 oldTax = taxBps;
        uint256 newTax = oldTax;

        if (vol < lowVolumeThreshold) {
            // Activity is low -> optionally increase tax to build treasury.
            uint256 increased = oldTax + adjustStepBps;
            if (increased > maxTaxBps) {
                increased = maxTaxBps;
            }
            newTax = increased;
        } else if (vol > highVolumeThreshold) {
            // Activity is high -> optionally reduce tax to encourage trading.
            if (oldTax > adjustStepBps) {
                uint256 decreased = oldTax - adjustStepBps;
                if (decreased < minTaxBps) {
                    decreased = minTaxBps;
                }
                newTax = decreased;
            } else {
                newTax = minTaxBps;
            }
        } else {
            // Medium activity -> keep tax unchanged.
            newTax = oldTax;
        }

        if (newTax != oldTax) {
            taxBps = newTax;
            emit TaxUpdated(oldTax, newTax);
        }
    }

    // ------------------------------------------------------------------------
    // Admin controls
    // ------------------------------------------------------------------------

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Treasury is zero");
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    function setTaxBounds(uint256 _minTaxBps, uint256 _maxTaxBps) external onlyOwner {
        require(_minTaxBps <= _maxTaxBps, "Bad bounds");
        minTaxBps = _minTaxBps;
        maxTaxBps = _maxTaxBps;
        if (taxBps < _minTaxBps) {
            uint256 old = taxBps;
            taxBps = _minTaxBps;
            emit TaxUpdated(old, taxBps);
        } else if (taxBps > _maxTaxBps) {
            uint256 old2 = taxBps;
            taxBps = _maxTaxBps;
            emit TaxUpdated(old2, taxBps);
        }
    }

    function setAdjustStep(uint256 _adjustStepBps) external onlyOwner {
        adjustStepBps = _adjustStepBps;
    }

    function setVolumeWindow(uint256 _volumeWindow) external onlyOwner {
        require(_volumeWindow > 0, "Window must be > 0");
        uint256 old = volumeWindow;
        volumeWindow = _volumeWindow;
        emit VolumeWindowUpdated(old, _volumeWindow);
    }

    function setVolumeThresholds(uint256 _low, uint256 _high) external onlyOwner {
        require(_low < _high, "Bad thresholds");
        lowVolumeThreshold = _low;
        highVolumeThreshold = _high;
        emit VolumeThresholdsUpdated(_low, _high);
    }

    function setTaxExempt(address account, bool exempt) external onlyOwner {
        isTaxExempt[account] = exempt;
        emit TaxExemptUpdated(account, exempt);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero newOwner");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }
}
