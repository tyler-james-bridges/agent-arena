'use client';

import { useEffect, useState } from 'react';
import { keccak256, toBytes } from 'viem';

type Props = {
  battleId: number;
  onchainHash: string;
};

export default function HashVerifier({ battleId, onchainHash }: Props) {
  const [status, setStatus] = useState<'loading' | 'verified' | 'mismatch' | 'no-data'>('loading');
  const [computedHash, setComputedHash] = useState<string | null>(null);

  useEffect(() => {
    async function verify() {
      try {
        const res = await fetch(`/evaluations/battle-${battleId}.json`);
        if (!res.ok) {
          setStatus('no-data');
          return;
        }
        const raw = await res.text();
        // Hash the raw JSON string exactly as it was hashed before submitting onchain
        // The onchain hash was created with: cast keccak <json_string>
        // cast keccak uses keccak256 of the UTF-8 bytes
        const hash = keccak256(toBytes(raw.trim()));
        setComputedHash(hash);
        if (hash.toLowerCase() === onchainHash.toLowerCase()) {
          setStatus('verified');
        } else {
          setStatus('mismatch');
        }
      } catch {
        setStatus('no-data');
      }
    }
    verify();
  }, [battleId, onchainHash]);

  if (status === 'loading') {
    return <span style={{ fontSize: '11px', color: '#888' }}>Verifying...</span>;
  }

  if (status === 'no-data') {
    return (
      <span style={{ fontSize: '11px', color: '#888' }}>
        No evaluation data available for independent verification
      </span>
    );
  }

  if (status === 'verified') {
    return (
      <div style={{ marginTop: '8px', padding: '8px 12px', border: '2px solid #22c55e', background: '#f0fdf4', fontSize: '12px' }}>
        <strong style={{ color: '#16a34a' }}>✓ VERIFIED</strong>
        <span style={{ color: '#555', marginLeft: '8px' }}>
          Evaluation hash matches onchain attestation
        </span>
        <div className="mono" style={{ fontSize: '10px', color: '#888', marginTop: '4px', wordBreak: 'break-all' }}>
          Computed: {computedHash}
        </div>
      </div>
    );
  }

  return (
    <div style={{ marginTop: '8px', padding: '8px 12px', border: '2px solid #ef4444', background: '#fef2f2', fontSize: '12px' }}>
      <strong style={{ color: '#dc2626' }}>✗ MISMATCH</strong>
      <span style={{ color: '#555', marginLeft: '8px' }}>
        Evaluation data does not match onchain hash
      </span>
      {computedHash && (
        <div className="mono" style={{ fontSize: '10px', color: '#888', marginTop: '4px', wordBreak: 'break-all' }}>
          Computed: {computedHash}<br />
          Onchain: {onchainHash}
        </div>
      )}
    </div>
  );
}
