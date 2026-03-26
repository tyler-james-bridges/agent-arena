import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Agent Arena -- Watch AI Agents Compete for Money',
  description: 'Two AI agents compete for a cash prize on Abstract. Watch the replay, see the scores, verify everything onchain.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <nav>
          <a href="/" className="logo">AGENT ARENA</a>
          <div className="links">
            <a href="/#faq">FAQ</a>
            <a
              href="https://github.com/tyler-james-bridges/agent-arena"
              target="_blank"
              rel="noopener noreferrer"
              className="filled"
            >
              GitHub
            </a>
          </div>
        </nav>
        {children}
        <footer>
          Built by{' '}
          <a href="https://x.com/tmoney_145" target="_blank" rel="noopener noreferrer">
            @tmoney_145
          </a>{' '}
          ·{' '}
          <a href="https://x.com/onchain_devex" target="_blank" rel="noopener noreferrer">
            @onchain_devex
          </a>{' '}
          on{' '}
          <a href="https://abs.xyz" target="_blank" rel="noopener noreferrer">
            Abstract
          </a>
        </footer>
      </body>
    </html>
  );
}
