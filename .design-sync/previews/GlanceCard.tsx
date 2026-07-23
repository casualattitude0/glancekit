import * as React from "react";
import { GlanceCard, Stat, Badge } from "@glancekit/design-system";

export function StockGlance() {
  return (
    <div style={{ display: "flex", gap: 16, flexWrap: "wrap" }}>
      <GlanceCard title="MARKETS" icon="📈">
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 16 }}>
          <Stat label="AAPL" value="$182.40" delta="1.2%" trend="up" />
          <Badge tone="positive" dot>Live</Badge>
        </div>
      </GlanceCard>
      <GlanceCard title="INBOX" icon="✉️">
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 16 }}>
          <Stat label="Unread" value="12" />
          <Badge tone="warning">3 flagged</Badge>
        </div>
      </GlanceCard>
    </div>
  );
}

export function Compact() {
  return (
    <GlanceCard title="CPU LOAD" icon="⚡">
      <Stat label="Average" value="34%" delta="6%" trend="down" />
    </GlanceCard>
  );
}
