// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.7.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./handlers/Block.sol";
import "./handlers/BlockHeader.sol";
import "./handlers/Deposit.sol";
import "./handlers/Fraud.sol";
import "./handlers/Withdrawal.sol";

import "./lib/Cryptography.sol";

import "./types/BlockCommitment.sol";

import "./utils/SafeCast.sol";

/// @notice The Fuel v2 optimistic rollup system.
/// @dev This contract holds storage and immutable fields, with libraries providing the logic.
contract Fuel {
    ////////////////
    // Immutables //
    ////////////////

    /// @dev The Fuel block bond size in wei.
    uint256 public immutable BOND_SIZE;

    /// @dev The Fuel block finalization delay in Ethereum block.
    uint32 public immutable FINALIZATION_DELAY;

    /// @dev The contract name identifier used for EIP712 signing.
    bytes32 public immutable NAME;

    /// @dev The version identifier used for EIP712 signing.
    bytes32 public immutable VERSION;

    /////////////
    // Storage //
    /////////////

    /// @dev Maps Fuel block height => Fuel block ID.
    mapping(bytes32 => BlockCommitment) public s_BlockCommitments;

    /// @dev Maps depositor address => token address => Ethereum block number => token amount.
    mapping(address => mapping(address => mapping(uint32 => uint256))) public s_Deposits;

    /// @dev Maps Ethereum block number => withdrawal ID => is withdrawan bool.
    mapping(uint32 => mapping(bytes32 => bool)) public s_Withdrawals;

    /// @dev Maps fraud prover address => fraud commitment hash => Ethereum block number.
    mapping(address => mapping(bytes32 => uint32)) public s_FraudCommitments;

    /// @dev The Fuel block height of the finalized tip.
    uint32 public s_BlockTip;

    /// @notice Contract constructor.
    /// @param finalizationDelay The delay in blocks for Fuel block finalization.
    /// @param bond The bond in wei to put up for each block.
    /// @param name The name string used for EIP712 signing.
    /// @param version The version used for EIP712 signing.
    constructor(
        uint32 finalizationDelay,
        uint256 bond,
        bytes32 name,
        bytes32 version
    ) {
        // Set immutable constants.
        BOND_SIZE = bond;
        FINALIZATION_DELAY = finalizationDelay;
        NAME = name;
        VERSION = version;

        // Set the genesis block to be valid.
        s_BlockCommitments[bytes32(0)].status = BlockCommitmentStatus.Committed;
    }

    /// @notice Deposit a token.
    /// @param account Address of token owner.
    /// @param token Token address.
    /// @param amount The amount to deposit.
    /// @dev DepositHandler::deposit
    function deposit(
        address account,
        address token,
        uint256 amount
    ) external {
        DepositHandler.deposit(s_Deposits, msg.sender, account, amount, IERC20(token));
    }

    /// @notice Commit a new block.
    /// @param minimum Minimum Ethereum block number that this commitment is valid for.
    /// @param minimumHash Minimum Ethereum block hash that this commitment is valid for.
    /// @param height Rollup block height.
    /// @param previousBlockHash This is the previous merkle root.
    /// @param transactionRoot The transaciton merkle tree root.
    /// @param transactions The raw transaction data for this block.
    /// @param digestRoot The merkle root of the registered digests.
    /// @param digests The digests being registered.
    /// @dev BlockHandler::commitBlock.
    function commitBlock(
        uint32 minimum,
        bytes32 minimumHash,
        uint32 height,
        bytes32 previousBlockHash,
        bytes32 transactionRoot,
        bytes calldata transactions,
        bytes32 digestRoot,
        bytes32[] calldata digests
    ) external payable {
        // Check transaction origin.
        require(tx.origin == msg.sender, "origin-not-caller");

        // To avoid Ethereum re-org attacks, commitment transactions include a minimum.
        // Ethereum block number and block hash. Check will fail if transaction is > 256 block old.
        require(block.number > minimum, "minimum-block-number");
        require(blockhash(minimum) == minimumHash, "minimum-block-hash");

        // Require value be bond size.
        require(msg.value == BOND_SIZE, "bond-size");

        // Transactions packed together in a single bytes store.
        bytes memory packedTransactions = transactions;
        bytes32 commitmentHash = CryptographyLib.hash(packedTransactions);

        // Digest commitment hash.
        bytes32 digestHash = CryptographyLib.hash(abi.encodePacked(digests));

        // Create a Fuel block header.
        BlockHeader memory blockHeader =
            BlockHeader(
                msg.sender,
                previousBlockHash,
                height,
                SafeCast.toUint32(block.number),
                digestRoot,
                digestHash,
                SafeCast.toUint16(digests.length),
                transactionRoot,
                commitmentHash,
                SafeCast.toUint32(packedTransactions.length)
            );

        // Set the new block tip.
        BlockHandler.commitBlock(s_BlockCommitments, blockHeader);
    }

    /// @notice Get a commitment child.
    /// @param blockHash The block has in question.
    /// @param index The child index.
    /// @return child The child block hash.
    function getBlockCommitmentChild(bytes32 blockHash, uint32 index)
        external
        view
        returns (bytes32 child)
    {
        return s_BlockCommitments[blockHash].children[index];
    }

    /// @notice Get a commitment number of children.
    /// @param blockHash The block has in question.
    /// @return numChildren The number of children.
    function getBlockCommitmentNumChildren(bytes32 blockHash)
        external
        view
        returns (uint256 numChildren)
    {
        return s_BlockCommitments[blockHash].children.length;
    }

    /// @notice Register a fraud commitment hash.
    /// @param fraudHash The hash of the calldata used for a fraud commitment.
    /// @dev Uses the message sender (caller()) in the commitment.
    /// @dev Fraudhandler::commitFraudHash
    function commitFraudHash(bytes32 fraudHash) external {
        FraudHandler.commitFraudHash(s_FraudCommitments, fraudHash);
    }

    /// @notice Withdraw the block proposer's bond for a finalized block.
    /// @param blockHeader Rollup block header of block to withdraw bond for.
    /// @dev WithdrawalHandler::bondWithdraw
    function bondWithdraw(BlockHeader calldata blockHeader) external {
        // Ensure that the block header provided is real.
        require(
            BlockHeaderHandler.isBlockHeaderCommitted(s_BlockCommitments, blockHeader),
            "not-committed"
        );
        BlockHeaderHandler.requireBlockHeaderFinalizable(FINALIZATION_DELAY, blockHeader);

        // Handle the withdrawal of the bond.
        WithdrawalHandler.bondWithdraw(s_Withdrawals, BOND_SIZE, blockHeader);
    }
}
