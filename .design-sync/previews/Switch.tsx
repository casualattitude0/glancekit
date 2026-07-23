import * as React from "react";
import { Switch } from "@glancekit/design-system";

const col: React.CSSProperties = { display: "flex", flexDirection: "column", gap: 12 };

export function OnAndOff() {
  return (
    <div style={col}>
      <Switch checked label="Launch at login" />
      <Switch checked={false} label="Play sounds" />
    </div>
  );
}

export function Disabled() {
  return (
    <div style={col}>
      <Switch checked disabled label="Managed by profile" />
      <Switch checked={false} disabled label="Unavailable" />
    </div>
  );
}

export function Bare() {
  return (
    <div style={{ display: "flex", gap: 16, alignItems: "center" }}>
      <Switch checked={false} />
      <Switch checked />
    </div>
  );
}
