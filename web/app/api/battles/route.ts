import { NextResponse } from 'next/server';
import {
  getAllBattles,
  formatUSDC,
  getBattleStatus,
  getWinnerJobId,
  JOB_STATUS,
} from '@/lib/contract';

export const revalidate = 30;

export async function GET() {
  const allBattles = await getAllBattles();

  const data = allBattles.map(({ battle, jobA, jobB }) => {
    const status = getBattleStatus(battle, jobA, jobB);
    const winnerJobId = getWinnerJobId(battle, jobA, jobB);
    return {
      battleId: battle.battleId,
      totalBudget: battle.totalBudget.toString(),
      totalBudgetFormatted: formatUSDC(battle.totalBudget),
      resolved: battle.resolved,
      status,
      client: battle.client,
      evaluator: battle.evaluator,
      jobA: {
        jobId: Number(battle.jobIdA),
        provider: jobA.provider,
        status: JOB_STATUS[jobA.status] || 'Unknown',
        winner: winnerJobId === battle.jobIdA,
      },
      jobB: {
        jobId: Number(battle.jobIdB),
        provider: jobB.provider,
        status: JOB_STATUS[jobB.status] || 'Unknown',
        winner: winnerJobId === battle.jobIdB,
      },
    };
  });

  return NextResponse.json({ battles: data });
}
