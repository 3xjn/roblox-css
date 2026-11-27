import React from '@rbxts/react';

export interface StatusCardProps {
  title: string;
  online: boolean;
  clicks: number;
  onToggle: () => void;
  onCount: () => void;
}

export function StatusCard({ title, online, clicks, onToggle, onCount }: StatusCardProps) {
  return (
    <div className="card">
      <div className="header">
        <span className="title">{title}</span>
        <span className="badge" data-state={online ? 'online' : 'away'}>
          {online ? 'Online' : 'Away'}
        </span>
      </div>
      <p className="body">
        Styled with ordinary CSS rules, variables, :hover/:active, and data-state selectors — no Tailwind.
      </p>
      <div className="actions">
        <button className="btn" onClick={onToggle}>
          Toggle status
        </button>
        <button className="btn btn-outline" onClick={onCount}>
          Count
        </button>
        <span className="badge">Clicks: {clicks}</span>
      </div>
    </div>
  );
}
