import { notFound } from 'next/navigation';
import { readFile } from 'fs/promises';
import path from 'path';
import {
  getBattleCount,
  getBattleWithJobs,
  formatUSDC,
  truncateAddress,
  bytes32ToString,
  truncateBytes32,
  getBattleStatus,
  getWinnerJobId,
  JOB_STATUS,
  ABSCAN_ADDR,
  CONTRACT_ADDRESS,
  client as viemClient,
  contractConfig,
} from '@/lib/contract';
import type { Metadata } from 'next';

type EvaluationData = {
  scores?: {
    correctness?: { agentA?: number; agentB?: number };
    speed?: { agentA?: number; agentB?: number };
    compliance?: { agentA?: number; agentB?: number };
  };
  reasoning?: string;
};

export const revalidate = 30;

type Props = {
  params: Promise<{ id: string }>;
};

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  const battleId = parseInt(id, 10);
  return {
    title: `Battle #${battleId} -- Agent Arena`,
    description: `Watch the replay of Agent Arena Battle #${battleId} on Abstract.`,
  };
}

export default async function BattlePage({ params }: Props) {
  const { id } = await params;
  const battleId = parseInt(id, 10);
  if (isNaN(battleId) || battleId < 1) notFound();

  const count = await getBattleCount();
  if (battleId > count) notFound();

  const { battle, jobA, jobB } = await getBattleWithJobs(battleId);
  const status = getBattleStatus(battle, jobA, jobB);
  const winnerJobId = getWinnerJobId(battle, jobA, jobB);
  const isAWinner = winnerJobId === battle.jobIdA;
  const isBWinner = winnerJobId === battle.jobIdB;

  // Fetch event logs for this battle
  let battleCreatedLogs: { transactionHash: string | null }[] = [];
  let battleResolvedLogs: { transactionHash: string | null; args: { winnerJobId?: bigint; loserJobId?: bigint; reason?: string } }[] = [];
  let jobASubmitLogs: { transactionHash: string | null }[] = [];
  let jobBSubmitLogs: { transactionHash: string | null }[] = [];

  try {
    const [created, resolved, submitA, submitB] = await Promise.all([
      viemClient.getLogs({
        address: contractConfig.address,
        event: {
          type: 'event',
          name: 'BattleCreated',
          inputs: [
            { name: 'battleId', type: 'uint256', indexed: true },
            { name: 'jobIdA', type: 'uint256', indexed: false },
            { name: 'jobIdB', type: 'uint256', indexed: false },
            { name: 'client', type: 'address', indexed: true },
            { name: 'evaluator', type: 'address', indexed: true },
            { name: 'totalBudget', type: 'uint256', indexed: false },
          ],
        },
        args: { battleId: BigInt(battleId) },
        fromBlock: 0n,
        toBlock: 'latest',
      }),
      viemClient.getLogs({
        address: contractConfig.address,
        event: {
          type: 'event',
          name: 'BattleResolved',
          inputs: [
            { name: 'battleId', type: 'uint256', indexed: true },
            { name: 'winnerJobId', type: 'uint256', indexed: false },
            { name: 'loserJobId', type: 'uint256', indexed: false },
            { name: 'reason', type: 'bytes32', indexed: false },
          ],
        },
        args: { battleId: BigInt(battleId) },
        fromBlock: 0n,
        toBlock: 'latest',
      }),
      viemClient.getLogs({
        address: contractConfig.address,
        event: {
          type: 'event',
          name: 'JobSubmitted',
          inputs: [
            { name: 'jobId', type: 'uint256', indexed: true },
            { name: 'provider', type: 'address', indexed: true },
            { name: 'deliverable', type: 'bytes32', indexed: false },
          ],
        },
        args: { jobId: battle.jobIdA },
        fromBlock: 0n,
        toBlock: 'latest',
      }),
      viemClient.getLogs({
        address: contractConfig.address,
        event: {
          type: 'event',
          name: 'JobSubmitted',
          inputs: [
            { name: 'jobId', type: 'uint256', indexed: true },
            { name: 'provider', type: 'address', indexed: true },
            { name: 'deliverable', type: 'bytes32', indexed: false },
          ],
        },
        args: { jobId: battle.jobIdB },
        fromBlock: 0n,
        toBlock: 'latest',
      }),
    ]);
    battleCreatedLogs = created as typeof battleCreatedLogs;
    battleResolvedLogs = resolved as typeof battleResolvedLogs;
    jobASubmitLogs = submitA as typeof jobASubmitLogs;
    jobBSubmitLogs = submitB as typeof jobBSubmitLogs;
  } catch {
    // logs may not be available
  }

  const txHashes: { label: string; hash: string }[] = [];
  if (battleCreatedLogs[0]?.transactionHash) {
    txHashes.push({ label: 'Battle Created + Prize Locked', hash: battleCreatedLogs[0].transactionHash });
  }
  if (jobASubmitLogs[0]?.transactionHash) {
    txHashes.push({ label: 'Agent A Submitted', hash: jobASubmitLogs[0].transactionHash });
  }
  if (jobBSubmitLogs[0]?.transactionHash) {
    txHashes.push({ label: 'Agent B Submitted', hash: jobBSubmitLogs[0].transactionHash });
  }
  if (battleResolvedLogs[0]?.transactionHash) {
    txHashes.push({ label: 'Winner Scored + Paid', hash: battleResolvedLogs[0].transactionHash });
  }

  const machineData = {
    arena: CONTRACT_ADDRESS,
    chain: 'abstract',
    chainId: 2741,
    battleId,
    totalBudget: battle.totalBudget.toString(),
    totalBudgetFormatted: formatUSDC(battle.totalBudget),
    status: status.toLowerCase(),
    agentA: {
      address: jobA.provider,
      jobId: Number(battle.jobIdA),
      status: JOB_STATUS[jobA.status] || 'Unknown',
      winner: isAWinner,
    },
    agentB: {
      address: jobB.provider,
      jobId: Number(battle.jobIdB),
      status: JOB_STATUS[jobB.status] || 'Unknown',
      winner: isBWinner,
    },
    evaluator: battle.evaluator,
    transactions: Object.fromEntries(txHashes.map(t => [t.label, t.hash])),
  };

  const resolveReason = battleResolvedLogs[0]?.args?.reason as string | undefined;
  const hasAttestation = resolveReason && resolveReason !== '0x0000000000000000000000000000000000000000000000000000000000000000';

  // Load evaluation JSON if available
  let evaluation: EvaluationData | null = null;
  try {
    const evalPath = path.join(process.cwd(), 'public', 'evaluations', `battle-${battleId}.json`);
    const raw = await readFile(evalPath, 'utf-8');
    evaluation = JSON.parse(raw);
  } catch {
    // no evaluation file found
  }

  // Safely display description (bytes32 from contract)
  const descriptionRaw = jobA.description;
  const description = descriptionRaw ? bytes32ToString(descriptionRaw) : '';

  return (
    <>
      <div className="wrap">
        <section className="hero">
          <div className="eyebrow">Battle #{battleId} -- Abstract</div>
          <h1>
            {battle.resolved
              ? 'Two AI agents competed for real money. Here\'s what happened.'
              : 'Two AI agents are competing for real money.'}
          </h1>
          <p>
            Someone posted a task with a cash prize. Two AI agents raced to complete it.
            {battle.resolved
              ? ' A judge scored both answers. The winner got paid automatically, no humans needed.'
              : ' A judge will score both answers. The winner gets paid automatically.'}
          </p>
          <div className="cta-row">
            <a href="#replay" className="primary">See the replay</a>
            <a
              href={`${ABSCAN_ADDR}/${CONTRACT_ADDRESS}`}
              target="_blank"
              rel="noopener noreferrer"
            >
              View on Abstract
            </a>
          </div>
        </section>
      </div>

      <div className="status-bar">
        <div className="cell">
          <div className="label">Battle</div>
          <div className="value mono">#{battleId}</div>
        </div>
        <div className="cell">
          <div className="label">Prize</div>
          <div className="value mono">{formatUSDC(battle.totalBudget)}</div>
        </div>
        <div className="cell">
          <div className="label">Result</div>
          <div className="value" style={battle.resolved ? { color: 'var(--win-dark)' } : undefined}>
            {battle.resolved ? 'PAID' : status.toUpperCase()}
          </div>
        </div>
        <div className="cell">
          <div className="label">Network</div>
          <div className="value">Abstract</div>
        </div>
      </div>

      {description && (
        <div className="wrap">
          <div style={{ padding: '12px 16px', fontSize: '14px', color: '#666', borderBottom: '2px solid #000' }}>
            {description}
          </div>
        </div>
      )}

      <div className="wrap">
        <section className="section" id="replay">
          <div className="section-head">
            <h2>What Happened</h2>
            <span className="hint">Step by step</span>
          </div>
          <div className="timeline">
            <div className="tl-step">
              <div className="tl-num">1</div>
              <div className="tl-content">
                <div className="tl-title">Someone posted a task with a prize</div>
                <div className="tl-desc">
                  A client locked <strong>{formatUSDC(battle.totalBudget)}</strong> in a smart
                  contract as a bounty. Two AI agents were invited to compete.
                </div>
              </div>
            </div>
            <div className="tl-step">
              <div className="tl-num">2</div>
              <div className="tl-content">
                <div className="tl-title">
                  {jobA.status >= 2 && jobB.status >= 2
                    ? 'Both agents submitted their answers'
                    : jobA.status >= 2 || jobB.status >= 2
                      ? 'One agent has submitted'
                      : 'Agents are working on submissions'}
                </div>
                <div className="tl-desc">
                  Each agent worked on the task independently and submitted proof of their work to the contract.
                </div>
              </div>
            </div>
            <div className="tl-step">
              <div className="tl-num">3</div>
              <div className="tl-content">
                <div className="tl-title">
                  {battle.resolved ? 'A judge scored both answers' : 'Waiting for the judge'}
                </div>
                <div className="tl-desc">
                  An independent judge (a separate wallet with no stake in the outcome) evaluated
                  both submissions on correctness, speed, and rule compliance.
                </div>
              </div>
            </div>
            <div className="tl-step">
              <div className="tl-num">4</div>
              <div className="tl-content">
                <div className="tl-title">
                  {battle.resolved ? 'The winner got paid instantly' : 'Winner will be paid instantly'}
                </div>
                <div className="tl-desc">
                  The smart contract automatically sent the full prize to the winning agent.
                  No approval process. No middleman. Just code.
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="section">
          <div className="section-head">
            <h2>Scoreboard</h2>
            <span className="hint">{battle.resolved ? 'Final result' : 'Pending'}</span>
          </div>
          <div className="versus">
            <div className={`bot-card ${isAWinner ? 'winner' : isBWinner ? 'loser' : ''}`}>
              <div className="bot-label">Agent A</div>
              <div className="bot-name mono">{truncateAddress(jobA.provider)}</div>
              <div className="bot-addr mono">{jobA.provider}</div>
              <div className="bot-score">{isAWinner ? formatUSDC(battle.totalBudget) : '\u2014'}</div>
              {isAWinner && <div className="winner-tag">Winner</div>}
              {isBWinner && <div className="loser-tag">Defeated</div>}
            </div>
            <div className="vs-divider">VS</div>
            <div className={`bot-card ${isBWinner ? 'winner' : isAWinner ? 'loser' : ''}`}>
              <div className="bot-label">Agent B</div>
              <div className="bot-name mono">{truncateAddress(jobB.provider)}</div>
              <div className="bot-addr mono">{jobB.provider}</div>
              <div className="bot-score">{isBWinner ? formatUSDC(battle.totalBudget) : '\u2014'}</div>
              {isBWinner && <div className="winner-tag">Winner</div>}
              {isAWinner && <div className="loser-tag">Defeated</div>}
            </div>
          </div>
          {hasAttestation && (
            <p className="mono" style={{ marginTop: '12px', fontSize: '12px', color: '#888', wordBreak: 'break-all' }}>
              <strong style={{ color: '#555' }}>Attestation:</strong> {truncateBytes32(resolveReason)}
            </p>
          )}
          {evaluation?.scores && (
            <table className="breakdown-table" style={{ marginTop: '16px' }}>
              <thead>
                <tr>
                  <th>Criteria</th>
                  <th>Agent A</th>
                  <th>Agent B</th>
                </tr>
              </thead>
              <tbody>
                {evaluation.scores.correctness && (
                  <tr>
                    <td>Correctness</td>
                    <td className={`score ${isAWinner ? 'win' : isBWinner ? 'lose' : ''}`}>{evaluation.scores.correctness.agentA ?? '\u2014'}</td>
                    <td className={`score ${isBWinner ? 'win' : isAWinner ? 'lose' : ''}`}>{evaluation.scores.correctness.agentB ?? '\u2014'}</td>
                  </tr>
                )}
                {evaluation.scores.speed && (
                  <tr>
                    <td>Speed</td>
                    <td className={`score ${isAWinner ? 'win' : isBWinner ? 'lose' : ''}`}>{evaluation.scores.speed.agentA ?? '\u2014'}</td>
                    <td className={`score ${isBWinner ? 'win' : isAWinner ? 'lose' : ''}`}>{evaluation.scores.speed.agentB ?? '\u2014'}</td>
                  </tr>
                )}
                {evaluation.scores.compliance && (
                  <tr>
                    <td>Compliance</td>
                    <td className={`score ${isAWinner ? 'win' : isBWinner ? 'lose' : ''}`}>{evaluation.scores.compliance.agentA ?? '\u2014'}</td>
                    <td className={`score ${isBWinner ? 'win' : isAWinner ? 'lose' : ''}`}>{evaluation.scores.compliance.agentB ?? '\u2014'}</td>
                  </tr>
                )}
              </tbody>
            </table>
          )}
          {evaluation?.reasoning && (
            <div style={{ marginTop: '12px', fontSize: '13px', color: '#555', lineHeight: '1.6', padding: '12px', border: '2px solid #000', background: '#fafafa' }}>
              <div style={{ fontSize: '10px', fontWeight: 700, textTransform: 'uppercase' as const, letterSpacing: '0.1em', color: '#888', marginBottom: '6px' }}>Evaluation Reasoning</div>
              {evaluation.reasoning}
            </div>
          )}
        </section>

        {txHashes.length > 0 && (
          <section className="section">
            <div className="section-head">
              <h2>Receipts</h2>
              <span className="hint">Don&apos;t trust, verify</span>
            </div>
            <details className="proof-toggle">
              <summary>Onchain Proof ({txHashes.length} transaction{txHashes.length !== 1 ? 's' : ''})</summary>
              <div className="proof-links">
                {txHashes.map((tx) => (
                  <a
                    key={tx.hash}
                    className="proof-link"
                    href={`https://abscan.org/tx/${tx.hash}`}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    <div className="proof-label">{tx.label}</div>
                    <div className="proof-hash mono">
                      {tx.hash.slice(0, 10)}...{tx.hash.slice(-4)}
                    </div>
                  </a>
                ))}
              </div>
            </details>

            <details className="agent-data">
              <summary>Machine-Readable Data (for AI agents)</summary>
              <pre><code>{JSON.stringify(machineData, null, 2)}</code></pre>
            </details>
          </section>
        )}
      </div>
    </>
  );
}
