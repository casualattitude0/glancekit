import * as React from "react";
import { TextField } from "@glancekit/design-system";

const col: React.CSSProperties = { display: "flex", flexDirection: "column", gap: 12, width: 260 };

export function Labeled() {
  return (
    <div style={col}>
      <TextField label="Feed URL" defaultValue="https://api.example.com/quotes" />
      <TextField label="API key" secure defaultValue="sk-live-9f2a1c" />
    </div>
  );
}

export function Placeholder() {
  return (
    <div style={col}>
      <TextField label="Symbol" placeholder="e.g. AAPL" />
    </div>
  );
}

export function Disabled() {
  return (
    <div style={col}>
      <TextField label="Account" defaultValue="casual@glancekit.app" disabled />
    </div>
  );
}
