import * as React from "react";
import { Slider } from "@glancekit/design-system";
import { SettingsRow } from "@glancekit/design-system";

const wrap: React.CSSProperties = { width: 240, display: "flex", flexDirection: "column", gap: 14 };

export function Values() {
  const [a, setA] = React.useState(30);
  const [b, setB] = React.useState(70);
  return (
    <div style={wrap}>
      <Slider value={a} onChange={setA} />
      <Slider value={b} onChange={setB} />
    </div>
  );
}

export function InARow() {
  const [v, setV] = React.useState(60);
  return (
    <div style={{ width: 320 }}>
      <SettingsRow title="Panel opacity" fillControl>
        <Slider value={v} onChange={setV} />
      </SettingsRow>
    </div>
  );
}

export function Disabled() {
  return (
    <div style={wrap}>
      <Slider value={45} disabled />
    </div>
  );
}
