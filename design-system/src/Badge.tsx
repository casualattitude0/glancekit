import * as React from "react";

export type BadgeTone = "neutral" | "positive" | "negative" | "warning" | "info";

export interface BadgeProps {
  /** Semantic colour: neutral, positive (green), negative (red), warning
   * (orange) or info (accent) — the status palette from the glances. */
  tone?: BadgeTone;
  /** Show a leading status dot. */
  dot?: boolean;
  /** Badge text. */
  children?: React.ReactNode;
}

/**
 * A small status pill in the glance status palette — a compact, rounded label
 * for state (Live, Paused, Error, Delayed). Keep the text to a word or two.
 */
export function Badge({ tone = "neutral", dot, children }: BadgeProps) {
  return (
    <span className={`gk-badge gk-badge--${tone}`}>
      {dot && <span className="gk-badge__dot" />}
      {children}
    </span>
  );
}
