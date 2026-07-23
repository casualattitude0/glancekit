import * as React from "react";
import { Button } from "@glancekit/design-system";

const row: React.CSSProperties = { display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" };

export function Variants() {
  return (
    <div style={row}>
      <Button variant="primary">Save</Button>
      <Button variant="secondary">Cancel</Button>
      <Button variant="plain">Learn more</Button>
      <Button variant="destructive">Reset all</Button>
    </div>
  );
}

export function Sizes() {
  return (
    <div style={row}>
      <Button variant="primary" size="small">Small</Button>
      <Button variant="primary" size="regular">Regular</Button>
      <Button variant="primary" size="large">Large</Button>
    </div>
  );
}

export function Disabled() {
  return (
    <div style={row}>
      <Button variant="primary" disabled>Save</Button>
      <Button variant="secondary" disabled>Cancel</Button>
    </div>
  );
}
