import * as React from "react";

export type StatTrend = "up" | "down" | "flat";

export interface StatProps {
  /** Caption above the value. */
  label: string;
  /** The headline value — rendered with tabular (monospaced) digits so it
   * stays stable as it updates. Pass pre-formatted text ("$182.40", "72%"). */
  value: React.ReactNode;
  /** Optional change indicator shown beside the value. */
  delta?: string;
  /** Direction of `delta` — colours it green (up), red (down) or grey (flat)
   * and picks the arrow. */
  trend?: StatTrend;
}

const ARROW: Record<StatTrend, string> = { up: "▲", down: "▼", flat: "→" };

/**
 * A glanceable metric: a caption over a large tabular-figures value with an
 * optional coloured delta. The core widget readout — built for numbers that
 * change without the layout shifting.
 */
export function Stat({ label, value, delta, trend = "flat" }: StatProps) {
  return (
    <div className="gk-stat">
      <span className="gk-stat__label">{label}</span>
      <span className="gk-stat__value-row">
        <span className="gk-stat__value">{value}</span>
        {delta != null && (
          <span className={`gk-stat__delta gk-stat__delta--${trend}`}>
            <span aria-hidden>{ARROW[trend]}</span>
            {delta}
          </span>
        )}
      </span>
    </div>
  );
}
