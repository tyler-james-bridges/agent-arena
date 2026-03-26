# Agent Arena Web App — Build Spec

## Overview
Build a Next.js web app for Agent Arena — an ERC-8183 compliant agent battle platform on Abstract (chain ID 2741). The app reads from an onchain contract to display battle results dynamically.

## Stack
- Next.js 15+ (App Router)
- TypeScript
- viem for contract reads
- Vanilla CSS (brutalist style, NO Tailwind)
- Deploy target: Vercel

## Contract Details
- **Address:** `0xc36BF8e23BE1bB9cb7062b35D17aCcDBA8D90651`
- **Chain:** Abstract (chainId: 2741, RPC: `https://api.mainnet.abs.xyz`)
- **Payment Token:** USDC.e `0x84A71ccD554Cc1b02749b35d22F684CC8ec987e1` (6 decimals)

### Key Contract Functions (read)
- `battleCount() → uint256` — total battles
- `jobCount() → uint256` — total jobs  
- `getBattle(uint256 battleId) → (uint256 jobIdA, uint256 jobIdB, address client, address evaluator, uint256 totalBudget, bool resolved)`
- `getJob(uint256 jobId) → (address client, address provider, address evaluator, uint256 budget, uint256 expiredAt, bytes32 description, bytes32 deliverable, uint8 status)`
- `jobToBattle(uint256 jobId) → uint256 battleId`

### Job Status Enum
0=Open, 1=Funded, 2=Submitted, 3=Completed, 4=Rejected, 5=Expired

### Events (for tx history via getLogs)
- `BattleCreated(uint256 indexed battleId, uint256 jobIdA, uint256 jobIdB, address indexed client, address indexed evaluator, uint256 totalBudget)`
- `BattleResolved(uint256 indexed battleId, uint256 winnerJobId, uint256 loserJobId, bytes32 reason)`
- `JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable)`
- `JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason)`
- `JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason)`

## Pages

### 1. Landing Page (`/`)
- Hero section: "Two agents entered. One got paid." headline
- Sub: explains what Agent Arena is in plain English (no jargon)
- Stats bar: total battles, total USDC paid out, network=Abstract
- Battle feed: list all battles from battleCount(), newest first
  - Each battle card: Battle #N, prize (formatted USDC), status (Open/In Progress/Resolved), winner address (truncated)
  - Each card links to /battle/[id]
- "How It Works" 4-step grid (Escrow, Submit, Score, Pay)
- FAQ section with these questions:
  - What is this?
  - Is this real money?
  - Can I verify this happened?
  - What is Abstract?
  - Can I run my own battle?
  - What's ERC-8183?
- Footer: Built by @onchain_devex on Abstract

### 2. Battle Detail Page (`/battle/[id]`)
- Reads battle data + both jobs from contract
- Status bar: battle #, prize, status, network
- "What Happened" narrative timeline (4 steps, built from actual job states)
- Scoreboard: two cards side-by-side
  - Winner card: dark green bg (var(--win-bg)), white text, "Winner" tag
  - Loser card: dark red bg (var(--lose-bg)), white text, "Defeated" tag
  - Each shows: agent label, address (mono), score (large)
  - VS divider between them
- Score breakdown table (if available)
- "Verify It Yourself" section: fetch event logs for this battle's tx hashes, link to abscan
- Machine-readable JSON (collapsible details element)

### 3. API Routes
- `GET /api/battles` — returns all battles with job data as JSON
- `GET /api/battles/[id]` — single battle with full job details

## Design System (CRITICAL — replicate exactly from design-reference.html)

### Colors
```css
:root {
  --win: #10b981;
  --win-dark: #065f46;
  --win-bg: #022c22;
  --win-light: #d1fae5;
  --lose: #ef4444;
  --lose-dark: #991b1b;
  --lose-bg: #450a0a;
  --lose-light: #fecaca;
}
```

### Rules
- Background: #fff, text: #000
- ALL borders: 2px solid #000
- Font: system-ui, -apple-system, sans-serif
- Monospace (addresses, hashes, numbers): ui-monospace, SFMono-Regular, Menlo, monospace
- Buttons/nav links: 2px border, uppercase text, bold, letter-spacing 0.05em, hover → black bg white text
- Winner: bg var(--win-bg), text white
- Loser: bg var(--lose-bg), text white
- Score table winning cells: var(--win-bg) bg, var(--win) text
- Score table losing cells: var(--lose-bg) bg, var(--lose) text
- "PAID" status text: color var(--win-dark)
- NO rounded corners (border-radius: 0)
- NO shadows
- NO gradients
- NO Tailwind
- Responsive: mobile stack on <640px, max-width 800px on desktop
- Section headings: 12px, uppercase, bold, letter-spacing 0.1em

### Reference
`design-reference.html` in this directory is the pixel-perfect reference. Match it exactly.

## Data
- Server components call viem readContract() 
- Use `revalidate = 30` (ISR)
- Event logs via viem getLogs for tx hashes
- USDC formatting: divide raw by 1e6, show as "$X.XX USDC"
- Truncate addresses: first 6 + last 4 chars

## ABI
Full ABI is in `abi.json` in this directory. Import it in lib/contract.ts.

## What NOT to Build
- No wallet connection
- No battle creation UI  
- No Tailwind
- No dark mode
- No animations beyond hover transitions
- No dependencies beyond next, react, viem

## Abscan Links
- Tx: `https://abscan.org/tx/{hash}`
- Address: `https://abscan.org/address/{addr}`
