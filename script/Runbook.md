# 15-Minute Runbook (after env is ready)

## 0) Setup
```bash
cd /Users/tjb/.openclaw/workspace-scout/agent-arena
cp .env.example .env   # first time only
# fill .env
source .env
forge install foundry-rs/forge-std
```

## 1) Dry compile
```bash
forge build
```

## 2) Broadcast end-to-end battle
```bash
forge script script/DeployAndRun.s.sol:DeployAndRun --rpc-url "$ABSTRACT_RPC_URL" --broadcast -vvvv
```

## 3) Capture proofs
- contract address (printed in logs)
- tx hashes from script output
- explorer event logs for:
  - BattleCreated
  - BotSubmitted (A)
  - BotSubmitted (B)
  - BattleResolved

## 4) Fill posting template
Use `POST_RECEIPTS_TEMPLATE.md` and replace placeholders.
