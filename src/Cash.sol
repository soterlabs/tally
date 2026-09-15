// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

interface CashTallyLike {
    function sort(int256 wad, uint8 to) external;
}

/// Authorized attribution of Ethereum cash receipts to prime supply income.
/// The writer verifies finalized receipt evidence and economic purpose off-chain.
/// This contract does NOT prove a Transfer log or turn every payer transfer into
/// yield. It deduplicates chain/Tally/transaction/log references and uses sort:
/// existing cash stays in NAV, gain increases, and unassigned equity decreases.
/// Grant this contract a Tally ward only after configuring trusted writers.
contract Cash {
    mapping (address => uint256) public wards;
    CashTallyLike public immutable tally;
    mapping (bytes32 => uint256) public receipts; // attributed amount [wad]

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Note(bytes32 indexed txid, uint256 indexed logidx, uint256 wad);

    modifier auth {
        require(wards[msg.sender] == 1, "Cash/not-authorized");
        _;
    }

    constructor(address tally_) {
        require(tally_ != address(0), "Cash/zero-tally");
        tally = CashTallyLike(tally_);
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }

    function note(bytes32 txid, uint256 logidx, uint256 wad) external auth {
        require(txid != bytes32(0), "Cash/zero-txid");
        require(wad > 0 && wad <= uint256(type(int256).max), "Cash/bad-amount");
        bytes32 ref = keccak256(abi.encode(block.chainid, address(tally), txid, logidx));
        require(receipts[ref] == 0, "Cash/already-noted");
        receipts[ref] = wad;
        tally.sort(int256(wad), 1); // MTM: supply income, subject to supply-loss carry
        emit Note(txid, logidx, wad);
    }
}
