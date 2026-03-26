import { NextResponse } from 'next/server';
import {
  getBattleCount,
  getBattleWithJobs,
  formatUSDC,
  getBattleStatus,
  getWinnerJobId,
  JOB_STATUS,
} from '@/lib/contract';

export const revalidate = 30;

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const battleId = parseInt(id, 10);
  if (isNaN(battleId) || battleId < 1) {
    return NextResponse.json({ error: 'Invalid battle ID' }, { status: 400 });
  }

  const count = await getBattleCount();
  if (battleId > count) {
    return NextResponse.json({ error: 'Battle not found' }, { status: 404 });
  }

  const { battle, jobA, jobB } = await getBattleWithJobs(battleId);
  const status = getBattleStatus(battle, jobA, jobB);
  const winnerJobId = getWinnerJobId(battle, jobA, jobB);

  return NextResponse.json({
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
      budget: jobA.budget.toString(),
      budgetFormatted: formatUSDC(jobA.budget),
      winner: winnerJobId === battle.jobIdA,
    },
    jobB: {
      jobId: Number(battle.jobIdB),
      provider: jobB.provider,
      status: JOB_STATUS[jobB.status] || 'Unknown',
      budget: jobB.budget.toString(),
      budgetFormatted: formatUSDC(jobB.budget),
      winner: winnerJobId === battle.jobIdB,
    },
  });
}
