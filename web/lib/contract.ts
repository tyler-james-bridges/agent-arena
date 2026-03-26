import { createPublicClient, http, formatUnits, type Address } from 'viem';
import { abstract } from 'viem/chains';
import abi from '../abi.json';

export const CONTRACT_ADDRESS = '0xAfbD99288D78Db7C18ca78B2A695Ba2d13f7f706' as const;
export const USDC_ADDRESS = '0x84A71ccD554Cc1b02749b35d22F684CC8ec987e1' as const;
export const ABSCAN_TX = 'https://abscan.org/tx';
export const ABSCAN_ADDR = 'https://abscan.org/address';

export const client = createPublicClient({
  chain: abstract,
  transport: http('https://api.mainnet.abs.xyz'),
});

export const contractConfig = {
  address: CONTRACT_ADDRESS as Address,
  abi,
} as const;

export const JOB_STATUS = ['Open', 'Funded', 'Submitted', 'Completed', 'Rejected', 'Expired'] as const;

export function formatUSDC(raw: bigint): string {
  const num = Number(formatUnits(raw, 6));
  return `$${num.toFixed(2)} USDC`;
}

export function truncateAddress(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

export function truncateBytes32(hex: string): string {
  if (!hex || hex.length <= 14) return hex || '';
  return `${hex.slice(0, 8)}...${hex.slice(-4)}`;
}

export function bytes32ToString(hex: string): string {
  try {
    if (!hex || /^0x0*$/.test(hex)) return '';
    const clean = hex.replace(/^0x/, '').replace(/00+$/, '');
    if (!clean) return '';
    const bytes: number[] = [];
    for (let i = 0; i < clean.length; i += 2) {
      bytes.push(parseInt(clean.substring(i, i + 2), 16));
    }
    // Only decode if all bytes are printable ASCII (0x20-0x7E)
    if (bytes.every(b => b >= 0x20 && b <= 0x7e)) {
      return new TextDecoder().decode(new Uint8Array(bytes));
    }
    return truncateBytes32(hex);
  } catch {
    return truncateBytes32(hex);
  }
}

export type BattleData = {
  battleId: number;
  jobIdA: bigint;
  jobIdB: bigint;
  client: string;
  evaluator: string;
  totalBudget: bigint;
  resolved: boolean;
};

export type JobData = {
  client: string;
  provider: string;
  evaluator: string;
  budget: bigint;
  expiredAt: bigint;
  description: string;
  deliverable: string;
  status: number;
  providerAgentId: bigint;
  hook: string;
};

export async function getBattleCount(): Promise<number> {
  const count = await client.readContract({
    ...contractConfig,
    functionName: 'battleCount',
  }) as bigint;
  return Number(count);
}

export async function getBattle(battleId: number): Promise<BattleData> {
  const result = await client.readContract({
    ...contractConfig,
    functionName: 'getBattle',
    args: [BigInt(battleId)],
  }) as [bigint, bigint, string, string, bigint, boolean];
  return {
    battleId,
    jobIdA: result[0],
    jobIdB: result[1],
    client: result[2],
    evaluator: result[3],
    totalBudget: result[4],
    resolved: result[5],
  };
}

export async function getJob(jobId: bigint): Promise<JobData> {
  const result = await client.readContract({
    ...contractConfig,
    functionName: 'getJob',
    args: [jobId],
  }) as [string, string, string, bigint, bigint, string, string, number, bigint, string];
  return {
    client: result[0],
    provider: result[1],
    evaluator: result[2],
    budget: result[3],
    expiredAt: result[4],
    description: result[5],
    deliverable: result[6],
    status: result[7],
    providerAgentId: result[8],
    hook: result[9],
  };
}

export async function getBattleWithJobs(battleId: number) {
  const battle = await getBattle(battleId);
  const [jobA, jobB] = await Promise.all([
    getJob(battle.jobIdA),
    getJob(battle.jobIdB),
  ]);
  return { battle, jobA, jobB };
}

export async function getAllBattles() {
  const count = await getBattleCount();
  const battles = [];
  for (let i = 1; i <= count; i++) {
    try {
      const data = await getBattleWithJobs(i);
      battles.push(data);
    } catch {
      // skip invalid battles
    }
  }
  return battles;
}

export function getBattleStatus(battle: BattleData, jobA: JobData, jobB: JobData): string {
  if (battle.resolved) return 'Resolved';
  if (jobA.status >= 2 || jobB.status >= 2) return 'In Progress';
  return 'Open';
}

export function getWinnerJobId(battle: BattleData, jobA: JobData, jobB: JobData): bigint | null {
  if (!battle.resolved) return null;
  if (jobA.status === 3) return battle.jobIdA;
  if (jobB.status === 3) return battle.jobIdB;
  return null;
}
