import * as React from "react";
import { Badge } from "@glancekit/design-system";

const row: React.CSSProperties = { display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" };

export function Tones() {
  return (
    <div style={row}>
      <Badge tone="positive">+1.24%</Badge>
      <Badge tone="negative">−0.86%</Badge>
      <Badge tone="warning">Delayed</Badge>
      <Badge tone="info">Beta</Badge>
      <Badge tone="neutral">Closed</Badge>
    </div>
  );
}

export function WithDot() {
  return (
    <div style={row}>
      <Badge tone="positive" dot>Live</Badge>
      <Badge tone="warning" dot>Paused</Badge>
      <Badge tone="negative" dot>Error</Badge>
    </div>
  );
}
