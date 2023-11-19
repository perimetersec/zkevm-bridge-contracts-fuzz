// SPDX-License-Identifier: Apache 2.0
pragma solidity 0.8.19;

interface IFlowRateWithdrawalQueueEvents {
    // Indicates a withdrawal has been queued.
    event EnQueuedWithdrawal(
        address indexed token,
        address indexed withdrawer,
        address indexed receiver,
        uint256 amount,
        uint256 timestamp,
        uint256 index
    );

    // Indicates a withdrawal has been processed.
    event ProcessedWithdrawal(
        address indexed token, address indexed withdrawer, address indexed receiver, uint256 amount, uint256 index
    );

    // Indicates that the new withdrawal delay.
    event WithdrawalDelayUpdated(uint256 delay, uint256 previousDelay);
}

interface IFlowRateWithdrawalQueueErrors {
    // A withdrawal was being processed, but the index is outside of the array.
    error IndexOutsideWithdrawalQueue(uint256 lengthOfQueue, uint256 requestedIndex);

    // A withdrawal was being processed, but the withdrawal is not yet available.
    error WithdrawalRequestTooEarly(uint256 timeNow, uint256 currentWithdrawalTime);

    // A withdrawal was being processed, but the token is zero. This indicates that the
    // withdrawal has already been processed.
    error WithdrawalAlreadyProcessed(address receiver, uint256 index);

    // Attempting to enqueue a token with token address = 0.
    error TokenIsZero(address receiver);
}
