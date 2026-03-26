// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {AgentArena} from "../src/AgentArena.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Step 1: Deploy contract + approve USDC spend
contract Deploy is Script {
    function run() external {
        uint256 pkClient = vm.envUint("PRIVATE_KEY_CLIENT");
        address usdc = vm.envAddress("PAYMENT_TOKEN");
        uint256 totalBudget = vm.envUint("TOTAL_BUDGET");

        vm.startBroadcast(pkClient);

        AgentArena arena = new AgentArena(usdc);
        console2.log("AgentArena:", address(arena));

        IERC20(usdc).approve(address(arena), totalBudget * 100);
        console2.log("Approved USDC spend");

        vm.stopBroadcast();
    }
}

/// @notice Step 2: Create battle + submit + resolve (pass ARENA_ADDRESS env)
contract RunBattle is Script {
    function run() external {
        uint256 pkClient = vm.envUint("PRIVATE_KEY_CLIENT");
        uint256 pkBotA = vm.envUint("PRIVATE_KEY_BOT_A");
        uint256 pkBotB = vm.envUint("PRIVATE_KEY_BOT_B");
        uint256 pkVerifier = vm.envUint("PRIVATE_KEY_VERIFIER");

        address botA = vm.addr(pkBotA);
        address botB = vm.addr(pkBotB);
        address evaluator = vm.addr(pkVerifier);

        uint256 totalBudget = vm.envUint("TOTAL_BUDGET");
        uint256 deadlineSeconds = vm.envUint("DEADLINE_SECONDS");
        address arenaAddr = vm.envAddress("ARENA_ADDRESS");

        bytes32 description = vm.envBytes32("PROMPT_HASH");
        bytes32 submitAHash = vm.envBytes32("SUBMIT_A_HASH");
        bytes32 submitBHash = vm.envBytes32("SUBMIT_B_HASH");
        bytes32 reason = vm.envBytes32("REASON_HASH");

        AgentArena arena = AgentArena(arenaAddr);

        // 1. Client creates battle (with ERC-8004 agent IDs: 0 = unregistered)
        vm.startBroadcast(pkClient);
        (uint256 battleId, uint256 jobIdA, uint256 jobIdB) = arena.createBattle(
            botA, botB, evaluator, totalBudget,
            block.timestamp + deadlineSeconds,
            string(abi.encodePacked(description)),
            0, // agentIdA (ERC-8004)
            0  // agentIdB (ERC-8004)
        );
        vm.stopBroadcast();

        console2.log("battleId:", battleId);
        console2.log("jobIdA:", jobIdA);
        console2.log("jobIdB:", jobIdB);

        // 2. Bot A submits
        vm.startBroadcast(pkBotA);
        arena.submit(jobIdA, submitAHash, "");
        vm.stopBroadcast();
        console2.log("Bot A submitted");

        // 3. Bot B submits
        vm.startBroadcast(pkBotB);
        arena.submit(jobIdB, submitBHash, "");
        vm.stopBroadcast();
        console2.log("Bot B submitted");

        // 4. Evaluator resolves
        vm.startBroadcast(pkVerifier);
        arena.resolveBattle(battleId, jobIdA, reason);
        vm.stopBroadcast();

        console2.log("Battle resolved. Winner: jobIdA");
    }
}
