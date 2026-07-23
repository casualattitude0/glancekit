import * as React from "react";
import { Stat } from "@glancekit/design-system";

const row: React.CSSProperties = { display: "flex", gap: 28, alignItems: "flex-start", flexWrap: "wrap" };

export function Trends() {
  return (
    <div style={row}>
      <Stat label="AAPL" value="$182.40" delta="1.2%" trend="up" />
      <Stat label="TSLA" value="$241.05" delta="0.9%" trend="down" />
      <Stat label="Portfolio" value="$48,207" delta="0.0%" trend="flat" />
    </div>
  );
}

export function Plain() {
  return (
    <div style={row}>
      <Stat label="Unread" value="12" />
      <Stat label="CPU" value="34%" />
      <Stat label="Next event" value="2:30 PM" />
    </div>
  );
}
